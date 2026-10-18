defmodule Fountain.Machines.Lease do
  @moduledoc """
  The durable half of a machine's ownership (ADR 0058, reduced by ADR 0072,
  keyed by workspace by ADR 0097).

  **The lease is on the workspace.** A sandbox is one machine; its workspace
  is what owns it (ADR 0097), so the lease that says which process is
  operating on the machine is on the `workspaces` row: `lease_epoch`,
  `lease_node`, `transition` and `transition_reason`. Every function here
  still takes the sandbox's id, because every caller is about one machine,
  and finds the workspace through `sandboxes.workspace_id`. Today every
  workspace is implicit and has one sandbox, so this is the lease 0058
  describes, on a different row.

  `lease_epoch` is a monotonic integer that is never reused; a claimant takes
  the next one under the machine's advisory lock (keyed by the workspace,
  `Fountain.Conversations.sandbox_lock_key/1`), and every write the holder
  then makes is a compare-and-set on that epoch. A write from a superseded
  epoch matches nothing and tells its caller `:stale`, which is how an
  operation that lost the machine makes no visible change.

  **The holder is a process of this boot.** `lease_node` names it as
  `"<boot id>/<pid>"`: `boot_id/0` is drawn once when the application starts,
  and the pid is the process that claimed. A lease is live exactly when its
  boot id is this boot's and its process is alive (`live?/1`). Fountain runs
  as one node and a deploy stops the old one before starting the new
  (ADR 0072), so a lease from any other boot is one whose holder is gone, and
  `sweep_boot/0` clears them all before anything else runs. A holder that
  dies mid-operation stops holding at the moment it dies: there is no TTL to
  wait out, no renewal to keep it alive and no clock to read.

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
  and hold a transaction-scoped advisory lock until the outer commit. Provider
  I/O happens in the owner, between these calls, never inside one.

  Nothing user-facing happens here, so nothing here is audited: a lease is
  control-plane bookkeeping, and the events an operation owes — `sandbox.destroyed`
  and its siblings — are recorded by the owner's verbs.

  The write half has four callers, and they are the four protocols: `Destroy`,
  `Park`, `Resume` and `Provision`. Each claims a lease around one operation,
  stamps the transition, does its provider I/O outside every lock, finalizes
  with `cas_update/3` and releases. `put_transition!/3` is the write the two
  lock-holding doors outside them make: the teardown fence and registration.

  The read half is `live?/1`, through `Machines.Machine.busy?/1` for readers
  outside this namespace, and the machine as a `Sandbox` struct whose four
  lease fields are its workspace's: `get/1`, `machines/0` for a reader that
  filters, and `lock_machine/2` for one that reads under the lock.

  ## Locks

  The order is always **the advisory lock, then the workspace's row, then the
  sandbox's row**. `cas_update/4` takes no advisory lock and locks the
  workspace's row before the sandbox's, and every locked reader
  (`lock_machine/2`) does the same, so a compare-and-set and a fence, a
  registration or a turn admission cannot deadlock on the two rows.

  ## Written twice (ADR 0097, step 3)

  Until the release after this one drops them, the sandbox keeps its own four
  columns, and every write here copies the workspace's onto the workspace's
  live sandbox in the same transaction (and onto the sandbox a write is
  addressed to). Nothing in this release reads them. They are there so that a
  rollback to the release before, which reads only the sandbox's, finds the
  machine as this one left it. `Fountain.Workspaces._unsafe_reconcile_live/0`
  carries the other way at boot, for the stamps such a release writes.

  ## A sandbox with no workspace

  Every live sandbox has one: every sandbox is born with one, and the boot
  sweep gives one to any that a release before ADR 0097 made. A sandbox
  retired before ADR 0097 has none, and nothing owns it: `claim/2` answers
  `{:error, :no_workspace}`, and its four fields are read from its own row,
  as before ADR 0097, so a stamp a fence writes there (`put_transition!/4`)
  is still seen by every reader. The protocols answer such a row as the
  terminal row it is (`unowned/1`) and refuse one that is somehow live as
  busy: only a failed boot reconcile leaves one, until the next boot.
  """

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workspaces.Workspace

  require Logger

  @typedoc "A lease generation. Monotonic per workspace; never reused."
  @type epoch :: non_neg_integer()

  @typedoc "Why a claim was refused: a live process of this boot holds the lease."
  @type held :: {:held, String.t()}

  @boot_key {__MODULE__, :boot_id}

  @destroying "destroying"

  # The boot sweep's first statement: a stamp a release before ADR 0097 step
  # 3b wrote on a live sandbox's own row only (it read and wrote no other),
  # carried onto the workspace before anything here reads the workspace's.
  # Under this release the two agree at every commit, so on a deployment that
  # never rolled back it writes nothing. The epoch never goes backwards, so no
  # epoch that release handed out is handed out again.
  @carry_sql """
  UPDATE workspaces w
     SET lease_epoch = GREATEST(w.lease_epoch, s.lease_epoch),
         transition = s.transition,
         transition_reason = s.transition_reason
    FROM sandboxes s
   WHERE s.workspace_id = w.id
     AND s.status NOT IN ('terminated', 'failed')
     AND (w.transition IS DISTINCT FROM s.transition
          OR w.transition_reason IS DISTINCT FROM s.transition_reason
          OR w.lease_epoch < s.lease_epoch)
  """

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
  @writable ~w(status transition transition_reason terminated_at last_resumed_at provider_meta)a

  # The two of them that live on the workspace (ADR 0097). The rest are the
  # machine's own and stay on the sandbox.
  @workspace_fields [:transition, :transition_reason]

  # Where a sandbox stops. Kept in step with `@terminal_statuses` in
  # `Fountain.Conversations`.
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
  `Sandbox` read through this module (`get/1`, `machines/0`,
  `lock_machine/2`), whose `lease_node` is its workspace's, or any map
  carrying `:lease_node`, so a query may `select` the one column. Live means
  the holder was named in this boot and its process is alive (ADR 0072). A
  holder from another boot, a malformed one and `nil` are all not live.
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

  # ── reading the machine ───────────────────────────────────────────────────

  @doc """
  Every sandbox, each with its workspace's lease in its four lease fields.

  The query every reader of a machine's lease or transition starts from. Its
  first binding is the sandbox and its second, named `:workspace`, the
  workspace (`NULL` columns for a sandbox with none), so a caller can add
  `where: [s, w] ...` or `where: as(:workspace).transition == ...`. The select
  replaces the sandbox's own copies of the four fields with the workspace's;
  a sandbox with no workspace keeps its own.
  """
  @spec machines() :: Ecto.Query.t()
  def machines do
    from s in Sandbox,
      left_join: w in Workspace,
      as: :workspace,
      on: w.id == s.workspace_id,
      select: %{
        s
        | lease_epoch:
            fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.lease_epoch, w.lease_epoch),
          lease_node:
            fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.lease_node, w.lease_node),
          transition:
            fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.transition, w.transition),
          transition_reason:
            fragment(
              "CASE WHEN ? IS NULL THEN ? ELSE ? END",
              w.id,
              s.transition_reason,
              w.transition_reason
            )
      }
  end

  @doc "One sandbox as `machines/0` reads it, or `nil`."
  @spec get(Ecto.UUID.t()) :: Sandbox.t() | nil
  def get(sandbox_id) when is_binary(sandbox_id),
    do: Repo.one(from s in machines(), where: s.id == ^sandbox_id)

  @doc """
  The sandbox, read under row locks by a caller that holds the machine's
  advisory lock: its workspace's row first, then its own, so this can never
  deadlock against `cas_update/4` (see the moduledoc). `mode` is `:update`
  or `:share`. Returns the struct as `machines/0` reads it, or `nil`.

  Runs inside the caller's transaction; that is the point of it.
  """
  @spec lock_machine(Ecto.UUID.t(), :update | :share) :: Sandbox.t() | nil
  def lock_machine(sandbox_id, mode) when is_binary(sandbox_id) and mode in [:update, :share] do
    case workspace_id_of(sandbox_id) do
      :not_found ->
        nil

      workspace_id ->
        workspace = workspace_id && locked(Workspace, workspace_id, mode)

        case locked(Sandbox, sandbox_id, mode) do
          nil -> nil
          %Sandbox{} = sandbox -> overlay(sandbox, workspace)
        end
    end
  end

  defp locked(schema, id, :update),
    do: Repo.one(from r in schema, where: r.id == ^id, lock: "FOR UPDATE")

  defp locked(schema, id, :share),
    do: Repo.one(from r in schema, where: r.id == ^id, lock: "FOR SHARE")

  # The workspace a sandbox belongs to: its id, `nil` for a sandbox with none,
  # `:not_found` for no sandbox. Read without a lock, and safe to: a live
  # sandbox's `workspace_id` is written when the row is inserted (or by the
  # boot sweep, before anything can claim), and nilified only by deleting its
  # workspace, which nothing does while the workspace has a live sandbox
  # (`Workspaces.delete_for_account/1`).
  defp workspace_id_of(sandbox_id) do
    case Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, select: {s.workspace_id}) do
      nil -> :not_found
      {workspace_id} -> workspace_id
    end
  end

  defp overlay(%Sandbox{} = sandbox, %Workspace{} = w) do
    %{
      sandbox
      | lease_epoch: w.lease_epoch,
        lease_node: w.lease_node,
        transition: w.transition,
        transition_reason: w.transition_reason
    }
  end

  # No workspace: the sandbox's own columns are its only record, as they were
  # before ADR 0097 (see the moduledoc).
  defp overlay(%Sandbox{} = sandbox, nil), do: sandbox

  @doc """
  What a protocol makes of a sandbox `claim/2` refused as
  `{:error, :no_workspace}`: `{:terminal, sandbox}` for a retired row, which
  it answers as the terminal row it is, with no lease taken; `:live` for a
  live one, which nothing can own until the next boot gives it a workspace
  and which it refuses as busy; `:not_found` for a row that went.
  """
  @spec unowned(Ecto.UUID.t()) :: {:terminal, Sandbox.t()} | :live | :not_found
  def unowned(sandbox_id) when is_binary(sandbox_id) do
    case get(sandbox_id) do
      nil ->
        :not_found

      %Sandbox{status: status} = sandbox when status in @terminal_statuses ->
        {:terminal, sandbox}

      %Sandbox{} ->
        Logger.warning(
          "machine #{sandbox_id}: a live sandbox with no workspace has no owner; " <>
            "the next boot gives it one (Workspaces._unsafe_reconcile_live/0)"
        )

        :live
    end
  end

  # ── the boot sweep ────────────────────────────────────────────────────────

  @doc """
  Clear every lease and every abandoned operation stamp left by an earlier
  boot (ADR 0072), on every workspace.

  Runs once at boot, before Oban, the endpoint and the rehydrator start, so
  nothing in this boot has claimed anything yet; the `WHERE` leaves this
  boot's leases alone all the same. A deploy stops the old node before the new
  one starts, so every lease of another boot belongs to a process that is
  gone. `destroying` stays for `SandboxReaper`'s driver (ADR 0058 stage 9a).
  `resuming` stays for the next wake to take over: an interrupted exec probe
  has not proved readiness, even when the row was already `ready` before the
  provider put it to sleep. Registration refuses that stamp too (#2560).

  First, a stamp a release before this one wrote on a live sandbox's row only
  is carried onto its workspace (see `@carry_sql`), so a rollback and a roll
  forward lose nothing even when `Workspaces._unsafe_reconcile_live/0` failed
  this boot. A live sandbox with no workspace, which only that failure
  leaves, has its own columns swept the same way. Then the workspaces' columns
  are copied onto their live sandboxes where they differ ("Written twice"),
  all in one transaction.

  Returns the number of workspaces it cleared.
  """
  @spec sweep_boot() :: non_neg_integer()
  def sweep_boot do
    prefix = boot_prefix() <> "%"

    # The reconcile's ten seconds: a stray session holding a row makes the boot
    # log a failure rather than wedge.
    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '10s'")
        sweep_rows(prefix)
      end)

    if count > 0, do: Logger.info("machine leases: cleared #{count} left by an earlier boot")
    count
  end

  defp sweep_rows(prefix) do
    _ = Repo.query!(@carry_sql)
    {count, _} = Repo.update_all(swept(Workspace, prefix), [])
    _ = Repo.update_all(from(s in swept(Sandbox, prefix), where: is_nil(s.workspace_id)), [])
    _ = copy_to_sandboxes(:all, nil)
    count
  end

  defp swept(schema, prefix) do
    from(r in schema,
      where:
        (not is_nil(r.lease_node) and not like(r.lease_node, ^prefix)) or
          (not is_nil(r.transition) and r.transition not in ["destroying", "resuming"] and
             (is_nil(r.lease_node) or not like(r.lease_node, ^prefix))),
      update: [
        set: [
          lease_node: nil,
          transition:
            fragment(
              "CASE WHEN ? IN ('destroying', 'resuming') THEN ? ELSE NULL END",
              r.transition,
              r.transition
            ),
          transition_reason:
            fragment(
              "CASE WHEN ? IN ('destroying', 'resuming') THEN ? ELSE NULL END",
              r.transition,
              r.transition_reason
            )
        ]
      ]
    )
  end

  # ── the lease ─────────────────────────────────────────────────────────────

  @doc """
  Take the lease on the machine behind `sandbox_id` for the calling process:
  on its workspace's row.

  Serializes on the machine's advisory lock, re-reads the workspace
  `FOR UPDATE`, and refuses with `{:error, {:held, holder}}` when a live
  process holds it. The verdict is made on the locked read, never on a struct
  the caller brought: a pre-lock reading is stale by construction.

  On success the epoch advances by exactly one and is returned. The holder
  quotes it on every subsequent write. `{:error, :no_workspace}` is a sandbox
  with no workspace, which nothing owns (see the moduledoc and `unowned/1`).

  `holder: pid` names a different holder than the caller; only tests do.
  `supersede: pid` takes the lease from that one holder even while it is
  alive. `ProvisionWatchdog` is the caller: it retires a provision whose
  server is wedged inside the provider, and stops that server straight after.
  The server's own later writes then fail their compare-and-set.
  """
  @spec claim(Ecto.UUID.t(), keyword()) ::
          {:ok, epoch()}
          | {:error,
             :not_found
             | :no_workspace
             | :lost
             | :transaction_open
             | {:invalid, :sandbox_id}
             | held()
             | term()}
  def claim(sandbox_id, opts \\ []) when is_binary(sandbox_id) and is_list(opts) do
    holder = opts |> Keyword.get(:holder, self()) |> holder()
    guarded(sandbox_id, fn -> do_claim(sandbox_id, holder, opts) end)
  end

  @doc """
  Give the lease up.

  Clears `lease_node` and keeps `lease_epoch` where it is: epochs are
  monotonic and never reused, so the next claimant still gets a strictly
  higher one and this holder's outstanding writes still fail. Guarded on the
  holder column too, so releasing twice is `{:error, :lost}` rather than a
  second success — after the first, this caller is no longer the holder.
  """
  @spec release(Ecto.UUID.t(), epoch()) ::
          :ok | {:error, :lost | :transaction_open | {:invalid, :sandbox_id} | term()}
  def release(sandbox_id, epoch) when is_binary(sandbox_id) and is_integer(epoch) do
    guarded(sandbox_id, fn ->
      if taken_epoch?(epoch), do: do_release(sandbox_id, epoch), else: {:error, :lost}
    end)
  end

  defp do_release(sandbox_id, epoch) do
    {:ok, result} =
      Repo.transaction(fn ->
        case Repo.update_all(held_by(sandbox_id, epoch), set: [lease_node: nil]) do
          {1, [workspace_id]} ->
            _ = copy_to_sandboxes(workspace_id, sandbox_id)
            :ok

          {0, _} ->
            {:error, :lost}
        end
      end)

    result
  end

  @doc """
  Write machine state, if and only if `epoch` is still the lease.

  The one write primitive the owner uses. In one short transaction: the
  workspace's row is locked where it holds this epoch *and a holder*, then
  the sandbox's row; nothing to lock is `:stale`, which is the whole protocol
  in one word — a superseded owner changes nothing and learns so. A lease that
  was released, or an epoch no claim ever handed out, is `:stale` for the same
  reason: neither is held. The answer is the sandbox as `machines/0` reads
  it, after the write.

  `transition` and `transition_reason` are written to the workspace and
  everything else to the sandbox, with the copy the moduledoc describes.
  `updated_at` moves on the sandbox with every write, and not with a claim or
  a release, so it keeps meaning "the machine changed".

  `attrs` is a plain map or a keyword list — **a struct is refused**
  (`{:error, {:invalid, :attrs}}`) even though it is a map, because nothing an
  owner writes is built by handing this function a schema. It may name only
  #{inspect(@writable)}, with atom keys, each at most
  once. `status` must be a member of `Sandbox.statuses/0` and `transition` of
  `Sandbox.transitions/0` (`nil` clears it, which is how a transition
  finalizes); anything else is `{:error, {:invalid, field}}` and nothing is
  written. That is **membership, not legality**: whether a transition is
  allowed from a state is the protocols' to decide. The one exception is
  retirement: a terminal sandbox is never written back to a live status,
  reported as `{:error, :retired}` so the owner does not mistake it for a
  takeover.

  **`:stale` beats `:retired`.** A superseded epoch is `:stale` even on a
  retired row; `:retired` means you *are* the holder and the row is terminal.
  A caller that no longer owns the machine has no business being told the
  row's status.

  **`destroying` survives a write that would clear it** (stage 9a). On a
  sandbox that is not yet terminal, a write naming `transition` as anything
  but `"destroying"` leaves the stamp and its reason exactly where they are,
  and returns the row saying so — the caller's other columns land, the intent
  does not move. That is what makes `destroying` the one *durable*
  transition: every other stamp is an abandoned operation a later owner
  clears, and this one is a request that outlives the owner that was serving
  it. See `preserving?/3` for the three writes that pass.

  A write that moves the status to `terminated` or `failed` stamps
  `terminated_at` when the row has none.

  **`refuse_fenced: true`** additionally requires no `destroying` stamp and
  answers `{:error, :fenced}` when there is one; see `refuse_fenced/2`.
  Refusals are checked in this order, so the reason names the first: not the
  holder, then retired, then fenced.

  **`nest: true` permits an enclosing transaction**, which every other function
  here refuses, and there are two callers. `Machines.Resume`'s admission runs
  this inside `Quotas.with_sandbox_reservation/2`'s transaction so that the
  `resuming` stamp and the quota count that authorised it commit together.
  `Machines.Provision.fail/2` runs it beside its caller's own write, so that
  `Launch.fail_initial_start/2` fails a conversation and its machine in one
  commit or neither. The moduledoc's reason for the guard does not reach this
  function — it is about holding the advisory lock until an outer commit, and
  this takes none — and the *other* thing nesting does, joining the caller's
  transaction so a rollback undoes the write, is exactly what those callers
  want. It is opt-in because everywhere else an enclosing transaction is the
  mistake the guard exists to catch.

  Two consequences a caller passing it owns. The two row locks this takes are
  held to the enclosing commit; in `Resume`'s case that is the quota
  reservation's, which took 4315 first, and nothing takes 4315 after either
  row. And an error out of a nested statement aborts the enclosing
  transaction, so the caller must treat a `{:database, _}` from here as fatal
  to the whole reservation rather than something to continue from; `Resume`
  does, by returning it and letting `with_sandbox_reservation/2` roll back.

  It does not ask whether the holder is alive: the caller *is* the holder.
  What the compare-and-set buys is that the moment another claim has happened
  — after this holder died, or `ProvisionWatchdog` superseded it — the old
  holder's write is invisible.
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
          {:ok, result} = Repo.transaction(fn -> locked_cas(sandbox_id, epoch, sets, opts) end)
          result
        end
      else
        {:error, :stale}
      end
    end)
  end

  defp locked_cas(sandbox_id, epoch, sets, opts) do
    with {:ok, workspace} <- held_workspace(sandbox_id, epoch),
         {:ok, sandbox} <- locked_sandbox(sandbox_id),
         :ok <- refuse_revival(sandbox, sets),
         :ok <- refuse_fenced(workspace, Keyword.get(opts, :refuse_fenced, false)) do
      write(sandbox, workspace, sets)
    end
  end

  # The workspace's row, locked, if it still holds `epoch` with a holder. The
  # epoch *and the holder column*: an epoch-only match makes the lease nobody
  # took quotable by anybody, and `release/2` keeps the epoch on purpose.
  defp held_workspace(sandbox_id, epoch) do
    with workspace_id when is_binary(workspace_id) <- workspace_id_of(sandbox_id),
         %Workspace{} = workspace <-
           Repo.one(
             from w in Workspace,
               where:
                 w.id == ^workspace_id and w.lease_epoch == ^epoch and not is_nil(w.lease_node),
               lock: "FOR UPDATE"
           ) do
      {:ok, workspace}
    else
      _ -> {:error, :stale}
    end
  end

  # Gone between the two reads only if the sandbox was deleted, which nothing
  # does to a row a lease is held on; answered as the lost machine it is.
  defp locked_sandbox(sandbox_id) do
    case locked(Sandbox, sandbox_id, :update) do
      nil -> {:error, :stale}
      %Sandbox{} = sandbox -> {:ok, sandbox}
    end
  end

  # Holding the lease is not permission to un-retire a row. Terminal-to-terminal
  # still goes through, and a write that never names a status is not a revival.
  # The only copy of the rule `Conversations.prevent_sandbox_revival/1` was.
  defp refuse_revival(%Sandbox{status: status}, sets) do
    new = Keyword.get(sets, :status)

    if is_binary(new) and new not in @terminal_statuses and status in @terminal_statuses,
      do: {:error, :retired},
      else: :ok
  end

  # **`refuse_fenced: true`** additionally requires **no `destroying` stamp**,
  # and it is opt-in because everywhere else the fence is not this write's
  # business. `Destroy` writes a terminal status onto a row it has just fenced,
  # and `Park`'s finalize is allowed to land on a fence that arrived
  # mid-operation (stage 6b). What cannot be allowed is a *provision*
  # finishing `ready` onto a machine somebody asked to be destroyed while it
  # was being built, which `SandboxReaper.sweep_fenced_teardowns/0` would then
  # finish underneath a conversation. `Provision.admissible/1` reads the same
  # stamp, so the two ends of the bracket agree about what a fence means.
  defp refuse_fenced(%Workspace{transition: @destroying}, true), do: {:error, :fenced}
  defp refuse_fenced(%Workspace{}, _refuse?), do: :ok

  defp write(%Sandbox{} = sandbox, %Workspace{} = workspace, sets) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {workspace_sets, sandbox_sets} = Keyword.split(sets, @workspace_fields)
    workspace_sets = if preserving?(workspace, sandbox, sets), do: [], else: workspace_sets
    workspace = written_workspace(workspace, workspace_sets)

    # The copy ("Written twice"), in the statement that writes the machine's
    # own columns.
    sets =
      sandbox_sets
      |> stamp_terminated_at(sandbox, now)
      |> Keyword.merge(
        updated_at: now,
        lease_epoch: workspace.lease_epoch,
        lease_node: workspace.lease_node,
        transition: workspace.transition,
        transition_reason: workspace.transition_reason
      )

    {1, [written]} =
      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id, select: s), set: sets)

    {:ok, overlay(written, workspace)}
  end

  defp written_workspace(workspace, []), do: workspace

  defp written_workspace(%Workspace{id: id}, sets) do
    {1, [written]} =
      Repo.update_all(from(w in Workspace, where: w.id == ^id, select: w), set: sets)

    written
  end

  # `destroying` is the one transition a write may not take off a live machine
  # (ADR 0058 stage 9a). Every other stamp is abandonable: a reader that finds
  # `parking` or `resuming` with no live lease is looking at an owner that
  # died, and three sites clear it on sight so the machine can be used again.
  # `destroying` is the opposite statement — somebody asked for this machine
  # to go away, and an owner dying halfway through does not withdraw the
  # request.
  #
  # Enforced here rather than only at the callers because the write that would
  # lose it is not a clearing write at all. `Machines.Park`'s finalize writes
  # `status: "suspended", transition: nil` on a machine it stamped `parking`,
  # and a teardown fence committing *during* the suspend — the fence takes the
  # advisory lock, the park holds only its lease — lands between the stamp and
  # the finalize. So the park still finalizes (the machine really is suspended
  # and the row must say so) and the stamp rides through, for the driver to
  # finish.
  #
  # **Three writes deliberately pass.** A write that names `transition:
  # "destroying"` is a re-stamp, which is how a second destroy records its own
  # reason. A write that moves the sandbox to a terminal status is the destroy
  # finishing, and clearing the stamp there is the finalize. And a stamp on a
  # sandbox that is *already* terminal is leftovers rather than intent, so the
  # guard reads the sandbox's status as it was before the write.
  #
  # When it fires neither of the workspace's two columns is written. A write
  # that named only the reason never reaches here (it names no `transition`),
  # and a write that named both keeps both.
  defp preserving?(%Workspace{transition: @destroying}, %Sandbox{status: status}, sets)
       when status not in @terminal_statuses do
    Keyword.has_key?(sets, :transition) and
      Keyword.get(sets, :transition) != @destroying and
      Keyword.get(sets, :status) not in @terminal_statuses
  end

  defp preserving?(_workspace, _sandbox, _sets), do: false

  # Fills `terminated_at` on the way into a terminal status, keeping the row's
  # own when it has one, and a caller's own when it names one. A write that
  # never names a status leaves the column alone.
  defp stamp_terminated_at(sets, %Sandbox{} = sandbox, now) do
    if Keyword.get(sets, :status) in @terminal_statuses and
         not Keyword.has_key?(sets, :terminated_at) do
      Keyword.put(sets, :terminated_at, sandbox.terminated_at || now)
    else
      sets
    end
  end

  @doc """
  Set the machine's `transition` and `transition_reason`, for the two writers
  of them outside the owner: the teardown fence's `destroying` stamp
  (`Machines.Destroy.stamp_intent!/2`) and registration's clearing of an
  abandoned one (`Machines.Binding.clear_abandoned_transition/1`).

  Inside the caller's transaction, under the machine's advisory lock and after
  `lock_machine(sandbox_id, :update)`; that order is the caller's to keep.
  Written to the workspace and copied onto its live sandbox and this one; a
  sandbox with no workspace has its own columns written. `touch: true` also
  moves the sandbox's `updated_at`, which the fence's stamp does:
  `SandboxReaper.sweep_fenced_teardowns/0` measures its grace from it.
  Returns how many sandbox rows were written: `0` for one that vanished.
  """
  @spec put_transition!(Ecto.UUID.t(), String.t() | nil, String.t() | nil, keyword()) ::
          non_neg_integer()
  def put_transition!(sandbox_id, transition, reason, opts \\ []) when is_binary(sandbox_id) do
    sets = [transition: transition, transition_reason: reason]

    count =
      case workspace_id_of(sandbox_id) do
        :not_found ->
          0

        nil ->
          {count, _} =
            Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox_id), set: sets)

          count

        workspace_id ->
          {1, _} =
            Repo.update_all(from(w in Workspace, where: w.id == ^workspace_id), set: sets)

          copy_to_sandboxes(workspace_id, sandbox_id)
      end

    if count > 0 and Keyword.get(opts, :touch, false) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)
      _ = Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox_id), set: [updated_at: now])
    end

    count
  end

  # The copy ("Written twice"): the workspace's four columns onto its live
  # sandbox, and onto `also` whatever its status, which is the sandbox the
  # write was addressed to. `:all` copies every workspace onto its live
  # sandbox, for the boot sweep. Returns how many sandboxes it wrote.
  defp copy_to_sandboxes(workspace_id, also) do
    query =
      from s in Sandbox,
        join: w in Workspace,
        on: w.id == s.workspace_id,
        update: [
          set: [
            lease_epoch: w.lease_epoch,
            lease_node: w.lease_node,
            transition: w.transition,
            transition_reason: w.transition_reason
          ]
        ]

    query =
      case {workspace_id, also} do
        # Only the rows that differ: a workspace per launch, and most agree.
        {:all, _} ->
          where(
            query,
            [s, w],
            s.status not in @terminal_statuses and
              (fragment("? IS DISTINCT FROM ?", s.lease_node, w.lease_node) or
                 fragment("? IS DISTINCT FROM ?", s.transition, w.transition) or
                 fragment("? IS DISTINCT FROM ?", s.transition_reason, w.transition_reason) or
                 s.lease_epoch != w.lease_epoch)
          )

        {id, nil} ->
          where(query, [s, w], w.id == ^id and s.status not in @terminal_statuses)

        {id, also} ->
          where(
            query,
            [s, w],
            w.id == ^id and (s.status not in @terminal_statuses or s.id == ^also)
          )
      end

    {count, _} = Repo.update_all(query, [])
    count
  end

  defp do_claim(sandbox_id, holder, opts) do
    superseded = superseded_holder(Keyword.get(opts, :supersede))

    Conversations.with_sandbox_lock(sandbox_id, fn ->
      case workspace_id_of(sandbox_id) do
        :not_found -> {:error, :not_found}
        nil -> {:error, :no_workspace}
        workspace_id -> claim_workspace(sandbox_id, workspace_id, holder, superseded)
      end
    end)
  end

  defp claim_workspace(sandbox_id, workspace_id, holder, superseded) do
    current =
      Repo.one(
        from w in Workspace,
          where: w.id == ^workspace_id,
          select: %{epoch: w.lease_epoch, lease_node: w.lease_node},
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
          from(w in Workspace, where: w.id == ^workspace_id and w.lease_epoch == ^current.epoch)

        case Repo.update_all(claimed, set: [lease_epoch: epoch, lease_node: holder]) do
          {1, _} ->
            _ = copy_to_sandboxes(workspace_id, sandbox_id)
            log_claim(sandbox_id, holder, epoch, current)
            {:ok, epoch}

          {0, _} ->
            {:error, :lost}
        end
    end
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

  # The workspace of `sandbox_id` where it holds `epoch` with a holder,
  # selecting its id: `release/2`'s one statement.
  defp held_by(sandbox_id, epoch) do
    from w in Workspace,
      join: s in Sandbox,
      on: s.workspace_id == w.id,
      where: s.id == ^sandbox_id and w.lease_epoch == ^epoch and not is_nil(w.lease_node),
      select: w.id
  end

  # `claim/2` hands out 1 first, so anything below it is not an epoch a
  # claim ever produced — it is the column default wearing an epoch's clothes.
  defp taken_epoch?(epoch), do: epoch >= 1

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
