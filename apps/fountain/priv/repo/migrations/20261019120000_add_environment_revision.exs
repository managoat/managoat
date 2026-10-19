defmodule Fountain.Repo.Migrations.AddEnvironmentRevision do
  @moduledoc """
  Which version of its environment a sandbox was built from (#2987).

    * `environments.revision`, a UUID that a trigger replaces on every update
      that changes a provision-time field: `repositories`, `packages`,
      `setup_script`, `setup_timeout_seconds`, `env_vars`, `networking_type`
      or `networking_config`. `name`, `metadata` and the secrets (their own
      table, live through the broker) leave it alone. The model is
      `inference_revision`, written by `fountain_lock_inference_source()`.
      Existing rows each get a fresh one from the column's default.
    * `sandboxes.built_from_revision`, the environment's `revision` the
      machine was provisioned from, and `sandboxes.built_from_digests`, a
      keyed digest of each provision-time field as it was then
      (`Fountain.Workspaces.Staleness`). No value is stored. Both are null on
      a sandbox built before this release, or from no environment.

  A trigger rather than the context, so every writer moves the revision: the
  API, `managoat apply` and anything later that updates the row.

  The column's default is volatile, so adding it rewrites `environments`
  under an exclusive lock: a small table (a few rows per account), and the
  ten-second `lock_timeout` makes a busy one fail the migration rather than
  queue behind it.

  The previous release never reads or writes these columns, so it runs
  against this schema; `down/0` drops them.
  """
  use Ecto.Migration

  @fields ~w(repositories packages setup_script setup_timeout_seconds env_vars
             networking_type networking_config)

  def up do
    execute "SET LOCAL lock_timeout = '10s'"

    alter table(:environments) do
      add :revision, :uuid, null: false, default: fragment("gen_random_uuid()")
    end

    alter table(:sandboxes) do
      add :built_from_revision, :uuid
      add :built_from_digests, :map
    end

    changed =
      Enum.map_join(@fields, " OR ", &"NEW.#{&1} IS DISTINCT FROM OLD.#{&1}")

    execute """
    CREATE OR REPLACE FUNCTION fountain_environment_revision() RETURNS trigger AS $$
    BEGIN
      IF #{changed} THEN
        NEW.revision := gen_random_uuid();
      ELSE
        NEW.revision := OLD.revision;
      END IF;
      RETURN NEW;
    END;
    $$ LANGUAGE plpgsql
    """

    execute """
    CREATE TRIGGER environment_revision BEFORE UPDATE ON environments
    FOR EACH ROW EXECUTE FUNCTION fountain_environment_revision()
    """
  end

  def down do
    execute "SET LOCAL lock_timeout = '10s'"
    execute "DROP TRIGGER IF EXISTS environment_revision ON environments"
    execute "DROP FUNCTION IF EXISTS fountain_environment_revision()"

    alter table(:sandboxes) do
      remove :built_from_digests
      remove :built_from_revision
    end

    alter table(:environments) do
      remove :revision
    end
  end
end
