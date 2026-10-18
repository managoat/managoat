defmodule Fountain.Repo.Migrations.AddMachineLeaseToWorkspaces do
  use Ecto.Migration

  require Logger

  # ADR 0097, step 3a: the lease columns of ADR 0058 (`lease_epoch`,
  # `lease_node`, `transition`, `transition_reason`) arrive on `workspaces`,
  # where step 3b moves the owner. This release still reads them from
  # `sandboxes` and writes both (`Fountain.Machines.Lease`), so nothing changes
  # for a caller; the columns on `sandboxes` are dropped a release after 3b.
  #
  # Four things, in this order:
  #
  #   1. **The columns.** Same types and defaults as on `sandboxes`
  #      (`20260916120000`): an epoch of `0` is "never claimed", and `NULL`s are
  #      "nobody holds it" and "no operation in flight".
  #
  #   2. **`workspaces.user_id` becomes nullable, nilified when the user goes**
  #      instead of cascading. A workspace now carries its machine's durable
  #      `destroying` stamp, and account deletion can leave a live sandbox
  #      behind (a destroy that raised, #2329: `sandboxes.user_id` is nilified
  #      for the same reason). Deleting that sandbox's workspace with the user
  #      would delete the stamp, and with step 3b, the only lease the owner can
  #      take on the machine. So such a workspace stays ownerless, as its
  #      sandbox does, until `SandboxReaper`'s driver finishes the destroy.
  #      `Workspaces.delete_for_account/1` still deletes every workspace with no
  #      live sandbox, which is all of them unless a destroy failed. A query
  #      scoped by `user_id` never matches a `NULL` one.
  #
  #   3. **The backfill again** (`20261018190100`'s fill, which the step-2 PR
  #      said step 3 must repeat). A rollback to v0.36.x and forward again
  #      inserts live sandboxes with no workspace, and a wake on that release
  #      moves a conversation to one and leaves its old `workspace_id` behind.
  #      So: one implicit workspace per live sandbox that has none, **now
  #      including a sandbox with no user** (the case `20261018190100` skipped,
  #      because `user_id` was `NOT NULL`), and every conversation on a live
  #      sandbox pointed at that sandbox's workspace, which repoints the stale
  #      ones as well as filling the nulls. Idempotent. `Fountain.Machines.BootSweep`
  #      runs the same fill on every boot from this release on, because a
  #      migration runs once and a rollback can happen after it.
  #
  #   4. **The in-flight stamps carried.** Each live sandbox's lease columns are
  #      copied to its workspace: the durable `destroying` and `resuming`
  #      stamps above all (ADR 0097, Consequences: "the migration must carry
  #      any `destroying` stamp"). The epoch never goes backwards. Live rows
  #      only: a terminal sandbox's stamp is leftovers, and a workspace's
  #      columns describe its live machine.
  #
  # Safe on prod's Recreate deploy (ADR 0072): the old pod is gone before this
  # runs, so nothing claims or stamps concurrently, and every lease it copies
  # is a dead boot's, which the boot sweep clears straight after.
  #
  # Cost on prod at 2026-10-18: 23 live sandboxes, 23 workspaces; a few dozen
  # row writes.
  #
  # `down` drops the columns and puts the cascade back. It first deletes the
  # ownerless workspaces, which `NOT NULL` would refuse; their sandboxes'
  # `workspace_id` is nilified by the foreign key, and the previous release
  # reads neither. Nothing is audited, matching the other data migrations.

  @terminal "('terminated', 'failed')"

  def up do
    execute "SET LOCAL lock_timeout = '10s'"

    alter table(:workspaces) do
      add :lease_epoch, :bigint, null: false, default: 0
      add :lease_node, :string
      add :transition, :string
      add :transition_reason, :text

      modify :user_id, references(:users, type: :binary_id, on_delete: :nilify_all),
        null: true,
        from: {references(:users, type: :binary_id, on_delete: :delete_all), null: false}
    end

    flush()

    %{rows: [[workspaces, conversations]]} = repo().query!(fill_sql())
    %{num_rows: carried} = repo().query!(carry_sql())

    Logger.info(
      "migration: #{workspaces} implicit workspace(s) filled, #{conversations} " <>
        "conversation(s) repointed, lease state carried for #{carried} live sandbox(es)"
    )
  end

  def down do
    execute "SET LOCAL lock_timeout = '10s'"
    execute "DELETE FROM workspaces WHERE user_id IS NULL"

    alter table(:workspaces) do
      modify :user_id, references(:users, type: :binary_id, on_delete: :delete_all),
        null: false,
        from: {references(:users, type: :binary_id, on_delete: :nilify_all), null: true}

      remove :transition_reason
      remove :transition
      remove :lease_node
      remove :lease_epoch
    end
  end

  # A frozen copy of `Fountain.Workspaces._unsafe_reconcile_live/0`'s fill: a migration
  # must not call application code that later releases may change.
  defp fill_sql do
    """
    WITH live AS (
      SELECT s.id AS sandbox_id,
             gen_random_uuid() AS workspace_id,
             s.user_id, s.environment_id, s.vault_id, s.provider, s.status, s.inserted_at
        FROM sandboxes s
       WHERE s.status NOT IN #{@terminal}
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
         AND s.status NOT IN #{@terminal}
         AND c.workspace_id IS DISTINCT FROM COALESCE(live.workspace_id, s.workspace_id)
      RETURNING c.id
    )
    SELECT (SELECT count(*) FROM ws), (SELECT count(*) FROM cv)
    """
  end

  defp carry_sql do
    """
    UPDATE workspaces w
       SET lease_epoch = GREATEST(w.lease_epoch, s.lease_epoch),
           lease_node = s.lease_node,
           transition = s.transition,
           transition_reason = s.transition_reason
      FROM sandboxes s
     WHERE s.workspace_id = w.id
       AND s.status NOT IN #{@terminal}
    """
  end
end
