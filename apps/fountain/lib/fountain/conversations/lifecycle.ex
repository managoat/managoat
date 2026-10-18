defmodule Fountain.Conversations.Lifecycle do
  @moduledoc """
  How long a sandbox is allowed to run unattended, and what crossing each
  bound costs.

  Two bounds, both off by setting the value to `nil` or `0`:

  * **Idle timeout** — no turn activity for this long and the sandbox is
    **suspended**: the ConversationServer stops, the sprite stays alive at
    sprites.dev and scales itself to zero, and the sandbox row parks in
    `suspended`. The next prompt reattaches to the same sprite — same disk,
    same runtime session, so the agent keeps its memory of the conversation.
    This is the common case: someone starts a run, reads the answer, closes
    the tab. See decisions/0017.

  * **Max lifetime** — a ceiling on a *continuous run*, measured from the
    sandbox's creation or its last wake from `suspended`
    (`last_resumed_at || inserted_at`). Crossing it **destroys** the
    sprite. **Off by default since
    #936**: a tenant who wants a machine running 24/7 is not something to
    stop, so nothing automatic stops a sandbox that keeps itself busy — the idle timeout parks it once it stops, and the fleet ceiling bounds how
    many can be up. An operator who wants the old backstop sets
    `SANDBOX_MAX_LIFETIME_HOURS`.

  ## Why the split

  The original design (#233) destroyed the sprite on both bounds, on the
  premise that an idle sprite bills indefinitely. It doesn't — sprites scale
  to zero on their own — and #649 measured what the destroy costs: the
  runtime's session lives in the sandbox's filesystem, so resuming onto a new
  sprite fails on every path we have (`claude --resume` answers "No
  conversation found with session ID"; ACP `session/resume` answers `-32002
  Resource not found`). Fountain's own transcript survives either way — every
  `log_events` row still renders — but the agent's memory does not. So the
  idle bound, which exists for abandoned-not-runaway conversations, now parks
  instead of destroying, and only the max-lifetime ceiling still pays the
  #649 price. `explain/1` tells the user which one they got.

  Suspended sandboxes are never aged out — a parked sprite is treated as
  costing nothing (decisions/0017), and the disk it holds is the agent's
  memory.

  Setting the conversation itself to `terminated` on either bound would *not*
  be safe — it would make the conversation permanently unresumable, turning a
  cost control into data loss.

  ## Policy, then the actions

  The first half of this module is policy: `check/4`, `idle_action/1`,
  `explain/1,2` and the two bounds they read. Pure, and safe to ask from
  anywhere — the `ConversationServer` and `Workers.SandboxReaper` both do.

  The second half (#1376) is the consequence: the sandbox clock, the calls
  that park or destroy the machine. They talk to the provider, the rows and
  the stream, and they run inside a `ConversationServer` whose ownership of
  the conversation was established at `init/1`. The decision and its
  consequence sit in one file so a reader of `idle_action/1` can see what
  `:destroy` costs.

  Since ADR 0058 stages 5 and 6b, the machine half of that consequence is not
  written here: `destroy/4` and `park/4` ask `Fountain.Machines.Machine` for
  the machine and keep only the conversation's side of a reclaim.

  ## The teardown fence

  This module also owns the forced-teardown admission fence
  (`fence_sandbox_for_teardown/2`) — moved here from `Fountain.Conversations`
  in #2258. It is a rule about the machine, not a conversation verb, and this
  module already is one of its callers (`prepare_destroy/2`);
  `Machines.Destroy`, `Accounts.Deletion` and `Machines.Binding.detach/2`
  call it, they do not own it. The detach is the caller that asks with a
  terminating conversation, on an implicit workspace only: an explicit
  workspace keeps its machine when a conversation leaves it, and is not fenced
  (ADR 0097, `Machines.Binding.detach/2`).
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Egress
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Policy
  alias Fountain.Repo
  alias Managoat.Sandbox.Handle

  @default_idle_minutes 60
  @default_max_lifetime_hours 0

  # Advisory-lock namespace for machine operations, keyed by the workspace — must match
  # `Fountain.Conversations`' own `@sandbox_lock_namespace` (4316); every
  # module that takes this lock hardcodes the same integer rather than
  # sharing the attribute, since module attributes do not cross a module
  # boundary (`conversations/launch.ex` and `machines/binding.ex` do the same; `conversations/sandbox_identity.ex`
  # did until ADR 0058 stage 8b deleted it).
  @sandbox_lock_namespace 4316

  # Sandbox statuses a fence never reopens — must match
  # `Fountain.Conversations`' own `@terminal_statuses`, for the same reason.
  @terminal_statuses ~w(terminated failed)

  # How often the sandbox lifetime bounds are evaluated. A minute is far finer
  # than the bounds themselves (an hour, a day), so the cost of the tick is
  # irrelevant and the overshoot is bounded by it.
  @check_ms :timer.minutes(1)

  @doc "Idle timeout in seconds, or `nil` when disabled."
  @spec idle_timeout_seconds() :: pos_integer() | nil
  def idle_timeout_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_idle_timeout_minutes, @default_idle_minutes),
      60
    )
  end

  @doc "Absolute sandbox lifetime in seconds, or `nil` when disabled."
  @spec max_lifetime_seconds() :: pos_integer() | nil
  def max_lifetime_seconds do
    to_seconds(
      Application.get_env(:fountain, :sandbox_max_lifetime_hours, @default_max_lifetime_hours),
      3600
    )
  end

  @doc """
  How long a held `ask` waits for a human before it is denied (#940).

  Read from `:permission_ask_timeout_seconds`; the default and the parsing
  are the ACP library's (`Managoat.ACP.Permissions.ask_timeout_ms/1`). Must
  sit under `idle_timeout_seconds/0`: a held request suppresses only the idle
  verdict, so one that outlived the idle bound would be resolved by the
  max-lifetime ceiling instead — which destroys the sandbox rather than
  parking it (0017). The timeout has to fire first for an unanswered prompt
  to cost a turn rather than the agent's memory; `lifecycle_test.exs` pins
  the bound. When it fires the request is denied, as the turn's own end
  would deny it; no request outlives its turn (ADR 0014).

  Lived on `Fountain.Runtimes.ACP` until that module left for
  `Managoat.Runtimes` (#1368); it is the one thing there that read Fountain's
  configuration, and it belongs with the bound it has to stay under.
  """
  @spec ask_timeout_ms() :: pos_integer()
  def ask_timeout_ms do
    :fountain
    |> Application.get_env(:permission_ask_timeout_seconds)
    |> Managoat.ACP.Permissions.ask_timeout_ms()
  end

  defp to_seconds(nil, _unit), do: nil
  defp to_seconds(0, _unit), do: nil
  defp to_seconds(n, unit) when is_integer(n) and n > 0, do: n * unit

  defp to_seconds(n, unit) when is_binary(n) do
    case Integer.parse(n) do
      {i, _} -> to_seconds(i, unit)
      :error -> nil
    end
  end

  defp to_seconds(_, _), do: nil

  @doc """
  Which bound, if any, a sandbox has crossed.

  Returns `{:expired, :idle | :max_lifetime}` or `:ok`. `busy?` suppresses only
  the idle verdict: a turn in flight is activity by definition, while the
  absolute ceiling exists precisely for the conversation that never stops being
  busy.
  """
  @spec check(DateTime.t(), DateTime.t(), boolean(), DateTime.t()) ::
          {:expired, :idle | :max_lifetime} | :ok
  def check(started_at, last_activity_at, busy?, now \\ DateTime.utc_now()) do
    max_lifetime = max_lifetime_seconds()
    idle = idle_timeout_seconds()

    cond do
      max_lifetime && DateTime.diff(now, started_at) >= max_lifetime ->
        {:expired, :max_lifetime}

      not busy? && idle && DateTime.diff(now, last_activity_at) >= idle ->
        {:expired, :idle}

      true ->
        :ok
    end
  end

  @doc """
  Human-readable reason, for the stage event a client sees on the stream.

  Worth spending words on: from the user's side the sandbox simply went away,
  and an explanation is the difference between a bug report and a shrug.

  The two bounds now promise different things and the copy must not blur
  them. A suspend keeps the sprite's disk, so the agent genuinely resumes
  with its memory; a max-lifetime reclaim destroys it, and the agent's
  context goes with it (#649). Telling someone "history is preserved" on the
  destroy path — or hedging on the suspend path — makes the true sentence
  discredit the other.
  """
  @spec explain(:idle | :max_lifetime) :: String.t()
  def explain(:idle), do: explain(:idle, :suspend)

  def explain(:max_lifetime) do
    "Sandbox reclaimed after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime. Send another prompt to continue — the transcript above is kept, but the " <>
      "agent starts a fresh session and will not remember the earlier turns."
  end

  @doc """
  What crossing the idle bound does on this provider.

  `:suspend` where the provider can park with the disk preserved (the
  `:suspend` capability); `:destroy` where it cannot — an idle sandbox on
  such a backend keeps billing, so the cost control wins over the agent's
  memory, exactly as the max-lifetime ceiling already prices it.

  The decision itself moved to `Fountain.Machines.Policy.idle_action/1` in ADR
  0058 stage 7a, with the rest of what the two modes mean; this is the name the
  ConversationServer's idle reclaim, the reaper's park and `Machines.Park`'s
  recheck under the lease have always called it by, and it still is.
  """
  @spec idle_action(atom()) :: :suspend | :destroy
  defdelegate idle_action(provider), to: Fountain.Machines.Policy

  @doc """
  The idle copy, by what actually happened. Same honesty rule as the two
  arms of `explain/1`: promise memory only where the disk survives.
  """
  @spec explain(:idle | :max_lifetime, :suspend | :destroy) :: String.t()
  def explain(:idle, :suspend) do
    "Sandbox suspended after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the agent picks up right where it left off."
  end

  # The ceiling parks only an explicit workspace's machine (ADR 0097), and it
  # interrupts whatever turn was running to do it: the disk and the sessions
  # are kept, so the memory promise holds, and the cut turn is said aloud.
  def explain(:max_lifetime, :suspend) do
    "Sandbox parked after reaching the #{hours(max_lifetime_seconds())} hour maximum " <>
      "lifetime; a turn that was running was interrupted. Send another prompt to " <>
      "continue — the agent picks up right where it left off."
  end

  def explain(:idle, :destroy) do
    "Sandbox reclaimed after #{minutes(idle_timeout_seconds())} minutes idle. " <>
      "Send another prompt to continue — the transcript above is kept, but this sandbox " <>
      "provider cannot park an idle sandbox, so the agent starts a fresh session and " <>
      "will not remember the earlier turns."
  end

  @doc """
  The copy for a destroy, by the bound that reached it. `explain/2`'s
  destroy arms, named once so the two `publish_stage` fields agree.
  """
  @spec reclaim_message(:idle | :max_lifetime) :: String.t()
  def reclaim_message(:max_lifetime), do: explain(:max_lifetime)
  def reclaim_message(:idle), do: explain(:idle, :destroy)

  # ── the actions ───────────────────────────────────────────────────────────

  @doc """
  The provider tag for telemetry: read off the live handle, which was built
  from the sandbox row's provider column.
  """
  @spec provider(Handle.t() | nil) :: atom()
  def provider(%Handle{provider: provider}), do: provider
  def provider(_handle), do: :sprites

  @doc """
  When the sandbox's continuous run started.

  The absolute lifetime ceiling measures a continuous run, not calendar age:
  a wake from `suspended` stamps `last_resumed_at` and restarts the clock,
  while a deploy reattach of a `ready` row stamps nothing and keeps it.
  `SandboxReaper.expired?/2` must agree with this — change both together.
  """
  @spec clock_start(map()) :: DateTime.t() | NaiveDateTime.t()
  def clock_start(sandbox), do: sandbox.last_resumed_at || sandbox.inserted_at

  @doc """
  Arm the next lifecycle tick, in the calling process — the server.

  Interval overridable in tests so the timer wiring itself is testable —
  dropping this call from `ConversationServer.init/1` used to pass the whole
  suite (#337) while silently disabling idle/max-lifetime reclamation.
  """
  @spec schedule_check() :: reference()
  def schedule_check do
    interval = Application.get_env(:fountain, :lifecycle_check_ms, @check_ms)
    Process.send_after(self(), :lifecycle_check, interval)
  end

  @doc """
  Whether a conversation other than this one holds the machine busy: mid-turn,
  or active more recently than the idle bound. One conversation going quiet is
  not the machine's verdict; that is reached over all of them (ADR 0023 step
  5). Since ADR 0073 a machine has one conversation, so this is ordinarily
  false.
  """
  @spec busy_elsewhere?(String.t() | nil, String.t()) :: boolean()
  def busy_elsewhere?(sandbox_id, conversation_id) do
    # Ownership: the caller is the server for a conversation on this sandbox,
    # established at its init/1.
    Conversations._unsafe_sandbox_busy_elsewhere?(
      sandbox_id,
      conversation_id,
      idle_timeout_seconds()
    )
  end

  @doc """
  What the idle bound does to this machine.

  Park where the provider can preserve the disk (the `:suspend` capability —
  implicit scale-to-zero for Sprites, an explicit pause/stop for providers
  that need one), destroy where it cannot. The disk holds the runtime session
  — the agent's memory, which #649 proved cannot be rebuilt on a fresh
  sandbox — so parking is always preferred; but an idle sandbox that cannot
  park keeps billing, so that degrades to the destroy arm.

  **The suspend call is no longer made here** (ADR 0058 stage 6b). This
  function once asked the provider to suspend and answered `:destroy` when the
  call failed, which meant the decision, the provider round trip and the row
  write happened in three different modules with nothing held across them —
  #2307. The call now happens inside `Fountain.Machines.Park`, under the
  machine's lease and after a recheck, and the *same* degradation is reached
  from the other end: the protocol answers `{:error, :suspend_failed}` and the
  caller destroys instead. What is left here is the capability half, which is
  a pure question about the provider and needs no lease to answer — and
  `Park` asks it again under one anyway, because a pre-lease verdict is stale
  by construction.
  """
  @spec idle_machine_action(Handle.t() | nil) :: :park | :destroy
  def idle_machine_action(handle),
    # The kind of workspace does not change the idle bound's answer.
    do: Policy.reclaim_action(:idle, provider(handle), :implicit)

  @doc """
  What the max-lifetime ceiling does to this conversation's machine:
  `:destroy` on an implicit workspace, as it always has, and `:park` on an
  explicit one where the provider can park (`Fountain.Machines.Policy`, ADR
  0097). A park at the ceiling interrupts every running turn on the machine
  first (`Fountain.Machines.Park`).
  """
  @spec ceiling_action(String.t() | nil, Handle.t() | nil) :: :park | :destroy
  def ceiling_action(sandbox_id, handle) do
    # Ownership: the caller is the server for a conversation on this sandbox,
    # established at its init/1.
    kind =
      case sandbox_id && Conversations._unsafe_get_sandbox(sandbox_id) do
        %Sandbox{} = sandbox -> Fountain.Workspaces.machine_kind(sandbox)
        nil -> :implicit
      end

    Policy.reclaim_action(:max_lifetime, provider(handle), kind)
  end

  @doc """
  The whole idle verdict for a conversation server: `:keep` the machine,
  `:park` it, or `:destroy` it.

  `:keep` is `busy_elsewhere?/2` — this conversation is idle and the machine is
  not, because another conversation on it is mid-turn or was active more
  recently than the bound. The verdict is the machine's, reached over all of
  them (ADR 0023 step 5), and the next tick asks again. With one conversation
  per machine (ADR 0073) the verdict is ordinarily `:park` or `:destroy`.

  It is decided here rather than in the server for the reason the rest of this
  module exists (#1376): the server owns its transcript, its adapter and its
  turn state machine, and the lifecycle policy is not any of those. The owner
  re-asks the same question under the lease and can still answer
  `:machine_occupied`; this one keeps the server from dropping its connection
  to find that out on every tick of a machine somebody else is using.
  """
  @spec idle_machine_action(String.t(), String.t() | nil, Handle.t() | nil) ::
          :keep | :park | :destroy
  def idle_machine_action(conversation_id, sandbox_id, handle) do
    if busy_elsewhere?(sandbox_id, conversation_id),
      do: :keep,
      else: idle_machine_action(handle)
  end

  @doc """
  Park the machine a conversation server has decided to give up: the machine
  through its owner, then the conversation back to `idle`, the stage event and
  the telemetry.

  The server-side wrapper around `Fountain.Machines.Park`, which owns
  everything that touches the machine — the lease, the recheck under it, the
  checkpoint, the suspend, the row write, the `sandbox.suspended` event and the
  notice to the machine's other conversations. What is left here is what is
  the *conversation's*: its own status, its transcript and the telemetry tag
  taken off the live handle.

  `nil` for `sandbox_id` is a conversation with no machine to park, and it
  still finishes: the stage event is what the client is waiting for, and there
  is nothing for an owner to do. Same as `main`'s `park_row(nil)`.

  The answers:

    * `:ok` — parked, or already parked by somebody else. Either way the
      machine is at rest and the conversation should say so.
    * `{:error, :suspend_failed}` / `{:error, :cannot_park}` — the machine
      cannot be parked. The caller destroys instead: an unparked machine keeps
      billing (ADR 0017).
    * `{:error, :machine_occupied}` — somebody else is on the machine. Neither
      parked nor destroyed; the next tick asks again.
    * any other `{:error, _}` — a refusal to act on right now. The server logs
      it and keeps the machine, exactly as a refused destroy already does.

  A terminal row answers `:ok` and writes nothing, and so does a fenced one —
  which is what `main` did with `park_row/1`'s `:skipped`. A machine somebody
  else has finished, or is in the middle of finishing, is not this
  conversation's news to publish.
  """
  @spec park(String.t(), String.t() | nil, Handle.t() | nil, :idle | :max_lifetime) ::
          :ok | {:error, term()}
  def park(conversation_id, nil, handle, reason),
    do: finish_park(conversation_id, handle, reason)

  def park(conversation_id, sandbox_id, handle, reason) do
    case Machine.park(sandbox_id,
           actor: "system:conversation_server",
           reason: reason,
           # Excluded from the owner's occupancy check, the way
           # `busy_elsewhere?/2` excludes it here: a server parking the machine
           # it is bound to is not a reason to call that machine busy.
           requesting_conversation_id: conversation_id,
           # The wording is the caller's, and this caller has always had one.
           notify: {conversation_id, "suspended", to_string(reason), explain(reason, :suspend)}
         ) do
      {:ok, outcome} when outcome in [:parked, :already_parked] ->
        finish_park(conversation_id, handle, reason)

      # Somebody else has stopped this machine, or is about to: a terminal row,
      # or a teardown fence on a live one. Nothing to park and nothing
      # to say — `main` reached the same answer through `park_row/1`'s
      # `:skipped`, and the server stops either way rather than ticking at a
      # machine somebody else owns the end of.
      {:ok, :already_terminal} ->
        :ok

      {:error, :fenced} ->
        :ok

      # The owner found an abandoned park on a machine that is still running
      # and cleared it. Nothing was parked, so this is not a park — the next
      # tick decides again, on a row that now says what it means.
      {:ok, :recovered} ->
        {:error, :recovered}

      {:error, _} = error ->
        error
    end
  end

  defp finish_park(conversation_id, handle, reason) do
    # The conversation stays idle and resumable; the sprite stays parked.
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # Same stage/state as the reclaim below (LogEvent's state set is closed and
    # clients already key on the "sandbox" stage); `event` is the discriminator.
    Conversations.publish_stage(conversation_id, "sandbox", "done", %{
      event: "suspended",
      reason: to_string(reason),
      message: explain(reason, :suspend)
    })

    :telemetry.execute([:fountain, :sandbox, :suspended], %{count: 1}, %{
      provider: provider(handle)
    })

    :ok
  end

  @doc """
  Fence admission before the server closes its adapter.
  The caller owns the sandbox through its conversation.
  Refuses an enclosing transaction; a successful fence commits before returning.
  Already-admitted turns may still be interrupted by this forced reclaim.

  A pre-check, and since ADR 0058 stage 9a it is also the fence of record.
  `destroy/4` used to reach the same fence again through `Machine.destroy/2`,
  which wrote no second request event and could not reach a different verdict;
  now the `transition: "destroying"` this one stamps sends the protocol down
  its continuation clause instead, so the fence runs once. `Machines.Destroy`'s
  takeover section lists what that second read could have answered and why none
  of it can change. What this buys the server is the *timing* — it closes its
  adapter knowing nothing can be admitted behind it, and a refusal here costs
  no teardown at all.
  """
  @spec prepare_destroy(String.t() | nil, :idle | :max_lifetime) :: :ok | {:error, term()}
  def prepare_destroy(sandbox_id, reason) do
    cond do
      Fountain.Repo.in_transaction?() ->
        {:error, :provider_transaction_open}

      is_nil(sandbox_id) ->
        :ok

      true ->
        with %Conversations.Sandbox{} = sandbox <- Conversations._unsafe_get_sandbox(sandbox_id),
             # A self-call written `__MODULE__.fence_sandbox_for_teardown(...)`
             # so `lifecycle_fence_test.exs` can drive this fence with Mimic,
             # as `Interruption.interrupt_dead/1` does for
             # `wake_for_interrupt/1`. It used to pin a race on the *second*
             # call — `Machines.Destroy`'s, once the adapter was already
             # closed — and since stage 9a there is no second call: the stamp
             # this one writes sends the protocol down its continuation
             # clause.
             {:ok, _} <-
               __MODULE__.fence_sandbox_for_teardown(sandbox,
                 actor: "system:conversation_server",
                 reason: to_string(reason),
                 # `reason` here is `:idle | :max_lifetime`, which is already
                 # the destroy vocabulary — `destroy/4` hands `Machine.destroy/2`
                 # the same atom — so the fence stamps exactly what the protocol
                 # would have.
                 transition_reason: reason
               ) do
          :ok
        else
          nil -> {:error, :not_found}
          {:error, _} = error -> error
        end
    end
  end

  @doc """
  Tear down the sandbox; the conversation stays `idle` and resumable (setting
  it `terminated` here would make a cost control into data loss). Serves both
  the max-lifetime ceiling and the idle bound on a provider that cannot park.

  The machine half — the fence, the provider destroy and the terminal write —
  is `Fountain.Machines.Machine.destroy/2` (ADR 0058 stage 5). What is left
  here is the conversation half: the egress release, the conversation's own
  status, its stage event and the telemetry the server matches on, none of
  which the machine's owner knows or should.

  **No `:terminating_conversation_id`**, deliberately. This is a reclaim, not
  a terminate: the conversation stays and its next prompt builds a new
  machine, so the fence takes no conversation's binding into account, as a
  forced teardown's does. A terminating conversation is the detach's argument
  (`Machines.Binding.detach/2`), for a conversation that is ending.

  `handle` is now only the provider tag on the telemetry. The machine to
  destroy is read off the row, so a reclaim whose caller has already dropped
  its handle destroys the machine rather than leaking it.
  """
  @spec destroy(
          String.t(),
          String.t() | nil,
          Handle.t() | nil,
          :idle | :max_lifetime
        ) :: :ok | {:error, term()}
  def destroy(conversation_id, sandbox_id, handle, reason) do
    # Checked here as well as in the protocol, and with this module's own word
    # for it: `Machine.destroy/2` is not reached at all when there is no
    # machine, and a caller inside a transaction must be refused either way.
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with :ok <- reclaim_machine(conversation_id, sandbox_id, reason) do
        do_destroy(conversation_id, handle, reason)
      end
    end
  end

  # No machine was ever minted for this conversation; there is nothing to
  # reclaim and the rows below still move.
  defp reclaim_machine(_conversation_id, nil, _reason), do: :ok

  defp reclaim_machine(conversation_id, sandbox_id, reason) do
    case Machine.destroy(sandbox_id,
           actor: "system:conversation_server",
           reason: reason,
           notify: {conversation_id, "reclaimed", to_string(reason), reclaim_message(reason)}
         ) do
      # `:destroyed`, or `:already_terminal` for a machine someone else
      # finished first; either leaves this conversation's own bookkeeping
      # below to do.
      {:ok, _outcome} -> :ok
      {:error, _} = error -> error
    end
  end

  defp do_destroy(conversation_id, handle, reason) do
    Egress.release(conversation_id)

    conv = Conversations._unsafe_get_conversation!(conversation_id)
    if conv.status == "running", do: Conversations.update_conversation(conv, %{status: "idle"})

    # `state` is a stage-lifecycle vocabulary — LogEvent allows only
    # started/done/failed/interrupted, and both the CLI and the LiveView switch
    # on it. A reclaimed sandbox is a stage that reached its end, so "done" is
    # accurate and needs no client to learn a new word; the `reason` and
    # `message` fields carry what actually happened.
    Conversations.publish_stage(conversation_id, "sandbox", "done", %{
      event: "reclaimed",
      reason: to_string(reason),
      message: reclaim_message(reason)
    })

    :telemetry.execute([:fountain, :sandbox, :reclaimed], %{count: 1}, %{
      reason: reason,
      provider: provider(handle)
    })

    :ok
  end

  # Liveness (#2255 decision 2): "is any server alive on this machine" is one
  # question, asked by two callers that each used to scan for it themselves —
  # `Termination.reap_sandbox/1` and `Workers.SandboxReaper`'s own
  # `server_alive?/1`. One scan, exposed in the two shapes those callers need:
  # the conversation ids for the one that acts on them, the boolean for the
  # one that only decides.
  #
  # Both now read `Fountain.Machines.Occupancy` (ADR 0058 stage 4), which is
  # the same scan for every "is anyone here" question rather than for these
  # two alone. `from_preloaded/1` is the constructor that runs no query, which
  # is what keeps this usable inside the reaper's per-row passes.
  @doc """
  Conversation ids on `sandbox` with a live, registered `ConversationServer`.

  `sandbox.conversations` must already be preloaded — every caller already
  carries it from the query that fetched the sandbox (a reap target, or the
  reaper's own stuck/abandoned scan), so this runs no query of its own.
  """
  @spec live_conversation_ids(Sandbox.t()) :: [String.t()]
  def live_conversation_ids(%Sandbox{conversations: conversations} = sandbox)
      when is_list(conversations) do
    sandbox |> Occupancy.from_preloaded() |> Occupancy.live_ids()
  end

  @doc """
  Whether any conversation on `sandbox` has a live, registered
  `ConversationServer` — the same scan as `live_conversation_ids/1`, for a
  caller that only needs yes or no.
  """
  @spec any_server_alive?(Sandbox.t()) :: boolean()
  def any_server_alive?(%Sandbox{} = sandbox) do
    sandbox |> Occupancy.from_preloaded() |> Occupancy.any_live?()
  end

  # Teardown fence (#2258): the machine-policy rule every destroy, a forced
  # account deletion and a conversation's detach refuse or commit against.
  @doc """
  Commit an admission fence before a caller tears down a sandbox. No provider
  I/O runs here. The caller owns this row and must stop actors and clean up
  the provider after success. Already admitted turns may be forcibly stopped.

  The fence is the `destroying` stamp (`Fountain.Machines.Destroy.stamp_intent!/2`),
  the one every reader refuses and `Quotas` counts until the row is terminal,
  so the machine is closed to reuse and holds its capacity until retirement
  completes. Its reason is the **destroy** reason the caller is about to ask
  for (`Fountain.Machines.Destroy.reasons/0`), passed as `:transition_reason`,
  where `:reason` is this event's own wording; a caller that names none stamps
  `:teardown`. A new forced intent records `sandbox.teardown_requested`
  after commit; a repeat writes nothing and records nothing. The one stamp
  that is not a repeat is `"reset"`, which only a release from before ADR 0073
  removed the per-sandbox reset can have left: fencing over it rewrites the
  reason and records the event, so the machine goes away for the newer
  reason. (Until ADR 0058 stage 9b this fence also
  wrote `reset_requested_at` and `teardown_requested_at`, and told a repeat
  from new intent by the second.)
  Refuses an enclosing transaction. `opts` carries actor, request_ip, reason and
  `:metadata` — extra keys merged into the event, for a caller whose own delete
  is about to nilify `user_id` on both the event and the sandbox it names.

  Two options belong to the detach (ADR 0058 stage 8b,
  `Fountain.Machines.Binding.detach/2`), which is this fence with a
  terminating conversation: `refuse_busy: true` refuses `{:error, :machine_busy}`
  on a row whose owner holds a live lease, judged on the locked read and the
  database's clock, and `:deadline` refuses `{:error, :detach_expired}` when
  that clock is past it. Neither is read by the forced callers.

  With a terminating_conversation_id, first lock and verify that conversation's
  current attachment and owner. The sandbox row stays locked through the
  fence.
  """
  def fence_sandbox_for_teardown(%Sandbox{} = sandbox, opts \\ []) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      case do_fence_sandbox_for_teardown(sandbox, opts) do
        {:ok, {fenced, true}} ->
          Audit.record(%{
            user_id: fenced.user_id,
            action: "sandbox.teardown_requested",
            resource_type: "sandbox",
            resource_id: fenced.id,
            # ADR 0013 keeps `admin:<operator_id>` for account deletion alone,
            # so an operator reaping a machine from /admin/sandboxes records
            # the plain `admin` the vocabulary allows here.
            actor: teardown_actor(Keyword.get(opts, :actor, "self")),
            request_ip: Keyword.get(opts, :request_ip),
            metadata:
              Map.merge(
                %{
                  "reason" => Keyword.get(opts, :reason, "teardown"),
                  "provider" => fenced.provider
                },
                Keyword.get(opts, :metadata, %{})
              )
          })

          {:ok, fenced}

        {:ok, {fenced, false}} ->
          {:ok, fenced}

        {:error, _} = error ->
          error
      end
    end
  end

  @doc """
  The actor string a machine-lifecycle event records, from the one a caller
  gave.

  ADR 0013 reserves `admin:<operator_id>` for account deletion alone, so an
  operator reaping a machine from /admin/sandboxes records the plain `admin`
  the vocabulary allows. Public since ADR 0058 stage 5 so `sandbox.destroyed`
  and this module's own `sandbox.teardown_requested` cannot disagree about who
  did it: the two events describe one operation.
  """
  @spec teardown_actor(String.t()) :: String.t()
  def teardown_actor("admin:" <> _), do: "admin"
  def teardown_actor(actor), do: actor

  defp do_fence_sandbox_for_teardown(sandbox, opts) do
    ending_id = Keyword.get(opts, :terminating_conversation_id)

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @sandbox_lock_namespace,
        Conversations.sandbox_lock_key(sandbox.id)
      ])

      # Match admission's advisory -> conversation -> workspace -> sandbox
      # lock order (`Machines.Lease`'s, ADR 0097).
      lock_terminating_conversation(sandbox, ending_id)

      current = Lease.lock_machine(sandbox.id, :update) || Repo.rollback(:not_found)

      # The detach's two refusals, on the locked row and the database's clock
      # (stage 8b). Before the policy: a machine an owner is operating on is
      # not one to decide anything about, and a caller that has left is not
      # one to decide for.
      refuse_busy_or_expired(current, opts)

      # Forced teardown may stop an admitted turn.
      cond do
        current.status in @terminal_statuses ->
          {current, false}

        # A forced teardown is already asked for: a repeat, which writes nothing
        # and records no second intent. A pre-ADR-0073 reset's stamp is not
        # one — escalating it is new intent, below.
        current.transition == "destroying" and current.transition_reason != "reset" ->
          {current, false}

        # New intent, or a leftover reset escalated to a forced teardown, which
        # rewrites the reason: the machine is going away for the newer reason. The whole
        # write is the stamp (ADR 0058 stage 9b), in the owner's namespace and
        # this transaction — see `Destroy.stamp_intent!/2`.
        true ->
          {Destroy.stamp_intent!(current, transition_reason(opts)), true}
      end
    end)
  end

  # What the fence writes into `transition_reason`.
  #
  # **The destroy vocabulary, not this module's** (`Machines.Destroy.reasons/0`),
  # and the distinction is the whole of surfaces' S1. The fence's own `:reason`
  # is the *event's* wording — "conversation_terminated", "agent_deleted",
  # "reaped" — and `Machines.Destroy` documents at length that the two
  # vocabularies are deliberately different. Before stage 9a this column only
  # ever held the destroy vocabulary, because `Destroy.stamp_then_destroy/3`
  # wrote it; 9a made the fence stamp first and the protocol continue from that
  # stamp without writing its own, so a fence that wrote its own word here would
  # have silently changed what the column means and made `SandboxReaper`'s
  # driver record `teardown` where the owner records `terminated`.
  #
  # So the caller passes `:transition_reason` — the atom it is about to hand
  # `Destroy` as `:reason` — and every caller that knows one does. A caller that
  # does not gets `:teardown`, the word this module's own event defaults to and
  # the one `Destroy.reason_from_string/1` falls back to: one unknown, spelled
  # the same at both ends.
  #
  # Total over what a caller can pass, which the first draft was not: it read
  # the caller-supplied `:reason` straight into the changeset, so a non-binary
  # one — and `:reason` carries interpolated provider errors on several paths —
  # raised `Ecto.ChangeError` from inside the fence's transaction, a crash path
  # that did not exist before this stage (protocol review). Only an atom or a
  # binary is a reason; anything else is the unknown, spelled `:teardown` at
  # both ends.
  defp transition_reason(opts) do
    case Keyword.get(opts, :transition_reason, :teardown) do
      reason when is_atom(reason) and not is_nil(reason) -> Atom.to_string(reason)
      reason when is_binary(reason) -> reason
      _other -> "teardown"
    end
  end

  # One clock read, and only for a caller that asked for either check: the
  # forced callers pay nothing. `statement_timestamp()` advances between
  # statements, so this is the instant after the locked read rather than the
  # transaction's start.
  defp refuse_busy_or_expired(current, opts) do
    refuse_busy? = Keyword.get(opts, :refuse_busy, false)
    deadline = Keyword.get(opts, :deadline)

    if refuse_busy? or not is_nil(deadline) do
      if refuse_busy? and Machine.busy?(current), do: Repo.rollback(:machine_busy)
      if Binding.expired?(deadline, Machine.db_now()), do: Repo.rollback(:detach_expired)
    end

    :ok
  end

  defp lock_terminating_conversation(_sandbox, nil), do: :ok

  defp lock_terminating_conversation(sandbox, ending_id) when is_binary(ending_id) do
    Repo.one(
      from c in Conversation,
        where:
          c.id == ^ending_id and c.sandbox_id == ^sandbox.id and c.user_id == ^sandbox.user_id,
        select: c.id,
        lock: "FOR UPDATE"
    ) || Repo.rollback(:sandbox_unavailable)
  end

  defp minutes(nil), do: "?"
  defp minutes(seconds), do: div(seconds, 60)
  defp hours(nil), do: "?"
  defp hours(seconds), do: div(seconds, 3600)
end
