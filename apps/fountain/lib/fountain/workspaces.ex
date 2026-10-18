defmodule Fountain.Workspaces do
  @moduledoc """
  Workspaces (ADR 0097). The writes that keep a workspace beside every live
  sandbox: the implicit workspace a sandbox is born with, its status following
  that sandbox's provision, and `_unsafe_reconcile_live/0`, which repairs the
  pairing at every boot. The machine's owner and lease are the workspace's
  (step 3b), and `Fountain.Machines.Lease` reads and writes them. Since step 4
  the lifecycle reads the workspace's kind (`machine_kind/1`): a detach keeps
  an explicit workspace's machine, and the ceiling parks it. Nothing a caller
  sees reads a workspace yet (step 5).

  Every query a caller can reach is scoped by `user_id`. `_unsafe_reconcile_live/0`
  and `_unsafe_sweep_ended/0` are sweeps over every account and say so.

  **An implicit workspace ends with its conversation** (step 4): once the
  conversation is terminal and its machine is gone, the row is deleted
  (`release_ended/1`, from the termination path; `_unsafe_sweep_ended/0`,
  hourly from `SandboxReaper`, for whatever that path missed). Deleted rather
  than kept with an ended status: once its machine is terminal nothing reads
  it, its lease guards nothing, and a kept row per launch would accumulate
  for ever. While its conversation lives it is kept, machine or no machine,
  because the conversation's next prompt builds its next machine in it. The
  same sweep deletes an ownerless workspace (account deletion keeps one beside
  a machine whose destroy failed, #2329) once that machine is terminal, and
  the `provisioning` rows a lost wake race left before step 4.

  **Nothing here is audited, deliberately.** An implicit workspace is made in
  the launch's transaction, where an audit event cannot be recorded (ADR 0013),
  and it is not a thing anybody asked for: it is the launch's own sandbox
  given an owner record, and `conversation.created` and
  `sandbox.provisioned` / `sandbox.provision_failed`, recorded after their
  commits, already describe it. `workspace.created` and `workspace.deleted`
  are for the explicit workspaces a caller creates and deletes by API (step 5).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workspaces.Workspace

  @terminal_statuses ~w(terminated failed)

  # `_unsafe_reconcile_live/0`'s fill. `20261018210000` keeps a frozen copy.
  @fill_sql """
  WITH live AS (
    SELECT s.id AS sandbox_id,
           gen_random_uuid() AS workspace_id,
           s.user_id, s.environment_id, s.vault_id, s.provider, s.status, s.inserted_at
      FROM sandboxes s
     WHERE s.status NOT IN ('terminated', 'failed')
       AND s.workspace_id IS NULL
     ORDER BY s.id
       FOR UPDATE OF s
  ),
  ws AS (
    INSERT INTO workspaces
      (id, user_id, environment_id, vault_id, provider, name, implicit, status,
       inserted_at, updated_at)
    SELECT workspace_id, user_id, environment_id, vault_id, provider, NULL, true,
           CASE WHEN status IN ('pending', 'starting') THEN 'provisioning' ELSE 'ready' END,
           inserted_at,
           date_trunc('second', timezone('UTC', now()))
      FROM live
    RETURNING id
  ),
  sb AS (
    UPDATE sandboxes s
       SET workspace_id = live.workspace_id
      FROM live
     WHERE s.id = live.sandbox_id
    RETURNING s.id
  ),
  cv AS (
    UPDATE conversations c
       SET workspace_id = COALESCE(live.workspace_id, s.workspace_id)
      FROM sandboxes s
      LEFT JOIN live ON live.sandbox_id = s.id
     WHERE c.sandbox_id = s.id
       AND s.status NOT IN ('terminated', 'failed')
       AND c.workspace_id IS DISTINCT FROM COALESCE(live.workspace_id, s.workspace_id)
    RETURNING c.id
  )
  SELECT (SELECT count(*) FROM ws), (SELECT count(*) FROM cv)
  """

  @doc """
  Insert the implicit workspace for a sandbox about to be reserved.

  `attrs` carries `:user_id`, `:provider` (a string), and the launch's resolved
  `:environment_id` and `:vault_id` — the same values the sandbox row is
  given. Runs inside the caller's reservation transaction, so a refused
  reservation takes the workspace with it.
  """
  @spec insert_implicit(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def insert_implicit(attrs) when is_map(attrs) do
    attrs
    |> Map.take([:user_id, :environment_id, :vault_id, :provider])
    |> Workspace.implicit_changeset()
    |> Repo.insert()
  end

  @doc """
  Move a workspace out of `provisioning` once its sandbox's provision has
  settled: `ready` for a `ready` sandbox, `failed` for a `failed` one.
  Anything else is left alone, and so is a workspace that has already
  settled, so a park, a wake or a later destroy never moves it. An explicit
  workspace is `provisioning` again only while a rebuild of its lost machine
  runs (`Lease.succeed/3`, ADR 0097 step 4), and settles the same way.

  Called by `Fountain.Machines.Provision` after its own write commits, outside
  every transaction. Best effort: a workspace that cannot be written is
  logged and the provision's answer stands, because nothing reads the status
  yet.
  """
  @spec settle_provision(Sandbox.t()) :: :ok
  def settle_provision(%Sandbox{workspace_id: workspace_id, user_id: user_id, status: status})
      when is_binary(workspace_id) and is_binary(user_id) and status in ["ready", "failed"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _ =
      Repo.update_all(
        from(w in Workspace,
          where: w.id == ^workspace_id and w.user_id == ^user_id and w.status == "provisioning"
        ),
        set: [status: status, updated_at: now]
      )

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: could not record its provision as #{status}: " <>
          Exception.message(error)
      )

      :ok
  end

  def settle_provision(%Sandbox{}), do: :ok

  @doc """
  Delete the workspaces `user_id` owns, for account deletion, inside its
  transaction and before the user row goes: every one with no live sandbox.

  A workspace whose sandbox is still live is kept, and the user's delete
  nilifies its `user_id` (ADR 0097, step 3a). That sandbox is one whose
  destroy failed during the deletion (#2329), and its workspace carries the
  machine's lease and `destroying` stamp, which `SandboxReaper`'s driver needs
  to finish the destroy. Ordinarily there is none: the deletion has destroyed
  every machine by now.

  The explicit delete, rather than leaving it to the foreign key, is still
  needed for the others. One delete of the user would otherwise reach each
  terminal sandbox by two paths in one statement, its own `user_id` and its
  workspace's `ON DELETE SET NULL` on `workspace_id`; when the sandbox row was
  written in the deleting transaction (every SQL-sandboxed test, or a launch
  and a deletion in one transaction), PostgreSQL re-checks
  `sandboxes_workspace_id_fkey` between them and the delete fails.

  **The rows are taken in the machine layer's order: conversations, then
  workspaces, then sandboxes** (the teardown fence's and a turn admission's;
  `Fountain.Machines.Lease` locks a workspace before its sandbox, ADR 0097
  step 3b). So the conversations' pointers are cleared, the workspaces locked,
  the sandboxes' pointers cleared, and only then are the workspaces deleted,
  rather than leaving it to the foreign key's `ON DELETE SET NULL`, whose order
  is not this one. A deletion that went another way could deadlock against a
  lease release on a machine it had just destroyed (review of step 3a,
  reproduced).
  The user row's own delete, straight after, still cascades in the foreign
  keys' order, as it did before workspaces. The delete re-checks that no live
  sandbox has appeared. Not audited: `account.deleted`, recorded by
  `Fountain.Accounts.Deletion` outside the transaction, is the record.
  """
  @spec delete_for_account(Ecto.UUID.t()) :: :ok
  def delete_for_account(user_id) when is_binary(user_id) do
    # Every one of the user's conversations, then every one of its workspaces,
    # the kept ones included, locked before anything here or the user row's
    # cascade reaches a sandbox: the cascade nilifies `sandboxes.user_id`
    # before `workspaces.user_id` (the foreign keys' trigger order), and a
    # compare-and-set on a machine that outlived the deletion holds its
    # workspace's row while it waits for its sandbox's (review of step 3b,
    # reproduced).
    _ =
      Repo.all(
        from(c in Conversation,
          where: c.user_id == ^user_id,
          order_by: c.id,
          select: c.id,
          lock: "FOR UPDATE"
        )
      )

    _ =
      Repo.all(
        from(w in Workspace,
          where: w.user_id == ^user_id,
          order_by: w.id,
          select: w.id,
          lock: "FOR UPDATE"
        )
      )

    case Repo.all(from(w in without_live_sandbox(), where: w.user_id == ^user_id, select: w.id)) do
      [] ->
        :ok

      ids ->
        _ =
          Repo.update_all(from(c in Conversation, where: c.workspace_id in ^ids),
            set: [workspace_id: nil]
          )

        _ =
          Repo.update_all(from(s in Sandbox, where: s.workspace_id in ^ids),
            set: [workspace_id: nil]
          )

        {_count, _} = Repo.delete_all(from(w in without_live_sandbox(), where: w.id in ^ids))
        :ok
    end
  end

  defp without_live_sandbox do
    from(w in Workspace,
      as: :workspace,
      where:
        not exists(
          from(s in Sandbox,
            where:
              s.workspace_id == parent_as(:workspace).id and
                s.status not in ^@terminal_statuses
          )
        )
    )
  end

  @doc """
  The kind of workspace that owns the machine behind `sandbox`: `:implicit`,
  ended with its one conversation, or `:explicit`, which a caller made and
  which keeps its machine until it is deleted (ADR 0097, Lifecycle).

  A sandbox with no workspace (a row from before ADR 0097) or whose workspace
  has gone reads as `:implicit`: that is how every machine behaved before
  workspaces, and an explicit workspace is never deleted while it has a live
  sandbox. The flag is fixed at create, so an unlocked read is exact.
  """
  @spec machine_kind(Sandbox.t() | %{workspace_id: Ecto.UUID.t() | nil}) ::
          :implicit | :explicit
  def machine_kind(%{workspace_id: nil}), do: :implicit

  def machine_kind(%{workspace_id: workspace_id}) when is_binary(workspace_id) do
    case Repo.one(from(w in Workspace, where: w.id == ^workspace_id, select: w.implicit)) do
      false -> :explicit
      _implicit_or_gone -> :implicit
    end
  end

  @doc """
  Delete the workspace behind `sandbox_id` if it has ended: an implicit one
  (or one whose account was deleted) with no live sandbox and no live
  conversation (ADR 0097: an implicit workspace "is destroyed with the
  conversation").

  Called once a conversation's termination and its machine's destroy have
  both happened, from whichever of the two finishes last
  (`Fountain.Conversations.Termination`); whichever runs first finds the
  other still live and leaves the row, so one of them deletes it.
  `SandboxReaper` collects whatever neither reached (`_unsafe_sweep_ended/0`).
  Best effort and outside every transaction; nothing is audited, as nothing
  is for an implicit workspace (see the moduledoc).
  """
  @spec release_ended(Ecto.UUID.t() | nil) :: :ok
  def release_ended(nil), do: :ok

  def release_ended(sandbox_id) when is_binary(sandbox_id) do
    case Repo.one(from(s in Sandbox, where: s.id == ^sandbox_id, select: s.workspace_id)) do
      nil -> :ok
      workspace_id -> delete_ended([workspace_id])
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "sandbox #{sandbox_id}: ended workspace not released: " <> Exception.message(error)
      )

      :ok
  end

  @doc """
  Delete every ended workspace (see `release_ended/1`): the backstop
  `SandboxReaper` runs hourly over every account. It collects what the
  termination path did not reach: a destroy that finished after its
  conversation was already gone, the `provisioning` rows a lost wake race left
  before step 4, and the ownerless rows account deletion keeps beside a
  machine whose destroy failed (#2329), once that machine is terminal.
  Returns how many were deleted.
  """
  @spec _unsafe_sweep_ended() :: non_neg_integer()
  def _unsafe_sweep_ended do
    ids = Repo.all(from(w in ended(), select: w.id, limit: 500))
    if ids == [], do: 0, else: delete_ended(ids, :count)
  end

  # Ended: an implicit workspace, or one with no account left to own it, with
  # no live sandbox and no conversation that could still be prompted into it.
  # An explicit workspace with an owner lives until it is deleted (step 5).
  # A row whose lease is still held is not ended yet: a destroy writes its
  # machine terminal before it releases the lease, and deleting the row in
  # between would leave the release nothing to write and change the advisory
  # lock's key under an operation (review of step 4a). The sweep takes it
  # once the lease is released.
  defp ended do
    from(w in without_live_sandbox(),
      where:
        is_nil(w.lease_node) and (w.implicit or is_nil(w.user_id)) and
          not exists(
            from(c in Conversation,
              where:
                c.workspace_id == parent_as(:workspace).id and
                  c.status not in ^@terminal_statuses
            )
          )
    )
  end

  # In the machine layer's lock order, as `delete_for_account/1` takes it:
  # the conversations, then the workspaces, then the pointers cleared and the
  # rows deleted, each re-checked under those locks. A conversation can only
  # leave a workspace (a terminal one is never prompted again) and a live
  # sandbox only enters one through a live conversation's wake, so a row that
  # is ended under the locks stays ended.
  defp delete_ended(ids, answer \\ :ok) do
    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        _ =
          Repo.all(
            from(c in Conversation,
              where: c.workspace_id in ^ids,
              order_by: c.id,
              select: c.id,
              lock: "FOR UPDATE"
            )
          )

        _ =
          Repo.all(
            from(w in Workspace,
              where: w.id in ^ids,
              order_by: w.id,
              select: w.id,
              lock: "FOR UPDATE"
            )
          )

        case Repo.all(from(w in ended(), where: w.id in ^ids, select: w.id)) do
          [] ->
            0

          ended_ids ->
            _ =
              Repo.update_all(from(c in Conversation, where: c.workspace_id in ^ended_ids),
                set: [workspace_id: nil]
              )

            _ =
              Repo.update_all(from(s in Sandbox, where: s.workspace_id in ^ended_ids),
                set: [workspace_id: nil]
              )

            {count, _} = Repo.delete_all(from(w in Workspace, where: w.id in ^ended_ids))
            count
        end
      end)

    if answer == :count, do: count, else: :ok
  end

  @doc """
  Give every live sandbox a workspace and point every conversation on a live
  sandbox at its sandbox's.

  Run by `Fountain.Machines.BootSweep` on every boot, before anything can
  claim a lease, and once by `20261018210000_add_machine_lease_to_workspaces`.
  A migration runs once, and a rollback to a release before ADR 0097 followed
  by this one again leaves sandboxes it made with no workspace, conversations
  it moved with a stale `workspace_id`, and stamps it wrote on the sandbox
  row only. Idempotent: on a deployment that never rolled back it writes
  nothing.

  The fill is `20261018190100`'s, plus a live sandbox with no user (account
  deletion nilifies `sandboxes.user_id`), which gets an ownerless workspace so
  its owner still has a lease to take. The repoint touches only conversations
  on a live sandbox: a terminal one's pointer is history. The stamps such a
  release wrote on a sandbox row are carried to its workspace by
  `Fountain.Machines.Lease.sweep_boot/0`, in the transaction that then sweeps
  them, so the two can never be split by a failure between them.

  One transaction under a ten-second `lock_timeout`, like the migrations: a
  stray session holding one of these rows makes the boot log a failure rather
  than wedge (`BootSweep` carries on to the lease sweep).

  Returns `{filled, repointed}`. Nothing is audited: an implicit workspace is
  not something anybody asked for (see the moduledoc).
  """
  @spec _unsafe_reconcile_live() :: {non_neg_integer(), non_neg_integer()}
  def _unsafe_reconcile_live do
    {:ok, {filled, repointed}} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '10s'")
        %{rows: [[filled, repointed]]} = Repo.query!(@fill_sql)
        {filled, repointed}
      end)

    if filled + repointed > 0 do
      Logger.info("workspaces: #{filled} filled, #{repointed} conversation(s) repointed")
    end

    {filled, repointed}
  end
end
