defmodule Fountain.Machines.Destroy do
  @moduledoc """
  One destroy protocol for one machine (ADR 0058, stage 5).

  Every conversation-side destroy used to be the same five steps written out
  again: fence admission, call the provider, write the row terminal, tell the
  co-tenants, and hope nothing else was doing the same thing at the same time.
  `Fountain.Conversations.Lifecycle.do_destroy/4`,
  `ConversationServer.terminate_machine/2` and
  `Termination.retire_terminated_sandbox/2` each had their own version, and
  the third one had no provider call at all — it fenced the row, retired it,
  and left the sprite for the reaper's next pass. This module is those five
  steps once, and the sites now ask for them.

  Stage 5b added the forced-teardown side to the same door:
  `Accounts.Deletion.destroy_sprites/2`, `SandboxReaper.expire/3` and
  `Termination.reap_sandbox/2`'s dead-server arm. What makes those *forced* is
  one option: they pass `terminating_conversation_id: nil`, so the fence takes
  no conversation's binding into account — a deleted account's machines go
  because the account is going, and an expired machine nobody can reach is
  destroyed even though its idle conversation is still bound to it.

  ## The steps

  1. Refuse an enclosing transaction. Provider I/O is never inside a lock or a
     transaction (ADR 0058; #2309), and every step below is its own short
     transaction or none.
  2. **Claim a lease** (`Fountain.Machines.Lease.claim/2`) for one operation.
     A lease held by someone else is waited on, briefly, then refused as
     `{:error, :machine_busy}`. The owner process does **not** hold a standing
     lease yet — that arrives with `park` and `ensure_up` in stages 6 and 7 —
     so this lease bounds this destroy and nothing more.
  3. **Fence** with `Lifecycle.fence_sandbox_for_teardown/2`, which stamps
     `transition: "destroying"` under the machine's advisory lock and closes
     the machine to admission on every node. (Until stage 9b it also wrote
     `reset_requested_at` and `teardown_requested_at`, which a replica that
     predated the owner honoured.)
  4. **Stamp the intent**: `transition: "destroying"` by compare-and-set on
     the lease epoch, before any provider I/O. A reader that finds it sees
     what is being done to the machine rather than racing it, and a takeover
     after a crash sees where the previous owner got to.
  5. **Destroy at the provider**, outside every transaction and every lock.
     An already-gone machine (`:not_found`) is success. Any other provider
     error, or a raise, is logged as a warning ("provider destroy failed for
     <machine> on <provider>") and does **not** stop the finalize: that is
     what every one of the three sites did before this module existed ("a
     provider error still retires the fenced row for reconciliation",
     `termination_actor_fence_test.exs`). The backstop for the machine it may
     leave behind is `SandboxReaper`'s hourly pass over terminal rows whose
     machine the provider still lists, which deletes it again. The log line
     is the only record that this delete went unconfirmed: `sandbox.destroyed`
     is written either way and does not say.
  6. **Finalize**: `status: "terminated"` and the transition cleared, again by
     compare-and-set on the epoch. Zero rows means a newer epoch owns the
     machine, which is `{:error, :superseded}` — this destroy changed nothing
     and the caller must not report that it did.
  7. Release the lease. A lost release is harmless: the epoch is spent either
     way, and the next claimant takes a higher one.
  8. **Audit** `sandbox.destroyed` after the finalize has committed and
     outside every transaction, carrying the actor the caller supplied
     (ADR 0013's vocabulary, unchanged). `sandbox.teardown_requested` from
     step 3 stays where it is, and `audit: false` does not reach it — a caller
     may silence the completion it is about to delete the subject of, never
     the intent the fence recorded.
  9. **Tell any other conversation still bound to the machine**, through
     `MachineEvents.tell_cotenants/5`, the one sender of that cast — when the
     caller supplies the notice to send. Since ADR 0073 a machine has one
     conversation, so the list this sends to is ordinarily empty.

  ## Takeover, and the stamp as the fence

  A claim that finds `transition: "destroying"` on a row that is **not yet
  terminal** skips the fence (already written) and the stamp (already there)
  and continues from step 5, which is safe because destroying a machine twice
  is destroying it once — the second call answers `:not_found`.

  Until stage 9a that only ever described a takeover: an owner that died
  between step 4 and step 6. It now also describes the first pass of any
  destroy whose fence ran before the claim, because the fence writes the stamp
  with it — `Lifecycle.fence_sandbox_for_teardown/2` does, and since stage 9b
  the stamp is the only record of the intent. `SandboxReaper`'s driver for
  abandoned fences is the other such caller, and it is also what finishes, as
  a teardown, a stamp left by the per-sandbox reset ADR 0073 removed. A
  `destroying` stamp is written by a fence or by this protocol, never by
  anything else.

  **The stamp is the one transition a reader may not clear** (stage 9a). Every
  other one — `parking`, `resuming`, `provisioning` — is an abandoned operation
  that `Conversations.register_server/2`, `Resume.under_lease/3` and
  `Provision.clear_foreign_stamp/2` take off a lease-less row so the machine
  can be used again. A `destroying` stamp with a dead lease is not an abandoned
  operation; it is an unfinished destroy, and `Lease.cas_update/4` keeps it
  through any write that does not retire the row.

  The status check in front of that is not defensive padding. A terminal write
  that knows nothing about `transition` leaves the stamp on, so a *finished*
  destroy still wearing one is a state the fleet can be in. Continuing from it
  would call the provider again and record a second `sandbox.destroyed` for a
  machine that was already gone. Such a row answers
  `{:ok, :already_terminal}` and has its stale stamp cleared.

  `SandboxReaper.finish_teardown/1` was that writer until stage 9a, where it
  became a driver and its write became this protocol's own finalize — which
  carries an epoch and clears the stamp. On a fleet where every replica runs
  9a, nothing produces the shape. The check stays because **a replica that
  predates 9a still produces it**, from the same sweep, for as long as a
  rollout is half done; `destroy_test.exs` builds the row with that write
  rather than forging it.

  That idempotence is the *sequential* argument. Since ADR 0072 a lease is
  held for as long as its holder process lives, so a second destroy cannot
  claim while the first is still at the provider; two destroys of one machine
  overlap only if the first holder died mid-call, which leaves its provider
  request in flight. Every adapter is a delete by name, so that overlap is
  safe too.

  A provider adapter that *raises* rather than answering is caught and treated
  exactly like an error return — logged in full, the finalize still runs. The
  machine was not reached either way, and a fenced row stranded in a live
  status because a provider client blew up is the leak `SandboxReaper`'s
  moduledoc was written about.

  ## Outcomes

  `{:ok, :destroyed}` did the work.
  `{:ok, :already_terminal}` is a row that had already stopped. Both are
  outcomes a caller can report.

  The `{:error, _}` shapes here are the *protocol's* vocabulary —
  `:machine_busy`, `:superseded`, and whatever the fence or `Lease` hands back,
  including `Lease`'s `{:database, sqlstate}`. They are precise on purpose and
  they are **not** the vocabulary the rest of the system speaks:
  `Fountain.Machines.Machine.destroy/2` is the door, and it translates them
  before anything user-facing sees them.

  Step 1's transaction guard is process-local, which matters once the gate is
  on: the protocol then runs in the owner process, which is never inside the
  caller's transaction, so the guard cannot fire there. `Machine.destroy/2`
  checks before it dispatches for exactly that reason.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.MachineEvents
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Reads
  alias Fountain.Repo

  require Logger

  @typedoc """
  What a destroy did. `:destroyed` ran the protocol through;
  `:already_terminal` is a row that had already stopped.
  """
  @type outcome :: :destroyed | :already_terminal

  # How long a *waiter* waits for a holder. This bounds the caller, and the
  # caller is usually a person: an HTTP `DELETE` on the
  # dead-server path, or a `ConversationServer` whose own client gives up at
  # `conversation_call_timeout_ms` (30s). A wait that outlives its caller
  # wedges a server for longer than anyone is listening and answers a word —
  # `provisioning` — that means the opposite of what happened. Giving up in
  # five seconds and letting the fence and `SandboxReaper` finish the job is
  # strictly better. `machine_bounds_test.exs` pins this against both ceilings.
  @busy_wait_ms 5_000

  # How often the wait re-asks. The contended case is two destroys of the same
  # machine arriving together, so this is a handful of polls, not hundreds.
  @poll_ms 250

  # Where a machine stops. Same two as `Fountain.Conversations`'
  # `@terminal_statuses` and `Lease`'s `@terminal_statuses`.
  @terminal_statuses ~w(terminated failed)

  # **The destroy vocabulary**, closed and owned here because this module is
  # what puts it on the row and in the trail. `:reason` becomes
  # `transition_reason` on the machine and `"reason"` in `sandbox.destroyed`.
  #
  # It is deliberately *not* the fence vocabulary. `Lifecycle`'s own
  # `sandbox.teardown_requested` says why a caller asked
  # ("conversation_terminated", "agent_deleted", "reaped", …) and this says what
  # happened to the machine; the two are paired at every call site and the
  # option names keep them apart (`:reason` against `:fence_reason`, or
  # `:destroy_reason` against `:reason` one layer up in `Termination`).
  @reasons ~w(terminated idle max_lifetime reclaimed reset admin_reap home_destroyed
              provider_gone replaced account_deleted compute_stopped
              teardown)a

  @reason_by_string Map.new(@reasons, &{Atom.to_string(&1), &1})
  @known_reason_strings Map.keys(@reason_by_string)

  @doc """
  The destroy reason a `transition_reason` string names, as an atom.

  A machine's `transition_reason` is written by this protocol's stamp and, since
  ADR 0058 stage 9a, by the fence that precedes it — which stamps this
  vocabulary rather than its own precisely so that one column means one thing.
  `SandboxReaper`'s driver reads it back to continue a destroy somebody
  abandoned, and it must get the same word the original caller gave or the row
  and the trail will disagree about why a machine went away.

  **Total, and explicitly so.** The first version of the driver used
  `String.to_existing_atom/1` with a fallback, which is wrong twice over: whether
  a term converts depends on what else happens to be loaded — `"reaped"`
  converted under the suite and raised under `mix run`, so two replicas could
  write two different reasons for one row — and a term that does convert is not
  thereby the right one, since `"reaped"` is the *fence's* word for a machine
  whose destroy reason is `:admin_reap`. A closed vocabulary is matched, not
  parsed.

  Anything else is `:teardown`, which is the word `Lifecycle`'s fence defaults
  its own event to. Reaching it means a row carries a reason no caller in this
  release writes — an older replica's, or a hand-edited row — and finishing that
  destroy with a generic word is better than refusing to finish it.
  """
  @spec reason_from_string(String.t() | nil) :: atom()
  def reason_from_string(reason) when reason in @known_reason_strings,
    do: @reason_by_string[reason]

  def reason_from_string(_other), do: :teardown

  @doc "The closed destroy vocabulary, for the tests that pin it term by term."
  @spec reasons() :: [atom()]
  def reasons, do: @reasons

  @doc """
  Record that `sandbox` is to be destroyed: `transition: "destroying"`, with
  `reason` in the destroy vocabulary. The whole of a fence's write (ADR 0058
  stage 9b), for the fence that asks for a destroy before the owner runs one,
  `Lifecycle.fence_sandbox_for_teardown/2`.

  **In the owner's namespace, not its process.** The fence decides under the
  machine advisory lock, on a row it read `FOR UPDATE`, and the teardown
  fence's last-detach rule reads rows its own transaction has written and not
  yet committed (#2348 review), so the write runs inside the caller's
  transaction and never behind a `GenServer.call`. What moving it here buys is
  one writer of the stamp's shape, beside the protocol that continues from it
  (`under_lease/3`'s continuation clause) and the vocabulary it is written in.

  Not through `Lease.cas_update/4`: a fence is written by a caller that holds
  no lease — that is what a fence *is* — and the protocol's own stamp, one step
  later and under its epoch, restates it. Raises on a failed update, like the
  `Repo.update!/1` it replaces, because the caller's transaction is the thing
  that has to roll back.
  """
  @spec stamp_intent!(Sandbox.t(), String.t()) :: Sandbox.t()
  def stamp_intent!(%Sandbox{} = locked, reason) when is_binary(reason) do
    # On the machine's workspace, and copied onto the sandbox (ADR 0097, step
    # 3b): in the fence's transaction, after its `Lease.lock_machine/2`.
    case Lease.put_transition!(locked.id, "destroying", reason, touch: true) do
      0 -> raise Ecto.StaleEntryError, struct: locked, action: :update
      _ -> Lease.get(locked.id)
    end
  end

  @doc """
  Destroy the machine behind `sandbox_id`.

  Options:

    * `:actor` (required) — the audit actor for `sandbox.destroyed`, from
      ADR 0013's closed vocabulary (`"self"`, `"api"`, `"ui"`, `"admin"`,
      `"admin:<id>"`, `"system:<worker>"`). Passed to the fence too, which
      folds `admin:<id>` to `admin` for its own event.
    * `:reason` (required, an atom) — `:terminated`, `:idle`, `:max_lifetime`,
      `:reclaimed`. Becomes `transition_reason` on the row and `"reason"` in
      the audit metadata.
    * `:fence_reason` — the string the fence's own
      `sandbox.teardown_requested` event carries, when it differs from
      `reason`. Defaults to `to_string(reason)`. A dead-server terminate wants
      `"conversation_terminated"` here and `:terminated` above, which is the
      case this option exists for.
    * `:terminating_conversation_id` — the conversation being ended, for the
      fence's conversation-then-sandbox lock order.
    * `:provider` — `:destroy` (the default) calls
      `Managoat.Sandbox.destroy/1` at step 5. `:already_gone` skips the call
      because the caller has just asked the provider and been told this
      machine does not exist, so a delete would cost a round trip and name a
      machine that is no longer this row's. Two callers pass it, both through
      `Termination._unsafe_destroy_machine/2`: `ConversationServer`, when a
      reattach finds the machine gone, and `Wake`, retiring a row whose disk
      a probe just found gone or that it created and never built anything on.
      Everything after step 5 is identical, so this chooses whether the
      provider is *called*, never whether the row is written.
    * `:metadata` — extra keys merged into the fence's event, for a caller
      whose own delete is about to nilify `user_id` on the row it names.
    * `:request_ip` — attribution, passed to both events.
    * `:audit` — `false` suppresses the `sandbox.destroyed` event. The fence's
      `sandbox.teardown_requested` is unaffected: that one is
      `Lifecycle.fence_sandbox_for_teardown/2`'s and is written whatever this
      says. Defaults to `true`, and exactly one caller passes `false` —
      `Fountain.Accounts.Deletion`, whose own `terminate_conversation(audit:
      false)` has always suppressed the per-conversation events for the same
      reason: `audit_events.user_id` is nilified by the delete seconds later,
      so a per-machine row would survive as an orphan describing a cascade,
      and `account.deleted` already carries the identity (#2344, stage 5b).
      Note this is *not* the `user_id: nil` skip below — at destroy time the
      row still names its tenant, so that clause does not fire.
    * `:notify` — `{conversation_id, event, reason, message}`, the notice to
      cast to any other conversation still bound to the machine once it is
      gone. The cast is sent from here, `MachineEvents.tell_cotenants/5`'s
      one caller outside `Machines.Park`, which is what "sent by the owner
      only" means. `Lifecycle`'s reclaim is the one caller that passes it.
      Since ADR 0073 a machine has one conversation, so there is ordinarily
      nobody to tell. Omitted by every caller that has nothing to say: an
      account deletion, an expiry and an admin reap are not reclamations a
      conversation can be told to expect a new machine after, and none of
      them notified before ADR 0058 either.
    * `:busy_wait_ms` — how long to wait for a lease somebody else holds.
      Defaults to #{@busy_wait_ms}. Tests shorten it; no call site does.
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
      claim_and_destroy(sandbox_id, opts)
    end
  end

  @doc """
  How long `run/2` waits for a lease somebody else holds before refusing.

  Public so `machine_bounds_test.exs` can pin it against the two ceilings it
  has to sit under — `Machine`'s call timeout and `conversation_call_timeout_ms`
  — rather than against a number a test passed in itself.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  # The two required options, checked before anything is claimed or written.
  # Both are caller bugs rather than runtime conditions — a destroy with no
  # actor records an event ADR 0013 has no word for, and a reason that is not
  # an atom reaches the row as `transition_reason` and the trail as `"reason"`
  # in whatever shape it arrived in — so they raise rather than answer.
  defp validated(opts) do
    _actor = Keyword.fetch!(opts, :actor)

    case Keyword.fetch!(opts, :reason) do
      reason when is_atom(reason) and not is_nil(reason) ->
        :ok

      other ->
        raise ArgumentError, "Machines.Destroy: :reason must be an atom, got #{inspect(other)}"
    end

    validated_choice(opts, {:provider, [:destroy, :already_gone]})
    validated_notify(Keyword.get(opts, :notify))

    opts
  end

  # The notice is cast after the finalize, so a shape `notify_cotenants/2` has
  # no clause for would raise once the machine is already gone. Refused here
  # instead, before anything is claimed.
  defp validated_notify(nil), do: :ok

  defp validated_notify({conversation_id, event, reason, message})
       when is_binary(conversation_id) and is_binary(event) and is_binary(reason) and
              is_binary(message),
       do: :ok

  defp validated_notify(other) do
    raise ArgumentError,
          "Machines.Destroy: :notify must be {conversation_id, event, reason, message}, " <>
            "got #{inspect(other)}"
  end

  # The option value that steers the protocol is matched on, not branched on
  # with a fallback, so a typo would reach the caller as a `FunctionClauseError`
  # from somewhere in the middle of a destroy. Refused here for the same reason
  # `:reason` is: it is a caller bug, and the call has not claimed or written
  # anything yet.
  defp validated_choice(opts, {key, allowed}) do
    value = Keyword.get(opts, key, hd(allowed))

    unless value in allowed do
      raise ArgumentError,
            "Machines.Destroy: #{inspect(key)} must be one of #{inspect(allowed)}, " <>
              "got #{inspect(value)}"
    end
  end

  # ── the lease around one operation ────────────────────────────────────────

  defp claim_and_destroy(sandbox_id, opts) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

    case claim(sandbox_id, deadline) do
      {:ok, epoch} ->
        try do
          under_lease(sandbox_id, epoch, opts)
        after
          # `after`, not a plain next statement: an adapter that *raises*
          # unwinds through here, and a lease left held would otherwise keep
          # this machine unclaimable for as long as this owner lives — so the
          # next terminate of it waits out `@busy_wait_ms` and refuses, for a
          # failure that already happened. Releasing keeps the epoch, so it is
          # safe on every path, including one that has already been superseded.
          # Best effort and deliberately not matched on: a destroy that
          # finished is finished whether or not its lease came back.
          _ = Lease.release(sandbox_id, epoch)
        end

      # A sandbox with no workspace has no owner (ADR 0097): a row retired
      # before workspaces existed, answered as the terminal row it is.
      {:error, :no_workspace} ->
        case Lease.unowned(sandbox_id) do
          {:terminal, sandbox} -> already_terminal(sandbox, opts)
          :live -> {:error, :machine_busy}
          :not_found -> {:error, :not_found}
        end

      {:error, _} = error ->
        error
    end
  end

  # A lease someone else holds is waited out rather than refused outright: two
  # destroys of one machine arriving together is the ordinary case (a reaper
  # pass and a user's terminate), and the second one wants the first one's
  # answer, not an error. The wait is bounded by `@busy_wait_ms`: how long a
  # holder may hold is not how long a caller should wait.
  defp claim(sandbox_id, deadline) do
    case Lease.claim(sandbox_id) do
      {:ok, epoch} ->
        {:ok, epoch}

      {:error, {:held, holder}} ->
        retry_or_refuse(sandbox_id, deadline, "lease held by #{holder}")

      # The advisory lock behind `Lease.claim/2` is held by somebody else right
      # now — `Conversations.with_sandbox_lock/2` grew a `lock_timeout` in
      # stage 6b, and out of `claim/2` that word can mean nothing else. Waited
      # out exactly like a held lease, because it is the same condition one
      # step earlier.
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
      Logger.warning("machine #{sandbox_id}: destroy refused, #{why}")
      {:error, :machine_busy}
    end
  end

  # ── the protocol ──────────────────────────────────────────────────────────

  defp under_lease(sandbox_id, epoch, opts) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :not_found}

      # A machine that has already stopped, still carrying the intent of the
      # destroy that stopped it. **Checked before the continuation below**, and
      # that order is the whole point: matching on `transition` alone would
      # send a finished destroy back through the provider and record a second
      # `sandbox.destroyed` for a machine that was gone. Not a forged state: a
      # terminal write that knows nothing about `transition` leaves the stamp
      # exactly here, and until stage 9a
      # `SandboxReaper.finish_teardown/1` was that write. Since 9a it goes
      # through this protocol and clears the stamp, so on a fleet where every
      # replica runs 9a nothing produces the shape — and a replica that
      # predates it still does, for as long as a rollout is half done. See the
      # moduledoc.
      %Sandbox{transition: "destroying", status: status} = done
      when status in @terminal_statuses ->
        clear_stale_transition(done, epoch)
        already_terminal(done, opts)

      # The intent is already on the row, so this owner picks the work up at
      # step 5. Two shapes reach here and they are not the same thing.
      #
      # The one this clause was written for is a **takeover**: step 4 landed and
      # step 6 did not, because the previous holder died in the middle of its
      # provider call or was superseded before it could finalize.
      #
      # The other arrived with stage 9a and is now the *ordinary* path for every
      # destroy whose fence ran before the claim: the fence writes the stamp
      # (and, since stage 9b, only the stamp), so a detach that fenced first,
      # and `SandboxReaper`'s driver continuing a fence somebody abandoned, both
      # come through here on their first pass rather than through the fence
      # below. What that skips is the fence write (already done, and idempotent
      # anyway) and `stamp_then_destroy/3` (which would rewrite the same
      # reason). A `destroying` stamp is written by a fence or by this protocol
      # and by nothing else, so a row that reaches this clause has been fenced.
      #
      # It also skips the fence's *re-ask* under the sandbox lock, and that is
      # worth being exact about, because two callers fence before they get
      # here: `Lifecycle.prepare_destroy/2`, so the conversation server can
      # close its adapter knowing nothing can be admitted behind it, and
      # `Binding.fence_then_finish/4`, whose fence with the ending conversation
      # *is* the detach decision. The re-ask could only answer `:not_found` or
      # a terminal status differently, and both are read here, from the row,
      # in the two clauses above. Nothing can attach to the machine in between:
      # since ADR 0073 a conversation never joins another's sandbox, and the
      # committed fence closes it to admission. So what the stamp removes is a
      # second read, not a second decision.
      %Sandbox{transition: "destroying"} = interrupted ->
        Logger.info(
          "machine #{sandbox_id}: continuing a destroy already stamped on the row " <>
            "(#{interrupted.transition_reason || "no reason"}) at epoch #{epoch}"
        )

        destroy_and_finalize(interrupted, epoch, opts)

      %Sandbox{} = sandbox ->
        fence_then_destroy(sandbox, epoch, opts)
    end
  end

  # Answering `:already_terminal` is the outcome; clearing the stamp is the
  # tidying that makes the column mean something again — while it is set on a
  # terminal row, "is this machine mid-destroy?" cannot be answered from the
  # row, which is the column's only job. A status-free write is not a revival,
  # so `Lease.refuse_revival/2` lets it through on a terminal row; a refusal
  # here is somebody else's business and is logged rather than returned,
  # because the caller's answer does not depend on it.
  defp clear_stale_transition(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(sandbox.id, epoch, transition: nil, transition_reason: nil) do
      {:ok, _cleared} ->
        Logger.info(
          "machine #{sandbox.id}: cleared a stale destroying stamp on a #{sandbox.status} row"
        )

      {:error, reason} ->
        Logger.warning(
          "machine #{sandbox.id}: could not clear a stale destroying stamp (#{inspect(reason)})"
        )
    end

    :ok
  end

  defp fence_then_destroy(sandbox, epoch, opts) do
    # A remote call, so `lifecycle_fence_test.exs` can drive a race on it with
    # Mimic the way `Lifecycle.prepare_destroy/2` already does.
    case Lifecycle.fence_sandbox_for_teardown(sandbox, fence_opts(opts)) do
      {:ok, %Sandbox{status: status} = done} when status in @terminal_statuses ->
        already_terminal(done, opts)

      {:ok, %Sandbox{} = fenced} ->
        stamp_then_destroy(fenced, epoch, opts)

      {:error, _} = error ->
        error
    end
  end

  defp fence_opts(opts) do
    reason = Keyword.fetch!(opts, :reason)

    [
      actor: Keyword.fetch!(opts, :actor),
      reason: Keyword.get(opts, :fence_reason) || to_string(reason),
      # The row's word, in this module's own vocabulary — the same one
      # `stamp_then_destroy/3` writes a step later. The fence commits first and
      # the stamp only follows it, so an owner that dies between the two leaves
      # this value for `SandboxReaper`'s driver to hand back through
      # `reason_from_string/1`. Without it every such row read `teardown`, and
      # the sweep recorded a reason the caller never gave (review, round 2).
      transition_reason: reason
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    # Merged into `sandbox.teardown_requested` by the fence, for a caller whose
    # own delete is about to nilify the `user_id` on the event and the row it
    # names. `main`'s `retire_terminated_sandbox/2` forwarded the caller's whole
    # opts list, so dropping it here would have been a silent narrowing.
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
    |> put_unless_nil(
      :terminating_conversation_id,
      Keyword.get(opts, :terminating_conversation_id)
    )
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  defp stamp_then_destroy(sandbox, epoch, opts) do
    case Lease.cas_update(sandbox.id, epoch,
           transition: "destroying",
           transition_reason: to_string(Keyword.fetch!(opts, :reason))
         ) do
      {:ok, %Sandbox{} = marked} -> destroy_and_finalize(marked, epoch, opts)
      {:error, :stale} -> {:error, :superseded}
      {:error, :retired} -> already_terminal(sandbox, opts)
      {:error, _} = error -> error
    end
  end

  defp destroy_and_finalize(sandbox, epoch, opts) do
    # A sandbox-files read admitted before this destroy's claim may still be at
    # the provider, and the drain waits it out first (#2394), bounded by
    # `Reads.window_ms/0`, because no read is admitted while this lease is
    # live. `:already_gone` calls nothing, so it has nothing to wait for.
    provider = Keyword.get(opts, :provider, :destroy)

    if provider == :destroy,
      do: Reads.drain(sandbox.id, Keyword.take(opts, [:read_window_ms]))

    after_provider(sandbox, epoch, opts, destroy_at_provider(sandbox, provider))
  end

  defp after_provider(sandbox, epoch, opts, provider_result) do
    case provider_result do
      :ok ->
        finalize(sandbox, epoch, opts)

      # The fenced row retires anyway, so the fleet sees a terminal row rather
      # than a live one nobody can find, and `SandboxReaper`'s pass over
      # terminal rows deletes the machine again if the provider still lists it.
      {:error, reason} ->
        provider_gave_up(sandbox, reason)
        finalize(sandbox, epoch, opts)
    end
  end

  defp finalize(sandbox, epoch, opts) do
    case Lease.cas_update(sandbox.id, epoch,
           status: "terminated",
           transition: nil,
           transition_reason: nil
         ) do
      {:ok, %Sandbox{} = terminated} ->
        # The machine is gone, so no turn admitted on it can continue: the
        # owner ends them (stage 8b), under the lease it still holds and after
        # the finalize has committed, so a recovering actor's later write —
        # the reattaching server's give-up, a successor on a replacement
        # machine — finds each turn already terminal. Every running turn
        # bound to the machine, whoever is driving it: a forced destroy has
        # already stopped or terminated the servers, and a conversation-side
        # one has interrupted its own turn before reaching here.
        end_turns(terminated, opts)

        # Both after the finalize commits, in this order: the trail is the
        # durable record and must not depend on a cast reaching anybody.
        audit(terminated, opts)
        notify_cotenants(terminated, opts)
        {:ok, :destroyed}

      {:error, :stale} ->
        # A newer epoch owns this machine. The provider call above may well
        # have succeeded; the takeover reads the row's true state and is the
        # one allowed to say what happened to it.
        Logger.warning("machine #{sandbox.id}: destroy superseded before its finalize")
        {:error, :superseded}

      {:error, :retired} ->
        already_terminal(sandbox, opts)

      {:error, _} = error ->
        error
    end
  end

  # Somebody else stopped this machine. The caller's own bookkeeping still has
  # to run, and so does the caller's notice, for any other server still holding
  # a handle to a machine that is already gone (ordinarily none since ADR 0073).
  # The turns too (stage 8b), and for the same reason: a machine written
  # terminal without an owner — a pre-9a replica's `finish_teardown/1`, on a
  # half-done rollout — has had no owner end its turns, and ending one twice is
  # a `:noop`.
  defp already_terminal(%Sandbox{} = sandbox, opts) do
    end_turns(sandbox, opts)
    notify_cotenants(sandbox, opts)
    {:ok, :already_terminal}
  end

  defp end_turns(%Sandbox{} = sandbox, opts) do
    Admission.end_turns_on(sandbox.id, "machine_destroyed",
      actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor))
    )
  end

  # ── the provider ──────────────────────────────────────────────────────────

  # The caller has already asked this provider about this machine and been
  # told it does not exist, so there is nothing to call and a call would be a
  # delete against a name that is no longer this machine's (a reattach or a
  # wake that probed and found it gone). Success, and the finalize runs exactly
  # as it does for a machine this module deleted itself.
  defp destroy_at_provider(%Sandbox{}, :already_gone), do: :ok

  # There is no "no machine to call" case to handle: `machine_name` is `NOT
  # NULL` in the database and required by `Sandbox.changeset/2`, so a row that
  # exists names a machine.
  defp destroy_at_provider(%Sandbox{} = sandbox, :destroy) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      # Already gone is the outcome asked for.
      {:error, :not_found} ->
        :ok

      {:error, _reason} = error ->
        error
    end
  rescue
    # An adapter that raises rather than answering is the same *outcome* as one
    # that returns an error — this machine was not reached — so it gets the same
    # treatment, and for the same reason: a fenced row must not be stranded in a
    # live status because a provider client blew up. `main` let the raise
    # through and paid for it with a row nobody could find (`SandboxReaper`'s
    # moduledoc lists that leak); catching it here means the row retires, the
    # trail records the destroy, and the reaper's pass over terminal rows
    # deletes the machine again if the provider still lists it. The exception
    # is logged in full so the adapter bug is still visible.
    error ->
      {:error, Exception.format(:error, error, __STACKTRACE__)}
  end

  # Always logged: an operator looking at a machine that outlived its row needs
  # the provider's own words, and this is the only place that has them.
  defp provider_gave_up(%Sandbox{} = sandbox, reason) do
    Logger.warning(
      "machine #{sandbox.id}: provider destroy failed for #{sandbox.machine_name} " <>
        "on #{sandbox.provider}: #{inspect(reason)}"
    )

    :ok
  end

  # ── after the finalize ────────────────────────────────────────────────────

  # Two ways a completed destroy records nothing, from opposite ends of the
  # same delete.
  #
  # `audit: false` is a caller that has asked for silence, and one does:
  # `Accounts.Deletion` is about to delete the tenant, which nilifies
  # `audit_events.user_id`, so a per-machine row would outlive its subject as
  # an orphan describing a cascade. That is the same judgement its own
  # `terminate_conversation(audit: false)` already makes about the
  # per-conversation events, and the reason `account.deleted` denormalises the
  # identity into its own metadata (#2344, stage 5b decision).
  #
  # A nil `user_id` is a row that has *already* lost its tenant — the #2329
  # trap, an account deletion that nilified before its machines were torn down.
  # An audit row with no `user_id` is a system event surfaced only in admin
  # views and would say nothing the deletion's own trail does not, so it is
  # skipped rather than recorded unattributed. Stage 5b's deletion caller does
  # not reach this clause (it suppresses through `:audit`, while `user_id` is
  # still set); a partly-completed delete can.
  #
  # The fence's `sandbox.teardown_requested` is not suppressed by either: it is
  # `Lifecycle.fence_sandbox_for_teardown/2`'s event, written before this is
  # ever consulted, and a teardown that was requested still happened.
  defp audit(%Sandbox{} = sandbox, opts) do
    cond do
      not Keyword.get(opts, :audit, true) -> :ok
      is_nil(sandbox.user_id) -> :ok
      true -> record_destroyed(sandbox, opts)
    end
  end

  defp record_destroyed(%Sandbox{} = sandbox, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: "sandbox.destroyed",
      resource_type: "sandbox",
      resource_id: sandbox.id,
      # Folded the same way the fence folds it (`Lifecycle.teardown_actor/1`):
      # ADR 0013 reserves `admin:<operator_id>` for account deletion alone, so
      # an operator reaping a machine records the plain `admin` the vocabulary
      # allows. Stage 5b's admin reap is the first caller that supplies the id
      # form, and the two events a destroy leaves have to agree on the actor
      # whichever stage wrote the caller.
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

  # The machine is gone, so any other conversation still bound to it has lost
  # its handle. `machine_gone` tells every one of them (ADR 0097: an explicit
  # workspace has many). A caller that knows what to say says it ("reclaimed"
  # and the bound that reclaimed it); any other gets the destroy's own words,
  # and every bound conversation but a terminating one is told. A server already
  # ending, or none, makes the cast a no-op (`MachineEvents.tell_cotenants/5`).
  defp notify_cotenants(%Sandbox{} = sandbox, opts) do
    {conversation_id, event, reason, message} =
      Keyword.get(opts, :notify) || default_notice(opts)

    sandbox.id
    |> Conversations._unsafe_list_cotenant_ids(conversation_id)
    |> MachineEvents.tell_cotenants(sandbox.id, event, reason, message)
  end

  defp default_notice(opts) do
    {Keyword.get(opts, :terminating_conversation_id), "reclaimed",
     to_string(Keyword.fetch!(opts, :reason)),
     "The sandbox was destroyed. Send another prompt to continue — the transcript " <>
       "above is kept, but the agent starts a fresh session and will not remember " <>
       "the earlier turns."}
  end
end
