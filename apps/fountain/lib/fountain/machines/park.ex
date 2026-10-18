defmodule Fountain.Machines.Park do
  @moduledoc """
  One park protocol for one machine (ADR 0058, stage 6b; closes #2307).

  A park is the only machine operation with a provider round trip *between*
  the decision and the write, and that is the whole of #2307. Both parks on
  `main` read the row, asked the provider to suspend, and then wrote
  `suspended` — `Fountain.Conversations.Lifecycle.park/4` from a conversation
  server's idle or ceiling tick, `Fountain.Workers.SandboxReaper.idle_sweep/2`
  from the hourly sweep — and neither held anything across the gap. A wake
  landing in it resumed a machine that was about to be suspended, or was
  suspended out from under; #2286 tried to close that with a lock and a
  durable claim, went five adversarial review rounds, and was withdrawn. This
  module is the answer the ADR settled on: a lease, an intent on the row, the
  provider outside every lock, and a compare-and-set finalize.

  `Fountain.Machines.Destroy` is the same shape for the other verb, and where
  the two agree they agree on purpose — the same lease, the same busy wait,
  the same "audit after commit, outside every transaction".

  ## The steps

  1. Refuse an enclosing transaction. Provider I/O is never inside a lock or a
     transaction (ADR 0058; #2309).
  2. **Claim a lease** (`Fountain.Machines.Lease.claim/2`) for one operation.
     A lease held by somebody else is waited on, briefly, then refused as
     `{:error, :machine_busy}`.
  3. **Revalidate under the lease** (#2307 constraint 1). A verdict taken
     before the claim is stale by construction, so *every* condition the
     caller decided on is re-read from the locked row and re-applied here:
     the status, the two fences, the provider's capability, whether anybody
     is on the machine, and — for a caller that supplies one — the bound its
     verdict named. Any of them refuses, and the lease is released.
  4. **Stamp the intent**: `transition: "parking"` by compare-and-set on the
     lease epoch, before any provider I/O. `Machines.Machine.busy?/1` already
     refuses a wake, an attach and the rehydrator on a live lease (stage 6a),
     so from here until the finalize nothing starts work on this machine; the
     stamp is what makes an *abandoned* park recognisable to the next owner.
  5. (A checkpoint of a persistent home was taken here until homes were
     removed, #2676.)
  6. **Suspend at the provider**, outside every transaction and every lock.
     An error — or a raise, which is the same outcome by 5a's rule — clears the
     transition, releases the lease and answers `{:error, :suspend_failed}`.
     Both callers degrade to a destroy on that, which is the rule ADR 0017
     priced: a park *call* that fails leaves the machine billing, so the cost
     control wins over the agent's memory.
  7. **Finalize**: `status: "suspended"` and the transition cleared, by
     compare-and-set on the same epoch. Zero rows means a newer epoch owns the
     machine — `{:error, :superseded}`, and the taker is the one allowed to say
     what happened to it.
  8. Release the lease. Then one `sandbox.suspended` audit event, and the
     co-tenant notice the caller supplied.
  9. `{:ok, :parked}`.

  ## Takeover

  A claim that finds `transition: "parking"` on a live row is looking at a park
  whose owner died between step 4 and step 7. Unlike a destroy, this one cannot
  simply be continued: destroying a machine twice is destroying it once, but
  *suspending* one twice is not safe to assume, and — worse — the previous
  owner may have suspended it already, in which case a second suspend and a
  finalize would be right while a resume would be wrong, and nothing on the row
  says which.

  So the taker asks the machine (`Managoat.Sandbox.get/1`) and compensates from
  the answer:

    * `:suspended` — the suspend landed and only the finalize was lost. The
      compensation *is* the finalize: write `suspended`, run the effects, audit.
      `{:ok, :parked}`.
    * `:running` — the suspend had not landed (or, on Sprites, never does
      anything: its suspend is a no-op and the machine scales to zero by
      itself). Clear the transition, leave the row `ready`, `{:ok, :recovered}`.
      The next idle verdict parks it again, through this same protocol, from
      the top.
    * anything else — `:unknown`, `:not_found`, a provider error, a raise —
      reads as running. Clearing a transition is always safe: it returns the
      row to the state every reader already handles, and the machine is
      re-examined on the next pass. Leaving a stale `parking` past one pass is
      the thing that is not safe, which is why there is no fourth branch.

  Never both. The taker resumes nothing: a resume is compute, and #2307
  constraint 5 puts compute behind the admission gates (the fleet ceiling) that
  this module does not consult. The salvage branch's compensating resume
  (`follow/2255-reaper-liveness-lock`, round 5) existed because the claim there
  was not a lease and a *successful* suspend could land after the claim was
  taken over; here the finalize is a compare-and-set on the epoch, so a
  superseded owner's suspend changes no row at all and the taker's reading of
  the machine is the only one that writes.

  `SandboxReaper.sweep_abandoned_sandboxes/0` already lists such rows — they
  are `ready`, past a bound, with no live server — so the reaper's own idle
  park is the takeover path, and it happens on the first pass that sees the
  row.

  ## The lease across the provider calls

  The lease is held for as long as this owner lives (ADR 0072), so a park
  slower than any bound keeps its machine to the end: nobody can take the row
  over and clear the transition while the suspend is still in flight. Until
  ADR 0072 a renewal timer kept a TTL lease alive across the checkpoint and the
  suspend, and the 6b review found what a lapsed one left behind — a machine
  genuinely suspended behind a row that said `ready`.

  The other half of that review note — `Wake.probe_sandbox/4` reusing a machine
  on any `{:ok, _info}` without reading its status, which on E2B
  means reusing one that is actually stopped — closed in 7a as well:
  `Fountain.Machines.Resume` reads the status and brings such a machine up.

  ## Outcomes

  `{:ok, :parked}` parked the machine. `{:ok, :already_parked}` is a row that
  was already `suspended` — somebody else's park, or this one superseded after
  its provider call. `{:ok, :already_terminal}` is a row that had stopped.
  `{:ok, :recovered}` is the takeover above finding the machine still running:
  nothing was parked, and nothing is wrong.

  The `{:error, _}` shapes are the *protocol's* vocabulary — `:machine_busy`
  (the lease), `:machine_occupied` (somebody is on the machine), `:fenced`,
  `:cannot_park`, `:not_expired`, `:suspend_failed`, `:superseded`, and
  whatever `Lease` hands back. They are precise on purpose and they are not the
  vocabulary the rest of the system speaks: `Fountain.Machines.Machine.park/2`
  is the door and translates them.

  Step 1's transaction guard is process-local, so with the gate on it cannot
  fire here — the protocol runs in the owner, which is never inside the
  caller's transaction. `Machine.park/2` checks before it dispatches, for the
  same reason `destroy/2` does.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.MachineEvents
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Occupancy
  alias Fountain.Machines.Reads
  alias Fountain.Repo

  require Logger

  @typedoc """
  What a park did. `:parked` ran the protocol through (or finished one whose
  owner died after its suspend); `:already_parked` is a row that was already
  `suspended`; `:already_terminal` a row that had stopped; `:recovered` an
  abandoned park cleared off a machine that turned out to be still running.
  """
  @type outcome :: :parked | :already_parked | :already_terminal | :recovered

  @typedoc "The bound a caller's verdict named, for the recheck at step 3."
  @type verdict :: {:expired, :idle | :max_lifetime}

  # How long a *waiter* waits for a holder. `Destroy`'s number, and for the
  # same reason: it bounds the caller, and a wait as long as an operation is
  # what once made a `DELETE` hang for a minute. A park
  # that cannot get the lease in five seconds leaves the machine to the next
  # tick or the next sweep, both of which come round again.
  @busy_wait_ms 5_000

  # How often the wait re-asks.
  @poll_ms 250

  @terminal_statuses ~w(terminated failed)

  @doc """
  Park the machine behind `sandbox_id`.

  Options:

    * `:actor` (required) — the audit actor for `sandbox.suspended`, from
      ADR 0013's vocabulary. The two callers pass
      `"system:conversation_server"` and `"system:sandbox_reaper"`.
    * `:reason` (required, an atom) — `:idle` or `:max_lifetime`, the bound
      that decided on this park. Becomes `transition_reason` on the row and
      `"reason"` in the audit metadata.
    * `:requesting_conversation_id` — the caller's own conversation. Supplying
      it says "I am a server bound to this machine", and it chooses the
      occupancy rule at step 3 as well as excluding the caller from it: see
      `occupancy_and_clock/2`. The reaper omits it, which is what makes *any*
      live server refuse its park.
    * `:verdict` — `{:expired, :idle | :max_lifetime}`, the reading the caller
      acted on, re-applied under the lease at step 3. See `still_expired?/3`
      for what it does and why only one caller supplies one.
    * `:notify` — `{conversation_id, event, reason, message}`, the notice to
      cast to the machine's other conversations once it is parked. The server
      supplies the "suspended" notice it has always sent; the reaper supplies
      none, as it never has.
    * `:request_ip` — attribution, passed to the audit event.
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
    * `:read_window_ms` — the bound on waiting for sandbox-files reads
      admitted before the claim (`Machines.Reads.drain/2`). Tests shorten it;
      no call site does.
  """
  @spec run(Ecto.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    opts = validated(opts)

    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      claim_and_park(sandbox_id, opts)
    end
  end

  @doc """
  How long `run/2` waits for a lease somebody else holds before refusing.

  Public so `machine_bounds_test.exs` can pin it against the two bounds it has
  to sit between, rather than against a number a test passed in itself.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  # The two required options, checked before anything is claimed or written,
  # and raised on rather than answered: both are caller bugs. Same rule, and
  # the same two words, as `Machines.Destroy.validated/1`.
  defp validated(opts) do
    _actor = Keyword.fetch!(opts, :actor)

    case Keyword.fetch!(opts, :reason) do
      reason when reason in [:idle, :max_lifetime] ->
        :ok

      other ->
        raise ArgumentError,
              "Machines.Park: :reason must be :idle or :max_lifetime, got #{inspect(other)}"
    end

    case Keyword.get(opts, :verdict) do
      nil -> :ok
      {:expired, bound} when bound in [:idle, :max_lifetime] -> :ok
      other -> raise ArgumentError, "Machines.Park: bad :verdict #{inspect(other)}"
    end

    opts
  end

  # ── the lease around one operation ────────────────────────────────────────

  defp claim_and_park(sandbox_id, opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

    case claim(sandbox_id, deadline) do
      {:ok, epoch} ->
        try do
          under_lease(sandbox_id, epoch, opts)
        after
          # `after`, not a plain next statement: a provider adapter that raises
          # unwinds through here, and a lease left held would keep this machine
          # unclaimable for as long as this owner lives, and every wake of it
          # would answer 503. Releasing keeps the epoch, so it is safe on
          # every path, including one already superseded.
          _ = Lease.release(sandbox_id, epoch)
        end

      # A sandbox with no workspace has no owner (ADR 0097); see
      # `Lease.unowned/1`.
      {:error, :no_workspace} ->
        case Lease.unowned(sandbox_id) do
          {:terminal, _sandbox} -> {:ok, :already_terminal}
          :live -> {:error, :machine_busy}
          :not_found -> {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  # A lease somebody else holds is waited out rather than refused outright: a
  # reaper pass and a server's idle tick arriving on one machine together is
  # the ordinary case, and the second one wants the first one's answer.
  #
  # `:sandbox_unavailable` is waited out the same way, and that is the point of
  # it: since stage 6b `Conversations.with_sandbox_lock/2` sets a
  # `lock_timeout`, so a claim that would once have blocked on advisory lock
  # 4316 comes back with that word instead. Out of `Lease.claim/2` it can mean
  # nothing else, and what it means is "somebody is holding the lock right
  # now" — the condition this loop exists for. Refusing on it would turn a
  # moment's contention into a failed park.
  defp claim(sandbox_id, deadline) do
    case Lease.claim(sandbox_id) do
      {:ok, epoch} ->
        {:ok, epoch}

      {:error, {:held, holder}} ->
        retry_or_refuse(sandbox_id, deadline, "lease held by #{holder}")

      {:error, :sandbox_unavailable} ->
        retry_or_refuse(sandbox_id, deadline, "the sandbox lock is held")

      {:error, _} = error ->
        error
    end
  end

  defp retry_or_refuse(sandbox_id, deadline, why) do
    if System.monotonic_time(:millisecond) + @poll_ms < deadline do
      Process.sleep(@poll_ms)
      claim(sandbox_id, deadline)
    else
      Logger.warning("machine #{sandbox_id}: park refused, #{why}")
      {:error, :machine_busy}
    end
  end

  # ── the protocol ──────────────────────────────────────────────────────────

  defp under_lease(sandbox_id, epoch, opts) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      # A park that finished, or a machine somebody else stopped, still wearing
      # the stamp. Checked before the takeover clause for the same reason
      # `Destroy` checks it first: continuing from a settled row would call the
      # provider again and record a second event for something already done.
      %Sandbox{transition: "parking", status: status} = settled
      when status in @terminal_statuses ->
        clear_transition(settled, epoch)
        {:ok, :already_terminal}

      %Sandbox{transition: "parking", status: "suspended"} = settled ->
        clear_transition(settled, epoch)
        {:ok, :already_parked}

      # Step 4 landed and step 7 did not. This lease is the takeover.
      %Sandbox{transition: "parking"} = interrupted ->
        take_over(interrupted, epoch, opts)

      # Somebody else's abandoned operation — a destroy or a reset that died
      # mid-flight. Its own protocol takes it over (`Destroy`'s continuation
      # clause, the reset reconciler); a park must not write over the intent,
      # and the fence that accompanies it would refuse below in any case. Named
      # here so the refusal says which state it saw.
      %Sandbox{transition: other} = sandbox when not is_nil(other) ->
        Logger.info("machine #{sandbox.id}: park refused, another owner left #{other} on the row")

        {:error, :fenced}

      %Sandbox{} = sandbox ->
        with :ok <- admissible(sandbox, opts) do
          stamp_then_park(sandbox, epoch, opts)
        end
    end
  end

  # Step 3. Every condition the caller decided on, re-read under the lease, in
  # the order that makes the answer most useful: what the row *is*, then what
  # has been asked of it, then what the provider can do, then who is on it,
  # then the clock.
  defp admissible(%Sandbox{status: status}, _opts) when status in @terminal_statuses,
    do: {:ok, :already_terminal}

  defp admissible(%Sandbox{status: "suspended"}, _opts), do: {:ok, :already_parked}

  defp admissible(%Sandbox{} = sandbox, opts) do
    cond do
      # No fence clause here since stage 9b. A fence is the `destroying` stamp,
      # and `under_lease/3` refuses every stamp that is not this park's own —
      # `destroying` among them — before this is reached, so a copy here would
      # be a guard no test could break (9a's rule for `Resume.admissible/2`).
      # Until 9b this read the two fence columns, which a row could carry with
      # no stamp at all. Why a fenced machine is refused: it is on its way out,
      # and parking it would write a live status over a row
      # `sweep_fenced_teardowns/0` is about to finish.
      Lifecycle.idle_action(Conversations.sandbox_provider_atom(sandbox)) == :destroy ->
        {:error, :cannot_park}

      true ->
        occupancy_and_clock(sandbox, opts)
    end
  end

  # Who is on the machine, and is it still past a bound — the two questions the
  # caller answered before it claimed, asked again where the answer can be
  # acted on.
  #
  # **The running-turn check is nearly unconditional** — `running_turn_veto?/2`
  # has the one exception and why. A server a wake is starting is already in
  # the registry: `Conversations.register_server/2` starts it under the
  # per-sandbox lock this park's claim took (ADR 0072).
  #
  # **The third depends on whom the caller speaks for**, and the two policies
  # here are the two that exist on `main`, kept apart on purpose.
  #
  #   * A caller with a `requesting_conversation_id` is a conversation server
  #     bound to this machine, and its question is ADR 0023 step 5's: is any
  #     *other* conversation active inside the idle window? A co-tenant whose
  #     server is live but idle is not activity — that is the whole reason
  #     `notify` exists, and refusing on it would mean two idle conversations
  #     on one home could never park it, each vetoing the other, until both
  #     servers died and the reaper did it. The busiest production machine
  #     carries 36 (ADR 0023).
  #   * A caller with none is a sweep, acting on nobody's behalf, and *any*
  #     live `ConversationServer` refuses it. That is the reaper's rule
  #     unchanged: its idle pass exists for machines with nothing watching
  #     them, and a machine with a server has one enforcing its own bounds.
  #
  # **The clock is the caller's verdict, re-run.** See `still_expired?/3`.
  defp occupancy_and_clock(%Sandbox{} = sandbox, opts) do
    occupancy = Occupancy.load(sandbox)

    cond do
      running_turn_veto?(occupancy, opts) ->
        {:error, :machine_occupied}

      held_by_somebody_else?(occupancy, Keyword.get(opts, :requesting_conversation_id)) ->
        {:error, :machine_occupied}

      still_expired?(sandbox, occupancy, Keyword.get(opts, :verdict)) ->
        :ok

      true ->
        {:error, :not_expired}
    end
  end

  # A turn running on the machine, and whose turn counts.
  #
  # For every caller but one, any turn anywhere: the idle bound's whole premise
  # is that nothing is running, so a turn found here means the verdict was
  # wrong, and the reaper's sweep is for machines nobody is using at all.
  #
  # **The max-lifetime ceiling is the exception, and it is the case the ceiling
  # exists for.** `Lifecycle.check/4` lets `{:expired, :max_lifetime}` through
  # with `busy?` true on purpose — the absolute bound is there for the
  # conversation that never stops being busy — so a server reaching this with
  # its own turn in flight is the normal way the ceiling fires, not a race. Its
  # own turn is what the park is cutting (`Lifecycle.explain(:max_lifetime,
  # :suspend)` says so to the user: "a turn in flight was cut"), and treating
  # it as a veto made the ceiling unable to park a home at all: the server had
  # already dropped its adapter by then, so the turn it left `running` had
  # nothing to end it, the server stayed up, and the machine went on billing
  # while the ceiling re-fired every minute. `main` parked, stopped the server,
  # and let `terminate/2` orphan the turn — which is what this restores.
  #
  # Another conversation's running turn still refuses. This conversation's
  # clock reaching a ceiling is not a reason to cut somebody else's work on the
  # same machine, and `main` never had to decide that because it did not ask.
  # **And a turn nothing is driving is not occupancy.** A `running` turn row
  # whose conversation has no live `ConversationServer` is a leftover, and one
  # shape of it never goes away on its own: a turn parked on a human's
  # permission decision, whose server then died. `SandboxReaper.sweep_stuck_turns/0` skips
  # those by design — a person may still answer — so the row stays `running`
  # for ever, and counting it refused the park for ever with it. `main` had no
  # turn check at all and its reaper reclaimed that machine; a stage that says
  # it does not change reclamation must not strand it.
  #
  # That closes the strand for the **reaper**, which is where it was stranded:
  # a machine with no live server anywhere is parked whatever its leftover turn
  # rows say. It does not close it for a *server* whose own turn is parked on a
  # permission nobody answers — that server never asks for an idle park at all,
  # because `Lifecycle.check/4` suppresses the idle verdict while
  # `current_turn` is set. That is `main`'s behaviour unchanged, and it means
  # such a machine is reclaimed by the ceiling and by nothing else, so
  # `SANDBOX_MAX_LIFETIME_HOURS` — off by default — is its only backstop. The
  # real answer is a deadline on an unanswered permission, which is neither
  # this stage's nor this module's.
  #
  # The requester is the exception to the exception: it *is* the thing driving
  # its own turn, so its own counts whether or not the registry agrees (and in
  # a test there is no registered server at all).
  defp running_turn_veto?(%Occupancy{} = occupancy, opts) do
    requester = Keyword.get(opts, :requesting_conversation_id)
    ceiling? = Keyword.fetch!(opts, :reason) == :max_lifetime
    live = MapSet.new(Occupancy.live_ids(occupancy))

    occupancy
    |> Occupancy.running_turn_ids()
    |> Enum.any?(fn conv_id ->
      if conv_id == requester,
        do: not ceiling?,
        else: MapSet.member?(live, conv_id)
    end)
  end

  defp held_by_somebody_else?(%Occupancy{} = occupancy, nil),
    do: Occupancy.any_live?(occupancy)

  defp held_by_somebody_else?(%Occupancy{} = occupancy, requester),
    do: Occupancy.busy_elsewhere?(occupancy, requester, Lifecycle.idle_timeout_seconds())

  @doc """
  Is the machine still past a lifetime bound, given the verdict its caller
  acted on?

  `nil` — no verdict — is always true, and that is a decision rather than an
  omission. Of the two callers only one carries a verdict that can go stale:
  `SandboxReaper` scans a page of `ready` rows, folds each one's activity, and
  then parks them one at a time, so by the time a park at the end of the list
  claims its lease its reading is minutes old and a wake may have landed in
  between. That is #2307 constraint 1 in the shape it was first found in, and
  the salvage branch's "admission wins the lock" cases are about exactly it.

  A conversation server decides on its own tick and asks in the same breath,
  and what could invalidate that decision in between — a co-tenant starting a
  turn, a wake registering a server — is the liveness half above, which it gets
  unconditionally. Re-deriving its verdict here from the machine-wide fold
  would also be a different question from the one it asked: its own
  `last_activity_at` moves on requests that insert no turn row.

  When a verdict *is* supplied, the recheck asks whether the machine is still
  past **some** bound, not the same one. A reaper that decided `:max_lifetime`
  on a row now merely idle still parks it — the machine is expired either way,
  and `transition_reason` records what the caller decided. What it refuses is a
  machine that is past nothing at all, which is what a wake landing between the
  scan and the claim leaves behind.
  """
  @spec still_expired?(Sandbox.t(), Occupancy.t(), verdict() | nil) :: boolean()
  def still_expired?(sandbox, occupancy, verdict)

  def still_expired?(_sandbox, _occupancy, nil), do: true

  def still_expired?(%Sandbox{} = sandbox, %Occupancy{} = occupancy, {:expired, _bound}) do
    last_activity_at = Occupancy.last_activity_at(occupancy) || sandbox.inserted_at

    match?(
      {:expired, _},
      Lifecycle.check(Lifecycle.clock_start(sandbox), last_activity_at, false)
    )
  end

  defp stamp_then_park(sandbox, epoch, opts) do
    # The turn this park cuts is ended **before** the stamp, in its own
    # committed write and not the stamp's transaction, so there is no window in
    # which a `running` turn sits on a `parking` row — the reading a recovering
    # actor or a cotenant's admission would otherwise take (stage 8b, the
    # lead's condition on the cut). See `end_cut_turn/2`.
    #
    # The price of that order, and why it is still the right one (round 1,
    # surfaces review): a `parking` stamp that is then refused — `:stale`
    # against a newer epoch, `:retired` against a terminal row — has already
    # written the turn `interrupted` with the reason `machine_parked`, for a
    # park that did not happen. The alternative is a window where the turn is
    # `running` on a row that says `parking`, and that window is read by two
    # things that then do the wrong work: a cotenant's admission counts the
    # turn against capacity on a machine going to sleep, and a recovering actor
    # takes it for a turn it should finish. A wrong word on a turn the ceiling
    # was cutting anyway is the cheaper error, and only the ceiling reaches
    # here — the server has already dropped its adapter by then, so the turn was
    # over either way. Between the two committed writes a second connection sees
    # an interrupted turn on an unstamped row under a live lease, which is a
    # state nothing refuses.
    end_cut_turn(sandbox, opts)

    case Lease.cas_update(sandbox.id, epoch,
           transition: "parking",
           transition_reason: to_string(Keyword.fetch!(opts, :reason))
         ) do
      {:ok, %Sandbox{} = marked} -> suspend_under_lease(marked, epoch, opts)
      {:error, :stale} -> {:error, :superseded}
      {:error, :retired} -> {:ok, :already_terminal}
      {:error, _} = error -> error
    end
  end

  # Steps 5 and 6, both outside every lock and every transaction, with the
  # intent already on the row.

  defp suspend_under_lease(%Sandbox{} = sandbox, epoch, opts) do
    # Before the provider call, a sandbox-files read admitted before this
    # park's claim is waited out (#2394): the suspend must not overlap its
    # exec. Bounded by `Reads.window_ms/0`, since no read is admitted while
    # this lease is live.
    :ok = Reads.drain(sandbox.id, Keyword.take(opts, [:read_window_ms]))
    after_suspend(sandbox, epoch, opts, suspend_at_provider(sandbox))
  end

  defp after_suspend(%Sandbox{} = sandbox, epoch, opts, provider_result) do
    case provider_result do
      :ok ->
        finalize(sandbox, epoch, opts)

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: provider suspend failed for #{sandbox.machine_name} " <>
            "on #{sandbox.provider}: #{inspect(reason)}"
        )

        # The transition comes off before the answer goes back, so the machine
        # is left exactly as it was found: `ready`, unfenced, claimable. The
        # caller degrades to a destroy from here and that destroy takes its own
        # lease, which this one is about to release.
        clear_transition(sandbox, epoch)
        {:error, :suspend_failed}
    end
  end

  # There is no "no machine to call" case: `machine_name` is `NOT NULL` and
  # required by `Sandbox.changeset/2`, so a row that exists names a machine.
  # `main`'s `Lifecycle.suspend/1` had a `nil` clause because it was handed the
  # *server's* handle, which a server without one passes as `nil`; the owner
  # reads the machine off the row and never has that problem.
  defp suspend_at_provider(%Sandbox{} = sandbox) do
    handle =
      sandbox
      |> Conversations.sandbox_provider_atom()
      |> Managoat.Sandbox.build_handle(sandbox.machine_name)

    with :ok <- Fountain.Broker.TransportRelay.stop(handle) do
      Managoat.Sandbox.suspend(handle)
    end
  rescue
    # An adapter that raises rather than answering is the same outcome as one
    # that returns an error — this machine was not parked — so it is treated
    # the same and logged in full (5a's rule, `Destroy.destroy_at_provider/2`).
    # The difference from a destroy is what follows: a destroy finalizes anyway
    # because a fenced row must not be stranded, while a park that did not
    # happen must not be written down as one.
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  end

  defp finalize(%Sandbox{} = sandbox, epoch, opts) do
    case Lease.cas_update(sandbox.id, epoch,
           status: "suspended",
           transition: nil,
           transition_reason: nil
         ) do
      {:ok, %Sandbox{} = parked} ->
        audit(parked, opts)
        notify_cotenants(parked, opts)
        {:ok, :parked}

      {:error, :stale} ->
        # A newer epoch owns this machine. The suspend above may well have
        # landed; the taker reads the machine's true state and is the one
        # allowed to say what happened to it. The caller is told the machine is
        # parked or parking, which is what `:superseded` means at the door.
        Logger.warning("machine #{sandbox.id}: park superseded before its finalize")
        {:error, :superseded}

      {:error, :retired} ->
        {:ok, :already_terminal}

      {:error, _} = error ->
        error
    end
  end

  # ── takeover ──────────────────────────────────────────────────────────────

  # A takeover is a park, so it revalidates like one.
  #
  # The first draft went from the provider probe straight to the finalize,
  # which made the takeover the one path into `suspended` that checked
  # nothing — no fence, no running turn, no `woken_at`, no capability. That is
  # not a narrow window, because **nothing clears a `parking` stamp off a row
  # whose holder has died except an owner**: `Machine.busy?/1` ignores it by
  # 6a's design, and a wake that reuses such a row leaves it exactly where it
  # is. So an abandoned park, a wake, a fresh turn and then any later park
  # would have written `suspended` over a machine in use — the ordinary path's
  # `:machine_occupied`, turned into `{:ok, :parked}` by the takeover clause.
  # A teardown fence landing on a stamped row was overwritten the same way.
  #
  # Since stage 6b `Conversations.register_server/2` also clears a lease-less
  # stamp on its way past, so the reader half of that story is closed too; the
  # two agree, and this is the half that must hold even if a reader forgets.
  defp take_over(%Sandbox{} = sandbox, epoch, opts) do
    Logger.info(
      "machine #{sandbox.id}: taking over an abandoned park " <>
        "(#{sandbox.transition_reason || "no reason"}) at epoch #{epoch}"
    )

    case admissible(sandbox, opts) do
      :ok ->
        compensate(sandbox, epoch, opts)

      # Not this park's machine any more. Clear the intent its owner left —
      # otherwise the row goes on lying about what is happening to it, and the
      # next owner inherits the same question — and refuse exactly as the
      # ordinary path would have.
      refusal ->
        Logger.info(
          "machine #{sandbox.id}: abandoned park is no longer admissible " <>
            "(#{inspect(refusal)}); clearing the stamp"
        )

        clear_transition(sandbox, epoch)
        refusal
    end
  end

  defp compensate(%Sandbox{} = sandbox, epoch, opts) do
    case machine_state(sandbox) do
      :suspended ->
        # The suspend landed and the finalize was lost. Finishing it *is* the
        # compensation. The audit and the effects run here and not in the dead
        # owner, which is the only place they can run: it is gone.
        finalize(sandbox, epoch, opts)

      :running ->
        clear_transition(sandbox, epoch)
        {:ok, :recovered}
    end
  end

  # What the machine says about itself, folded to the only two answers a
  # takeover can act on.
  #
  # `:unknown` and every error — including `:not_found`, which E2B answers for
  # a machine that is gone — fold to `:running`, because the safe compensation
  # is the one that writes the least: clearing the transition leaves a `ready`
  # row, which is the state every reader already handles, and the next pass
  # looks again. Writing `suspended` on a guess would hide a machine that is
  # still up and billing behind a status no sweep examines (decisions/0017).
  #
  # Sprites is worth naming: its `suspend/1` is a no-op — the sprite scales to
  # zero on its own schedule — so its `get/1` answers `:running` for a machine
  # a park had just "suspended", and such a takeover clears rather than
  # finalizes. Not *always*: the same sprite reports `stopped` once it has
  # actually scaled to zero, which `normalize_status/1` folds to `:suspended`
  # and this finalizes. Both answers are right for Sprites, because there the
  # park is a row write and nothing at the provider was left half-done either
  # way.
  defp machine_state(%Sandbox{} = sandbox) do
    handle =
      Conversations.sandbox_provider_atom(sandbox)
      |> Managoat.Sandbox.build_handle(sandbox.machine_name)

    case Managoat.Sandbox.get(handle) do
      {:ok, %{status: :suspended}} ->
        :suspended

      {:ok, %{status: status}} ->
        Logger.info("machine #{sandbox.id}: provider reports #{status}; recovering to ready")
        :running

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: provider could not say whether #{sandbox.machine_name} " <>
            "is parked (#{inspect(reason)}); recovering to ready"
        )

        :running
    end
  rescue
    error ->
      Logger.warning(
        "machine #{sandbox.id}: provider raised while probing #{sandbox.machine_name}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :running
  end

  # Clearing the stamp is what makes the column mean something again: while it
  # is set on a row nobody is working on, "is this machine mid-park?" cannot be
  # answered from the row, which is the column's only job. A status-free write
  # is not a revival, so `Lease.refuse_revival/2` lets it through even on a
  # terminal row. A refusal here belongs to whoever superseded us and is logged
  # rather than returned: the caller's answer does not depend on it.
  defp clear_transition(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(sandbox.id, epoch, transition: nil, transition_reason: nil) do
      {:ok, _cleared} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: could not clear a parking stamp (#{inspect(reason)})"
        )
    end

    :ok
  end

  # The one turn a park operates over is the requester's own at the ceiling —
  # `running_turn_veto?/2`'s exception, the turn the park is cutting — and the
  # owner ends it (stage 8b) rather than leaving it to the server's own
  # `terminate/2`, so the recovery that server makes on its way out finds the
  # turn already terminal. Every other running turn refused the park, or is a
  # turn nothing is driving that stage 6b deliberately leaves standing: a turn
  # parked on a person's permission whose server has died is still theirs to
  # answer, and a park is not the machine going away.
  #
  # Strictly before the `parking` stamp, under the lease, and not after the
  # finalize: from the stamp on, a reader that finds this turn `running` on a
  # `parking` row would be reading a state that never has to exist. The cost
  # is a turn ended for a park the stamp then refuses (`:stale`, `:retired`),
  # and it is no cost: the server that asked has already dropped its adapter
  # at the ceiling, so the turn could not have continued either way.
  #
  # The second door (rule 16) is the server ending the same turn itself, in
  # either order: `end_turn/3` on a turn already terminal is `:noop` and
  # records nothing, whichever side got there first. `binding_test.exs` drives
  # both orders.
  defp end_cut_turn(%Sandbox{} = sandbox, opts) do
    with :max_lifetime <- Keyword.fetch!(opts, :reason),
         requester when is_binary(requester) <- Keyword.get(opts, :requesting_conversation_id) do
      Admission.end_turns_on(sandbox.id, "machine_parked",
        only: requester,
        actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor))
      )
    else
      _ -> :ok
    end
  end

  # One `sandbox.suspended` event for both paths, and that is a change: on
  # `main` the reaper recorded one (`record_reap/3`) and the conversation
  # server's park recorded nothing at all, so the same thing happening to the
  # same machine was in the tenant's trail or not depending on which process
  # noticed first. It is recorded here, after the finalize commits and outside
  # every transaction, carrying the actor the caller supplied (ADR 0013).
  #
  # A row with no `user_id` records nothing, the #2329 trap: an audit row with
  # no tenant would say nothing an admin view does not already show. A park is
  # not a path account deletion takes, so there is no `audit: false` here to go
  # with `Destroy`'s.
  defp audit(%Sandbox{user_id: nil}, _opts), do: :ok

  defp audit(%Sandbox{} = sandbox, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.suspended",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor)),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "reason" => to_string(Keyword.fetch!(opts, :reason)),
        "provider" => sandbox.provider,
        "machine_name" => sandbox.machine_name,
        # The old key, kept beside machine_name until #2776.
        "sprite_name" => sandbox.machine_name
      }
    })

    :ok
  end

  # The machine is parked, so every other conversation on it has lost its
  # handle. Only a caller that knows what to say says it — the wording is the
  # caller's — and the reaper, which has no conversation of its own and never
  # notified before ADR 0058, still does not.
  defp notify_cotenants(%Sandbox{} = sandbox, opts) do
    case Keyword.get(opts, :notify) do
      nil ->
        :ok

      {conversation_id, event, reason, message} ->
        sandbox.id
        |> Conversations._unsafe_list_cotenant_ids(conversation_id)
        |> MachineEvents.tell_cotenants(sandbox.id, event, reason, message)
    end
  end
end
