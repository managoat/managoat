defmodule Fountain.Repo.Migrations.DropSandboxLeaseColumns do
  @moduledoc """
  Drops the sandbox's copy of the machine lease (ADR 0097 step 3, #3000):
  `sandboxes.lease_epoch`, `lease_node`, `transition` and
  `transition_reason`.

  Since step 3b (#2990, v0.37.0) the lease is on `workspaces`, and every
  reader reads it there; the sandbox's four columns were written only as a
  copy, so that a rollback to a release before 3b found them current, and
  the boot sweep gave a workspace to any live sandbox such a release made
  and carried back onto the workspace any stamp it wrote on the sandbox row.
  The release that ships this stops the copy and the carry and maps the four
  as virtual fields filled from the workspace
  (`Fountain.Machines.Lease.machines/0`). Take this only once a release with
  3b is rolled out, or on the supported stop-then-start deploy (ADR 0072): a
  release before this one maps the columns, and Ecto selects every mapped
  field.

  `up/0` does what that boot sweep did, one last time, before it drops the
  columns, because migrations run before the boot sweep:

    1. **The fill** (a frozen copy of `20261018210000`'s): every live sandbox
       with no workspace gets an implicit one, and every conversation on a
       live sandbox points at its sandbox's.
    2. **The carry**: a stamp a release before 3b wrote on a live sandbox's
       row (after a rollback to it) reaches the workspace rather than being
       lost. The epoch never goes backwards.

  On a deployment that never rolled back below 3b both write nothing: every
  live sandbox has a workspace, and the copy agrees with it at every commit.

  `down/0` restores the columns and copies each workspace's four onto its
  live sandbox, as 3b's boot sweep does, so that a release with 3b finds
  them equal (its boot carry would otherwise read the restored defaults as a
  stamp to carry and clear the workspace's `destroying` and `resuming`), and
  a release before 3b finds the lease where it reads it. **Run it with the
  deployment scaled to zero** (a one-off pod of this release's image), not
  from inside a running pod: this release keeps stamping only the workspace,
  so a stamp it wrote after `down` copied would be overwritten by the older
  release's boot carry.
  """
  use Ecto.Migration

  require Logger

  @terminal "('terminated', 'failed')"

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    # `execute` is queued and `query!` is not: the timeouts first.
    flush()

    %{rows: [[workspaces, conversations]]} = repo().query!(fill_sql())
    %{num_rows: carried} = repo().query!(carry_sql())

    Logger.info(
      "migration: #{workspaces} implicit workspace(s) filled, #{conversations} " <>
        "conversation(s) repointed, lease state carried for #{carried} live sandbox(es)"
    )

    execute("""
    ALTER TABLE sandboxes
      DROP COLUMN lease_epoch,
      DROP COLUMN lease_node,
      DROP COLUMN transition,
      DROP COLUMN transition_reason
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '60s'")

    execute("""
    ALTER TABLE sandboxes
      ADD COLUMN lease_epoch bigint NOT NULL DEFAULT 0,
      ADD COLUMN lease_node varchar(255),
      ADD COLUMN transition varchar(255),
      ADD COLUMN transition_reason text
    """)

    execute("""
    UPDATE sandboxes s
       SET lease_epoch = w.lease_epoch,
           lease_node = w.lease_node,
           transition = w.transition,
           transition_reason = w.transition_reason
      FROM workspaces w
     WHERE w.id = s.workspace_id
       AND s.status NOT IN #{@terminal}
    """)
  end

  # `20261018210000_add_machine_lease_to_workspaces`'s fill, frozen.
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

  # 3b's boot carry (`Fountain.Machines.Lease`'s `@carry_sql`), frozen: the
  # rows that differ, and never a lower epoch.
  defp carry_sql do
    """
    UPDATE workspaces w
       SET lease_epoch = GREATEST(w.lease_epoch, s.lease_epoch),
           transition = s.transition,
           transition_reason = s.transition_reason
      FROM sandboxes s
     WHERE s.workspace_id = w.id
       AND s.status NOT IN #{@terminal}
       AND (w.transition IS DISTINCT FROM s.transition
            OR w.transition_reason IS DISTINCT FROM s.transition_reason
            OR w.lease_epoch < s.lease_epoch)
    """
  end
end
