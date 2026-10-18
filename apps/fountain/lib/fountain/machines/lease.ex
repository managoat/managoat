defmodule Fountain.Machines.Lease do
  @moduledoc """
  The durable half of a machine's ownership (ADR 0058, reduced by ADR 0072).

  A lease on the `sandboxes` row says which process is operating on the
  machine. `lease_epoch` is a monotonic integer that is never reused; a
  claimant takes the next one under the per-sandbox advisory lock, and every
  write the holder then makes is a compare-and-set on that epoch. A write from
  a superseded epoch matches zero rows and tells its caller `:stale`, which is
  how an operation that lost the machine makes no visible change.

  **The holder is a process of this boot.** `lease_node` names it as
  `"<boot id>/<pid>"`: `boot_id/0` is drawn once when the application starts,
  and the pid is the process that claimed. A lease is live exactly when its
  boot id is this boot's and its process is alive (`live?/1`). Fountain runs
  as one node and a deploy stops the old one before starting the new
  (ADR 0072), so a lease from any other boot is one whose holder is gone, and
  `sweep_boot/0` clears them all before anything else runs. A holder that
  dies mid-operation stops holding at the moment it dies: there is no TTL to
  wait out, no renewal to keep it alive and no clock to read.

  That is why the `lease_until` column is gone. Until ADR 0072 the lease was
  a deadline on the database's clock, renewed by `Machines.Renewal` while an
  operation ran and taken over early from a holder on a disconnected node.
  All of that existed because two BEAMs could hold leases at once.

  What did not depend on the cluster stays. A provision runs in a
  `ConversationServer` while a park or a destroy runs in the machine's owner,
  and each makes a provider round trip between deciding and writing (#2307),
  so the advisory lock, the `FOR UPDATE` re-read, the durable `transition`
  and the epoch compare-and-set are still what keeps them apart.

  An epoch on its own is not a lease. `lease_epoch` defaults to `0` on every
  row, `release/2` keeps the epoch it surrendered, and neither of those is a
  lease anybody holds — so `release/2` and `cas_update/3` match on the holder
  column as well as the epoch, and refuse an epoch below `1` before they query
  at all.

  Every function here is one short statement or transaction, and refuses to run
  inside an enclosing one (`{:error, :transaction_open}`) unless the caller says
  the nesting is deliberate — one caller does, and `cas_update/4`'s `nest:`
  option is where that is argued. Nesting would join the caller's transaction
  through a savepoint and hold a transaction-scoped advisory lock until the
  outer commit. Provider I/O happens in the owner, between these calls, never
  inside one.

  Nothing user-facing happens here, so nothing here is audited: a lease is
  control-plane bookkeeping, and the events an operation owes — `sandbox.destroyed`
  and its siblings — are recorded by the owner's verbs.

  The write half has four callers, and they are the four protocols: `Destroy`,
  `Park`, `Resume` and `Provision`. Each claims a lease around one operation,
  stamps the transition, does its provider I/O outside every lock, finalizes
  with `cas_update/3` and releases.

  The read half is `live?/1`, through `Machines.Machine.busy?/1` for readers
  outside this namespace.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  require Logger

  @typedoc "A lease generation. Monotonic per sandbox; never reused."
  @type epoch :: non_neg_integer()

  @typedoc "Why a claim was refused: a live process of this boot holds the lease."
  @type held :: {:held, String.t()}

  @boot_key {__MODULE__, :boot_id}

  @destroying "destroying"

  # The only columns a machine's owner may write through `cas_update/3`.
  # `lease_*` are absent on purpose — a lease changes hands through the
  # functions below, under the lock, and never as a side effect of a state
  # write.
  #
  # `provider_meta` joined them in stage 6b. It is not machine *state* the way
  # the others are, but it is written in the middle of a transition and by the
  # owner that holds it (a provision records the machine's URL), and that write
  # has to be invisible if the operation has been superseded, for the same
  # reason the finalize does.
  #
  # `applied_skills` joined them in stage 7b and left with config homes (ADR
  # 0097 step 1): the record of a conversation's skills is the conversation's
  # (`Fountain.Conversations.Skills`), because the skills are in its own
  # config home rather than in a directory of the machine's.
  @writable ~w(status transition transition_reason terminated_at last_resumed_at provider_meta)a

  # Where a sandbox stops. Kept in step with `@terminal_statuses` in
  # `Fountain.Conversations`, whose `prevent_sandbox_revival/1` this mirrors.
  @terminal_statuses ~w(terminated failed)

  @doc """
  Draw this boot's id. `Fountain.Application.start/2` calls it once, before
  the supervision tree starts; a second call keeps the first id, so a lease
  claimed under it never reads dead.
  """
  @spec init_boot() :: String.t()
  def init_boot do
    case :persistent_term.get(@boot_key, nil) do
      nil ->
        id = 8 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)
        :persistent_term.put(@boot_key, id)
        id

      id ->
        id
    end
  end

  @doc "This boot's id. See `init_boot/0`."
  @spec boot_id() :: String.t()
  def boot_id, do: :persistent_term.get(@boot_key)

  @doc """
  How `lease_node` names `pid` as a holder of this boot. Public so tests can
  stand a process in as a holder.
  """
  @spec holder(pid()) :: String.t()
  def holder(pid) when is_pid(pid) and node(pid) == node(),
    do: boot_id() <> "/" <> List.to_string(:erlang.pid_to_list(pid))

  @doc """
  Is somebody holding this machine right now?

  **The one definition, for readers inside this namespace and out.** Takes a
  `Sandbox`, or any map carrying `:lease_node`, so a query may `select` the
  one column rather than the row. Live means the holder was named in this boot
  and its process is alive (ADR 0072). A holder from another boot, a malformed
  one and `nil` are all not live.
  """
  @spec live?(Sandbox.t() | map()) :: boolean()
  def live?(%{lease_node: holder}) when is_binary(holder) do
    case holder_pid(holder) do
      {:ok, pid} -> Process.alive?(pid)
      :error -> false
    end
  end

  def live?(%{lease_node: nil}), do: false

  defp holder_pid(holder) do
    prefix = boot_id() <> "/"

    with true <- String.starts_with?(holder, prefix),
         pid_text = binary_part(holder, byte_size(prefix), byte_size(holder) - byte_size(prefix)),
         {:ok, pid} <- parse_pid(pid_text) do
      {:ok, pid}
    else
      _ -> :error
    end
  end

  defp parse_pid(text) do
    {:ok, :erlang.list_to_pid(String.to_charlist(text))}
  rescue
    ArgumentError -> :error
  end

  @doc """
  The holder prefix every lease of this boot starts with, for a reader that
  has to ask the question in SQL (`Quotas`). SQL cannot ask whether a process
  is alive, so a reader that uses this counts a lease whose holder died in
  this boot as held until the next claim or the next boot clears it.
  """
  @spec boot_prefix() :: String.t()
  def boot_prefix, do: boot_id() <> "/"

  @doc """
  Clear every lease and every abandoned operation stamp left by an earlier
  boot (ADR 0072).

  Runs once at boot, before Oban, the endpoint and the rehydrator start, so
  nothing in this boot has claimed anything yet; the `WHERE` leaves this
  boot's leases alone all the same. A deploy stops the old node before the new
  one starts, so every lease of another boot belongs to a process that is
  gone. `destroying` stays for `SandboxReaper`'s driver (ADR 0058 stage 9a).
  `resuming` stays for the next wake to take over: an interrupted exec probe
  has not proved readiness, even when the row was already `ready` before the
  provider put it to sleep. Registration refuses that stamp too (#2560).

  Returns the number of rows it cleared.
  """
  @spec sweep_boot() :: non_neg_integer()
  def sweep_boot do
    prefix = boot_prefix() <> "%"

    {count, _} =
      Repo.update_all(
        from(s in Sandbox,
          where:
            (not is_nil(s.lease_node) and not like(s.lease_node, ^prefix)) or
              (not is_nil(s.transition) and s.transition not in ["destroying", "resuming"] and
                 (is_nil(s.lease_node) or not like(s.lease_node, ^prefix))),
          update: [
            set: [
              lease_node: nil,
              transition:
                fragment(
                  "CASE WHEN ? IN ('destroying', 'resuming') THEN ? ELSE NULL END",
                  s.transition,
                  s.transition
                ),
              transition_reason:
                fragment(
                  "CASE WHEN ? IN ('destroying', 'resuming') THEN ? ELSE NULL END",
                  s.transition,
                  s.transition_reason
                )
            ]
          ]
        ),
        []
      )

    if count > 0, do: Logger.info("machine leases: cleared #{count} left by an earlier boot")
    count
  end

  @doc """
  Take the lease on `sandbox_id` for the calling process.

  Serializes on the per-sandbox advisory lock, re-reads the row `FOR UPDATE`,
  and refuses with `{:error, {:held, holder}}` when a live process holds it.
  The verdict is made on the locked read, never on a struct the caller
  brought: a pre-lock reading is stale by construction.

  On success the epoch advances by exactly one and is returned. The holder
  quotes it on every subsequent write.

  `holder: pid` names a different holder than the caller; only tests do.
  `supersede: pid` takes the lease from that one holder even while it is
  alive. `ProvisionWatchdog` is the caller: it retires a provision whose
  server is wedged inside the provider, and stops that server straight after.
  The server's own later writes then fail their compare-and-set.
  """
  @spec claim(Ecto.UUID.t(), keyword()) ::
          {:ok, epoch()}
          | {:error,
             :not_found | :lost | :transaction_open | {:invalid, :sandbox_id} | held() | term()}
  def claim(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    holder = opts |> Keyword.get(:holder, self()) |> holder()
    guarded(sandbox_id, fn -> do_claim(sandbox_id, holder, opts) end)
  end

  @doc """
  Give the lease up.

  Clears `lease_node` and keeps `lease_epoch` where it is:
  epochs are monotonic and never reused, so the next claimant still gets a
  strictly higher one and this holder's outstanding writes still fail. Guarded
  on the holder column too, so releasing twice is `{:error, :lost}` rather
  than a second success — after the first, this caller is no longer the holder.
  """
  @spec release(Ecto.UUID.t(), epoch()) ::
          :ok | {:error, :lost | :transaction_open | {:invalid, :sandbox_id} | term()}
  def release(sandbox_id, epoch) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch) do
        case Repo.update_all(held_by(sandbox_id, epoch), set: [lease_node: nil]) do
          {1, _} -> :ok
          {0, _} -> {:error, :lost}
        end
      else
        {:error, :lost}
      end
    end)
  end

  @doc """
  Write machine state, if and only if `epoch` is still the lease.

  The one write primitive the owner uses. One `update_all` matching on the
  epoch *and the holder columns*, returning the row it wrote; zero rows is
  `:stale`, which is the whole protocol in one word — a superseded owner
  changes nothing and learns so. A lease that was released, or an epoch no
  claim ever handed out, is `:stale` for the same reason: neither is held.

  `attrs` is a plain map or a keyword list — **a struct is refused**
  (`{:error, {:invalid, :attrs}}`) even though it is a map, because nothing an
  owner writes is built by handing this function a schema. It may name only
  #{inspect(@writable)}, with atom keys, each at most
  once. `status` must be a member of `Sandbox.statuses/0` and `transition` of
  `Sandbox.transitions/0` (`nil` clears it, which is how a transition
  finalizes); anything else is `{:error, {:invalid, field}}` and the row is
  untouched. That is **membership, not legality** — whether a particular
  transition is allowed from a particular state belongs to `Machines.Policy`
  in a later stage, and nothing here decides it. The one exception is
  retirement: a terminal row is never written back to a live status, the same
  refusal `Conversations.update_sandbox/2` made before stage 9b deleted it,
  reported as `{:error, :retired}` so the owner
  does not mistake it for a takeover.

  **`:stale` beats `:retired`.** A superseded epoch is `:stale` even on a
  retired row; `:retired` means you *are* the holder and the row is terminal. A
  caller that no longer owns the machine has no business being told the row's
  status, and the diagnosis reads through the same held-lease predicate the
  write did, so it falls to `:stale` before the status is ever consulted.

  **`destroying` survives a write that would clear it** (stage 9a). On a row
  that is not yet terminal, a write naming `transition` as anything but
  `"destroying"` leaves the stamp and its reason exactly where they are, and
  returns the row saying so — the caller's other columns land, the intent does
  not move. That is what makes `destroying` the one *durable* transition: every
  other stamp is an abandoned operation a later owner clears, and this one is a
  request that outlives the owner that was serving it. Three writes pass
  through: a re-stamp of `destroying` itself, a write that retires the row
  (which is the destroy finishing), and any write to a row that is *already*
  terminal, where the stamp is leftovers rather than intent. See
  `preserve_destroying/2`.

  A write that moves the status to `terminated` or `failed` stamps
  `terminated_at` when the row has none, as `Conversations.stamp_terminated_at/1`
  did until stage 9b deleted it — see `stamp_terminated_at/2` below for why
  that matters and where it is deliberately narrower.

  Deliberately takes no advisory lock: a single guarded `update_all` is already
  atomic, and the serialization this needs was done when the epoch was taken.

  **`nest: true` permits an enclosing transaction**, which every other function
  here refuses, and there are two callers. `Machines.Resume`'s admission runs
  this inside `Quotas.with_sandbox_reservation/2`'s transaction so that the
  `resuming` stamp and the quota count that authorised it commit together.
  `Machines.Provision.fail/2` runs it beside its caller's own write, so that
  `Launch.fail_initial_start/2` fails a conversation and its machine in one
  commit or neither — which `main` did under the per-sandbox advisory lock, and
  which the machine's row leaving that lock's reach would otherwise have cost. The
  moduledoc's reason for the guard does not reach this function — it is about
  holding `pg_advisory_xact_lock(4316, …)` until an outer commit, and this takes
  no advisory lock — and the *other* thing nesting does, joining the caller's
  transaction so a rollback undoes the write, is exactly what a reservation
  wants: a refused quota must leave no stamp behind. It is opt-in rather than
  the default because everywhere else an enclosing transaction is the mistake
  the guard exists to catch, and the option makes a reviewer look at the one
  place it is not.

  Two consequences a caller passing it owns. The diagnosis of a zero-row write
  runs a second read *inside* that transaction, so it sees the transaction's own
  uncommitted rows — which is right here, since the only writer of this row in
  this transaction is this call. And an error out of the nested `Repo.update_all`
  aborts the enclosing transaction, so the caller must treat any `{:error, _}`
  from here as fatal to the whole reservation rather than something to continue
  from; `Resume` does, by returning it and letting `with_sandbox_reservation/2`
  roll back.

  It does not ask whether the holder is alive: the caller *is* the holder.
  What the CAS buys is that the moment another claim has happened — after this
  holder died, or `ProvisionWatchdog` superseded it — the old holder's write is
  invisible.
  """
  @spec cas_update(Ecto.UUID.t(), epoch(), map() | keyword(), keyword()) ::
          {:ok, Sandbox.t()}
          | {:error,
             :stale | :retired | :fenced | :transaction_open | {:invalid, atom()} | term()}
  def cas_update(sandbox_id, epoch, attrs, opts \\ [])
      when is_binary(sandbox_id) and is_integer(epoch) and is_list(opts) do
    guarded(sandbox_id, Keyword.get(opts, :nest, false), fn ->
      if taken_epoch?(epoch) do
        with {:ok, sets} <- cast_attrs(attrs) do
          # `updated_at` moves with a state change and not with a claim or a
          # release, so it keeps meaning "the machine changed".
          sets = Keyword.put(sets, :updated_at, DateTime.utc_now() |> DateTime.truncate(:second))

          {query, sets} =
            sandbox_id
            |> held_by(epoch)
            |> refuse_revival(sets)
            |> refuse_fenced(Keyword.get(opts, :refuse_fenced, false))
            |> stamp_terminated_at(sets)
            |> select([s], s)
            |> preserve_destroying(sets)

          case Repo.update_all(query, set: sets) do
            {1, [sandbox]} -> {:ok, sandbox}
            {0, _} -> {:error, zero_row_reason(sandbox_id, epoch, opts)}
          end
        end
      else
        {:error, :stale}
      end
    end)
  end

  defp do_claim(sandbox_id, holder, opts) do
    superseded = superseded_holder(Keyword.get(opts, :supersede))

    Conversations.with_sandbox_lock(sandbox_id, fn ->
      current =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^sandbox_id,
            select: %{epoch: s.lease_epoch, lease_node: s.lease_node},
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:error, :not_found}

        live?(current) and current.lease_node != superseded ->
          {:error, {:held, current.lease_node}}

        true ->
          epoch = current.epoch + 1

          claimed =
            from(s in Sandbox, where: s.id == ^sandbox_id and s.lease_epoch == ^current.epoch)

          case Repo.update_all(claimed, set: [lease_epoch: epoch, lease_node: holder]) do
            {1, _} ->
              log_claim(sandbox_id, holder, epoch, current)
              {:ok, epoch}

            {0, _} ->
              {:error, :lost}
          end
      end
    end)
  end

  defp superseded_holder(nil), do: nil
  defp superseded_holder(pid) when is_pid(pid), do: holder(pid)

  defp log_claim(sandbox_id, holder, epoch, %{lease_node: previous} = current) do
    if live?(current) do
      Logger.warning(
        "machine lease on sandbox #{sandbox_id} taken by #{holder} at epoch #{epoch} " <>
          "from #{previous}, which is still alive and is being stopped"
      )
    end

    :ok
  end

  # The epoch *and the holder column*: an epoch-only match makes the lease
  # nobody took quotable by anybody, and `release/2` keeps the epoch on
  # purpose. Requiring a holder closes both, and `taken_epoch?/1` refuses 0
  # before the query.
  defp held_by(sandbox_id, epoch) do
    from s in Sandbox,
      where: s.id == ^sandbox_id and s.lease_epoch == ^epoch and not is_nil(s.lease_node)
  end

  # `do_claim/3` hands out 1 first, so anything below it is not an epoch a
  # claim ever produced — it is the column default wearing an epoch's clothes.
  defp taken_epoch?(epoch), do: epoch >= 1

  # Holding the lease is not permission to un-retire a row. Terminal-to-terminal
  # still goes through, and a write that never names a status is not a revival.
  # The same rule as `Fountain.Conversations.prevent_sandbox_revival/1`, which
  # stage 9b deleted with `update_sandbox/2`; this is the only copy now.
  defp refuse_revival(query, sets) do
    case Keyword.get(sets, :status) do
      nil -> query
      status when status in @terminal_statuses -> query
      _live -> from(s in query, where: s.status not in @terminal_statuses)
    end
  end

  # Fills `terminated_at` on the way into a terminal status, as
  # `Fountain.Conversations.stamp_terminated_at/1` did for `update_sandbox/2`
  # until stage 9b deleted both; this is the only copy now. Of the writers of
  # a terminal status the ones that *fail* a machine never pass a timestamp —
  # which once left every failed sandbox reading as still running. `cas_update/3` is another such writer.
  # `COALESCE` in the database rather than a read here keeps the write one
  # statement and keeps a caller's own timestamp, so this only fills a gap.
  #
  # Narrower than the original on purpose. `stamp_terminated_at/1` worked off
  # `get_field/2`, which falls back to the *stored* status, so it also repaired
  # a status-free write to an already-terminal row. This fires only on the
  # transition into a terminal status, which is the case with the hazard; a
  # write that never names a status leaves the column alone.
  defp stamp_terminated_at(query, sets) do
    if Keyword.get(sets, :status) in @terminal_statuses and
         not Keyword.has_key?(sets, :terminated_at) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      from(s in query, update: [set: [terminated_at: coalesce(s.terminated_at, ^now)]])
    else
      query
    end
  end

  # `destroying` is the one transition a write may not take off a live row
  # (ADR 0058 stage 9a). Every other stamp is abandonable: a reader that finds
  # `parking` or `resuming` with no live lease is looking at an owner that
  # died, and three sites clear it on sight so the machine can be used again.
  # `destroying` is the opposite statement — somebody asked for this machine to
  # go away, and an owner dying halfway through does not withdraw the request.
  # Since stage 9b stopped reading `reset_requested_at` and
  # `teardown_requested_at`, this column is the only record of that intent.
  #
  # Enforced here rather than only at the callers because the write that would
  # lose it is not a clearing write at all. `Machines.Park`'s finalize writes
  # `status: "suspended", transition: nil` on a row it stamped `parking`, and a
  # teardown fence committing *during* the suspend — the fence takes the
  # advisory lock, the park holds only its lease — lands on that row between the
  # stamp and the finalize. Under 9a the fence columns also caught it; since 9b
  # nothing but this does. So the park still finalizes (the
  # machine really is suspended and the row must say so) and the stamp rides
  # through, for the driver to finish.
  #
  # **Three writes deliberately pass.** A write that names `transition:
  # "destroying"` is a re-stamp, which is how a second destroy records its own
  # reason. A write that moves the row to a terminal status is the destroy
  # finishing, and clearing the stamp there is the finalize. And a stamp on a
  # row that is *already* terminal is not intent but leftovers —
  # `Destroy.clear_stale_transition/2`'s tidying of a row some older writer
  # retired without an epoch — so the guard reads the row's status, not only
  # the write's.
  #
  # The columns leave `sets` when it fires, because Ecto raises on a field set
  # twice; `stamp_terminated_at/2` avoids the same collision by checking the
  # caller did not name the column at all.
  defp preserve_destroying(query, sets) do
    if preserving?(sets) do
      query =
        from(s in query,
          update: [
            set: [
              transition:
                fragment(
                  "CASE WHEN ? = ? AND ? NOT IN ('terminated', 'failed') THEN ? ELSE ? END",
                  s.transition,
                  ^@destroying,
                  s.status,
                  s.transition,
                  type(^Keyword.get(sets, :transition), :string)
                )
            ]
          ]
        )

      {preserve_reason(query, sets), Keyword.drop(sets, [:transition, :transition_reason])}
    else
      {query, sets}
    end
  end

  # **Only when the caller named it.** A write that names `transition` alone —
  # `Resume.stamp/2` is the one today — used to leave `transition_reason`
  # untouched, because `update_all` writes the columns it is given and no
  # others. The first draft of `preserve_destroying/2` moved *both* columns into
  # `CASE` fragments unconditionally, so the reason's `ELSE` branch was a `nil`
  # nobody had asked for: a stamp that named one column silently erased the
  # other (protocol review, promoted to a blocker). The guard is the caller's
  # own key, so this preserves a stamp without inventing a write.
  defp preserve_reason(query, sets) do
    if Keyword.has_key?(sets, :transition_reason) do
      from(s in query,
        update: [
          set: [
            transition_reason:
              fragment(
                "CASE WHEN ? = ? AND ? NOT IN ('terminated', 'failed') THEN ? ELSE ? END",
                s.transition,
                ^@destroying,
                s.status,
                s.transition_reason,
                type(^Keyword.get(sets, :transition_reason), :string)
              )
          ]
        ]
      )
    else
      query
    end
  end

  # A write is at risk of losing the stamp when it names `transition` as
  # something other than `destroying` and does not retire the row. A write that
  # names neither column touches neither, and a write that names only
  # `transition_reason` cannot orphan a stamp it is not moving.
  defp preserving?(sets) do
    Keyword.has_key?(sets, :transition) and
      Keyword.get(sets, :transition) != @destroying and
      Keyword.get(sets, :status) not in @terminal_statuses
  end

  # **`refuse_fenced: true`** additionally requires **no `destroying` stamp** —
  # the fence, since stage 9b stopped reading the two columns 9a stamped beside
  # it — and it is opt-in for the same reason `nest:` is: everywhere else the
  # fence is not this write's business.
  #
  # `Destroy` writes a terminal status onto a row it has just fenced, and
  # `Park`'s finalize is allowed to land on a fence that arrived mid-operation
  # (stage 6b decided that). What cannot be allowed is the third case, and it
  # arrived with stage 7b: a *provision* finishing onto a row somebody asked to
  # be reset while the machine was being built. `Conversations.update_sandbox/2`
  # refused exactly that — it rolled back with `:sandbox_reset_pending` unless the
  # write was terminal — and it was the only thing refusing it, so a bracket that
  # wrote `ready` through `cas_update/4` without this would have handed a
  # conversation a machine the reset reconciler was about to delete.
  #
  # **Either fence, where `update_sandbox/2` once read only the reset one**
  # (7b round 1, behaviour review). A `ready` finalize landing on a
  # *teardown*-fenced row hands a conversation a machine somebody has asked to
  # be destroyed, which `SandboxReaper.sweep_fenced_teardowns/0` then finishes
  # underneath it. Both fences stamp `destroying`, so one condition refuses
  # both, and `Provision.admissible/1` reads the same one, so the two ends of
  # the bracket agree about what a fence means.
  defp refuse_fenced(query, false), do: query

  defp refuse_fenced(query, true) do
    from s in query,
      where: is_nil(s.transition) or s.transition != ^@destroying
  end

  # Only on the refusal path, so the write itself stays one statement. Without
  # it a revival and a takeover are the same zero rows, and an owner told
  # `:stale` would go looking for a successor that never existed.
  #
  # The order is the order the write applies them, so the reason names the
  # first thing that refused: not the holder, then retired, then fenced.
  defp zero_row_reason(sandbox_id, epoch, opts) do
    case Repo.one(
           from s in held_by(sandbox_id, epoch),
             select: map(s, [:status, :transition])
         ) do
      nil ->
        :stale

      %{status: status} when status in @terminal_statuses ->
        :retired

      row ->
        if Keyword.get(opts, :refuse_fenced, false) and fenced?(row),
          do: :fenced,
          else: :stale
    end
  end

  # What `refuse_fenced/2` requires to be absent, read back in the same words
  # so the diagnosis and the write cannot disagree about what a fence is.
  defp fenced?(row), do: row.transition == @destroying

  # A struct is a map, so `is_map/1` and the `@spec` both let one through, and
  # `Enum.reduce_while/3` then raises `Protocol.UndefinedError` on it. Refused
  # like every other caller bug rather than raised, and said in the docstring.
  defp cast_attrs(attrs) when is_struct(attrs), do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) when not is_map(attrs) and not is_list(attrs),
    do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) when attrs == %{} or attrs == [], do: {:error, {:invalid, :attrs}}

  defp cast_attrs(attrs) do
    Enum.reduce_while(attrs, {:ok, []}, fn {field, value}, {:ok, sets} ->
      # A keyword list can name the same column twice, which reaches Ecto as
      # two `SET` clauses and raises `Ecto.QueryError` mid-transaction. It is a
      # caller's bug either way, so it is refused here like any other bad attr.
      with {:ok, casted} <- cast_attr(field, value),
           false <- List.keymember?(sets, field, 0) do
        {:cont, {:ok, [{field, casted} | sets]}}
      else
        _ -> {:halt, {:error, {:invalid, field}}}
      end
    end)
  end

  defp cast_attr(:status, value) do
    if value in Sandbox.statuses(), do: {:ok, value}, else: :error
  end

  defp cast_attr(:transition, nil), do: {:ok, nil}

  defp cast_attr(:transition, value) do
    if value in Sandbox.transitions(), do: {:ok, value}, else: :error
  end

  defp cast_attr(field, value) when field in @writable,
    do: Ecto.Type.cast(Sandbox.__schema__(:type, field), value)

  # Every key that is not a writable column, including a string one: an owner's
  # write is built in code, not forwarded from a caller's map.
  defp cast_attr(_field, _value), do: :error

  # The three things every entry point checks before it touches the database,
  # and the one it catches after.
  #
  # A database fault is an answer, not a crash: Ecto rolls the transaction back
  # on the way out — releasing the transaction-scoped advisory lock with it —
  # and the caller gets a reason rather than an exception to handle at every
  # call site (#2309's `57014` is the shape this is written for). The rescue
  # covers faults the database raises, server-side and connection alike, and
  # nothing else: a malformed `attrs` or a `sandbox_id` that is not a UUID
  # would reach Ecto as `Ecto.QueryError` or `Ecto.Query.CastError`, and those
  # are caller bugs, refused up front instead of dressed up as database faults.
  defp guarded(sandbox_id, fun), do: guarded(sandbox_id, false, fun)

  defp guarded(sandbox_id, nest?, fun) do
    cond do
      not nest? and Repo.in_transaction?() ->
        {:error, :transaction_open}

      # `is_binary/1` on the public functions admits any string; the `@spec`
      # says `Ecto.UUID.t()` and the query would raise on anything else. The
      # length test is not redundant: `Ecto.UUID.cast/1` also accepts the raw
      # 16-byte form, which is not what a `:binary_id` column is queried with
      # and which reaches Ecto as an `Ecto.Query.CastError` — the one thing
      # this check exists to prevent.
      byte_size(sandbox_id) != 36 or Ecto.UUID.cast(sandbox_id) == :error ->
        {:error, {:invalid, :sandbox_id}}

      true ->
        try do
          fun.()
        rescue
          error in [Postgrex.Error, DBConnection.ConnectionError] ->
            {:error, {:database, sqlstate(error)}}
        end
    end
  end

  defp sqlstate(%Postgrex.Error{postgres: %{code: code}}), do: code
  defp sqlstate(%DBConnection.ConnectionError{}), do: :connection_error
  defp sqlstate(_error), do: :unknown
end
