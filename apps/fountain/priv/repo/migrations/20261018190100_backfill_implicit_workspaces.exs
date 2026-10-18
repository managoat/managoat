defmodule Fountain.Repo.Migrations.BackfillImplicitWorkspaces do
  use Ecto.Migration

  require Logger

  # ADR 0097, step 2: one implicit workspace per non-terminal sandbox, and the
  # sandbox and its conversations pointed at it. From this release every new
  # sandbox is born with one (`Fountain.Workspaces.insert_implicit/1`); this
  # gives the machines already running one too, so the owner can key by
  # workspace in step 3 without a live machine that has none.
  #
  # **Which sandboxes.** Every row whose status is not `terminated` or `failed`
  # and that has no workspace yet. Terminal rows keep a null `workspace_id`
  # (ADR 0097, Data): they are history, and a workspace for each would be
  # thousands of rows nothing will ever own.
  #
  # **Where the environment and vault come from.** The sandbox's own
  # `environment_id` and `vault_id`. The ADR says "of its conversation", and
  # they are the same pair: the conversation's `environment_id` is the
  # launch's override, nil for "the agent's", and the sandbox's is what the
  # launch resolved from it (`override || agent.environment_id`), which is
  # what the disk was built from and what an implicit workspace is made with
  # at launch. The vault is copied to both rows from one value. On prod
  # (2026-10-18) no live sandbox disagreed with its conversation on either.
  # Reading the sandbox also covers a live sandbox with no conversation.
  #
  # **Odd shapes, explicitly:**
  #
  #   * A live sandbox with **no conversation** gets a workspace like any
  #     other. It is a machine that still exists and that the reaper will
  #     tear down, and from step 3 that runs through a workspace's owner.
  #   * A live sandbox with **several conversations** (none should survive
  #     `20261014160000_one_conversation_per_sandbox`) gets one workspace,
  #     and every conversation on it points at it, which is what a workspace
  #     with many conversations is.
  #   * Every conversation whose `sandbox_id` is the sandbox is pointed at it,
  #     whatever its own status. A `failed` conversation on a `suspended`
  #     machine is still that machine's.
  #   * A live sandbox with **no user** (account deletion nilifies
  #     `sandboxes.user_id`, and a destroy that raised leaves the row live) is
  #     skipped: a workspace needs an owner, and the reaper retires such a row
  #     by its sandbox id. Its id is logged.
  #
  # **Status** is what the sandbox implies: `pending` and `starting` are a
  # provision in flight, `provisioning`; `ready` and `suspended` were built,
  # `ready`. The sandbox's own status, transition and lease are untouched; the
  # lease moves in step 3.
  #
  # **Timestamps.** The workspace is stamped with its sandbox's `inserted_at`,
  # since that is when it began. `updated_at` on the sandbox and conversation
  # rows is left alone: nothing about the machine or the run changed.
  #
  # One statement, so the three writes commit together, and idempotent (rows
  # that already have a workspace are skipped), so running it again after a
  # rollback to the previous release and forward again — which inserts
  # sandboxes without workspaces in between — fills in only those. A migration
  # does not run twice by itself, so step 3, the first to depend on every live
  # sandbox having a workspace, has to repeat this fill. It should also repoint
  # a conversation whose `workspace_id` no longer matches its sandbox's: a wake
  # on the previous release moves `sandbox_id` to a workspace-less sandbox and
  # leaves the old `workspace_id` behind, which the `IS NULL` test below does
  # not catch.
  #
  # Safe on prod's Recreate deploy: the old pod is gone before this runs, so
  # nothing inserts a sandbox concurrently. On a rolling deploy an old replica
  # could insert one after this commits; that row has no workspace until
  # step 3's fill, and nothing reads `workspace_id` before then.
  #
  # Cost on prod at 2026-10-18: 23 live sandboxes (all `suspended`, each with
  # one conversation), so 23 inserts and 46 updates.
  #
  # One-way in effect: `down` is a no-op, because rolling back
  # `20261018190000` drops the table and both columns, and the previous
  # release reads neither. Nothing is audited, matching the other data
  # migrations.

  @terminal "('terminated', 'failed')"

  def up do
    repo().query!("SET LOCAL lock_timeout = '10s'")

    %{rows: orphans} =
      repo().query!("""
      SELECT id::text FROM sandboxes
       WHERE status NOT IN #{@terminal} AND workspace_id IS NULL AND user_id IS NULL
       ORDER BY id
      """)

    %{rows: [[workspaces, sandboxes, conversations]]} =
      repo().query!("""
      WITH live AS (
        SELECT s.id AS sandbox_id,
               gen_random_uuid() AS workspace_id,
               s.user_id, s.environment_id, s.vault_id, s.provider, s.status, s.inserted_at
          FROM sandboxes s
         WHERE s.status NOT IN #{@terminal}
           AND s.workspace_id IS NULL
           AND s.user_id IS NOT NULL
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
           SET workspace_id = live.workspace_id
          FROM live
         WHERE c.sandbox_id = live.sandbox_id
           AND c.workspace_id IS NULL
        RETURNING c.id
      )
      SELECT (SELECT count(*) FROM ws), (SELECT count(*) FROM sb), (SELECT count(*) FROM cv)
      """)

    Logger.info(
      "migration: #{workspaces} implicit workspace(s) for #{sandboxes} live sandbox(es), " <>
        "#{conversations} conversation(s) pointed at them"
    )

    if orphans != [] do
      Logger.warning(
        "migration: #{length(orphans)} live sandbox(es) with no user left without a workspace: " <>
          Enum.map_join(orphans, ", ", &List.first/1)
      )
    end
  end

  def down, do: :ok
end
