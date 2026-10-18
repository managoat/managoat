defmodule Fountain.Machines.Provision do
  @moduledoc """
  One server taking possession of one machine (ADR 0058, stage 7b).

  The three protocols before this one — `Fountain.Machines.Destroy`,
  `Fountain.Machines.Park`, `Fountain.Machines.Resume` — each *moved* a verb out
  of its caller. This one does not, and the difference is the whole design.
  Provisioning is not a provider round trip with some bookkeeping around it: it
  is a pipeline of a dozen steps — skills, a runtime config, an env file, a
  broker CA, packages, a clone, a setup script, an inference reservation, an
  adapter — that builds `ConversationServer`'s own state as it goes and belongs
  to that server (ADR 0037; #1369). What ADR 0058 needs is not the pipeline but
  the **row and the machine**: the status writes, the create, and the destroys
  on the failure arms. So this is a **bracket**. The owner claims the lease,
  stamps the intent, creates the machine, runs the caller's pipeline as a
  callback under the lease, and writes `ready` or `failed` from what the
  callback answers. The pipeline stays where it is.

      claim the lease (4316, one short transaction, released at its commit)
      revalidate under the lease
      CAS transition: "provisioning"
      ── no lock, no transaction from here ──
      discard a half-built machine, if this is a second attempt
      create at the provider
      CAS status: "starting"
      run the caller's pipeline, under the lease
      CAS status: "ready" (+ the build record) — or "failed", or nothing
      release; then the effects, then one audit event

  ## The reservation is the row, not a stamp

  `Resume` had to invent a reservation: a `suspended` row counts against
  nothing, so the stamp it writes inside the quota transaction is what makes a
  machine on its way up hold a slot. A provision needs none of that, and asking
  why is what settles where the bracket begins.

  The fleet ceiling counts `pending`, `starting` and `ready`. The row
  is inserted `pending`, by `Launch.reserve_initial_conversation/4` or
  `Wake.create_fresh_sandbox_and_start/4`, **inside**
  `Quotas.with_sandbox_reservation/2`'s own transaction — so the fleet ceiling
  is checked and the slot is taken in one
  commit, before any server exists. *The row's creation is the reservation.*

  Which decides the lock order, the thing 7a had to be corrected about. The rule
  is that anyone holding 4315 may take 4316 and never the reverse, and
  `reserve_initial_conversation/4` is a 4315-then-4316 holder. This bracket
  begins **after** that reservation has committed — the server does not exist
  until it has — so it never takes 4316 under a held 4315. It takes no quota
  lock at all: there is nothing here to admit, because the admission happened
  when the row was written.

  `Conversations.create_sandbox/1`'s insert therefore stays where it is and is
  still counted by the ratchet. Creating a row is not an operation on a machine;
  there is no machine yet, and nothing to own.

  ## The steps

  1. Refuse an enclosing transaction (#2309).
  2. **Claim a lease** for one operation. Held by somebody else: waited on
     briefly, then `{:error, :machine_busy}`. That is the case of two servers
     for one conversation — under Horde, CRDT merges and registry lag both
     produced them (#367) — and it is the whole of "two servers never provision
     one row":
     the second waits, is refused, and stops without touching the machine.
  3. **Revalidate under the lease**: the row is there, it is not terminal,
     neither fence is set, and its status is one a provision starts from. An
     abandoned stamp left by some *other* verb is cleared on the way past, which
     is `Resume`'s rule and `Conversations.register_server/2`'s precedent.
  4. **CAS `transition: "provisioning"`**. Before any provider call, so a reader
     that meets this row sees an owner rather than racing one, and so the next
     attempt can tell that a machine may have been created.
  5. **Discard a half-built machine**, if this is a second attempt — see
     `interrupted?/1`. `Managoat.Sandbox.create/2` adopts an existing machine by
     name and the pipeline's steps are not idempotent (`git clone` refuses a
     checkout that exists; a setup script that starts services fails on the
     second start), so a remnant is torn down rather than finished.
  6. **Create at the provider**, outside every lock.
  7. **CAS `status: "starting"`**: the machine exists.
  8. **Run the caller's pipeline**, under the lease, which holds for as long
     as the calling server lives. #329's thirty-minute ceiling is
     `ProvisionWatchdog`'s, which supersedes the lease and stops the server.
  9. **Finalize**, from what the pipeline answered. See `finalize/5`: `ready`
     with the build record, `failed`, or — for the two answers that mean another
     actor now owns this row — the machine destroyed and *nothing written*.
  10. Release. Then the effects `Conversations.update_sandbox/2` would have run,
      then one audit event.

  ## Interruption, and why there is no separate takeover

  `Destroy`, `Park` and `Resume` each have a takeover clause: a claim that finds
  its own verb's stamp on a row whose holder has died is looking at an
  operation whose owner died, and each compensates by asking the provider what
  actually happened. A provision does not need one, because the compensation for
  a half-built machine is **to build it again**, which is the protocol itself.

  That is not a new decision. `main` has done it since #1372:
  `discard_interrupted_attempt/3` tears the remnant down and the
  server provisions from the top. All this stage does is decide *when* a row
  counts as interrupted, and it widens the test by exactly one shape:

    * `status: "starting"` — `main`'s test, and still true. The old attempt got
      as far as creating the machine.
    * `transition: "provisioning"` on a `pending` row — **new**, and it exists
      because this protocol writes the stamp before the create where `main` wrote
      `starting` before it. A `pending` row wearing the stamp is an attempt that
      may have created a machine and died before it could say so. Discarding
      costs one destroy against a name that may not exist, which every adapter
      answers without complaint; not discarding costs a `git clone` into a
      checkout that already exists, which is how this was found.

  A takeover is therefore just an ordinary run with `interrupted?` true, and it
  re-reads every condition under its own lease like any other.

  ## What is deliberately *not* here

  **No hop through the owner process.** `Machine.destroy/2`, `park/2` and
  `ensure_up/2` run inside `Fountain.Machines.Machine`, so two operations on one
  machine queue in one mailbox. `Machine.provision/3` runs inline on its
  caller, and says so. Three reasons, in order of how much they matter:

    * the callback **is** the caller's pipeline. It builds and returns the
      `ConversationServer`'s own state, spawns its adapter and closes over its
      secrets; running it inside another `GenServer` would move the pipeline out
      of the server, which is the one thing ADR 0037 and #1369 say this stage
      must not do.
    * it runs for minutes. A `GenServer.call` of that length is over every
      timeout in this tree, and an owner occupied for half an hour would refuse
      the destroy that is the way to stop it.
    * it buys nothing. What makes two provisions of one row safe is the lease
      and the compare-and-set, exactly as the moduledoc of
      `Fountain.Machines.Machine` says of the other three — the process is an
      optimization of contention, not the correctness — and the contention here
      is a duplicate server, which the lease refuses in one round trip.

  **No admission.** See the reservation, above.

  **A superseded provision's writes stop with its server.** The only way to
  lose this lease while the holder lives is `ProvisionWatchdog`'s `supersede:`
  claim, and the watchdog stops the server straight after it has retired the
  row. Until ADR 0072 a lapsed TTL lease could be taken over while its holder
  went on running its pipeline into a machine carrying the row's name.

  ## Outcomes

  `{:ok, :provisioned, result}` built the machine; `result` is whatever the
  pipeline returned. `{:ok, :already_terminal}` is a row that had stopped —
  retirement won while this was starting, and there is nothing to build for.

  The `{:error, _}` shapes are the protocol's vocabulary — `:machine_busy`,
  `:fenced`, `:superseded`, `{:not_provisionable, status}`, `:not_found`,
  whatever `Lease` hands back, and the pipeline's own reason — and
  `Fountain.Machines.Machine.provision/3` is the door that translates them.
  """

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  require Logger

  @typedoc """
  What taking possession did. `:provisioned` built the machine and the row says
  `ready`; `:already_terminal` is a row that had stopped; `:confirmed` is
  `confirm_up/2` finding the machine it was handed still live; `:failed` is
  `fail/2` retiring one; `:not_provisioning` is `fail/2` finding nothing to
  retire.
  """
  @type outcome :: :provisioned | :already_terminal | :confirmed | :failed | :not_provisioning

  @typedoc """
  The caller's pipeline, run under the lease with the machine it is to build on.

  It is handed the provider handle and the lease epoch — the epoch because a
  step that records something on the row mid-provision (`record_sandbox_url/3`'s
  `provider_meta`) must write it by compare-and-set on the same epoch, or a
  superseded attempt leaves its URL behind on another owner's machine.

  `{:ok, result}` finalizes the row `ready` and hands `result` back.
  `{:error, reason, result}` is a pipeline that failed and has cleaned up after
  itself; `result` is returned to the caller beside the reason, because the
  caller's own teardown needs the state its pipeline had reached.

  **`result` is never `nil`.** The protocol's contract is "three elements
  means the pipeline ran and there is a result", and
  `Fountain.Conversations.FreshProvision` reads the three-element shapes this
  produces as "there is a `%{state: _}` to unwind" — the two readings coincide
  only because no pipeline answers `{:ok, nil}`. A pipeline that did would
  reach `FreshProvision` with no clause, and the rescued `CaseClauseError`
  would be reported as the provision having raised (stage 7b review, carried
  into 8a).
  """
  @type pipeline ::
          (Managoat.Sandbox.Handle.t(), Lease.epoch() ->
             {:ok, term()} | {:error, term(), term()})

  # How long a *waiter* waits for a holder. `Destroy`'s, `Park`'s and
  # `Resume`'s number. The waiter here is a duplicate server, which has nothing
  # useful to do with a longer wait: the machine belongs to the other one, and
  # stopping is the right answer a second sooner.
  @busy_wait_ms 5_000

  # How often the wait re-asks.
  @poll_ms 250

  @terminal_statuses ~w(terminated failed)

  # The statuses a provision starts from. `pending` is a fresh row; `starting`
  # is an attempt that got as far as the machine and was interrupted.
  @provisionable ~w(pending starting)

  # And the statuses a server may take possession of a machine it did not build:
  # `ready` is the ordinary reattach, `suspended` is a machine the reaper parked
  # between the wake's own resume and this server starting. See `confirm/3`.
  @confirmable ~w(ready suspended)

  # The three answers from a pipeline that mean **another actor already owns this
  # row**, where the machine this attempt built is its own to destroy and the row
  # is not its to write.
  #
  # `:configuration_changed` is a reassignment that committed while
  # the provider was working: the successor must wake the committed selection,
  # and a `failed` row would be this attempt failing somebody else's machine.
  # `:sandbox_reset_pending` is a reset fence landing in the same window, whose
  # own owner finishes the row. `:retired` is the same shape reached through
  # `Conversations.claim_sandbox/2`, which a pipeline step may still return.
  # `main` destroyed the handle and wrote nothing on all three, and so does this.
  #
  # `FreshProvision.@foreign_provision_owner` keeps two of them, deliberately:
  # it decides what the *conversation* owes, and `:retired` never reaches it —
  # the protocol answers `{:ok, :already_terminal}` for a retired row before the
  # caller is asked.
  @foreign_owner [:configuration_changed, :sandbox_reset_pending, :retired]

  @doc """
  Build the machine behind `sandbox_id`, running `fun` as the pipeline.

  Options:

    * `:actor` (required) — the audit actor for `sandbox.provisioned` and
      `sandbox.provision_failed`, from ADR 0013's vocabulary. The server passes
      `"system:conversation_server"`.
    * `:on_claim` — run once the machine is this attempt's and the intent is on
      the row, before anything is created, and handed whether this is a rebuild
      (see `interrupted?/1`). `:ok` carries on; `{:error, reason}` fails the row
      and answers, with nothing created and nothing to destroy.

      It exists so that the things a caller does *because* it now owns the
      machine happen in the order they did before the bracket: the server
      announces `provision/started` here, with the authoritative reading of
      whether an earlier attempt was interrupted rather than the one it guessed
      from a pre-claim snapshot, and refuses a provider/environment pairing that
      cannot work (#935) where `main` refused it — after the announcement, and
      before anything is provisioned. A row that was retired while this server
      was starting therefore announces nothing at all, which is the invariant
      `conversation_server_provision_retirement_test.exs` pins.
    * `:ready_attrs` — extra columns to write in the same statement that makes
      the row `ready`: `applied_skills`, the record of the skills
      the disk was built with. Computed by the caller *before* the bracket,
      because it is known from the agent rather than from anything the
      pipeline discovers, and written by compare-and-set so a superseded
      attempt leaves none behind.
    * `:conversation_id` — recorded in the audit metadata.
    * `:request_ip` — attribution, passed to the audit event.
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
  """
  @spec run(Ecto.UUID.t(), pipeline(), keyword()) ::
          {:ok, :provisioned, term()}
          | {:ok, :already_terminal}
          | {:error, term()}
          | {:error, term(), term()}
  def run(sandbox_id, fun, opts)
      when is_binary(sandbox_id) and is_function(fun, 2) and is_list(opts) do
    _actor = Keyword.fetch!(opts, :actor)

    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      under_claim(sandbox_id, opts, &provision_under_lease(&1, &2, fun, opts))
    end
  end

  @doc """
  Confirm the machine behind `sandbox_id` is still this server's to attach to.

  The reattach arm of the same door. A `ConversationServer` that has just asked
  the provider and been told its machine is up writes `ready` on the row before
  it attaches — not to change anything, which is why `main`'s comment on it
  reads "validate even a cached ready row", but to assert under the machine's own
  serialization that retirement did not win while the provider was answering.

  So this is the shortest protocol here: claim, revalidate, one compare-and-set,
  release. No provider call — the caller has already made it — and no audit
  event, because nothing happened to the machine. The write is not a formality:
  it moves `updated_at`, which is what `SandboxReaper.release_stuck_sandboxes/0`
  reads as a sign of life.

  A `suspended` row comes here too, and it is the one case that does more than
  assert: see `confirm/3`. It is a machine the reaper parked between the wake's
  own resume and this server starting, and the caller has *already asked the
  provider* and been told the machine is running — so the row is brought back to
  `ready` with `last_resumed_at` and, new in this stage, a `sandbox.resumed`
  event.

  **No provider call and no admission**, which is a deliberate difference from
  `Machine.ensure_up/2` and worth stating rather than leaving to be noticed.
  There is nothing to resume: the caller's probe, a few lines earlier in
  `ConversationServer.do_reattach/6`, is what got it here. And refusing it at a
  quota would strand a conversation whose machine is up and whose disk is
  reachable, which is the opposite of what a cap is for — the wake that brought
  this machine back was admitted when it ran. That leaves the *unadmitted
  reattach* exactly where `main` left it, and naming it is the honest thing to
  do: a machine that comes back this way is not re-counted until it is `ready`,
  which it becomes here. Stage 8's admission is where a reattach becomes
  visible to the owner as a decision rather than a fact.

  Options: `:actor` (required when the row may be `suspended`, for the event),
  `:conversation_id`, `:request_ip` and `:busy_wait_ms`.
  """
  @spec confirm_up(Ecto.UUID.t(), keyword()) ::
          {:ok, :confirmed | :already_terminal} | {:error, term()}
  def confirm_up(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      under_claim(sandbox_id, opts, &confirm_under_lease(&1, &2, opts))
    end
  end

  @doc """
  Retire a machine whose provisioning is not going to happen.

  The terminal write on its own, for the three callers that have to fail a row
  they never brought under a lease: the server's two pre-flight failures (tenant
  credentials it could not load, MCP variables it could not substitute),
  `Launch.fail_initial_start/2` when the server itself would not start, and
  `ProvisionWatchdog` at the absolute deadline.

  Claim, revalidate that the row is still one a provision was expected on, run
  the caller's `:if` guard if it brought one, compare-and-set `failed`, release,
  effects, one `sandbox.provision_failed`. `{:ok, :not_provisioning}` is a row
  that is no longer `pending` or `starting` — somebody else settled it — and is
  not an error at any caller.

  Options: `:actor` (required), `:reason` (an atom, required — it becomes
  `transition_reason` and the audit metadata's `"reason"`), plus
  `:conversation_id`, `:request_ip` and `:busy_wait_ms`. `:supersede` takes
  the lease from that one holder even while it lives; `ProvisionWatchdog` passes
  the wedged server it is about to stop (`Lease.claim/2`).

  `:before_write` is run with the row as this lease read it, after the
  revalidation above and before the row is written. `:ok` carries on; anything
  else is `{:ok, :not_provisioning}` and nothing is written.

  It is a *callback* rather than a predicate because one caller needs both
  halves of it. `Launch.fail_initial_start/2` fails a conversation and its
  machine together, and `main` did that in one transaction under the
  per-sandbox advisory lock — the machine's row is the owner's now, so the
  transaction is gone, and what replaces it is this: the binding is re-checked
  and the conversation is failed here, under the lease, so the order an
  observer sees is the order `main` committed.
  """
  @spec fail(Ecto.UUID.t(), keyword()) ::
          {:ok, :failed | :already_terminal | :not_provisioning} | {:error, term()}
  def fail(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    _actor = Keyword.fetch!(opts, :actor)
    _reason = Keyword.fetch!(opts, :reason)

    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      under_claim(sandbox_id, opts, &fail_under_lease(&1, &2, opts))
    end
  end

  @doc """
  Insert the row a provision will build: the reservation.

  Stage 7b found that the reservation needs no stamp of its own — the row is
  inserted `pending` inside the fleet reservation's transaction
  (`Fountain.Quotas.with_sandbox_reservation/2`), and `pending` already counts
  against the ceiling — so the bracket `run/3` opens begins after that commit.
  This is the insert, moved here from `Conversations.create_sandbox/1` in stage
  9b so that the owner's namespace is the only code that writes the
  `sandboxes` row. It runs inside the caller's transaction, as it always did.
  """
  @spec reserve(map()) :: {:ok, Sandbox.t()} | {:error, Ecto.Changeset.t()}
  def reserve(attrs) when is_map(attrs) do
    %Sandbox{}
    |> Sandbox.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  How long `run/3` waits for a lease somebody else holds before refusing.

  Public so `machine_bounds_test.exs` can pin it against the bounds it sits
  between.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  # ── the lease around one operation ────────────────────────────────────────

  # All three verbs take the lease the same way, so they take it in one place.
  # `fun` is handed the row as it was read under the lease and the epoch.
  defp under_claim(sandbox_id, opts, fun) do
    deadline =
      System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

    case claim(sandbox_id, Keyword.take(opts, [:supersede]), deadline) do
      {:ok, epoch} ->
        try do
          case Conversations._unsafe_get_sandbox(sandbox_id) do
            nil -> {:error, :not_found}
            %Sandbox{} = sandbox -> fun.(sandbox, epoch)
          end
        after
          # `after`, not a plain next statement, for `Park`'s and `Resume`'s
          # reason: a provider adapter or a pipeline step that raises unwinds
          # through here, and a lease left held keeps this machine unclaimable
          # for as long as this server lives — during which every wake of it
          # answers 503 and the retry the caller is about to make is refused.
          _ = Lease.release(sandbox_id, epoch)
        end

      {:error, _} = error ->
        error
    end
  end

  # A lease somebody else holds is waited out rather than refused outright, as
  # everywhere else here. What is waiting is usually a duplicate server, and
  # what it finds after the wait is a machine that is not its to build.
  defp claim(sandbox_id, claim_opts, deadline) do
    case Lease.claim(sandbox_id, claim_opts) do
      {:ok, epoch} ->
        {:ok, epoch}

      {:error, {:held, holder}} ->
        retry_or_refuse(sandbox_id, claim_opts, deadline, "lease held by #{holder}")

      # The advisory lock is held right now (`with_sandbox_lock/2`'s
      # `lock_timeout`, stage 6b): a moment's contention, waited out the same
      # way rather than turned into a failed provision.
      {:error, :sandbox_unavailable} ->
        retry_or_refuse(sandbox_id, claim_opts, deadline, "the sandbox lock is held")

      {:error, _} = error ->
        error
    end
  end

  defp retry_or_refuse(sandbox_id, claim_opts, deadline, why) do
    if System.monotonic_time(:millisecond) + @poll_ms < deadline do
      Process.sleep(@poll_ms)
      claim(sandbox_id, claim_opts, deadline)
    else
      Logger.warning("machine #{sandbox_id}: provision refused, #{why}")
      {:error, :machine_busy}
    end
  end

  # ── the protocol ──────────────────────────────────────────────────────────

  defp provision_under_lease(%Sandbox{} = sandbox, epoch, fun, opts) do
    case admissible(sandbox) do
      :ok ->
        interrupted? = interrupted?(sandbox)
        sandbox = clear_foreign_stamp(sandbox, epoch)

        case stamp(sandbox, epoch) do
          {:ok, %Sandbox{} = marked} -> build(marked, epoch, interrupted?, fun, opts)
          settled -> settled
        end

      refusal ->
        refusal
    end
  end

  # Step 3. What the row *is*, then what has been asked of it, then whether
  # there is anything here to build — `Resume.admissible/2`'s order, and the
  # fences come before the status for its reason: a machine whose reset or
  # teardown has been asked for is on its way out, and building one would
  # reserve compute at the provider that somebody has already said goodbye to.
  defp admissible(%Sandbox{status: status}) when status in @terminal_statuses,
    do: {:ok, :already_terminal}

  defp admissible(%Sandbox{} = sandbox) do
    cond do
      # The fence is the `destroying` stamp — both fences write it (stage 9a),
      # and since stage 9b it is the only thing read — which is what makes
      # `clear_foreign_stamp/2`'s claim below structural rather than
      # incidental.
      sandbox.transition == "destroying" ->
        {:error, :fenced}

      sandbox.status in @provisionable ->
        :ok

      # `ready` or `suspended`. `ConversationServer.dispatch_provision/7` sends
      # these to the reattach arm and never here, so this is a caller that has
      # gone wrong rather than a race — and answering rather than building is
      # the important half: `Managoat.Sandbox.create/2` adopts by name, so a
      # provision onto a live machine would re-run the pipeline over a working
      # disk.
      true ->
        {:error, {:not_provisionable, sandbox.status}}
    end
  end

  # An attempt that may have left a machine behind. See the moduledoc; the
  # `provisioning` half is new in this stage and the `starting` half is `main`'s.
  defp interrupted?(%Sandbox{status: "starting"}), do: true
  defp interrupted?(%Sandbox{transition: "provisioning"}), do: true
  defp interrupted?(%Sandbox{}), do: false

  # Somebody else's stamp — a park, a resume — on a machine whose lease this
  # claim has just taken. **That stamp is abandoned by construction**:
  # `Lease.claim/2` refuses while the current lease is live, so holding one is
  # proof that no other owner is working here. Cleared and the row judged by its
  # status, which is stage 6a's rule applied on the owner's side, and `Resume`'s
  # clause verbatim.
  #
  # **A `destroying` stamp is never cleared here**, and since stage 9a that is a
  # rule rather than an observation. It used to read "never reaches here: it
  # always arrives with a fence, and `admissible/1` has already refused" — true
  # while the fence columns exist and nothing at all once 9b drops them, on a
  # function whose whole job is to delete a stamp. Both doors into this one now
  # refuse the stamp themselves (`admissible/1` and `confirm_under_lease/3`),
  # and the clause below refuses to clear it whichever door a later caller
  # arrives through, which is what `Lease.cas_update/4` would enforce
  # underneath in any case.
  #
  # Our *own* verb's stamp is left alone — `stamp/2` is about to write it again,
  # and `interrupted?/1` has already read what it means.
  defp clear_foreign_stamp(%Sandbox{transition: nil} = sandbox, _epoch), do: sandbox
  defp clear_foreign_stamp(%Sandbox{transition: "provisioning"} = sandbox, _epoch), do: sandbox

  # **Inert, deliberately, and said so rather than tested** (review). Both doors
  # into this function refuse a `destroying` row before reaching it, and
  # `Lease.cas_update/4` would keep the stamp even if one did not — so no plant
  # of this clause can fail a test, and a test that cannot fail is a claim
  # nobody is checking. It stays as the local statement of a rule enforced
  # twice above and once underneath; delete it with the columns at 9b if it
  # still has no reader.
  defp clear_foreign_stamp(%Sandbox{transition: "destroying", status: status} = sandbox, _epoch)
       when status not in @terminal_statuses,
       do: sandbox

  defp clear_foreign_stamp(%Sandbox{transition: other} = sandbox, epoch) do
    Logger.info(
      "machine #{sandbox.id}: clearing an abandoned #{other} stamp left by an owner " <>
        "whose holder had died"
    )

    case Lease.cas_update(sandbox.id, epoch, [transition: nil, transition_reason: nil], []) do
      {:ok, cleared} -> cleared
      {:error, _} -> sandbox
    end
  end

  # Step 4. The durable intent, before any provider call. `transition_reason`
  # carries whether this is a first attempt or a rebuild, which is the one thing
  # an operator reading the row mid-provision wants to know.
  defp stamp(%Sandbox{} = sandbox, epoch) do
    case Lease.cas_update(
           sandbox.id,
           epoch,
           [transition: "provisioning", transition_reason: nil],
           []
         ) do
      {:ok, %Sandbox{} = marked} ->
        {:ok, marked}

      # `:machine_busy` rather than `:superseded`, for `Resume.stamp/2`'s
      # reason: nothing has been built, the row still says `pending`, and the
      # honest answer to a caller that has lost the machine before it started is
      # that somebody else has it.
      {:error, :stale} ->
        {:error, :machine_busy}

      {:error, :retired} ->
        {:ok, :already_terminal}

      {:error, _} = error ->
        error
    end
  end

  # ── the machine, and the caller's pipeline ────────────────────────────────

  # Steps 5 to 8, under the one lease. The create and the pipeline are one
  # operation from the lease's point of view: the machine exists from the middle
  # of it.
  defp build(%Sandbox{} = sandbox, epoch, interrupted?, fun, opts) do
    on_claim = Keyword.get(opts, :on_claim, fn _interrupted? -> :ok end)

    case on_claim.(interrupted?) do
      :ok -> build_under_lease(sandbox, epoch, interrupted?, fun, opts)
      {:error, reason} -> refuse_before_create(sandbox, epoch, reason, opts)
    end
  end

  # The caller's pre-flight said no, after this attempt took the machine and
  # announced itself. Nothing was created, so there is nothing to destroy — the
  # row is failed and the reason travels, which is what a caller that publishes
  # its own stage events needs.
  #
  # The reason goes on the row as well as to the caller (round 1, protocol and
  # behaviour reviews). The first draft wrote `:provision_refused`, which threw
  # away the only thing an operator reading `transition_reason` wants — #935's
  # refusal is `{:network_policy, :unsupported_backend}`, and `reason_text/1`
  # has handled tuples since change 9.
  defp refuse_before_create(%Sandbox{} = sandbox, epoch, reason, opts) do
    Logger.error(
      "machine #{sandbox.id}: provision refused before the machine: #{inspect(reason)}"
    )

    _ = write_failed(sandbox, epoch, reason, opts)
    {:error, reason}
  end

  defp build_under_lease(%Sandbox{} = sandbox, epoch, interrupted?, fun, opts) do
    outcome = create_and_run(sandbox, epoch, interrupted?, fun)

    case outcome do
      %{step: :built} = attempt ->
        finalize(sandbox, epoch, attempt, opts)

      %{step: :pipeline_failed} = attempt ->
        fail_pipeline(sandbox, epoch, attempt, opts)

      # No machine was created, so there is nothing to destroy and the row is
      # this attempt's to fail.
      %{step: :create_failed, reason: reason} ->
        Logger.error("machine #{sandbox.id}: provision could not start: #{inspect(reason)}")
        _ = write_failed(sandbox, epoch, :create_failed, opts)
        {:error, reason}

      # A machine exists and the row would not take `starting` — see
      # `orphaned/4` for why that is three different situations.
      %{step: :orphaned} = attempt ->
        orphaned(sandbox, epoch, attempt)
    end
  end

  # The machine exists and the row refused `starting`. Three situations, and
  # `main` had none of them because it wrote `starting` *before* the create
  # (round 1, protocol review — the first draft answered `:create_failed` for
  # all three, which dropped the handle on the floor and wrote `failed` over
  # another actor's terminal row, because `Lease.refuse_revival/2` permits
  # terminal-to-terminal).
  #
  # The split is `finalize/5`'s, for `finalize/5`'s reasons.
  defp orphaned(%Sandbox{} = sandbox, _epoch, %{handle: handle, reason: :retired}) do
    # Retired while the machine was being created, and **this attempt is still
    # the holder** — so the machine is its own, nobody else will come for it,
    # and the row is not its to write. Exactly `finalize/5`'s `:retired` arm,
    # one compare-and-set earlier.
    Logger.info(
      "machine #{sandbox.id}: the row was retired between the create and the status; " <>
        "destroying the machine and leaving the row to its owner"
    )

    destroy_attempt(sandbox, handle, :retired)
    {:ok, :already_terminal}
  end

  defp orphaned(%Sandbox{} = sandbox, epoch, %{reason: :stale}) do
    # Superseded. The taker is building under this row's name, so a destroy
    # here would take theirs.
    Logger.warning(
      "machine #{sandbox.id}: the provision at epoch #{epoch} was superseded between " <>
        "the create and the status; leaving the machine to the owner that took over"
    )

    {:error, :superseded}
  end

  defp orphaned(%Sandbox{} = sandbox, _epoch, %{reason: reason}) do
    # A database fault: the row cannot be told that a machine exists. The lease
    # is still this attempt's, so the machine is its own — but it is left where
    # it is, because the row that would name it is exactly the thing that will
    # not take a write.
    #
    # **Collected by `SandboxReaper.destroy_dead_sprites/2`**, not by the next
    # attempt's `interrupted?/1` (round 2, behaviour review — the first draft
    # named the wrong one). There is no next attempt: the caller answers this by
    # retiring the row through `fail_provision/2`, and `failed_attrs/1` clears
    # the stamp `interrupted?/1` would have read. What is left is a terminal row
    # whose machine is still up at the provider, which is the pass that sweeps
    # for exactly that.
    Logger.error(
      "machine #{sandbox.id}: the machine was created but the row would not say so " <>
        "(#{inspect(reason)}); leaving it for the reaper's untracked sweep"
    )

    {:error, reason}
  end

  defp create_and_run(%Sandbox{} = sandbox, epoch, interrupted?, fun) do
    provider = Conversations.sandbox_provider_atom(sandbox)
    :ok = discard_interrupted_attempt(provider, sandbox, interrupted?)

    case create_at_provider(provider, sandbox) do
      {:ok, handle} ->
        # The machine exists. Said on the row before the pipeline runs, so a
        # reader — and the next attempt — can tell a row that has a machine from
        # one that has only been asked for.
        case Lease.cas_update(sandbox.id, epoch, [status: "starting"], []) do
          {:ok, %Sandbox{}} ->
            case fun.(handle, epoch) do
              {:ok, result} ->
                %{step: :built, handle: handle, result: result}

              {:error, reason, result} ->
                %{
                  step: :pipeline_failed,
                  handle: handle,
                  reason: reason,
                  result: result
                }
            end

          {:error, reason} ->
            %{step: :orphaned, handle: handle, reason: reason}
        end

      {:error, reason} ->
        %{step: :create_failed, reason: reason}
    end
  end

  # The row's provider decides where the machine is created; adopt-on-
  # already-exists is the adapter's job. Retried, because a create that lost its
  # response is the case adoption by name exists for.
  #
  # Adoption checks no owner, and that is the decision rather than a gap: the
  # provider organization belongs to this instance alone (ADR 0005, 2026-10-15
  # addendum, #1919), tenants within it are kept apart by account-prefixed
  # names (#1920) and the live `(provider, machine_name)` unique index (#2141),
  # and a machine made by some other application is unsupported, not defended
  # against.
  #
  # Moved here from `Conversations.Provisioning` in stage 7b: it is a mutation
  # of a machine, made between the lease that makes it safe and the
  # compare-and-set that records it, which is the definition of an owner's work.
  defp create_at_provider(provider, %Sandbox{} = sandbox) do
    meta = %{sandbox_id: sandbox.id, step: "create", provider: provider}

    Fountain.Telemetry.span([:provision_step], meta, fn ->
      result =
        Managoat.Sandbox.Retry.with_backoff(
          fn -> Managoat.Sandbox.create(provider, sandbox.machine_name) end,
          label: "sprite create #{sandbox.machine_name}"
        )

      {result, meta}
    end)
  end

  # A sandbox left behind by an interrupted attempt cannot be finished in
  # place: `Sandbox.create` adopts an existing sprite by name, so a restarted
  # server would re-run every step on a half-built machine — and the steps
  # are not idempotent (`git clone` refuses a checkout that already exists,
  # a setup script that starts services fails on the second start). Seen
  # live when a deploy landed during an environment's `setup` stage: the
  # restart re-provisioned onto the same sprite and died in `clone`. Tear the
  # remnant down first; a sprite that is already gone is not an error.
  #
  # Moved here with the create, and it is the same argument twice: this destroy
  # is the compensation half of an owner's operation, and the only reason it was
  # ever a step of `Provisioning` is that provisioning had no owner.
  defp discard_interrupted_attempt(_provider, _sandbox, false), do: :ok

  defp discard_interrupted_attempt(provider, %Sandbox{} = sandbox, true) do
    Logger.warning(
      "machine #{sandbox.id}: #{sandbox.machine_name} was left mid-provision by an " <>
        "interrupted attempt; destroying it before provisioning again"
    )

    handle = Managoat.Sandbox.build_handle(provider, sandbox.machine_name)

    case Managoat.Sandbox.destroy(handle) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.info(
          "machine #{sandbox.id}: discarding #{sandbox.machine_name} returned " <>
            "#{inspect(reason)}; provisioning anyway"
        )

        :ok
    end
  end

  # ── the finalizes ─────────────────────────────────────────────────────────

  # `ready`, the build record and the intent cleared, in one compare-and-set —
  # `main`'s `claim_sandbox(sandbox, %{status: "ready", applied_skills: …})`,
  # with the epoch in front of it.
  defp finalize(%Sandbox{} = sandbox, epoch, %{handle: handle, result: result}, opts) do
    attrs =
      opts
      |> Keyword.get(:ready_attrs, [])
      |> Keyword.merge(status: "ready", transition: nil, transition_reason: nil)

    case Lease.cas_update(sandbox.id, epoch, attrs, refuse_fenced: true) do
      {:ok, %Sandbox{} = ready} ->
        :ok = Fountain.Workspaces.settle_provision(ready)
        audit(ready, "sandbox.provisioned", %{}, opts)
        {:ok, :provisioned, result}

      # Superseded. The machine belongs to whoever took the row over — it is
      # built under the row's own name — so nothing is written and nothing is
      # destroyed; their `interrupted?/1` collects it. See `build/5`.
      {:error, :stale} ->
        Logger.warning("machine #{sandbox.id}: provision superseded before its finalize")
        {:error, :superseded, result}

      # Retired, or fenced, while the pipeline ran — and **this attempt is still
      # the holder**, which is what makes these different from `:stale` above.
      # The machine it just built belongs to it and nobody else will come for
      # it, so it is destroyed here, exactly as `main`'s `:retired` and
      # `:sandbox_reset_pending` arms destroyed it. The row is not written: the
      # retirement or the fence is another actor's statement about this machine,
      # and `ready` over either would be this attempt overruling it.
      {:error, settled} when settled in [:retired, :fenced] ->
        Logger.info(
          "machine #{sandbox.id}: the row was #{settled} while it was being built; " <>
            "destroying the machine and leaving the row to its owner"
        )

        destroy_attempt(sandbox, handle, settled)
        settled_finalize(settled, result)

      {:error, _reason} = error ->
        error
    end
  end

  defp settled_finalize(:retired, result), do: {:ok, :already_terminal, result}
  defp settled_finalize(:fenced, result), do: {:error, :fenced, result}

  # The three failure arms `main` had, kept apart because each says something
  # different about who owns the row.
  #
  # **Another actor owns it** (`@foreign_owner`): this attempt's machine is
  # destroyed — it is this attempt's, built under this epoch, and nobody else
  # will come for it — and *nothing is written*. `main` was explicit about it in
  # two comments ("Retire only its own resources"; "a replacement may own it"),
  # and writing `failed` here would fail a conversation that a reassignment or
  # a replacement has already taken over.
  #
  # **Anything else**: the machine is destroyed and the row is failed, which is
  # `main`'s third arm and the ordinary case — a step of the pipeline said no.
  defp fail_pipeline(%Sandbox{} = sandbox, epoch, attempt, opts) do
    %{handle: handle, reason: reason, result: result} = attempt
    destroy_attempt(sandbox, handle, reason)

    if reason in @foreign_owner do
      {:error, reason, result}
    else
      Logger.error("machine #{sandbox.id}: provision step failed: #{inspect(reason)}")
      _ = write_failed(sandbox, epoch, reason, opts)
      {:error, reason, result}
    end
  end

  # This attempt's machine, built under this epoch. Best effort and never fatal:
  # `main` discarded the result at all three sites, and a provider that will not
  # take it back leaves a machine `SandboxReaper`'s untracked sweep collects.
  defp destroy_attempt(%Sandbox{} = sandbox, handle, reason) do
    _ = Managoat.Sandbox.destroy(handle)
    :ok
  rescue
    error ->
      Logger.warning(
        "machine #{sandbox.id}: could not destroy the machine this failed provision " <>
          "(#{inspect(reason)}) built: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  defp write_failed(%Sandbox{} = sandbox, epoch, reason, opts) do
    attrs = failed_attrs(reason)

    case Lease.cas_update(sandbox.id, epoch, attrs, []) do
      {:ok, %Sandbox{} = failed} ->
        :ok = Fountain.Workspaces.settle_provision(failed)
        audit(failed, "sandbox.provision_failed", %{"reason" => reason_text(reason)}, opts)
        {:ok, :failed}

      {:error, refusal} ->
        # Superseded or already terminal. Both mean this row is no longer this
        # attempt's to write, and neither is worth failing a caller that has
        # already failed.
        Logger.info(
          "machine #{sandbox.id}: could not record the failed provision (#{inspect(refusal)})"
        )

        {:error, refusal}
    end
  end

  defp failed_attrs(reason),
    do: [status: "failed", transition: nil, transition_reason: reason_text(reason)]

  # A pipeline's reason is whatever the step that refused said, and the steps
  # here answer tuples as readily as atoms — `{:broker, :session, :timeout}`,
  # `{:network_policy, :forbidden}`. `transition_reason` is a string column and
  # the audit metadata is JSON, so neither can take one raw, and `to_string/1`
  # on a tuple raises `Protocol.UndefinedError` from inside a failure handler,
  # which is the worst place in this module to raise from: the row is left live
  # and the caller's own rescue writes the failure a second time.
  #
  # Truncated because a formatted `%Ecto.Changeset{}` or a provider body is
  # thousands of characters and this column is read by an operator, not parsed.
  defp reason_text(reason) when is_atom(reason), do: to_string(reason)
  defp reason_text(reason), do: reason |> inspect() |> String.slice(0, 200)

  # ── confirm ───────────────────────────────────────────────────────────────

  defp confirm_under_lease(%Sandbox{status: status}, _epoch, _opts)
       when status in @terminal_statuses,
       do: {:ok, :already_terminal}

  defp confirm_under_lease(%Sandbox{} = sandbox, epoch, opts) do
    cond do
      # `admissible/1`'s fence, for its reasons.
      sandbox.transition == "destroying" ->
        {:error, :fenced}

      sandbox.status not in @confirmable ->
        {:error, {:not_confirmable, sandbox.status}}

      true ->
        sandbox = clear_foreign_stamp(sandbox, epoch)
        confirm(sandbox, epoch, opts)
    end
  end

  # `main`'s two `attrs` maps, kept exactly, with the epoch in front of them and
  # the event the second one always deserved behind it.
  #
  # A `suspended` row here is a machine Fountain parked whose disk the caller has
  # just been told is running, so bringing the row back to `ready` **is** a wake:
  # it stamps `last_resumed_at`, and — new in this stage — it records
  # `sandbox.resumed`, the same event `Machines.Resume` records for the wake
  # path. `main` recorded nothing, so a machine that came back this way was
  # missing from its tenant's trail exactly as a wake was before 7a.
  defp confirm(%Sandbox{status: "suspended"} = sandbox, epoch, opts) do
    attrs = [
      status: "ready",
      last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)
    ]

    with {:ok, %Sandbox{} = up} <- settle_confirm(Lease.cas_update(sandbox.id, epoch, attrs, [])) do
      audit(up, "sandbox.resumed", %{}, opts)
      {:ok, :confirmed}
    end
  end

  defp confirm(%Sandbox{} = sandbox, epoch, _opts) do
    with {:ok, %Sandbox{}} <-
           settle_confirm(Lease.cas_update(sandbox.id, epoch, [status: "ready"], [])),
         do: {:ok, :confirmed}
  end

  defp settle_confirm({:ok, %Sandbox{}} = ok), do: ok
  defp settle_confirm({:error, :stale}), do: {:error, :superseded}
  defp settle_confirm({:error, :retired}), do: {:ok, :already_terminal}
  defp settle_confirm({:error, _} = error), do: error

  # ── fail ──────────────────────────────────────────────────────────────────

  defp fail_under_lease(%Sandbox{status: status}, _epoch, _opts)
       when status in @terminal_statuses,
       do: {:ok, :already_terminal}

  defp fail_under_lease(%Sandbox{} = sandbox, epoch, opts) do
    if sandbox.status in @provisionable do
      retire(sandbox, epoch, Keyword.get(opts, :before_write), opts)
    else
      {:ok, :not_provisioning}
    end
  end

  defp retire(%Sandbox{} = sandbox, epoch, nil, opts),
    do: write_failed(sandbox, epoch, Keyword.fetch!(opts, :reason), opts)

  # **`:before_write` and the row's write are one transaction** (round 1,
  # surfaces review). The first draft ran the hook, committed it, and then wrote
  # the row — two commits with a window between them, where `main` held both in
  # one. The window is narrow and it is not harmless: `Launch.fail_initial_start/2`
  # is the hook's only caller, it fails the *conversation* there, and a crash
  # after that commit left a `failed` conversation pointing at a `pending`
  # machine — a reserved fleet slot with no server, which nothing but the
  # reaper's hourly pass collects.
  #
  # `Lease.cas_update/4`'s `nest: true` is what makes this possible, and it is
  # the second caller to use it (`Resume`'s admission is the first). The
  # compare-and-set takes no advisory lock, so nesting it holds none open; what
  # nesting buys is exactly what it buys there — a write that a rollback undoes.
  #
  # The two effects and the audit event stay *outside*: they are
  # `update_sandbox/2`'s post-commit half and must not run against a write that
  # may still roll back.
  defp retire(%Sandbox{} = sandbox, epoch, before_write, opts) do
    reason = Keyword.fetch!(opts, :reason)

    outcome =
      Repo.transaction(fn ->
        with :ok <- before_write.(sandbox),
             {:ok, %Sandbox{} = failed} <-
               Lease.cas_update(sandbox.id, epoch, failed_attrs(reason), nest: true) do
          failed
        else
          # A hook that stood the retire down. Rolled back rather than returned,
          # so anything it wrote before deciding goes with it.
          :stale -> Repo.rollback(:stale)
          {:error, refusal} -> Repo.rollback({:refused, refusal})
          other -> Repo.rollback({:refused, other})
        end
      end)

    case outcome do
      {:ok, %Sandbox{} = failed} ->
        :ok = Fountain.Workspaces.settle_provision(failed)
        audit(failed, "sandbox.provision_failed", %{"reason" => reason_text(reason)}, opts)
        {:ok, :failed}

      {:error, :stale} ->
        {:ok, :not_provisioning}

      {:error, {:refused, refusal}} ->
        Logger.info(
          "machine #{sandbox.id}: could not record the failed provision (#{inspect(refusal)})"
        )

        {:error, refusal}
    end
  end

  # ── after the finalize ────────────────────────────────────────────────────

  # Each provision finalize (`finalize/4`'s `ready`, `write_failed/4` and
  # `retire/4`) is followed, outside the transaction and before the audit
  # event, by `Fountain.Workspaces.settle_provision/1`: the sandbox's implicit
  # workspace takes the provision's outcome (ADR 0097, step 2). `confirm/3`'s
  # `ready` does not settle: it reaches only rows whose provision already did.
  # Best effort and read by nothing yet. A workspace whose sandbox is retired
  # mid-provision by some other path (a wake that lost the start race, a
  # conversation terminated while its machine was still `pending`) stays
  # `provisioning`; nothing reads it before step 4.

  # One completed-operation event per owner verb is the pattern stages 5, 6 and
  # 7a set (`sandbox.destroyed`, `sandbox.suspended`, `sandbox.resumed`); these
  # are the fourth and the fifth. `main` recorded neither, so a tenant's trail
  # began at the first turn and a machine that never came up left no trace at
  # all. Recorded after the finalize commits and outside every transaction,
  # carrying the actor the caller supplied (ADR 0013).
  #
  # The **stage** events — `provision/started`, `provision/done`,
  # `provision/failed` — stay exactly where they are, published by the server.
  # They are a live view of one conversation starting; this is a tenant's
  # durable record of a machine. A row with no `user_id` records nothing, the
  # #2329 trap.
  defp audit(%Sandbox{user_id: nil}, _action, _metadata, _opts), do: :ok

  defp audit(%Sandbox{} = sandbox, action, metadata, opts) do
    Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: Lifecycle.teardown_actor(Keyword.fetch!(opts, :actor)),
      request_ip: Keyword.get(opts, :request_ip),
      metadata:
        metadata
        |> Map.merge(%{
          "provider" => sandbox.provider,
          "machine_name" => sandbox.machine_name,
          # The old key, kept beside machine_name until #2776.
          "sprite_name" => sandbox.machine_name
        })
        |> put_conversation(Keyword.get(opts, :conversation_id))
    })

    :ok
  end

  defp put_conversation(metadata, nil), do: metadata
  defp put_conversation(metadata, conv_id), do: Map.put(metadata, "conversation_id", conv_id)
end
