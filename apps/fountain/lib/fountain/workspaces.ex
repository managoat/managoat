defmodule Fountain.Workspaces do
  @moduledoc """
  Workspaces (ADR 0097). At step 3a of the ADR's sequence this is only the
  writes that keep a workspace beside every live sandbox: the implicit
  workspace a sandbox is born with, its status following that sandbox's
  provision, and `_unsafe_reconcile_live/0`, which repairs the pairing at every boot.
  Nothing reads a workspace yet, so nothing here changes what a caller sees.
  The machine's lease columns are written onto it by `Fountain.Machines.Lease`.

  Every query a caller can reach is scoped by `user_id`. `_unsafe_reconcile_live/0`
  is a boot-time sweep over every account and says so.

  **Nothing deletes an implicit workspace yet**, except account deletion
  (`delete_for_account/1`, which keeps one whose machine survived it, and
  nothing removes that ownerless row afterwards; nor the ones a rollback to
  v0.36.x leaves, whose account deletion nilifies every workspace): the
  ADR ends one with its conversation, and that is step 4's lifecycle work. Until
  then a row is left per launch and per fresh-sandbox wake, as a sandbox row
  is, including the `provisioning` ones a lost wake race leaves, which nothing
  points at.

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

  # `_unsafe_reconcile_live/0`'s two statements. `20261018210000` keeps a frozen copy.
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
  Move an implicit workspace out of `provisioning` once its sandbox's
  provision has settled: `ready` for a `ready` sandbox, `failed` for a
  `failed` one. Anything else is left alone, and so is a workspace that has
  already settled, so a park, a wake or a later destroy never moves it.

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
          where:
            w.id == ^workspace_id and w.user_id == ^user_id and w.implicit and
              w.status == "provisioning"
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

  **The pointers are cleared first, conversations then sandboxes, and only
  then are the workspaces deleted**, rather than left to the foreign key's
  `ON DELETE SET NULL`, which would lock the workspace's row before its
  sandbox's. That is the order of the machine-layer writers it can race: the
  teardown fence locks the conversation, then the sandbox, then copies onto
  the workspace, and `Fountain.Machines.Lease` writes the sandbox before the
  workspace. A deletion that went the other way could deadlock against a lease
  release on a machine it had just destroyed (review of step 3a, reproduced).
  The user row's own delete, straight after, still cascades in the foreign
  keys' order, as it did before workspaces. The delete re-checks that no live
  sandbox has appeared. Not audited: `account.deleted`, recorded by
  `Fountain.Accounts.Deletion` outside the transaction, is the record.
  """
  @spec delete_for_account(Ecto.UUID.t()) :: :ok
  def delete_for_account(user_id) when is_binary(user_id) do
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
  Give every live sandbox a workspace, point every conversation at its
  sandbox's, and carry each live sandbox's in-flight stamps to its workspace.

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
  on a live sandbox: a terminal one's pointer is history. The carry copies
  `transition` and `transition_reason` where they differ, and never moves the
  epoch backwards. In this release the lease sweep straight after copies every
  live sandbox's columns onto its workspace anyway, so the carry matters only
  if that sweep fails; from step 3b, where the workspace's columns are the ones
  read, it is what brings across a stamp an earlier release wrote on the
  sandbox row.

  One transaction under a ten-second `lock_timeout`, like the migrations: a
  stray session holding one of these rows makes the boot log a failure rather
  than wedge (`BootSweep` carries on to the lease sweep).

  Returns `{filled, repointed, carried}`. Nothing is audited: an implicit
  workspace is not something anybody asked for (see the moduledoc).
  """
  @spec _unsafe_reconcile_live() :: {non_neg_integer(), non_neg_integer(), non_neg_integer()}
  def _unsafe_reconcile_live do
    {:ok, {filled, repointed, carried}} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '10s'")
        %{rows: [[filled, repointed]]} = Repo.query!(@fill_sql)
        %{num_rows: carried} = Repo.query!(@carry_sql)
        {filled, repointed, carried}
      end)

    if filled + repointed + carried > 0 do
      Logger.info(
        "workspaces: #{filled} filled, #{repointed} conversation(s) repointed, " <>
          "#{carried} stamp(s) carried from a sandbox row"
      )
    end

    {filled, repointed, carried}
  end
end
