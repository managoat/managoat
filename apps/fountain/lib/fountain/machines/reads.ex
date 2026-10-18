defmodule Fountain.Machines.Reads do
  @moduledoc """
  Read admission: how a sandbox-files read takes part in the machine's
  ownership protocol (ADR 0039, ADR 0058, #2394).

  `Fountain.SandboxFiles` runs four fixed scripts on a machine through
  `Managoat.Sandbox.exec/4`. Until this module it decided whether it could on
  the struct its caller handed in — `status: "ready"` as of whenever the
  controller fetched the row — and then called the provider with nothing
  between that reading and the exec. A park or a destroy committing in that gap
  was not seen: the read ran against a machine being suspended or deleted, and
  on a provider whose exec wakes a suspended machine it woke it (#1715).

  A read is short, it leaves this node for the provider, and it must not be
  what keeps a machine from being reclaimed. Those three together decide the
  shape.

  ## Admission

  `run/3` admits a read in one short transaction under the machine's advisory
  lock (4316), the lock `Lease.claim/2` takes, and decides from the row read
  under it — never from the caller's struct, which is stale by construction
  (#2307 constraint 1):

    * a row that is not `ready` is refused `{:sandbox_not_ready, status}`, the
      word the API has always used — `suspended` is never woken for a read;
    * a row with **any** `transition` stamp is refused `:sandbox_unavailable`.
      `destroying` is durable intent and refused whatever its lease says (stage
      9a). A lapsed `parking` or `resuming` stamp is refused too, which is
      stricter than turn admission: a park that died after its suspend leaves a
      `ready` row over a suspended machine, and a read there is exactly the
      wake this refuses. The next park or sweep clears it;
    * a **live lease** is refused `:sandbox_unavailable` — an owner is mid-
      operation, and between its claim and its stamp the lease is all there is.

  An admitted read records itself in this node's table of reads (below) with
  an expiry of `window_ms/0` from now, **while it still holds the lock**, and
  only then lets the lock go. The lock is released before the provider is
  called: ADR 0058 keeps provider I/O out of every transaction and every
  advisory lock.

  ## Where admitted reads live

  In memory: a named public ETS table, one entry `{ref, sandbox_id,
  expires_at}` per admitted read, `expires_at` on this node's monotonic clock.
  `Fountain.Machines.Reads.Table` owns it and does nothing else.

  Until ADR 0072 this was a `sandbox_reads` row, because a park on one node
  had to see a read admitted on another. Fountain now runs as one node and two
  BEAMs never overlap (Recreate deploys), so every read a drain can be asked
  about was admitted in this BEAM, and a read admitted by an earlier boot died
  with it, as its machine lease did (`BootSweep`). The table starts empty at
  boot, which is the truth.

  The lock still orders the two. Nothing has to commit for a drain to see an
  entry: it is visible the moment it is inserted, and it is inserted before
  the claim can take the lock.

  An entry is not tied to its caller's process. The read's task outlives a
  caller that is killed, until its cutoff, so a monitor on the caller would
  let a drain through while the exec was still at the provider. The expiry is
  what bounds a dead caller's entry, exactly as it bounded its row.

  ## The two orders

  They are the same pair `Machines.Admission` argues for turns, read from the
  read's end. A park or destroy whose claim committed first has a live lease on
  the row, and the admission that waited on 4316 behind it reads that lease and
  refuses — the read never reaches the provider. A read admitted first has
  inserted its entry before the claim could take the lock, so the operation sees
  it: `drain/2`, which `Park` and `Destroy` call inside their lease and
  before any provider call, waits until every unexpired read on the machine
  has been released or has run out.

  No new read can be admitted while the drain waits, because the drain runs
  under the operation's live lease. So the wait is bounded by the longest
  window already admitted — `window_ms/0` — and a client polling the files API
  cannot hold a machine awake: it gets `503 sandbox_unavailable` for the length
  of the operation instead.

  ## The window, and what bounds it

  The window is only a promise if the read is really off the provider by the
  time it ends. `Managoat.Sandbox.exec/4`'s `:timeout` bounds how long the
  adapter *collects* output, not its synchronous startup (`ExecDeadline`'s own
  note), so it is not enough on its own. `run/3` therefore runs the caller's
  function in a task under `Fountain.TaskSupervisor` and kills it at a hard
  cutoff `@margin_ms` before the window ends. The cutoff is an absolute
  instant on the monotonic clock, taken from *before* the admission, so it
  always falls before the expiry the drain compares against, which is taken
  after it on the same clock. It is never turned into a relative budget until
  the task itself is running.

  The task, not its caller, enforces it. Starting a task waits on the
  supervisor, and the caller can die or be descheduled at any point after
  that. So the task starts its own watchdog, which sets an absolute timer for
  the cutoff and kills the task when it fires, and only then checks the
  clock. A task that starts after the cutoff returns without calling `fun`.
  A task that starts in time has its watchdog before its first provider call,
  so the kill comes at the cutoff however late the start was and whether or
  not the caller is still alive. A read that reaches the cutoff answers
  `{:sandbox_unreachable, :read_window_closed}`, the 503 an unreachable
  provider already gets.

  A read whose admission has already used up its budget — a caller descheduled
  between the commit and the exec, or a task the supervisor started late —
  does not start: `{:error, :sandbox_unavailable}` without a provider call. Nothing is queued anywhere; the admission runs in the
  caller, so a caller that has given up has nothing left to run later.

  **Release** is `after`, so a read that returns, fails or raises deletes its
  entry at once; so does an admission that refused or raised. A caller that is
  killed outright never runs it, and its entry expires: the drain waits out at
  most one window for it, and the next admission on the machine deletes it.

  ## What this does not promise

  Fountain does not begin a park's or a destroy's provider work while an
  admitted read's window is open, and it does not start a read on a machine an
  operation holds or has stamped. What happens *at the provider* after the
  local cutoff — a remote script still running after its connection was cut —
  is the provider's, and so is a machine the provider put to sleep by itself:
  an admitted read's exec wakes a sleeping sprite, and the E2B adapter resumes
  a sandbox paused on its timeout before it runs a command. ADR 0039's
  2026-10-15 addendum accepts that wake and records its cost (#2395).

  ## Why inline, not in the owner

  The same reason `Admission.end_turn/3` runs inline. Routing admission through
  `Machines.Machine` would queue a read behind a park's minute-long checkpoint
  only to refuse it afterwards, and the owner's mailbox would carry messages
  whose callers had long since gone. The advisory lock and the lease are the
  correctness; the owner's serialisation buys a read nothing.
  """

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  require Logger

  # How long an admitted read may be at the provider. Above the files API's
  # 30 s exec timeout by the margin below plus room for the admission itself.
  # `machine_bounds_test.exs` pins it between that timeout and the lease TTLs
  # of the two operations that drain it.
  @window_ms 40_000

  # How far before the window's end the local cutoff falls. The cutoff is
  # dated from before the admission and the expiry from inside it, on the same
  # clock, so the two are already ordered; the margin is for the kill itself
  # and for a drain polling on its own interval.
  @margin_ms 5_000

  # How often a drain re-reads the table.
  @poll_ms 100

  @table __MODULE__

  @doc """
  Admit a read on `sandbox_id`, run `fun` inside its window, and release it.

  `fun` receives the sandbox row as the admission read it — so the handle is
  built from the machine that was checked, not from the caller's struct — and
  the milliseconds it has left, which is at most `window_ms/0 - @margin_ms`. It
  runs in a task and is killed if it has not returned by then.

  Answers what `fun` answers, or a refusal: `{:sandbox_not_ready, status}`,
  `:sandbox_unavailable`, `:not_found`, or
  `{:sandbox_unreachable, :read_window_closed}` for a read cut off at the end
  of its window. `:window_ms` and `:task_supervisor` are test seams; no call
  site passes them.
  """
  @spec run(Ecto.UUID.t(), (Sandbox.t(), pos_integer() -> result), keyword()) ::
          result | {:error, term()}
        when result: term()
  def run(sandbox_id, fun, opts \\ [])
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    window = Keyword.get(opts, :window_ms, @window_ms)
    cutoff = System.monotonic_time(:millisecond) + window - margin_ms(window)

    if Repo.in_transaction?() do
      # The admission's lock would be held until that caller committed, and
      # the exec would run inside its transaction: ADR 0058 keeps provider I/O
      # out of both.
      {:error, :transaction_open}
    else
      read = make_ref()

      try do
        with {:ok, sandbox} <- admit(sandbox_id, read, window) do
          if System.monotonic_time(:millisecond) < cutoff do
            supervisor = Keyword.get(opts, :task_supervisor, Fountain.TaskSupervisor)
            bounded(supervisor, sandbox, cutoff, fun)
          else
            {:error, :sandbox_unavailable}
          end
        end
      after
        :ets.delete(@table, read)
      end
    end
  end

  @doc """
  Wait until no admitted read on `sandbox_id` is inside its window.

  For `Park` and `Destroy`, from inside their lease and before their
  provider call. Returns `:ok`; it never refuses, because reclamation must not
  be defeated by reads. The wait is bounded by the window: every read that can
  still be counted was admitted before the caller's claim, and none can be
  admitted while the caller's lease is live. `:read_window_ms` shortens that
  bound for a test.
  """
  @spec drain(Ecto.UUID.t(), keyword()) :: :ok
  def drain(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    bound = Keyword.get(opts, :read_window_ms, @window_ms) + @poll_ms
    started = System.monotonic_time(:millisecond)
    do_drain(sandbox_id, started, started + bound)
  end

  @doc "How long an admitted read may hold its machine. See the moduledoc."
  @spec window_ms() :: pos_integer()
  def window_ms, do: @window_ms

  @doc "How long before the window's end a read is cut off."
  @spec margin_ms() :: pos_integer()
  def margin_ms, do: @margin_ms

  @doc """
  How many reads on `sandbox_id` are inside their window right now. The
  drain's question, public for the suite.
  """
  @spec in_flight(Ecto.UUID.t()) :: non_neg_integer()
  def in_flight(sandbox_id) when is_binary(sandbox_id) do
    now = System.monotonic_time(:millisecond)
    :ets.select_count(@table, [{{:_, sandbox_id, :"$1"}, [{:>, :"$1", now}], [true]}])
  end

  # ── admission ─────────────────────────────────────────────────────────────

  defp admit(sandbox_id, read, window) do
    Conversations.with_sandbox_lock(sandbox_id, fn ->
      # Its lease and transition are its workspace's (ADR 0097, step 3b).
      row = Lease.get(sandbox_id)

      case row do
        nil -> {:error, :not_found}
        sandbox -> admissible(sandbox, read, window)
      end
    end)
  end

  defp admissible(%Sandbox{status: status}, _read, _window) when status != "ready",
    do: {:error, {:sandbox_not_ready, status}}

  defp admissible(%Sandbox{transition: transition} = sandbox, _read, _window)
       when not is_nil(transition) do
    Logger.info("sandbox files: read refused on #{sandbox.id}, row stamped #{transition}")
    {:error, :sandbox_unavailable}
  end

  defp admissible(%Sandbox{} = sandbox, read, window) do
    if Lease.live?(sandbox) do
      Logger.info(
        "sandbox files: read refused on #{sandbox.id}, lease held by #{sandbox.lease_node}"
      )

      {:error, :sandbox_unavailable}
    else
      insert(sandbox.id, read, window)
      {:ok, sandbox}
    end
  end

  # The entry, under the lock, and the leftovers of any caller that was killed
  # before it could release: those have expired, so no drain is waiting on
  # them, and this is the one place that meets them.
  defp insert(sandbox_id, read, window) do
    now = System.monotonic_time(:millisecond)
    :ets.select_delete(@table, [{{:_, sandbox_id, :"$1"}, [{:"=<", :"$1", now}], [true]}])
    true = :ets.insert_new(@table, {read, sandbox_id, now + window})
  end

  # ── the window ────────────────────────────────────────────────────────────

  # `async_nolink` so a raise in `fun` comes back as a value this process can
  # re-raise *after* its `after` has released the entry, rather than as a link
  # signal that kills the caller before it can.
  #
  # Unlinked also means the task outlives a caller that is killed, and that
  # caller's `yield` was the cutoff. `async_nolink` returns only after the
  # supervisor has started the task, which can be late, and the task is
  # already running by then. So nothing on the caller's side of that call can
  # be the cutoff: `guarded/3` arms it from inside the task, on the absolute
  # instant, before `fun` can run.
  defp bounded(supervisor, sandbox, cutoff, fun) do
    task = Task.Supervisor.async_nolink(supervisor, fn -> guarded(sandbox, cutoff, fun) end)
    await(task, sandbox, cutoff)
  end

  # The watchdog comes first and the clock check second. So by the time `fun`
  # runs, the kill is already set for the cutoff. The watchdog's timer is
  # absolute, so it fires at the cutoff however long the watchdog took to
  # start. If the watchdog only starts after the cutoff, the check below has
  # already refused the read.
  defp guarded(sandbox, cutoff, fun) do
    watchdog(self(), cutoff)

    case cutoff - System.monotonic_time(:millisecond) do
      budget when budget > 0 -> {:ran, fun.(sandbox, budget)}
      _spent -> :spent
    end
  end

  # Not linked, so a task that returns first does not take the watchdog with
  # it, and the watchdog does not depend on the caller. It lives until the
  # task is gone or the cutoff fires, whichever comes first.
  defp watchdog(task, cutoff) do
    spawn(fn ->
      ref = Process.monitor(task)
      :erlang.start_timer(cutoff, self(), :cutoff, abs: true)

      receive do
        {:DOWN, ^ref, :process, ^task, _reason} -> :ok
        {:timeout, _timer, :cutoff} -> Process.exit(task, :kill)
      end
    end)
  end

  defp await(task, sandbox, cutoff) do
    wait = max(cutoff - System.monotonic_time(:millisecond), 0)

    case Task.yield(task, wait) || Task.shutdown(task, :brutal_kill) do
      {:ok, {:ran, result}} ->
        result

      # The task started after the cutoff and never called `fun`.
      {:ok, :spent} ->
        {:error, :sandbox_unavailable}

      # The watchdog and the `yield` share one deadline, so the watchdog can
      # win by a hair; its kill is the cutoff, not a crash.
      {:exit, :killed} ->
        cut_off(sandbox)

      {:exit, reason} ->
        exit(reason)

      nil ->
        cut_off(sandbox)
    end
  end

  defp cut_off(sandbox) do
    Logger.warning("sandbox files: read on #{sandbox.id} cut off at the end of its window")

    {:error, {:sandbox_unreachable, :read_window_closed}}
  end

  # A window too short to hold the margin — only a test's — keeps a fifth of
  # itself as margin instead.
  defp margin_ms(window) when window > 2 * @margin_ms, do: @margin_ms
  defp margin_ms(window), do: div(window, 5)

  # ── the drain ─────────────────────────────────────────────────────────────

  defp do_drain(sandbox_id, started, deadline) do
    pending = in_flight(sandbox_id)

    cond do
      pending == 0 ->
        waited = System.monotonic_time(:millisecond) - started

        if waited >= @poll_ms,
          do: Logger.info("machine #{sandbox_id}: waited #{waited} ms for reads to finish")

        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        Logger.warning(
          "machine #{sandbox_id}: reads still counted past their window (#{pending}); " <>
            "proceeding"
        )

        :ok

      true ->
        Process.sleep(@poll_ms)
        do_drain(sandbox_id, started, deadline)
    end
  end

  defmodule Table do
    @moduledoc """
    Owns the table of admitted reads (`Fountain.Machines.Reads`) and does
    nothing else, so that nothing it does can crash and take the table with it.
    Started before the machine owners and the endpoint, where every drain and
    every admission comes from.
    """
    use GenServer

    def start_link(opts),
      do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

    @impl true
    def init(:ok) do
      :ets.new(Fountain.Machines.Reads, [:named_table, :public, :set, write_concurrency: true])
      {:ok, nil}
    end
  end
end
