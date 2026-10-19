defmodule Fountain.Repo.Migrations.CreateWorkspaceSetupLogs do
  @moduledoc """
  The last setup's output of each explicit workspace (#3009): one row per
  workspace, replaced by each setup (create, retry, a rebuild after a loss,
  the rebuild verb). Kept in the database rather than on the machine, so it
  outlives the machine it describes: a lost or destroyed machine's setup is
  still readable. Bounded and redacted by the writer
  (`Fountain.Workspaces.SetupOutput`).

  Additive: the previous release neither reads nor writes it, and `down`
  drops it.
  """
  use Ecto.Migration

  def change do
    create table(:workspace_setup_logs, primary_key: false) do
      add :workspace_id,
          references(:workspaces, type: :binary_id, on_delete: :delete_all),
          primary_key: true

      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false
      # The machine this setup built. No foreign key: the row describes the
      # setup, and outlives whatever happens to that sandbox's row.
      add :sandbox_id, :binary_id, null: false
      add :status, :string, null: false
      add :step, :string
      add :steps, {:array, :map}, null: false, default: []
      add :started_at, :utc_datetime_usec, null: false
      add :finished_at, :utc_datetime_usec

      timestamps(type: :utc_datetime)
    end

    create index(:workspace_setup_logs, [:user_id])
  end
end
