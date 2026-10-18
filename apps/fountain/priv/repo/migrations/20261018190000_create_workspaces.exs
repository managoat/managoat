defmodule Fountain.Repo.Migrations.CreateWorkspaces do
  use Ecto.Migration

  # ADR 0097, step 2: the `workspaces` table and the two pointers to it. Nothing
  # reads them yet; `20261018190100` backfills the live sandboxes.
  #
  # The lease columns (`lease_epoch`, `lease_node`, `transition`,
  # `transition_reason`) are not here. They move from `sandboxes` in step 3,
  # with the migration that carries the in-flight stamps.
  #
  # Foreign keys:
  #
  #   * `user_id` cascades: account deletion deletes the account's workspaces
  #     (ADR 0097, Lifecycle).
  #   * `environment_id` and `vault_id` nilify, as `sandboxes`' and
  #     `conversations`' own do. That is the ADR's rule for an implicit
  #     workspace, and every workspace is implicit until `/api/workspaces`
  #     ships; the 409 for an explicit one is enforced in the context then.
  #   * `sandboxes.workspace_id` and `conversations.workspace_id` nilify, so a
  #     sandbox row outlives its workspace as history, as it outlives its user.
  #
  # `sandboxes_live_workspace_index` is the ADR's "at most one non-terminal
  # sandbox per workspace". The statuses are the terminal pair every other
  # live-row index here uses (`sandboxes_live_machine_name_index`).
  #
  # Reversible: `down` drops the columns, the indexes and the table, and the
  # previous release reads none of them. `up` and `down` rather than `change`
  # so the lock timeout comes first in both directions (a `change` replays its
  # commands in reverse on rollback).
  #
  # Both fail fast rather than wait behind a stray session's lock: an `ALTER`
  # that waits queues every later reader of `sandboxes` and `conversations`
  # behind it, which is how a deploy took prod down on 2026-10-15. A refused
  # boot retries; a wedged one serves nothing.
  def up do
    execute "SET LOCAL lock_timeout = '10s'"

    create table(:workspaces, primary_key: false) do
      add :id, :binary_id, primary_key: true
      add :user_id, references(:users, type: :binary_id, on_delete: :delete_all), null: false

      add :environment_id,
          references(:environments, type: :binary_id, on_delete: :nilify_all)

      add :vault_id, references(:vaults, type: :binary_id, on_delete: :nilify_all)
      add :provider, :string, null: false
      add :name, :string
      add :implicit, :boolean, null: false, default: false
      add :status, :string, null: false, default: "provisioning"
      add :error, :text

      timestamps(type: :utc_datetime)
    end

    create index(:workspaces, [:user_id])
    create index(:workspaces, [:environment_id])
    create index(:workspaces, [:vault_id])

    create constraint(:workspaces, :workspaces_status_check,
             check: "status IN ('provisioning', 'ready', 'failed')"
           )

    # An explicit workspace is named by its creator; an implicit one has no
    # name of its own.
    create constraint(:workspaces, :workspaces_explicit_named_check,
             check: "implicit OR name IS NOT NULL"
           )

    alter table(:sandboxes) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end

    alter table(:conversations) do
      add :workspace_id, references(:workspaces, type: :binary_id, on_delete: :nilify_all)
    end

    create unique_index(:sandboxes, [:workspace_id],
             name: :sandboxes_live_workspace_index,
             where: "status NOT IN ('terminated', 'failed')"
           )

    # The partial index above covers live rows only; the nilify on a
    # workspace's delete also has to find the terminal ones.
    create index(:sandboxes, [:workspace_id])
    create index(:conversations, [:workspace_id])
  end

  def down do
    execute "SET LOCAL lock_timeout = '10s'"

    drop index(:conversations, [:workspace_id])
    drop index(:sandboxes, [:workspace_id])
    drop index(:sandboxes, [:workspace_id], name: :sandboxes_live_workspace_index)

    alter table(:conversations) do
      remove :workspace_id
    end

    alter table(:sandboxes) do
      remove :workspace_id
    end

    drop table(:workspaces)
  end
end
