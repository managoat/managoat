defmodule Fountain.Machines.Resume do
  @moduledoc """
  One resume protocol for one machine (ADR 0058, stage 7a).

  ADR 0023 step 4 asked for a per-sandbox owner so that "two prompts waking one
  machine resume it once; the second waits". On `main` they do not. Two wakes of
  one parked home both read `suspended`, both call `Managoat.Sandbox.resume/1`,
  and both write `ready`; what serializes them is an accident — the *per-user*
  advisory lock `Fountain.Quotas.with_sandbox_reservation/2` takes, which
  happens to be held across the provider call. That accident is also the bug it
  is paying for: the provider round trip runs **inside a database transaction**,
  which ADR 0058 forbids outright and #2309 priced, and it serializes every
  resume a tenant makes rather than every resume of one machine.

  This module is the same shape as `Fountain.Machines.Park` and
  `Fountain.Machines.Destroy` — a lease, a recheck under it, an intent on the
  row, the provider outside every lock, a compare-and-set finalize — with one
  thing neither of them has: an **admission** step, because a resume is the only
  verb here that turns a parked disk back into compute somebody is billed for.

  #### The ceiling, and why it is where it is

  What the reservation actually protects is two concurrent starts *or wakes* of
  **different** machines both reading "there is room" and both provisioning:
  the fleet ceiling. What it does **not** need to protect is one machine against itself —
  that is the lease's job, and it does it per machine instead of per fleet.

  So the two are separated, and the ordering is the whole of 7a:

      claim the lease (4316, one short transaction, released at its commit)
      revalidate under the lease
      admit + reserve   (4315, one short transaction, ENDS HERE)
      ── no lock, no transaction, no advisory lock held from here ──
      provider resume and exec readiness, under the lease
      compare-and-set finalize

  The admission is one transaction that takes the quota locks, runs the three
  checks, and — in the *same* transaction — stamps `transition: "resuming"` on
  the row by compare-and-set. That stamp is the reservation. Without it the
  checks would be a read with no record: machine A passes, machine B passes
  while A is still `suspended` and therefore still uncounted, and both wake past
  a cap that had room for one. `Fountain.Quotas.active_sandboxes/0` counts a
  `resuming` row **whose lease is live**, so a machine on its way up holds a slot
  from the instant it is admitted until it is `ready` and counted in its own
  right — and an *abandoned* resume stops holding one when the next claim or
  the next boot clears its lease (ADR 0072; `Lease.boot_prefix/0` says why SQL
  cannot see a holder that died in this boot).

  **The two locks are never held at once, in either order.** 4316 is a
  transaction-scoped advisory lock inside `Lease.claim/2`'s own short
  transaction and is gone before this returns; the lease that outlives it is a
  row, not a lock. 4315 is taken by the admission, after the claim has
  committed, and released at the admission's commit. So the deadlock #2309
  warned about — two namespaces taken in opposite orders — has no site here, and
  `resume_test.exs` proves it with `pg_blocking_pids`.

  ## The steps

  0. **Answer a machine that is already up from one read**, without a lease. A
     prompt to a running machine is the common case and needs nothing done to
     it; see `up_already?/2` for the five conditions that fall through instead.
  1. Refuse an enclosing transaction (#2309).
  2. **Claim a lease** for one operation. Held by somebody else: waited on
     briefly, then `{:error, :machine_busy}`. This is what makes two wakes of one
     machine resume it once — the second waits, and then finds `ready`.
  3. **Revalidate under the lease** (#2307 constraint 1): terminal, either
     fence, the status.
  4. **Admit and reserve**, above.
  5. **Resume at the provider**, then confirm Sprites answers a no-op exec,
     outside every lock and transaction, under the lease. The probe retries
     transient failures within a 60-second budget; synchronous SDK startup can
     overrun it (see `Readiness`). The lease holds for as long as the owner
     lives. An error — or a
     raise, 5a's rule — clears the transition and answers
     `{:error, :resume_failed}`, leaving a parked row `suspended`. An implicit
     provider wake on a `ready` row keeps its `resuming` stamp on failure, so
     reads refuse it and the next wake retries without resetting its lifetime.
     The parked disk
     is the agent's memory, and a row marked `ready` over a still-parked
     machine would strand it. That is `main`'s rule, kept.
  6. **Finalize** `status: "ready"`, transition cleared, by compare-and-set on
     the same epoch — and `last_resumed_at` **only where the row was
     `suspended`**. See `finalize/3`: restamping it restarts the max-lifetime
     ceiling's clock, and a machine the provider stopped under a `ready` row is
     not one Fountain parked.
  7. Release. Then, on the same condition, one `sandbox.resumed` audit event.
  8. `{:ok, :resumed}`.

  ## Takeover

  A claim that finds `transition: "resuming"` on a live row is looking at a
  resume whose owner died between steps 4 and 6. As with a park, the row does
  not say whether the provider call landed, so the taker asks the machine
  (`Managoat.Sandbox.get/1`) and compensates from the answer:

    * `:running` — the resume landed and only the finalize was lost. The
      taker re-admits and confirms exec readiness before finalizing `ready`.
      The dead owner's reservation expired with its lease.
    * `:suspended` — the resume had not landed. Clear the transition, leave the
      row `suspended`, `{:ok, :recovered}`. The next wake resumes it through
      this protocol from the top, admission and all.
    * anything else — `:unknown`, `:not_found`, a provider error, a raise —
      reads as suspended. Clearing a transition is always the write that claims
      least, and `suspended` is the state the row was already in.

  An interrupted implicit wake on a `ready` row is retried through admission
  when the provider is still suspended. Other suspended takeovers recover the
  parked row without starting compute. Every exec probe follows admission.

  **This takeover clears a stale `resuming` stamp.** The boot sweep preserves
  it while releasing the dead lease, and registration refuses it until the next
  wake proves readiness (#2560). A stamp whose holder has died is
  invisible to `Machine.busy?/1`, `Quotas.active_sandboxes/0` stops counting it
  at the next boot, and neither reaper sweep looks at `suspended` rows at all — they
  scan `ready`. So a machine nobody ever wakes again keeps the stamp, which costs
  exactly one thing: the admin table renders it as `resuming (abandoned)`. It
  blocks reads and registration until a wake recovers it. `Machines.Destroy`
  can still replace it with its destroy fence. Widening a sweep to `suspended` rows would change
  what reclamation looks at, which is not this stage's to change.

  **One shape of it is worse than cosmetic, and is named here rather than left
  to be found** (7a round 2, carried into 7b). A takeover whose re-admission is
  *refused* — the tenant filled the slot after the dead owner's lease stopped counting —
  clears the stamp and leaves the row `suspended` over a machine the provider
  says is **running**. That machine bills, and neither reaper sweep looks at
  `suspended` rows: the idle sweep and the fenced-teardown sweep both scan
  `ready`. Nothing corrects it until somebody prompts the conversation again, at
  which point this protocol resumes a machine that was never down and the row
  catches up.

  It is bounded — it needs a tenant at its cap at the moment a takeover happens
  — and closing it means a sweep over `suspended` rows whose provider reports
  running, which is a change to what reclamation looks at and belongs with
  whoever decides that.

  ## Outcomes

  `{:ok, :resumed}` brought the machine up. `{:ok, :already_up}` is a row that
  was already `ready` — somebody else's resume, or this one superseded after its
  provider call. `{:ok, :already_terminal}` is a row that had stopped.
  `{:ok, :recovered}` is the takeover above finding the machine still parked:
  nothing was resumed, and nothing is wrong.

  The `{:error, _}` shapes are the *protocol's* vocabulary — `:machine_busy`,
  `:fenced`, `:provisioning`, `:resume_failed`, `:superseded`, the admission's
  own refusals, and whatever `Lease` hands back.
  `Fountain.Machines.Machine.ensure_up/2` is the door and translates them.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Readiness
  alias Fountain.Quotas
  alias Fountain.Repo

  require Logger

  @typedoc """
  What a resume did. `:resumed` ran the protocol through (or finished one whose
  owner died after its provider call); `:already_up` is a row that was already
  `ready`; `:already_terminal` a row that had stopped; `:recovered` an abandoned
  resume cleared off a machine that turned out to be still parked.
  """
  @type outcome :: :resumed | :already_up | :already_terminal | :recovered

  # How long a *waiter* waits for a holder. `Destroy`'s and `Park`'s number.
  # This is the bound "the second wake waits" is measured against: a resume that
  # settles inside it hands the second caller `{:ok, :already_up}`, and one that
  # does not hands it `:sandbox_unavailable` and a `Retry-After`. Five seconds
  # is the wait a person is behind, not the lease.
  @busy_wait_ms 5_000

  # How often the wait re-asks.
  @poll_ms 250

  @terminal_statuses ~w(terminated failed)

  # The statuses a provision is still in flight on. `main` answers
  # `{:provisioning, id}` from `Wake.classify_reusable/2` for these and waits on
  # the registry; a resume has nothing to do with them and says so in the same
  # word.
  @provisioning_statuses ~w(pending starting)

  @doc """
  Bring the machine behind `sandbox_id` up.

  Options:

    * `:actor` (required) — the audit actor for `sandbox.resumed`, from ADR
      0013's vocabulary. The wake passes `"system:wake"`.
    * `:requesting_conversation_id` — the conversation whose prompt is waking
      the machine. Recorded in the audit metadata; it does not decide anything,
      because a resume is good for every conversation on the machine rather than
      for the one that asked.
    * `:observed` — what the caller's own probe just heard from the provider
      (`:running | :suspended | :unknown`). Only `:suspended` does anything, and
      only on a `ready` row: see `admissible/2`. `Wake.probe_sandbox/4` supplies
      it; a caller with no reading of its own omits it.
    * `:request_ip` — attribution, passed to the audit event.
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
    * `:readiness_timeout_ms`, `:readiness_retry_ms` — test seams for the
      Sprites exec probe's 60-second budget and 250-millisecond retry delay.
  """
  @spec run(Ecto.UUID.t(), keyword()) :: {:ok, outcome()} | {:error, term()}
  def run(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    _actor = Keyword.fetch!(opts, :actor)

    cond do
      Repo.in_transaction?() -> {:error, :transaction_open}
      up_already?(sandbox_id, opts) -> {:ok, :already_up}
      true -> claim_and_resume(sandbox_id, opts)
    end
  end

  # **The machine is already up and nobody is doing anything to it**: answer from
  # one read, and take no lease (round 1, behaviour review).
  #
  # `ensure_up/2` is asked on every reuse, and the overwhelmingly common case is
  # a prompt to a conversation whose machine is running. The first draft claimed
  # and released a lease for that — an advisory lock and two row writes per
  # prompt, where `main` wrote nothing, with `lease_epoch` climbing by two per
  # prompt and a new 503 whenever two prompts to one machine collided in the
  # five-second wait. None of it bought anything: the answer was
  # `{:ok, :already_up}` either way.
  #
  # Deliberately narrow, because a fast path that answers for a row that needed
  # work is a machine nobody starts. Everything below falls through to the full
  # protocol, lease and all:
  #
  #   * anything but `ready` — `suspended` is the resume this exists for, and
  #     terminal and provisioning rows have answers of their own;
  #   * any `transition` stamp — a `destroying` one is the fence, which is
  #     `:fenced` and has to be said, and any other is a row with an abandoned
  #     operation on it to clear;
  #   * any holder on the lease, live or dead. Testing `lease_node` rather than
  #     `Lease.live?/1` is deliberate and *stricter*: a machine whose holder has
  #     died takes the slow path and gets the recheck it deserves.
  #   * a caller whose own probe says the provider has stopped this machine,
  #     which is the one shape where a `ready` row does need the provider.
  defp up_already?(sandbox_id, opts) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: "ready", transition: nil, lease_node: nil} ->
        Keyword.get(opts, :observed) != :suspended

      _ ->
        false
    end
  end

  @doc """
  How long `run/2` waits for a lease somebody else holds before refusing.

  Public so `machine_bounds_test.exs` can pin it against the two bounds it has
  to sit between.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  # ── the lease around one operation ────────────────────────────────────────

  defp claim_and_resume(sandbox_id, opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

    case claim(sandbox_id, deadline) do
      {:ok, epoch} ->
        try do
          under_lease(sandbox_id, epoch, opts)
        after
          # `after`, not a plain next statement, for `Park`'s reason: a provider
          # adapter that raises unwinds through here, and a lease left held
          # keeps this machine unclaimable for as long as this owner lives, and
          # every wake of it answers 503.
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

  # A lease somebody else holds is waited out rather than refused outright, and
  # here that wait is the *feature*: two prompts arriving on one parked home
  # milliseconds apart is the ordinary case, and the second one wants the
  # first one's machine, not a second resume of it.
  #
  # `:sandbox_unavailable` out of `Lease.claim/2` means the advisory lock is
  # held right now (`with_sandbox_lock/2`'s `lock_timeout`, stage 6b) and is
  # waited out the same way — refusing on it would turn a moment's contention
  # into a failed wake.
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
      Logger.warning("machine #{sandbox_id}: resume refused, #{why}")
      {:error, :machine_busy}
    end
  end

  # ── the protocol ──────────────────────────────────────────────────────────

  defp under_lease(sandbox_id, epoch, opts) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      # A resume that finished, or a machine somebody else stopped, still
      # wearing the stamp. Checked before the takeover clause for `Park`'s
      # reason: continuing from a settled row would call the provider again and
      # record a second event for something already done.
      %Sandbox{transition: "resuming", status: status} = settled
      when status in @terminal_statuses ->
        clear_transition(settled, epoch)
        {:ok, :already_terminal}

      # Step 4 landed and step 6 did not. This lease is the takeover.
      %Sandbox{transition: "resuming"} = interrupted ->
        take_over(interrupted, epoch, opts)

      # The one foreign stamp that is not abandoned (ADR 0058 stage 9a).
      # `destroying` is durable intent: somebody asked for this machine to go
      # away, and the owner dying between the fence and the finalize did not
      # withdraw the request. Refused with `:fenced`, the word `admissible/2`
      # already answers for the columns this stamp replaces, and refused
      # *before* the clearing clause below so the intent survives to be driven.
      #
      # Checked after the terminal-row clauses above by construction: a
      # `destroying` stamp on a terminal row is the leftovers
      # `Destroy.clear_stale_transition/2` describes, and `admissible/2`'s own
      # terminal head answers `{:ok, :already_terminal}` for it.
      %Sandbox{transition: "destroying", status: status} = fenced
      when status not in @terminal_statuses ->
        Logger.info(
          "machine #{fenced.id}: resume refused, the machine is being destroyed " <>
            "(#{fenced.transition_reason || "no reason"})"
        )

        {:error, :fenced}

      # Somebody else's stamp — a park, a destroy, a reset — on a machine whose
      # lease this claim has just taken. **That stamp is abandoned by
      # construction**: `Lease.claim/2` refuses while the current lease is live,
      # so holding one is proof that no other owner is working here. Clearing it
      # and judging the row by its status is stage 6a's rule — "busy means a
      # live lease", and a transition with a dead lease is an owner that died,
      # not one working — applied on the owner's side of the same seam
      # `Wake.maybe_reuse_sandbox/1` reads on the reader's.
      #
      # The first draft refused instead (round 1, behaviour review), and that
      # was 6a's decision inverted: `ensure_up/2` is asked on *every* reuse, so
      # a `ready` row wearing a lease-less `parking` stamp answered 503 to every
      # prompt until an hourly sweep happened to clear it — the same
      # up-to-75-minute withholding 6a round 1 found and closed.
      #
      # What still refuses is a **fence**, and a fence is the `destroying`
      # stamp: the durable statement that this machine is going away, not the
      # leftovers of an owner that stopped. The clause above refuses it (stage
      # 9a), and it is the only fence since stage 9b stopped reading the two
      # columns that once stood beside it. What reaches here is `parking` and
      # `resuming`, which carry no fence and never meant "refuse me".
      #
      # Clearing another verb's stamp is `Conversations.register_server/2`'s
      # precedent, and it costs the same thing there: `Destroy` loses a
      # shortcut — it re-enters at its fence, which is idempotent — and `Park`
      # loses nothing, because its takeover revalidates from the top anyway.
      %Sandbox{transition: other} = sandbox when not is_nil(other) ->
        Logger.info(
          "machine #{sandbox.id}: clearing an abandoned #{other} stamp left by an owner " <>
            "whose holder had died"
        )

        clear_transition(sandbox, epoch)
        admit_or_refuse(%{sandbox | transition: nil, transition_reason: nil}, epoch, opts)

      %Sandbox{} = sandbox ->
        admit_or_refuse(sandbox, epoch, opts)
    end
  end

  defp admit_or_refuse(%Sandbox{} = sandbox, epoch, opts) do
    case admissible(sandbox, opts) do
      :ok -> admit_then_resume(sandbox, epoch, opts)
      refusal -> refusal
    end
  end

  # Step 3. Every condition the caller decided on, re-read under the lease, in
  # the order that makes the answer most useful: what the row *is*, then what
  # has been asked of it, then whether there is anything here to do.
  defp admissible(%Sandbox{status: status}, _opts) when status in @terminal_statuses,
    do: {:ok, :already_terminal}

  defp admissible(%Sandbox{} = sandbox, opts) do
    cond do
      # No fence clause here since stage 9b. The fence is the `destroying`
      # stamp, and `under_lease/3` refuses it one step earlier — before this is
      # reached and before the terminal head above — so a copy here would be a
      # guard no test could break (stage 9a). The two columns this clause read
      # until then went with 9b. Why a fenced machine is refused rather than
      # woken, where `main` woke it: it is on its way out, and bringing it up
      # would re-reserve at the provider a machine somebody asked to be
      # destroyed and write a live status over a row
      # `sweep_fenced_teardowns/0` is about to finish.
      # A `ready` row whose machine the provider says is parked. This is the
      # other half of the 6b review's note, and `Wake.probe_sandbox/4` is what
      # supplies the reading: a park whose finalize was lost leaves exactly this
      # row, and on E2B the machine behind it is genuinely stopped.
      # `main` reused it and handed the conversation a handle to nothing.
      #
      # The verdict is the caller's observation and is deliberately not re-taken
      # under the lease, because taking it again is a provider round trip to
      # decide whether to make a provider round trip. It does not need to be
      # revalidated, because it cannot make this protocol do anything unsafe:
      # `resume/1` on a machine that turns out to be running is a no-op at every
      # adapter, the finalize writes `ready` over `ready` and so records no
      # wake, and the row's *own* state — the part a stale reading could make
      # this wrong about — is re-read here like everything else.
      sandbox.status == "ready" and Keyword.get(opts, :observed) == :suspended ->
        Logger.info(
          "machine #{sandbox.id}: row says ready and the provider says suspended; resuming"
        )

        :ok

      sandbox.status == "ready" ->
        {:ok, :already_up}

      # A provision in flight. The wake never reaches a resume on one of these —
      # `Wake.maybe_reuse_sandbox/1` answers `{:provisioning, id}` and the caller
      # waits for the registry (#800) — and the word is kept so a caller that
      # does reach it here behaves the same way.
      sandbox.status in @provisioning_statuses ->
        {:error, :provisioning}

      true ->
        :ok
    end
  end

  # ── admission ─────────────────────────────────────────────────────────────

  # Step 4: the quota checks and the reservation, in one short transaction that
  # ends before any provider I/O. See the moduledoc for why the stamp is inside
  # it and what happens without it.
  #
  # `exclude: sandbox_id` keeps `main`'s question exactly: "is there
  # capacity *besides* this machine". A suspended row does not count against the
  # ceiling (ADR 0017 — a parked sprite is scaled to zero), so without the exclusion
  # the very row being woken would start counting the moment it is stamped and
  # refuse its own resume at the ceiling.
  #
  # A row with no `user_id` is account deletion's nilified machine (#2329): there
  # is no tenant to check against and no cap it could exceed, so the reservation
  # is skipped and the stamp is written on its own. Nothing reaches this on that
  # path today — deletion destroys, it does not wake — and it answers rather than
  # raising because a protocol that crashes on an ownerless row is how #2329
  # stopped machine cleanup fleet-wide.
  defp admit_then_resume(%Sandbox{} = sandbox, epoch, opts) do
    case admit(sandbox, epoch) do
      {:ok, %Sandbox{} = marked} -> resume_and_finalize(marked, epoch, opts)
      settled -> settled
    end
  end

  # The admission on its own, so the takeover can run it too — see
  # `compensate/3`. `{:ok, marked}` is the row wearing the reservation.
  #
  # A row with no `user_id` is account deletion's nilified machine (#2329):
  # there is no tenant to check against and no cap it could exceed, so the
  # reservation is skipped and the stamp is written on its own. Nothing reaches
  # this on that path today — deletion destroys, it does not wake — and it
  # answers rather than raising because a protocol that crashes on an ownerless
  # row is how #2329 stopped machine cleanup fleet-wide.
  defp admit(%Sandbox{user_id: nil} = sandbox, epoch), do: settle_admission(stamp(sandbox, epoch))

  defp admit(%Sandbox{} = sandbox, epoch) do
    # A parked machine wakes on the provider that holds it, so its slot is
    # that provider's (#2667).
    Quotas.with_sandbox_reservation([provider: sandbox.provider, exclude: sandbox.id], fn ->
      stamp(sandbox, epoch)
    end)
    |> settle_admission()
  end

  # The row went terminal between the recheck and the stamp: not a refusal to
  # report, the machine is gone. Everything else — the fleet ceiling, a compare-and-set that found this lease
  # superseded — rolled its transaction back, so no stamp was written and the
  # row is exactly as it was found.
  defp settle_admission({:ok, %Sandbox{} = marked}), do: {:ok, marked}
  defp settle_admission({:error, :retired}), do: {:ok, :already_terminal}
  defp settle_admission({:error, _reason} = refusal), do: refusal

  # The reservation itself. Inside `with_sandbox_reservation/2`'s transaction on
  # purpose: the stamp is what makes this machine count against the ceiling the check just read, and a check whose reservation lands in a second transaction
  # is a check two callers can both pass.
  #
  # `nest: true` is how `Lease.cas_update/4` is told that the enclosing
  # transaction is deliberate rather than the mistake its guard usually catches.
  defp stamp(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(sandbox.id, epoch, [transition: "resuming"], nest: true) do
      {:ok, %Sandbox{} = marked} ->
        {:ok, marked}

      # **`:machine_busy`, not `:superseded`** (round 1, protocol review). The
      # two words look interchangeable and are not: `:superseded` becomes
      # `{:ok, :already_up}` at the door, which is a fair prediction *after* the
      # provider call — another owner holds the machine and will finalize the
      # resume that already landed — and a lie here. Nothing has been resumed
      # yet, the row still says `suspended`, and telling a prompt the machine is
      # up sends it on to a server it cannot reach. `:machine_busy` is the
      # honest answer and reads as `:sandbox_unavailable` with a `Retry-After`.
      {:error, :stale} ->
        {:error, :machine_busy}

      {:error, _} = error ->
        error
    end
  end

  # ── the provider call and the finalize ────────────────────────────────────

  defp resume_and_finalize(%Sandbox{} = sandbox, epoch, opts) do
    case resume_at_provider(sandbox, opts) do
      :ok ->
        finalize(sandbox, epoch, opts)

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: provider resume failed for #{sandbox.machine_name} " <>
            "on #{sandbox.provider}: #{inspect(reason)}"
        )

        # The transition comes off before the answer goes back, so the machine
        # is left exactly as it was found: `suspended`, unfenced, claimable, and
        # no longer counting against the cap. `main` left the row `suspended`
        # too — the parked disk is the agent's memory, and a row marked `ready`
        # over a still-parked machine would strand it.
        recover_failure(sandbox, epoch)
        {:error, :resume_failed}
    end
  end

  # There is no "no machine to call" case: `machine_name` is `NOT NULL` and
  # required by `Sandbox.changeset/2`, so a row that exists names a machine.
  defp resume_at_provider(%Sandbox{} = sandbox, opts) do
    handle =
      Conversations.sandbox_provider_atom(sandbox)
      |> Managoat.Sandbox.build_handle(sandbox.machine_name)

    case Managoat.Sandbox.resume(handle) do
      {:ok, resumed} -> Readiness.wait(resumed, opts)
      {:error, reason} -> {:error, reason}
    end
  rescue
    # An adapter that raises rather than answering is the same outcome as one
    # that returns an error — this machine was not resumed — so it is treated
    # the same and logged in full (5a's rule).
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  end

  defp confirm_and_finalize(sandbox, epoch, opts) do
    handle =
      Conversations.sandbox_provider_atom(sandbox)
      |> Managoat.Sandbox.build_handle(sandbox.machine_name)

    case Readiness.wait(handle, opts) do
      :ok ->
        finalize(sandbox, epoch, opts)

      {:error, _reason} ->
        recover_failure(sandbox, epoch)
        {:error, :resume_failed}
    end
  end

  # An implicit provider wake must retain its original lifetime clock. Keep
  # the failed wake's stamp on a ready row: Reads refuses even an abandoned
  # transition, and the next wake takes it over instead of taking the ready
  # fast path. A genuinely parked row already refuses reads by status.
  defp recover_failure(%Sandbox{status: "ready"}, _epoch), do: :ok
  defp recover_failure(sandbox, epoch), do: clear_transition(sandbox, epoch)

  # **Whether this counts as a wake is decided by the row, not by the provider**
  # (round 1, surfaces review), and it is the one place the two paths into here
  # part company.
  #
  # A row that was `suspended` is a machine Fountain parked and has now brought
  # back: it gets `last_resumed_at` and the `sandbox.resumed` event, both.
  #
  # A row that was already `ready` is the `observed: :suspended` path — the
  # provider says the machine is not running and Fountain never parked it — and
  # it gets **none of them**. The reason is `Lifecycle.clock_start/1`:
  # `last_resumed_at || inserted_at` is what the max-lifetime ceiling measures a
  # continuous run from, so restamping here would restart that clock on a
  # machine nobody parked. On Sprites, the instance default, that is not an edge
  # case but the *ordinary* reading — its `suspend/1` is a no-op and its `get/1`
  # reports the platform's own scale-to-zero schedule, so every sprite that has
  # scaled to zero by itself comes through here — and a ten-hour ceiling would
  # have been pushed ten hours out by a probe. `docs/guides/operate/sandbox-lifetime.md`
  # promises the opposite in as many words.
  #
  # Nothing to audit there either: no state changed, and a `sandbox.resumed` in
  # a tenant's trail for a machine that was never suspended describes something
  # that did not happen.
  defp finalize(%Sandbox{} = sandbox, epoch, opts) do
    case Lease.cas_update(sandbox.id, epoch, finalize_attrs(sandbox)) do
      {:ok, %Sandbox{} = up} ->
        if woken?(sandbox) do
          audit(up, opts)
        else
          Logger.info(
            "machine #{sandbox.id}: #{sandbox.machine_name} was restarted at the provider on a " <>
              "row that already said ready; not stamping last_resumed_at and not recording a " <>
              "wake"
          )
        end

        {:ok, :resumed}

      {:error, :stale} ->
        Logger.warning("machine #{sandbox.id}: resume superseded before its finalize")
        {:error, :superseded}

      {:error, :retired} ->
        {:ok, :already_terminal}

      {:error, _} = error ->
        error
    end
  end

  # A resume of a machine Fountain itself parked, as opposed to one the provider
  # had stopped under a row that still said `ready`. See `finalize/3`.
  defp woken?(%Sandbox{status: "suspended"}), do: true
  defp woken?(%Sandbox{}), do: false

  defp finalize_attrs(%Sandbox{} = sandbox) do
    base = [status: "ready", transition: nil, transition_reason: nil]

    if woken?(sandbox) do
      Keyword.put(base, :last_resumed_at, DateTime.utc_now() |> DateTime.truncate(:second))
    else
      base
    end
  end

  # ── takeover ──────────────────────────────────────────────────────────────

  # A takeover is a resume, so it revalidates like one — `Park`'s round-1
  # blocker, and the same hole would be here: nothing clears a `resuming` stamp
  # off a row whose holder has died except an owner, so an abandoned resume, a
  # destroy fence and then any later resume would have written `ready` over a
  # machine on its way out. Registration refuses both unfinished destroys and
  # resumes; only this protocol can establish readiness after an interrupted
  # probe.
  defp take_over(%Sandbox{} = sandbox, epoch, opts) do
    Logger.info("machine #{sandbox.id}: taking over an abandoned resume at epoch #{epoch}")

    # Force revalidation even on a ready row: a resuming stamp means its
    # implicit wake never proved readiness. The fresh provider reading below
    # decides which recovery to run, not the dead owner's observation.
    case admissible(sandbox, observed: :suspended) do
      :ok ->
        compensate(sandbox, epoch, opts)

      refusal ->
        Logger.info(
          "machine #{sandbox.id}: abandoned resume is no longer admissible " <>
            "(#{inspect(refusal)}); recovering the unfinished wake"
        )

        recover_failure(sandbox, epoch)
        refusal
    end
  end

  defp compensate(%Sandbox{} = sandbox, epoch, opts) do
    case machine_state(sandbox) do
      :running ->
        # The resume landed and the finalize was lost. Finishing it is the
        # compensation — **after re-running the admission** (round 1, behaviour
        # review).
        #
        # The first draft finalized straight from here, reasoning that the dead
        # owner had paid for the slot when it stamped. It had; the slot did not
        # survive it. `Quotas.active_sandboxes/0` counts a `resuming` row only
        # while its lease is *live*, which is what keeps an abandoned resume
        # from holding a slot for ever — so by the time a takeover
        # is possible at all, that reservation has already been released and
        # another machine may have taken the slot. Finalizing without asking
        # again put the fleet over the ceiling.
        #
        # Asking again costs nothing when there is room (the row is excluded
        # from its own count, as on the ordinary path) and refuses honestly when
        # there is not.
        case admit(sandbox, epoch) do
          {:ok, %Sandbox{} = readmitted} ->
            confirm_and_finalize(readmitted, epoch, opts)

          {:ok, :already_terminal} ->
            {:ok, :already_terminal}

          # No slot for it. The machine is running at the provider and the row
          # says `suspended`, which is the same divergence a failed resume
          # leaves and is resolved the same way: the next wake re-admits and
          # resumes, and `resume/1` on a machine that is already running is a
          # no-op at every adapter. Writing `ready` without a slot is the one
          # thing that is not available here.
          {:error, reason} ->
            Logger.warning(
              "machine #{sandbox.id}: took over a resume that had landed, but the tenant " <>
                "has no capacity for it now (#{inspect(reason)}); leaving the row parked"
            )

            recover_failure(sandbox, epoch)
            {:error, reason}
        end

      :suspended when sandbox.status == "ready" ->
        admit_then_resume(sandbox, epoch, opts)

      :suspended ->
        clear_transition(sandbox, epoch)
        {:ok, :recovered}
    end
  end

  # What the machine says about itself, folded to the only two answers a
  # takeover can act on — and folded the *opposite* way from `Park`'s, which is
  # the point rather than an inconsistency. Each protocol folds the uncertain
  # answers towards the state its row already claims, because that is the
  # compensation that writes least: for a park the row says `ready` and an
  # unknown machine is left running, and here the row says `suspended` and an
  # unknown machine is left parked. Writing `ready` on a guess would hand a
  # conversation a handle to a machine that is not there.
  #
  # Sprites is worth naming, because it is the provider where this answer is
  # least informative: its `suspend/1` is a no-op and its `resume/1` is a probe,
  # so `get/1` reports the platform's own scale-to-zero timing rather than
  # anything Fountain did. A sprite that has not yet scaled to zero answers
  # `:running` and this finalizes; one that has answers `:suspended` and this
  # clears a parked row. A running verdict still needs exec proof, and an
  # implicit wake of a ready row is re-admitted and retried when still asleep.
  defp machine_state(%Sandbox{} = sandbox) do
    handle =
      Conversations.sandbox_provider_atom(sandbox)
      |> Managoat.Sandbox.build_handle(sandbox.machine_name)

    case Managoat.Sandbox.get(handle) do
      {:ok, %{status: :running}} ->
        :running

      {:ok, %{status: status}} ->
        Logger.info("machine #{sandbox.id}: provider reports #{status}; recovering to suspended")
        :suspended

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: provider could not say whether #{sandbox.machine_name} " <>
            "is up (#{inspect(reason)}); recovering to suspended"
        )

        :suspended
    end
  rescue
    error ->
      Logger.warning(
        "machine #{sandbox.id}: provider raised while probing #{sandbox.machine_name}: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :suspended
  end

  # Clearing the stamp is what makes the column mean something again, and here
  # it is also what gives the fleet slot back: `Quotas.active_sandboxes/0`
  # counts a `resuming` row under a live lease, so a resume that refused or
  # failed must not leave one behind. A status-free write is not a revival, so
  # `Lease.refuse_revival/2` lets it through even on a terminal row. A refusal
  # here belongs to whoever superseded us and is logged rather than returned.
  defp clear_transition(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(sandbox.id, epoch, transition: nil, transition_reason: nil) do
      {:ok, _cleared} ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: could not clear a resuming stamp (#{inspect(reason)})"
        )
    end

    :ok
  end

  # ── after the finalize ────────────────────────────────────────────────────

  # One `sandbox.resumed` event, and it is new: `main` recorded nothing at all
  # when a parked machine came back, so a tenant's trail showed the suspend and
  # not the wake. One completed-operation event per owner verb is the pattern
  # stages 5 and 6 set (`sandbox.destroyed`, `sandbox.suspended`); this is the
  # third. Recorded after the finalize commits and outside every transaction,
  # carrying the actor the caller supplied (ADR 0013).
  #
  # A row with no `user_id` records nothing, the #2329 trap.
  defp audit(%Sandbox{user_id: nil}, _opts), do: :ok

  defp audit(%Sandbox{} = sandbox, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.resumed",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor)),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        %{
          "provider" => sandbox.provider,
          "machine_name" => sandbox.machine_name,
          # The old key, kept beside machine_name until #2776.
          "sprite_name" => sandbox.machine_name
        }
        |> put_requester(Keyword.get(opts, :requesting_conversation_id))
    })

    :ok
  end

  defp put_requester(metadata, nil), do: metadata
  defp put_requester(metadata, conv_id), do: Map.put(metadata, "conversation_id", conv_id)
end
