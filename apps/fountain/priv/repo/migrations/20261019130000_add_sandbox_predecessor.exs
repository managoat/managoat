defmodule Fountain.Repo.Migrations.AddSandboxPredecessor do
  @moduledoc """
  `sandboxes.predecessor_id`: the sandbox a rebuild replaced with this one
  (`Fountain.Machines.Lease.succeed/3`), so a rebuild can tell that the row it
  waited to rebuild from has been rebuilt from already (#3013). A retry of a
  failed workspace and a prompt into it then set it up once. Timestamps are
  to the second, which cannot order a row and its successor made in the same
  second.

  Nullable, no foreign key: the predecessor may be deleted with its
  workspace's other ended rows, and the column only ever answers "was this
  row succeeded". Null on every row made before this release, and on a
  workspace's first row. Indexed for that lookup.

  The previous release never reads or writes it, so it runs against this
  schema; `down/0` drops it.
  """
  use Ecto.Migration

  def change do
    alter table(:sandboxes) do
      add :predecessor_id, :binary_id
    end

    create index(:sandboxes, [:predecessor_id], where: "predecessor_id IS NOT NULL")
  end
end
