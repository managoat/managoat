defmodule Fountain.Machines.Machine do
  @moduledoc """
  The owner of one workspace's machine (ADR 0058, keyed by workspace by
  ADR 0097).

  One process per *active* workspace, registered in `Fountain.MachineRegistry`
  under the workspace id and supervised by `Fountain.MachineSupervisor`, both
  local to the one node Fountain runs as (ADR 0072). It idle-stops after
  a minute with nothing asked of it, and `ensure_started/1` brings it back:
  there is a process per active workspace, not one per row.

  Every verb still names the machine by its sandbox id, because every caller
  is about one machine, and the owner it reaches is that sandbox's
  workspace's (`owner_key/1`): the message carries the sandbox id and the
  protocol runs on it. Today a workspace has one sandbox, so this is still one
  owner per machine and per conversation; it is what lets a later step
  rebuild a lost machine without a second owner. A sandbox with no workspace,
  which only a row retired before ADR 0097 is, is served by a process of its
  own under its sandbox id, which the protocols answer as the terminal row it
  is (`Fountain.Machines.Lease.unowned/1`).

  Fourteen verbs so far. `who_is_here/1` returns the
  `Fountain.Machines.Occupancy` struct and reads nothing else. `destroy/2`,
  `park/2` and `ensure_up/2` run `Fountain.Machines.Destroy.run/2`,
  `Fountain.Machines.Park.run/2` and `Fountain.Machines.Resume.run/2` — three of
  the five protocols, lease and all. `provision/3`, `confirm_up/2` and
  `fail_provision/2` are the fourth, `Fountain.Machines.Provision`, which builds
  a machine, confirms one a server is reattaching to, and retires one whose
  provisioning is not going to happen. `admit_turn/3` and `end_turn/3` are
  the fifth, `Fountain.Machines.Admission` (stage 8a): the locked turn insert
  with the live-lease refusal decided under its lock, and the one door every
  turn-ending write an actor makes comes through. Between them they are
  everything here that writes: the row through `Fountain.Machines.Lease`, the
  provider through `Managoat.Sandbox.create/2`, `destroy/1`, `suspend/1` and
  `resume/1`, the turn rows through the context's locked writers, and one
  `sandbox.destroyed`, `sandbox.suspended`, `sandbox.resumed`,
  `sandbox.provisioned` or `sandbox.provision_failed` audit event. `detach/2`
  is the sixth, `Fountain.Machines.Binding` (stage 8b): the detach is decided
  under the machine's lock and refuses its lease. (`attach/3`, which put a
  second conversation on a machine, and the Codex auth binding went with
  persistent homes, #2676. `record_skills/2`, which wrote the machine's
  skills record, went with config homes, ADR 0097: the record is the
  conversation's.)

  Beside them is one predicate, `busy?/1` (stage 6a): whether an owner holds a
  live lease on a machine, from the row the caller already holds. It is the
  question every reader that was about to start work on a machine now asks
  first, and the answer it turns into is `:sandbox_unavailable`. It reads no
  database: a lease is live while its holder process of this boot is alive
  (ADR 0072).

  ## Which verbs run here

  `destroy/2`, `park/2`, `ensure_up/2`, `admit_turn/3` and `detach/2` are
  calls into this process, so two operations on one machine
  queue behind one another in its mailbox. The thing that makes a destroy safe
  against a concurrent destroy is still the lease on the row, not the mailbox
  in front of it: two owners can exist for a moment across a rolling deploy,
  and the lease is what makes the second one's write invisible. The process is
  an optimization of the contention, not the correctness. Until stage 9b a
  runtime flag, `MACHINE_OWNER_ENABLED`, could run the same protocols inline
  on the caller instead; stage 9b deleted it.

  **The provision verbs are the exception, and they say so.** `provision/3`,
  `confirm_up/2` and `fail_provision/2` run inline on their caller. The first
  is why: its callback is the
  `ConversationServer`'s own pipeline, which builds that server's state and runs
  for minutes, and running it inside this process would both move the pipeline
  out of the server (ADR 0037, #1369) and occupy the owner past every timeout in
  this tree. The other two follow it so that one verb family has one answer.
  `Fountain.Machines.Provision`'s moduledoc argues it in full; what makes it
  sound is the paragraph above — the lease is the correctness, the mailbox is
  the optimization — and the contention a provision has is a duplicate server,
  which the lease refuses in one round trip.

  **`end_turn/3` is the other exception** (stage 8a), and for the opposite
  reason: it is not a machine operation at all. It ends a turn — a write to the
  conversation's rows under their own locks, with no provider call and no
  machine state changed — and the owner's view of admitted turns is those rows,
  read under its lease when a park or a destroy needs them. Queueing a turn's
  end behind a cotenant's minute-long park would hold a server's `terminate/2`
  or adapter-exit path in a `GenServer.call`, and a timeout there leaves the
  turn `running` with nothing left to end it. `Fountain.Machines.Admission`'s
  moduledoc argues it; the fence it applies is the same either way.

  Asking through a process for an answer available from a pure function looks
  like ceremony, and it is the point: `who_is_here/1` is the door every writer
  comes through, so the answer and the writes that follow it share one
  process.

  ## The read that walks past a busy owner

  A GenServer is serial, so a destroy occupies this process for as long as it
  takes, and a `who_is_here/1` that arrives meanwhile waits behind it. Past
  `@call_timeout` that read gives up, logs, and reads `Occupancy` directly —
  correct, because the verb is read-only and a slightly late reading of who is
  on a machine harms nobody. Stage 4 wrote here that the fallback would have to
  go before `admit_turn` landed, on the reasoning that a writer deciding on the
  struct would be two owners again. Stage 8a's admission does not decide on the
  struct: it re-reads the machine's row and counts the running turns **under
  the advisory lock, inside its own transaction**, and it refuses rather than
  falls back when the owner cannot be reached, exactly as
  `destroy/2` does. So the fallback stays where it is, for the one verb that
  only looks; stage 8b's `detach/2` is held to the same rule as
  `admit_turn/3` — it decides under the lock, and refuses rather than falls
  back when the owner cannot be reached.

  ## The messages that carry a deadline

  A `GenServer.call` that times out leaves its message in the mailbox (stage
  8a round 1), so a verb whose late run would create state for a caller that
  has been told 503 carries that caller's deadline on the database clock and
  the owner refuses an expired one before running it. Two do: `admit_turn/3`
  (a turn row) and `detach/2` (a fence that closes a machine to admission
  with a server still serving on it). Since
  stage 8b `ensure_up/2` does too: a late resume was a machine brought up for
  nobody and billed until the idle bound collected it — collected, not leaked
  for good, but a cost with no one to pay for it. `destroy/2` and `park/2` do
  not, because a late run of either is idempotent: a destroy of a destroyed
  machine is `{:ok, :already_terminal}` to nobody, and a park re-checks under
  its lease that the machine is still idle.
  """

  # `:transient` — an idle-stop exits `:normal` and the supervisor leaves it stopped,
  # which is what makes this one process per *active* machine; an abnormal
  # exit is restarted, and the replacement then holds a registry slot for a
  # full idle window although nobody asked it anything. That is the right
  # trade from stage 5 on, when the owner holds a lease it must reclaim, and
  # it is merely harmless now, when it holds nothing.
  use GenServer, restart: :transient

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Turn
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Park
  alias Fountain.Machines.Provision
  alias Fountain.Machines.Resume
  alias Fountain.Repo

  # Long enough that a burst of questions about one machine — a lifecycle
  # check, a reaper pass and a park decision inside the same minute — reuses
  # one process; short enough that a machine nobody has asked about leaves no
  # process behind. Overridable per process for the tests that drive it.
  @idle_ms 60_000

  # The call is one to three indexed reads. A timeout longer than the default
  # would only ever hide a repo that is already in trouble.
  @call_timeout 15_000

  # A destroy is a provider round trip plus four short transactions, and it may
  # wait out another destroy's lease first — `Destroy.busy_wait_ms/0`, five
  # seconds. This has to sit clearly *above* that bound and clearly *below*
  # `conversation_call_timeout_ms` (30s), the ceiling a `ConversationServer`'s
  # own client gives up at. Equal to the protocol's bound, a destroy that waits
  # its full wait races this timeout and a success gets reported as a failure;
  # equal to the client's, a caller learns nothing before its own caller has
  # given up. `machine_bounds_test.exs` pins the ordering.
  @destroy_timeout 20_000

  # One consequence worth stating, because it is asymmetric and a caller feels
  # it: a destroy waits `Destroy.busy_wait_ms/0` — five seconds — for a lease
  # that a *park* holds for the whole park. So an admin reap
  # (`POST /api/admin/sandboxes/:id/reap`) that lands on a machine mid-park
  # answers 503 `sandbox_unavailable` rather than queueing behind it, and the
  # caller tries again. That is the trade `machine_bounds_test.exs` spells out
  # — the wait bounds the *caller*, who is a person, and a park that outlives
  # it is not a reason to hold a web request open.
  #
  # A park is a longer operation than a destroy and sits under a different
  # ceiling. Longer, because a home checkpoint is a provider round trip with
  # `Managoat.Sandbox.Retry`'s backoff behind it and the suspend follows it.
  # A different ceiling, because neither caller is a request: the conversation
  # server's park runs inside the server itself, from its own
  # `:lifecycle_check` message, so `call_server/2`'s 30s — the bound a
  # *client* of that server waits — is not over it, and the reaper's pass has
  # no client at all. What this does have to sit above is
  # `Park.busy_wait_ms/0`: a caller that gives up before the protocol's own
  # wait would report a refusal that had not happened yet.
  # `machine_bounds_test.exs` pins the ordering.
  @park_timeout 60_000

  # Prompt and explicit wakes run in background work (#2561). Let that caller
  # wait through the readiness budget rather than report wake/failed and drop
  # its queued prompt while the owner is still proving readiness. This allows
  # the 5s lease wait, provider lookup, 60s probe and SDK startup overrun.
  # Direct internal callers use the same ceiling; HTTP wakes still return
  # waking/queued immediately. SDK error-body streaming has only an inactivity
  # timeout, so this remains a caller bound, not a forced kill of the owner.
  @resume_timeout 120_000

  # An admission is one transaction that may first wait out a live lease —
  # `Admission.busy_wait_ms/0`, five seconds — so it takes the destroy's
  # ceiling for the destroy's reasons: clearly above the protocol's own wait,
  # so a caller never reports a refusal the protocol has not reached, and
  # clearly below `conversation_call_timeout_ms` (30s), because this caller
  # **is** a request: `TurnMachine.open/6` runs inside the server's
  # `handle_call` for the prompt, and the person who sent it is waiting on the
  # other side. An admission takes no lease of its own (see
  # `Fountain.Machines.Admission`). `machine_bounds_test.exs`
  # pins the ordering.
  #
  # **It bounds the caller's wait, not the queue** — and for this verb that
  # difference is a write (round 1, protocol and behaviour reviews). A
  # `GenServer.call` that times out leaves its message in the mailbox, and the
  # owner runs it when it gets there. For a destroy or a park a late run is
  # idempotent; for a resume it is a machine brought up for nobody (see the
  # `:ensure_up` clause); for an admission it is a turn row the prompt was
  # told does not exist — a `running` turn on a machine that has since been
  # parked, which nothing ends. So the message carries the caller's deadline
  # on the database clock (`db_now/0`, the clock the locked insert reads the
  # row with) and the owner refuses an admission whose deadline
  # has passed: once before it runs the protocol, and once more inside the
  # locked insert, against the clock it read the machine's row with. What
  # that bounds is the row *read*: a commit can still land one transaction
  # tail after the deadline (no lock wait sits in that tail; milliseconds in
  # practice). Closing the tail would mean the caller's `:timeout` arm going
  # back for a turn with its own `attrs`, not another clock read.
  @admit_timeout 20_000

  # A detach is the teardown fence with a terminating conversation — one
  # transaction — after waiting out a live lease for `Binding.busy_wait_ms/0`
  # (5s), so it takes the destroy's ceiling for the destroy's reasons: clearly
  # above the protocol's wait and clearly below `conversation_call_timeout_ms`,
  # because the caller is a request (a `DELETE`, or the server's own
  # `handle_call` for one). Deadline-carrying, as above. `machine_bounds_test.exs`
  # pins the ordering.
  @detach_timeout 20_000

  # ── public api ────────────────────────────────────────────────────────────

  @doc false
  def start_link(args) do
    key = Keyword.fetch!(args, :key)
    GenServer.start_link(__MODULE__, args, name: via(key))
  end

  @doc """
  How long a caller waits on the owner for a destroy.

  Public so `machine_bounds_test.exs` can pin it between
  `Destroy.busy_wait_ms/0` below it and `conversation_call_timeout_ms` above.
  """
  @spec destroy_timeout_ms() :: pos_integer()
  def destroy_timeout_ms, do: @destroy_timeout

  @doc """
  How long a caller waits on the owner for a park.

  Public so `machine_bounds_test.exs` can pin it above `Park.busy_wait_ms/0`.
  """
  @spec park_timeout_ms() :: pos_integer()
  def park_timeout_ms, do: @park_timeout

  @doc """
  How long a caller waits on the owner for a resume.

  Public so `machine_bounds_test.exs` can pin it above the lease wait,
  provider lookup, exec readiness budget and synchronous startup allowance.
  """
  @spec resume_timeout_ms() :: pos_integer()
  def resume_timeout_ms, do: @resume_timeout

  @doc """
  How long a caller waits on the owner for a turn admission.

  Public so `machine_bounds_test.exs` can pin it between
  `Admission.busy_wait_ms/0` below it and `conversation_call_timeout_ms` above.
  """
  @spec admit_timeout_ms() :: pos_integer()
  def admit_timeout_ms, do: @admit_timeout

  @doc """
  How long a caller waits on the owner for a detach.

  Public so `machine_bounds_test.exs` can pin it between
  `Binding.busy_wait_ms/0` below it and `conversation_call_timeout_ms` above.
  """
  @spec detach_timeout_ms() :: pos_integer()
  def detach_timeout_ms, do: @detach_timeout

  @doc "The registered name of the owner registered under `key` (see `owner_key/1`)."
  @spec via(String.t()) :: {:via, module(), {module(), String.t()}}
  def via(key), do: {:via, Registry, {Fountain.MachineRegistry, key}}

  @doc """
  The registry key of the owner of the machine behind `sandbox_id`: its
  workspace's id (ADR 0097, step 3b), or the sandbox's own for a sandbox
  with no workspace or no row. One indexed read, without a lock: a live
  sandbox's workspace does not change (see `Fountain.Machines.Lease`).
  """
  @spec owner_key(String.t()) :: String.t()
  def owner_key(sandbox_id) when is_binary(sandbox_id) do
    case Ecto.UUID.cast(sandbox_id) do
      {:ok, _} ->
        Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, select: s.workspace_id) ||
          sandbox_id

      :error ->
        sandbox_id
    end
  end

  @doc """
  The pid of the owner of the machine behind `sandbox_id`, or `nil` when none
  is registered.
  """
  @spec whereis(String.t()) :: pid() | nil
  def whereis(sandbox_id) when is_binary(sandbox_id),
    do: sandbox_id |> owner_key() |> whereis_key()

  defp whereis_key(key) do
    case Registry.lookup(Fountain.MachineRegistry, key) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  @doc """
  The owner of the machine behind `sandbox_id`, started if it is not running.

  Tolerates the start race: a concurrent start returns
  `{:error, {:already_started, pid}}`, and the winner is the owner.
  `opts` are passed to the child, which is how a test shortens `:idle_ms`.
  """
  @spec ensure_started(String.t(), keyword()) :: {:ok, pid()} | {:error, term()}
  def ensure_started(sandbox_id, opts \\ []) when is_binary(sandbox_id) do
    key = owner_key(sandbox_id)

    case whereis_key(key) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_child(key, opts)
    end
  end

  @doc """
  Who is on `sandbox_id`: bound conversations, whose servers are live, which
  are mid-turn and on what runtime, and when the machine last saw activity.

  Always an `Occupancy` struct. It is served by the owner, so the answer and
  the writes that follow it share one process; if the owner cannot be started
  or reached, it is read directly. That fallback is deliberate: this verb is read-only, so a machine with no process
  is not a reason to fail a caller that only wanted to look.
  """
  @spec who_is_here(String.t()) :: Occupancy.t()
  def who_is_here(sandbox_id) when is_binary(sandbox_id) do
    ask_owner(sandbox_id, 1)
  end

  @doc """
  Is an owner mid-operation on this machine, right now (ADR 0058 stage 6a)?

  **A live lease, and nothing else.** `Fountain.Machines.Lease.live?/1`: a
  holder process of this boot that is still alive. That is the same question
  `Lease.claim/2` answers when it refuses a claimant, so a reader and a
  claimant cannot disagree about who owns a machine.

  The readers that ask are the three that would otherwise start work on the
  machine underneath its owner: `Wake.maybe_reuse_sandbox/1`,
  `Machines.Binding.attachable/6` and `Rehydrator`'s boot sweep. Each turns `true`
  into the refusal the system already has, `:sandbox_unavailable` — 503 with a
  `Retry-After: 30`, `NotReadyError` in the SDK, retried by the
  caller. Thirty seconds is an honest number precisely
  because this is a *live* operation: one provider round trip, and the machine
  settles.

  **A stamped `transition` is deliberately not enough** (round 1, surfaces
  review). It was, in the first draft of this function, and it was wrong. A
  `transition` with no live lease is not an owner working — it is an owner that
  *died* mid-operation, and nothing resolves that row until a sweep gives up on
  it: `SandboxReaper.sweep_fenced_teardowns/0`, then on the hourly cron, or
  `SandboxResetReconciler` every five minutes (stage 9b made the first the
  only one, every five minutes). Treating it as busy meant every
  wake and attach onto an abandoned destroy answered 503 for between 16 and 75
  minutes, where `main` probed the provider, found the machine gone and handed
  the caller a fresh one immediately, and a queued start could expire in that
  window. `sweep_fenced_teardowns/0` calls such
  a row abandoned in as many words; two readers of one row must not disagree
  about it.

  So a stamped transition on a lease-less row reads exactly as it does on
  `main`: the wake probes, the attach checks identity, the boot sweep starts a
  server. Stage 6b's park takes a lease for the length of its checkpoint and
  suspend, so a park in flight is refused here; a *stale* `parking` row left by
  a dead owner is resolved by the park protocol's own takeover, from the owner's
  side, which is where an abandoned operation belongs.

  Takes a `Sandbox` the caller has already read, so the row costs no query.

  **One thing it deliberately does not do.** It says nothing about a terminal row, and callers must decide that first. A
  finalize writes `terminated` and releases the lease as two statements, so
  `terminated` with a live lease is a real, momentary state, and it means the
  machine is gone — which is a fresh machine, not a retry. Every caller here
  checks the terminal statuses before it asks.
  """
  @spec busy?(Sandbox.t() | map()) :: boolean()
  def busy?(sandbox), do: Lease.live?(sandbox)

  @doc """
  The database's clock, for the deadlines a caller hands the owner with an
  admission, an attach, a detach or a resume. The locked writes those verbs
  make compare the deadline against `statement_timestamp()`, so the deadline
  is drawn from the same clock.
  """
  @spec db_now() :: DateTime.t()
  def db_now do
    %Postgrex.Result{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT statement_timestamp()")
    now
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "database clock unreachable (#{inspect(error.__struct__)}); using this node's"
      )

      DateTime.utc_now()
  end

  @doc """
  Destroy the machine behind `sandbox_id`: `Fountain.Machines.Destroy.run/2`,
  run inside the owner. `opts` are the protocol's, documented there.

  **This is the door, so this is where the protocol's vocabulary becomes the
  system's.** `Destroy` answers precisely — `:machine_busy`, `:superseded`,
  `{:database, sqlstate}` — and those words are for the log and for this
  module. A caller of this function gets one of the two outcomes or an atom
  the rest of Fountain already knows, because the answer travels: a terminate
  runs on a request process, and `FountainWeb.FallbackController` renders
  whatever comes out of it. A tuple has no clause there at all (a 500), and a
  retryable refusal rendered as an unmapped 422 is worse than one rendered as
  the 503 `:sandbox_unavailable` already is.

  **And `:sandbox_unavailable` is the refusal, for good** (Jake, stage 6a).
  The ADR spoke of "one retryable refusal added to every transient-error
  vocabulary at once", and 5a wrote here that stage 6 would add it. Stage 6a
  looked at what a new word would buy and decided it was nothing: a wake or an
  attach that meets a machine mid-operation means exactly what a refused
  destroy means — come back shortly — and `:sandbox_unavailable` is already
  503 with a `Retry-After` and `NotReadyError` in the SDK. A second word would have to be
  taught to five clients (#2304, written and closed unmerged) to say the same
  thing. See `refusal/2`.

  Unlike `who_is_here/1` there is no falling back to a direct read when the
  owner cannot be reached. That verb only looked; this one writes, and a write
  that was refused a place to run has to say so rather than find another one.
  """
  @spec destroy(String.t(), keyword()) ::
          {:ok, Destroy.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open}
  def destroy(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # Checked here, not only in the protocol. `Destroy.run/2`'s own guard is
      # process-local, and it runs in the owner — which is never inside this
      # caller's transaction — so it cannot fire. Worse than
      # useless there: the owner's `Lease.claim` would block on the
      # machine advisory lock this open transaction holds, while the
      # caller blocks in `GenServer.call` until `@destroy_timeout`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      true ->
        sandbox_id |> destroy_in_owner(opts, 1) |> refusal(sandbox_id, :destroy)
    end
  end

  @doc """
  Park the machine behind `sandbox_id`: `Fountain.Machines.Park.run/2`, run
  inside the owner. `opts` are the protocol's, documented there.

  The door for the second verb, on the same terms as `destroy/2` above: the
  protocol answers precisely and this translates. Three of its words travel,
  because each one tells its caller to do something different and
  `:sandbox_unavailable` would tell it to do nothing:

    * `:cannot_park` — this provider has no `:suspend`, so an idle machine on
      it keeps billing. Both callers destroy instead (ADR 0017's degradation,
      which used to be decided by `Lifecycle.idle_action/1` at each site and is
      now decided once, under the lease).
    * `:suspend_failed` — the provider was asked and would not. Same
      degradation, same reason: a park call that fails leaves the machine
      billing.
    * `:machine_occupied` — somebody is on the machine. Neither caller
      degrades: a machine in use is not reclaimed at all, which is what
      `Lifecycle.busy_elsewhere?/2` has always done at the server and what the
      reaper's liveness scan has always done in the sweep.
    * `:fenced` — a reset or a teardown has been asked for, so this machine is
      going away and there is nothing to park. Both callers stop bothering with
      it rather than retrying: the fence's own owner finishes the job, and
      `SandboxReaper.sweep_fenced_teardowns/0` is the backstop if it dies.
    * `:not_expired` — the verdict the caller brought has gone stale and the
      machine is no longer past a bound. Only a caller that supplies a
      `:verdict` can receive it, and the one that does counts it apart from a
      refusal: a sweep that was wrong and was told so is constraint 1 working,
      not a machine it failed to reclaim.

  Everything else is a refusal to act on right now — contention for the lease,
  a fence, a verdict gone stale, a database fault — and reads as
  `:sandbox_unavailable`. `:superseded` is `{:ok, :already_parked}`: another
  owner holds the machine and is the one that says what happened to it, and
  from here it is parked or parking.
  """
  @spec park(String.t(), keyword()) ::
          {:ok, Park.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open
             | :cannot_park
             | :suspend_failed
             | :machine_occupied
             | :fenced
             | :not_expired}
  def park(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # As in `destroy/2`: the protocol's own guard is process-local and cannot
      # fire in the owner, and an open transaction here would have the owner's
      # `Lease.claim` block on the advisory lock this caller holds.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      true ->
        sandbox_id |> park_in_owner(opts, 1) |> refusal(sandbox_id, :park)
    end
  end

  @doc """
  Bring the machine behind `sandbox_id` up: `Fountain.Machines.Resume.run/2`,
  run inside the owner. `opts` are the protocol's, documented there.

  The door for the third verb, on the same terms as `destroy/2` and `park/2`:
  the protocol answers precisely and this translates. **This one lets the most
  words through**, and each is a different thing for the waking caller to do:

    * `:sandbox_reset_pending` — a reset or a teardown has been asked for, so
      there is nothing to wake. **Translated here**, from the protocol's
      `:fenced`, and it is the one refusal of the three verbs that had to be:
      `Park`'s `:fenced` is read by a conversation server and a sweep, which
      handle it and never put it on the wire, while this one travels all the way
      out of a prompt. Unmapped it rendered as `422 {"error": "fenced"}` through
      `FallbackController`'s terminal safety net, and a schedule's `last_error`
      read `:fenced` verbatim (round 1, surfaces review). `:sandbox_reset_pending`
      is what `main` answers for the fence it did check — 409, "Fountain
      completes it, and sending it again answers sandbox_reset_pending" — and it
      is right for both fences, because both write the same `destroying`
      stamp.
    * `:provisioning` — the machine is still being built. `main`'s word,
      unchanged, and the caller waits for the registry rather than the machine
      (#800).
    * `:sandbox_resume_failed` — the provider was asked and would not. `main`'s
      word, and the protocol's `:resume_failed` is translated to it here so the
      surfaces that already know it do not have to learn a second.
    * the admission's own refusal, `:fleet_full` — the fleet ceiling, exactly
      as `Quotas.with_sandbox_reservation/2` answers it on this path. It is a
      503, and flattening it to `:sandbox_unavailable` would hide that the
      limit was hit.

  Everything else is a refusal to act on right now — contention for the lease, a
  database fault, an unreachable owner — and reads as `:sandbox_unavailable`.
  `:superseded` is `{:ok, :already_up}`: another owner holds the machine and is
  the one that says what happened to it, and from here it is up or coming up.

  **A resume is not attempted at all on a machine that does not need one.** A
  `ready` row is `{:ok, :already_up}` and a terminal one `{:ok, :already_terminal}`,
  both without a provider call, so a caller may ask unconditionally — which is
  what makes this `ensure_up` rather than `resume`.
  """
  @spec ensure_up(String.t(), keyword()) ::
          {:ok, Resume.outcome()}
          | {:error,
             :sandbox_unavailable
             | :not_found
             | :provider_transaction_open
             | :sandbox_reset_pending
             | :provisioning
             | :sandbox_resume_failed
             | :fleet_full}
  def ensure_up(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    cond do
      # As in `destroy/2` and `park/2`: the protocol's own guard is
      # process-local and cannot fire in the owner, and an open transaction here
      # would have the owner's `Lease.claim` block on the advisory lock this
      # caller holds while the caller blocks in `GenServer.call`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      true ->
        sandbox_id |> resume_in_owner(opts, 1) |> refusal(sandbox_id, :ensure_up)
    end
  end

  @doc """
  Build the machine behind `sandbox_id`, running `fun` as the pipeline:
  `Fountain.Machines.Provision.run/3`, inline on the caller (see the
  moduledoc). `opts` are the protocol's, documented there.

  The door for the fourth protocol, and the one whose caller is not a request
  but a `ConversationServer` deciding whether it has a machine to work on. So
  the translation is narrower than `ensure_up/2`'s: almost every word travels,
  because each tells the server something different to do, and the two that do
  not are the two that mean *somebody else has this row*:

    * `:machine_busy` and `:superseded` become `{:ok, :claimed_elsewhere}`.
      Another server holds the machine — a duplicate, or a successor that
      took over an abandoned attempt — and the honest instruction to this one is
      to stop without touching anything. It is the same answer `main` reached by
      a different route: `claim_sandbox/2` answered `:retired` and the server
      stopped `:normal`.
    * `:fenced` becomes `:sandbox_reset_pending`, the word the server's own
      arms already match on and the one `update_sandbox/2` rolled back with when
      a reset fence landed mid-provision.

  Everything else — `:configuration_changed`, the pipeline's own reason, a
  `{:database, sqlstate}` — reaches the caller as itself, because the server
  decides on it: whether to fail the conversation, and what to publish on the
  `provision` stage.
  """
  @spec provision(String.t(), Provision.pipeline(), keyword()) ::
          {:ok, :provisioned, term()}
          | {:ok, :already_terminal | :claimed_elsewhere}
          | {:ok, :already_terminal | :claimed_elsewhere, term()}
          | {:error, term()}
          | {:error, term(), term()}
  def provision(sandbox_id, fun, opts)
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.run(fun, opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Rebuild the lost machine behind `sandbox_id` in its workspace, under one
  lease: `Fountain.Machines.Provision.rebuild/3`, inline on the caller, as
  `provision/3` is and for its reasons. Not called by anything yet (ADR 0097:
  step 4 wires it to the lifecycle). Its answers are `provision/3`'s, plus
  `{:ok, :rebuilt, sandbox, result}`.
  """
  @spec rebuild(String.t(), Provision.pipeline(), keyword()) ::
          {:ok, :rebuilt, Sandbox.t(), term()}
          | {:ok, :claimed_elsewhere}
          | {:error, term()}
          | {:error, term(), term()}
  def rebuild(sandbox_id, fun, opts)
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.rebuild(fun, opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Build the machine behind `sandbox_id` with no conversation on it: the
  machine-level steps of `setup` (`Fountain.Machines.Setup`) as the pipeline
  of `Fountain.Machines.Provision.run/3`, inline on the caller.

  **The seam explicit workspaces will use** (ADR 0097, "An explicit workspace
  is provisioned on create"; step 5). Nothing calls it yet. The owner's
  lease, the create, the `ready` or `failed` finalize, the workspace's status
  and the audit event are the bracket's, exactly as for a conversation's
  provision; what it adds is that no `ConversationServer` is involved. The
  actor defaults to `"system:machine"`.
  """
  @spec set_up(String.t(), Fountain.Machines.Setup.t(), keyword()) ::
          {:ok, :provisioned, :set_up}
          | {:ok, :already_terminal | :claimed_elsewhere}
          | {:error, term()}
          | {:error, term(), term()}
  def set_up(sandbox_id, %Fountain.Machines.Setup{} = setup, opts \\ [])
      when is_binary(sandbox_id) and is_list(opts) do
    provision(
      sandbox_id,
      Fountain.Machines.Setup.pipeline(setup),
      Keyword.put_new(opts, :actor, "system:machine")
    )
  end

  @doc """
  Confirm the machine behind `sandbox_id` is still this server's to attach to:
  `Fountain.Machines.Provision.confirm_up/2`. Inline, as `provision/3`.

  The reattach arm's half of the same door. `{:ok, :confirmed}` is a live row
  this server may attach to; `{:ok, :already_terminal}` and
  `{:error, :sandbox_reset_pending}` are the two ways retirement won while the
  provider was answering, which are exactly the two answers `main`'s
  `claim_sandbox/2` gave here. `{:ok, :claimed_elsewhere}` is the duplicate
  server again.
  """
  @spec confirm_up(String.t(), keyword()) ::
          {:ok, :confirmed | :already_terminal | :claimed_elsewhere} | {:error, term()}
  def confirm_up(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.confirm_up(opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Retire the machine behind `sandbox_id`, whose provisioning is not going to
  happen: `Fountain.Machines.Provision.fail/2`. Inline, as `provision/3`.

  For the callers that have to fail a row they never brought under a lease — the
  server's two pre-flight failures, a start that would not start, and the
  provisioning watchdog at its deadline. `{:ok, :not_provisioning}` and
  `{:ok, :already_terminal}` both mean there was nothing to retire, which is not
  an error at any of them.

  **The watchdog's caller should read the answer rather than assume it** (#394):
  the row has to be terminal before a stuck server is killed, and a refusal here
  means it is not. A refusal is not a place to stop, either —
  `Conversations.ProvisionWatchdog` retries it and then falls back to stopping
  the server anyway, because the pass that would otherwise collect the row
  (`SandboxReaper.release_stuck_sandboxes/0`) skips rows whose server is alive,
  which is every row this refusal can be about.
  """
  @spec fail_provision(String.t(), keyword()) ::
          {:ok, :failed | :already_terminal | :not_provisioning | :claimed_elsewhere}
          | {:error, term()}
  def fail_provision(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      sandbox_id |> Provision.fail(opts) |> provision_refusal(sandbox_id)
    end
  end

  @doc """
  Admit a turn on the machine behind `sandbox_id`:
  `Fountain.Machines.Admission.run/3`, run inside the owner. `attrs` is the turn row; `opts` are the protocol's, documented there.

  The door for the fifth protocol, and the one whose vocabulary is almost
  entirely the caller's already. The locked insert answers in the words
  `TurnMachine.open_turn/5` and `Connection.open_autonomous_turn/4` have
  matched on since long before ADR 0058 — `:not_running`,
  `:sandbox_unavailable`, the inference-source refusals,
  a changeset — and every one of them travels as itself, because each tells the
  server something different to publish. Two words are the protocol's and are
  translated here: `:machine_busy` (a live lease on the machine, already waited
  out for `Admission.busy_wait_ms/0`) and an unreachable owner both become
  `:sandbox_unavailable`, the 503 with a `Retry-After` that means "come back
  shortly" everywhere else in this module.

  Like `destroy/2` and unlike `who_is_here/1`, there is no falling back to an
  inline run when the owner cannot be reached: this verb writes, and a write
  refused a place to run says so.
  """
  @spec admit_turn(String.t(), map(), keyword()) ::
          {:ok, Turn.t()} | {:error, :sandbox_unavailable | :provider_transaction_open | term()}
  def admit_turn(sandbox_id, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_map(attrs) and is_list(opts) do
    cond do
      # As in `destroy/2`: the protocol's own guard is process-local and cannot
      # fire in the owner, and an open transaction here would have the owner's
      # locked insert block on the advisory lock this caller holds while the
      # caller blocks in `GenServer.call`.
      Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      true ->
        # `:admit_timeout_ms` is a test seam for the deadline below; no call
        # site in `lib/` passes it (`machine_bounds_test.exs` scans for it).
        timeout = Keyword.get(opts, :admit_timeout_ms, @admit_timeout)
        sandbox_id |> admit_in_owner(attrs, opts, timeout, 1) |> admission_refusal(sandbox_id)
    end
  end

  @doc """
  End a turn: `Fountain.Machines.Admission.end_turn/3`, inline on the caller
  (see the moduledoc). `ending` and `opts` are the protocol's,
  documented there; the answer is the write's own, untranslated, because none
  of its words reaches the wire — each caller logs or publishes on it itself.
  """
  @spec end_turn(Turn.t(), Admission.ending(), keyword()) ::
          {:ok, Turn.t()} | {:ok, Turn.t(), term()} | :noop | {:error, term()}
  def end_turn(%Turn{} = turn, ending, opts) when is_list(opts) do
    Admission.end_turn(turn, ending, opts)
  end

  @doc """
  End a conversation's binding to the machine behind `sandbox_id`:
  `Fountain.Machines.Binding.detach/2`, the last-detach decision, run inside
  the owner. `opts` are the protocol's, documented there.

  The answers travel: `{:ok, :detached}`, `{:ok, :destroyed}` and
  `{:ok, :already_terminal}` each tell the caller something different to do
  next, and the refusals are the fence's own words
  (`:sandbox_unavailable`, `:not_found`). A live lease, waited out, and an
  unreachable owner are `:sandbox_unavailable`; a `:superseded` destroy is
  `{:ok, :already_terminal}`.
  """
  @spec detach(String.t(), keyword()) ::
          {:ok, Binding.detach_outcome()}
          | {:error, :sandbox_unavailable | :provider_transaction_open | term()}
  def detach(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      timeout = Keyword.get(opts, :detach_timeout_ms, @detach_timeout)
      sandbox_id |> detach_in_owner(opts, timeout, 1) |> binding_refusal(sandbox_id)
    end
  end

  # The binding's translation. The protocol's vocabulary is the callers' with
  # four exceptions; see `detach/2`.
  defp binding_refusal({:ok, _} = ok, _sandbox_id), do: ok
  defp binding_refusal({:ok, _, _} = ok, _sandbox_id), do: ok

  defp binding_refusal({:error, :machine_busy}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: detach unavailable (an owner holds the lease); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  defp binding_refusal({:error, {:machine_unreachable, reason}}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: binding unavailable (#{inspect(reason)}); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  # The owner found the caller's deadline passed. The caller was already
  # answered `:sandbox_unavailable` by the timeout; this reaches nobody.
  defp binding_refusal({:error, expired}, _sandbox_id)
       when expired in [:detach_expired],
       do: {:error, :sandbox_unavailable}

  defp binding_refusal({:error, :transaction_open}, _sandbox_id),
    do: {:error, :provider_transaction_open}

  defp binding_refusal(other, _sandbox_id), do: other

  # The admission's translation. The write's vocabulary is the caller's, so
  # almost everything travels; see `admit_turn/3`.
  defp admission_refusal({:ok, _turn} = ok, _sandbox_id), do: ok

  defp admission_refusal({:error, :machine_busy}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: turn admission unavailable (an owner holds the lease); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  defp admission_refusal({:error, {:machine_unreachable, reason}}, sandbox_id) do
    Logger.warning(
      "machine #{sandbox_id}: turn admission unavailable (#{inspect(reason)}); " <>
        "answering :sandbox_unavailable"
    )

    {:error, :sandbox_unavailable}
  end

  # The owner found the caller's deadline passed before it could run the
  # admission. The caller was already answered `:sandbox_unavailable` by the
  # timeout; this answer reaches nobody, and is the same word for the log.
  defp admission_refusal({:error, :admission_expired}, _sandbox_id),
    do: {:error, :sandbox_unavailable}

  defp admission_refusal({:error, :transaction_open}, _sandbox_id),
    do: {:error, :provider_transaction_open}

  defp admission_refusal(other, _sandbox_id), do: other

  # The provision family's translation. Narrower than `refusal/3` because its
  # caller is a server rather than a request, and the reason usually decides
  # what that server does next. See `provision/3`.
  defp provision_refusal({:ok, _outcome} = ok, _sandbox_id), do: ok
  defp provision_refusal({:ok, _outcome, _result} = ok, _sandbox_id), do: ok

  defp provision_refusal({:error, reason}, sandbox_id)
       when reason in [:machine_busy, :superseded] do
    Logger.info(
      "machine #{sandbox_id}: provisioning is another owner's (#{inspect(reason)}); standing down"
    )

    {:ok, :claimed_elsewhere}
  end

  # The result travels with it: the pipeline reached a state its caller has to
  # unwind — a broker session, a rotated callback key — whether or not the row
  # ended up being this attempt's to write.
  defp provision_refusal({:error, reason, result}, sandbox_id)
       when reason in [:machine_busy, :superseded] do
    {:ok, outcome} = provision_refusal({:error, reason}, sandbox_id)
    {:ok, outcome, result}
  end

  defp provision_refusal({:error, :fenced}, _sandbox_id), do: {:error, :sandbox_reset_pending}

  defp provision_refusal({:error, :fenced, result}, _sandbox_id),
    do: {:error, :sandbox_reset_pending, result}

  defp provision_refusal({:error, :transaction_open}, _sandbox_id),
    do: {:error, :provider_transaction_open}

  defp provision_refusal(other, _sandbox_id), do: other

  # The protocols' answers, in the words the rest of the system uses.
  #
  # `:superseded` is not a failure to report: another owner took the machine
  # over and is the one that says what happened to it. From here the machine is
  # stopping or stopped for a destroy, parked or parking for a park — and each
  # is the same thing a caller is told when somebody else got there first,
  # because it is the same event.
  #
  # Everything not named in the verb's own list is "this machine could not be
  # reached right now", which is what `:sandbox_unavailable` already means
  # (503, `retry-after: 30`, retryable in the SDK). Contention, a
  # database fault out of `Lease` and an unreachable owner are all that shape.
  # The precise reason goes to the log, where an operator can find it; it does
  # not go on the wire.
  defp refusal({:ok, _outcome} = ok, _sandbox_id, _verb), do: ok

  defp refusal({:error, :superseded}, sandbox_id, verb) do
    Logger.info("machine #{sandbox_id}: #{verb} superseded; another owner finished it")
    superseded(verb)
  end

  # A caller bug, and every sibling verb's word for it.
  defp refusal({:error, :transaction_open}, _sandbox_id, _verb),
    do: {:error, :provider_transaction_open}

  # `main`'s word at every surface a wake reaches, and the two translations this
  # module does that are not flattenings.
  #
  # The protocol says `:resume_failed`, to sit beside `Park`'s `:suspend_failed`,
  # and the rest of Fountain has said `:sandbox_resume_failed` since #799.
  defp refusal({:error, :resume_failed}, _sandbox_id, :ensure_up),
    do: {:error, :sandbox_resume_failed}

  # And `:fenced`, which is a *protocol* word with no meaning outside this
  # namespace. `Park`'s may travel because both its callers handle it themselves;
  # a wake's caller is a prompt, and the answer goes on the wire. See
  # `ensure_up/2`.
  defp refusal({:error, :fenced}, _sandbox_id, :ensure_up),
    do: {:error, :sandbox_reset_pending}

  defp refusal({:error, reason}, sandbox_id, verb) do
    if reason in travelling(verb) do
      {:error, reason}
    else
      Logger.warning(
        "machine #{sandbox_id}: #{verb} unavailable (#{inspect(reason)}); " <>
          "answering :sandbox_unavailable"
      )

      {:error, :sandbox_unavailable}
    end
  end

  defp superseded(:destroy), do: {:ok, :already_terminal}
  defp superseded(:park), do: {:ok, :already_parked}
  defp superseded(:ensure_up), do: {:ok, :already_up}

  # The words each verb lets through, and nothing else.
  #
  # For a destroy: the fence's own refusals, which every caller of that path
  # already handled before ADR 0058 and which `FallbackController` maps.
  #
  # For a park: the three that decide what the caller does next. See `park/2`.
  defp travelling(:destroy) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open
    ]
  end

  # For `ensure_up`: the fence, the two states there is nothing to resume from,
  # the provider's refusal, and the admission's. See `ensure_up/2`.
  defp travelling(:ensure_up) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open,
      :sandbox_reset_pending,
      :provisioning,
      :sandbox_resume_failed,
      :fleet_full
    ]
  end

  defp travelling(:park) do
    [
      :not_found,
      :sandbox_unavailable,
      :provider_transaction_open,
      :cannot_park,
      :suspend_failed,
      :machine_occupied,
      :fenced,
      :not_expired
    ]
  end

  # The same gone-owner retry as `ask_owner/2`, and the same reason: the idle
  # timer fires on its own schedule, so the pid looked up can have exited by
  # the time it is called. One retry with a freshly started owner,
  # then a refusal. A `:timeout` is not retried — the owner is alive and busy,
  # and asking it twice only doubles the wait.
  defp destroy_in_owner(sandbox_id, opts, retries_left) do
    in_owner(sandbox_id, {:destroy, sandbox_id, opts}, @destroy_timeout, :destroy, retries_left)
  end

  defp park_in_owner(sandbox_id, opts, retries_left) do
    in_owner(sandbox_id, {:park, sandbox_id, opts}, @park_timeout, :park, retries_left)
  end

  # Deadline-carrying since stage 8b (the 8a round-2 residual): a resume that
  # reaches the owner after its caller gave up is refused rather than run for
  # nobody. `:resume_timeout_ms` is a test seam; no call site in `lib/` passes
  # it.
  defp resume_in_owner(sandbox_id, opts, retries_left) do
    timeout = Keyword.get(opts, :resume_timeout_ms, @resume_timeout)
    deadline = DateTime.add(db_now(), timeout, :millisecond)

    in_owner(
      sandbox_id,
      {:ensure_up, sandbox_id, opts, deadline},
      timeout,
      :ensure_up,
      retries_left
    )
  end

  defp detach_in_owner(sandbox_id, opts, timeout, retries_left) do
    deadline = DateTime.add(db_now(), timeout, :millisecond)
    in_owner(sandbox_id, {:detach, sandbox_id, opts, deadline}, timeout, :detach, retries_left)
  end

  # The deadline is dated on the database's clock, `timeout` from now: the one
  # clock every node shares (stage 7a's reason for the lease), and the one the
  # locked insert reads in the same statement as the machine's row. One trivial
  # query per prompt.
  defp admit_in_owner(sandbox_id, attrs, opts, timeout, retries_left) do
    deadline = DateTime.add(db_now(), timeout, :millisecond)

    in_owner(
      sandbox_id,
      {:admit_turn, sandbox_id, attrs, opts, deadline},
      timeout,
      :admit_turn,
      retries_left
    )
  end

  defp in_owner(sandbox_id, message, timeout, verb, retries_left) do
    case ensure_started(sandbox_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, message, timeout)
        catch
          :exit, reason
          when retries_left > 0 and elem(reason, 0) in [:noproc, :normal, :shutdown] ->
            Logger.debug("machine #{sandbox_id}: owner went away before #{verb}; retrying")
            in_owner(sandbox_id, message, timeout, verb, retries_left - 1)

          :exit, reason ->
            Logger.warning("machine #{sandbox_id}: #{verb} unreachable (#{inspect(reason)})")
            {:error, {:machine_unreachable, reason}}
        end

      {:error, reason} ->
        Logger.warning("machine #{sandbox_id}: no owner to #{verb} through (#{inspect(reason)})")

        {:error, {:machine_unreachable, reason}}
    end
  end

  # The pid can be gone between the lookup and the call — the idle timer fires
  # on its own schedule. `GenServer.call` *exits* on that, which
  # would make a read-only verb crash its caller. So: one retry with a freshly
  # started owner, then the direct read. Whatever happens, the caller gets a
  # struct, which is what the @spec promises.
  #
  # Only a *gone* owner is retried. A `:timeout` means the owner is alive and
  # slow — almost certainly a repo that is already in trouble — and retrying
  # that would make one caller wait two `@call_timeout`s before it gave up, so
  # it falls straight through to the direct read.
  defp ask_owner(sandbox_id, retries_left) do
    case ensure_started(sandbox_id) do
      {:ok, pid} ->
        try do
          GenServer.call(pid, {:who_is_here, sandbox_id}, @call_timeout)
        catch
          :exit, reason
          when retries_left > 0 and elem(reason, 0) in [:noproc, :normal, :shutdown] ->
            Logger.debug("machine #{sandbox_id}: owner went away (#{inspect(reason)}); retrying")
            ask_owner(sandbox_id, retries_left - 1)

          :exit, reason ->
            Logger.warning(
              "machine #{sandbox_id}: owner unreachable (#{inspect(reason)}); " <>
                "reading occupancy directly"
            )

            Occupancy.load(sandbox_id)
        end

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox_id}: no owner (#{inspect(reason)}); reading occupancy directly"
        )

        Occupancy.load(sandbox_id)
    end
  end

  # ── server ────────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    state = %{
      key: Keyword.fetch!(args, :key),
      idle_ms: Keyword.get(args, :idle_ms, @idle_ms),
      idle_token: nil
    }

    {:ok, arm_idle(state)}
  end

  # **In the test suite only**, a call is served on behalf of the process that
  # made it: the owner adopts the caller's `$callers` chain — the chain `Task`
  # hands the processes it starts — so a test's Ecto SQL
  # sandbox connection and its Mimic stubs reach the owner. Per call, not per
  # start, because one owner serves many callers: a chain recorded at start
  # would run a later caller's work on the first caller's connection. Until
  # stage 9b `MACHINE_OWNER_ENABLED` ran every verb inline on its caller in the
  # suite, so no test needed this.
  #
  # **Off in production, and nothing may turn it on by accident.** `config/test.exs`
  # sets `:owner_adopts_callers`; nothing else does, and with it off this
  # process never puts `$callers` at all, which is exactly `main`'s owner.
  # Something in production does read the key: `opentelemetry_ecto` walks
  # `$callers` on every query a process with no trace context of its own
  # makes, so adopting here would copy the caller's whole process dictionary
  # on each of the owner's queries and re-parent the owner's database spans
  # under the caller's. Better owner tracing, if it is wanted, is a separate
  # and deliberate change — propagate the trace context once per call — not a
  # side effect of a test seam. A runtime read rather than `compile_env`, so a
  # test can switch it off and prove the production shape
  # (`machine_test.exs`); one ETS lookup per call.
  @impl true
  def handle_call(message, {caller, _tag} = from, state) do
    if Application.get_env(:fountain, :owner_adopts_callers, false), do: adopt_callers(caller)
    serve(message, from, state)
  end

  defp adopt_callers(caller) when node(caller) == node() do
    chain =
      case Process.info(caller, {:dictionary, :"$callers"}) do
        {{:dictionary, :"$callers"}, callers} when is_list(callers) -> callers
        _ -> []
      end

    Process.put(:"$callers", [caller | chain])
  end

  defp adopt_callers(_caller), do: Process.delete(:"$callers")

  defp serve({:who_is_here, sandbox_id}, _from, state) do
    {:reply, Occupancy.load(sandbox_id), arm_idle(state)}
  end

  # Serialization, not safety: `Destroy.run/2`'s lease is what makes two
  # destroys of one machine correct, and running them one at a time here is
  # what keeps the second one from waiting out the first one's lease to find
  # out. It runs in the owner rather than in a task so the mailbox is the
  # queue; `@destroy_timeout` on the client side is the ceiling on the
  # caller's *wait* for it — a message whose caller has given up still runs
  # when the owner reaches it, and for this verb that late run is idempotent
  # (a destroy of a destroyed machine is `{:ok, :already_terminal}` to nobody).
  defp serve({:destroy, sandbox_id, opts}, _from, state) do
    {:reply, Destroy.run(sandbox_id, opts), arm_idle(state)}
  end

  # Same shape, same reason. A park occupies the owner for a checkpoint and a
  # suspend, which is longer than a destroy takes — `@park_timeout` on the
  # client side is the ceiling on the caller's wait, and a late park is a park
  # of a machine the recheck under the lease still has to find idle.
  defp serve({:park, sandbox_id, opts}, _from, state) do
    {:reply, Park.run(sandbox_id, opts), arm_idle(state)}
  end

  # Same shape, same reason, and here the serialization is the *feature* rather
  # than an optimization of it: two prompts waking one parked home arrive
  # milliseconds apart, and queueing the second behind the first is what makes
  # it find a machine that is already up instead of waiting out a lease to be
  # told so (ADR 0023 step 4).
  #
  # `@resume_timeout` bounds the caller's wait, not this queue, and a late
  # resume is **not** idempotent the way a late destroy or park is (8a round
  # 2, protocol review, driven): the caller was told `sandbox_unavailable` and
  # moved on, the queued resume then ran at the provider, and the machine
  # came up `ready` for nobody — billed until `Machines.Policy`'s idle
  # verdict parked it again. So since stage 8b the message carries the
  # caller's deadline, like the admission's, and the three-tuple clause below
  # refuses a resume that reaches the owner after it.
  # The two-tuple is the message a caller on the previous release sends — no
  # deadline, because it had none — and it runs as it always did; the
  # three-tuple (stage 8b) is refused past its deadline. `:resume_expired`
  # reads as `:sandbox_unavailable` at the door, to nobody.
  defp serve({:ensure_up, sandbox_id, opts, %DateTime{} = deadline}, _from, state) do
    reply =
      if DateTime.compare(db_now(), deadline) == :gt do
        Logger.warning(
          "machine #{sandbox_id}: a resume reached the owner after its caller's " <>
            "deadline; refusing without running it"
        )

        {:error, :resume_expired}
      else
        Resume.run(sandbox_id, opts)
      end

    {:reply, reply, arm_idle(state)}
  end

  # Same shape again, and the serialization is the feature here as it is for a
  # resume: a prompt that arrives while this machine is being resumed for a
  # cotenant waits in the mailbox and then finds it up, where inline it would
  # wait out `Admission.busy_wait_ms/0` against the lease and be told
  # `sandbox_unavailable`.
  #
  # **The timeout bounds the caller's wait, not this queue**, and unlike a
  # destroy or a park a late admission is not idempotent: it is a turn row
  # for a prompt that was already told 503 (round 1). So the message carries
  # the caller's deadline on the database clock, and an admission that reaches
  # the front of the mailbox after it is refused without running — here, from
  # one read of the clock, and again inside the locked insert, which judges
  # the same deadline against the `statement_timestamp()` it read the
  # machine's row with.
  #
  # What the two checks bound, exactly (round 2, protocol review, driven): the
  # write's check refuses a *row read* past the deadline, and the commit can
  # still land up to one transaction tail after it — the parent check, the
  # count, the insert and the parent update, with no lock wait
  # among them; milliseconds in practice. That tail is the price of the check
  # and the insert being two statements. This pre-check is not the smaller
  # half: the write's check sits after the machine's own verdicts, so an
  # expired message that finds a cotenant's lease live would answer
  # `:machine_busy` and poll the locked insert for the whole
  # `Admission.busy_wait_ms/0` on a caller that left; this one refuses it from
  # one clock read, and `admission_test.exs` pins that difference.
  #
  # The three-tuple below is the message a caller on the round-1 head sends —
  # no deadline, because it had none. An owner that crashed on it would cost a
  # cotenant's queued park (the mixed-version note in the PR); refusing is the
  # safe side, in the one word every version of the door translates.
  defp serve({:admit_turn, sandbox_id, attrs, opts, %DateTime{} = deadline}, _from, state) do
    reply =
      if DateTime.compare(db_now(), deadline) == :gt do
        Logger.warning(
          "machine #{sandbox_id}: an admission reached the owner after its caller's " <>
            "deadline; refusing without running it"
        )

        {:error, :admission_expired}
      else
        Admission.run(sandbox_id, attrs, Keyword.put(opts, :deadline, deadline))
      end

    {:reply, reply, arm_idle(state)}
  end

  # The binding verbs (stage 8b), the same shape as the admission and for the
  # same reason: an attach creates a conversation row and a detach writes a
  # fence, and either done late is done for a caller that was told 503. The
  # pre-check refuses from one clock read; the protocol refuses again against
  # the `statement_timestamp()` it read the machine's row with.
  defp serve({:detach, sandbox_id, opts, %DateTime{} = deadline}, _from, state) do
    reply =
      if DateTime.compare(db_now(), deadline) == :gt do
        Logger.warning(
          "machine #{sandbox_id}: a detach reached the owner after its caller's " <>
            "deadline; refusing without running it"
        )

        {:error, :detach_expired}
      else
        Binding.detach(sandbox_id, Keyword.put(opts, :deadline, deadline))
      end

    {:reply, reply, arm_idle(state)}
  end

  # **The rollout clause.** Every verb above answers a message shape this
  # release knows; a later one will add shapes it does not, and a squash-merged
  # chain cannot deliver "deploy the receiver first" (ADR 0058's rule 4). An
  # owner with no clause for the message dies with its whole mailbox — every
  # other caller queued behind it loses its operation, which is what an old
  # owner meeting stage 8b's `{:attach, …}`, `{:detach, …}` or
  # `{:ensure_up, opts, deadline}` does today (round 1, protocol review:
  # `owner exited: :function_clause`, and `ensure_up` is on every wake). 8a
  # took the narrow version of this for `admit_turn`'s old shape; this is the
  # general one, so the next stage's rollout costs the caller a 503 and not the
  # queue.
  #
  # `:sandbox_unavailable` because it is the one transient word every door in
  # every version translates, and the caller genuinely cannot have this machine
  # from this owner right now. Logged at `error`: in a test or on one release
  # this clause is only ever reached by a mistake, and it must be loud.
  defp serve(message, _from, state) do
    Logger.error(
      "machine owner #{state.key}: no handle_call clause for #{shape(message)}; refusing. " <>
        "A caller on a later release, or a message shape that was never added here."
    )

    {:reply, {:error, :sandbox_unavailable}, arm_idle(state)}
  end

  @impl true
  # The same hole on the cast side, and it does not need a later release to
  # open: with no `handle_cast/2` at all, `GenServer`'s generated one raises a
  # `RuntimeError` ("attempted to cast .. but no handle_cast/2 clause was
  # provided", driven — not the `{:bad_cast, ..}` an earlier version of this
  # comment claimed), which costs the mailbox exactly as a missing call clause
  # does. Nothing casts to an owner today — `machine_gone` is a cast, but it
  # goes to the *conversation servers*, never here — so this clause is the
  # whole cast surface, and a cast that arrives is by definition a shape this
  # release does not know. There is nobody to answer, so the refusal is simply
  # not dying.
  #
  # No `arm_idle/1`, for the reason the info clause gives and against the same
  # rule: **a call re-arms because a caller is waiting and will likely ask
  # again, and every other `handle_call` in this module re-arms; a message with
  # nobody waiting does not, because nothing was done.** Re-arming here would
  # keep an idle machine's owner alive on a message it refused, which is the
  # thing the info clause is careful not to do (round 3, behaviour review).
  def handle_cast(message, state) do
    Logger.error(
      "machine owner #{state.key}: no handle_cast clause for #{shape(message)}; ignoring. " <>
        "A caller on a later release, or a message shape that was never added here."
    )

    {:noreply, state}
  end

  # The tag and the arity, never the payload: an `{:attach, attrs, ..}` carries
  # a conversation's attributes, and a log line is not a place to put them.
  #
  # That claim used to hold for tuples only — the fallback inspected the whole
  # term, so a map or a binary was logged in full and the sentence above was
  # false for exactly the messages most likely to carry something (round 3,
  # protocol review). A bare atom is a shape in itself and carries nothing;
  # everything else is logged as its type and never its contents.
  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "#{inspect(elem(message, 0))}/#{tuple_size(message)}"

  defp shape(message) when is_atom(message), do: inspect(message)

  defp shape(message), do: "a #{type_name(message)}"

  defp type_name(message) when is_binary(message), do: "binary"
  defp type_name(message) when is_bitstring(message), do: "bitstring"
  defp type_name(message) when is_map(message), do: "map"
  defp type_name(message) when is_list(message), do: "list"
  defp type_name(message) when is_tuple(message), do: "tuple"
  defp type_name(message) when is_integer(message), do: "integer"
  defp type_name(message) when is_float(message), do: "float"
  defp type_name(message) when is_pid(message), do: "pid"
  defp type_name(message) when is_port(message), do: "port"
  defp type_name(message) when is_reference(message), do: "reference"
  defp type_name(message) when is_function(message), do: "function"
  defp type_name(_message), do: "term"

  @impl true
  def handle_info({:idle, token}, %{idle_token: token} = state) do
    # Nothing durable to release. A destroy's or a park's lease is claimed and
    # released inside its own `handle_call`, and a GenServer handles one
    # message at a time, so this message is only ever reached between
    # operations — never with one in flight. `ensure_started/1` starts a replacement on the next
    # question. The standing lease of stages 6 and 7 changes that, and will
    # have to be given up here.
    {:stop, :normal, state}
  end

  # A timer this process already re-armed past. Cancelling leaves the message
  # in the mailbox when it was already sent, so the token, not the cancel, is
  # what decides.
  def handle_info({:idle, _stale}, state), do: {:noreply, state}

  # And the info side, where the shapes are not a protocol at all. Defining
  # `handle_info/2` at all replaces the logged-and-ignored default `use
  # GenServer` would have given this module, so before this clause anything
  # unmatched raised a `FunctionClauseError` and took the machine's owner down
  # mid-operation.
  #
  # What can arrive is a hand-sent `:EXIT` or `:DOWN` tuple: a late reply to a
  # call that timed out is dropped, because the call's alias is deactivated at
  # the timeout, and the owner does not trap exits, so a real link exit kills
  # it rather than arriving as a message. Until ADR 0072 a lease renewer's
  # abandoned verdict landed here too.
  #
  # Warning rather than error, because unlike a call or a cast these are
  # ordinary runtime noise; `arm_idle/1` is deliberately not called, since a
  # stray message is not this machine being used. Driven both ways: a stray
  # neither extends nor shortens the owner's life, and it cannot stop one
  # underneath a live operation, because a GenServer handles one message at a
  # time and the operation's own re-arm makes the fired idle stale.
  def handle_info(message, state) do
    Logger.warning("machine owner #{state.key}: unexpected message #{shape(message)}; ignoring")

    {:noreply, state}
  end

  defp arm_idle(state) do
    token = make_ref()
    Process.send_after(self(), {:idle, token}, state.idle_ms)
    %{state | idle_token: token}
  end

  # ── starting ──────────────────────────────────────────────────────────────

  defp start_child(key, opts) do
    child = {__MODULE__, Keyword.put(opts, :key, key)}

    case DynamicSupervisor.start_child(Fountain.MachineSupervisor, child) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} when is_pid(pid) -> {:ok, pid}
      {:error, _reason} = error -> error
      :ignore -> {:error, :ignore}
    end
  end
end
