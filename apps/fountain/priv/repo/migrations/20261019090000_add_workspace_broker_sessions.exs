defmodule Fountain.Repo.Migrations.AddWorkspaceBrokerSessions do
  @moduledoc """
  A broker session may belong to a workspace instead of a conversation
  (ADR 0097, step 5): the session an explicit workspace's provision on create
  runs its packages, clones and setup script under, before any conversation
  exists.

  `conversation_id` becomes nullable and `workspace_id` is added, cascading
  with its workspace, so deleting a workspace takes its session with it. The
  `broker_session_one_owner` check says a session has exactly one of the
  two, the shape `20261018140000` used for build sessions.

  The previous release reads `conversation_id` only and never writes a
  session without one, so it can run against this schema; a workspace
  session it meets resolves to the rules stored in it, as any token does.
  `down/0` deletes the workspace sessions first, so `NOT NULL` can return.
  """
  use Ecto.Migration

  def up do
    execute "SET LOCAL lock_timeout = '10s'"

    alter table(:broker_sessions) do
      modify :conversation_id, :binary_id, null: true

      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all)
    end

    create index(:broker_sessions, [:workspace_id], where: "workspace_id IS NOT NULL")

    create constraint(:broker_sessions, :broker_session_one_owner,
             check: "num_nonnulls(conversation_id, workspace_id) = 1"
           )
  end

  def down do
    execute "SET LOCAL lock_timeout = '10s'"
    execute "DELETE FROM broker_sessions WHERE workspace_id IS NOT NULL"

    drop constraint(:broker_sessions, :broker_session_one_owner)
    drop index(:broker_sessions, [:workspace_id])

    alter table(:broker_sessions) do
      remove :workspace_id
      modify :conversation_id, :binary_id, null: false
    end
  end
end
