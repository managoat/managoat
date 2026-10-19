defmodule Fountain.AddMachineLeaseToWorkspacesMigrationTest do
  @moduledoc """
  `20261018210000_add_machine_lease_to_workspaces` (ADR 0097, step 3a): the
  backfill run again, an ownerless live sandbox included, stale conversation
  pointers repointed, and every live sandbox's in-flight stamp carried to its
  workspace. The columns themselves are exercised by every suite that runs
  against the migrated schema.

  The sandbox's own lease columns, which this migration carries from, are
  dropped by `20261019150100_drop_sandbox_lease_columns` (#3000). So the
  test stands the schema where a release before step 3a left it, with that
  drop's `down/0`, writes the rows an earlier release left, runs this
  migration down and up, and then the drop again: what an upgrade from a
  release before 3a straight to this one runs.
  """

  # The test runs migrations down and up inside its own SQL sandbox
  # transaction, which takes `ACCESS EXCLUSIVE` on two tables until it rolls
  # back, so it runs alone.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo.Migrations.AddMachineLeaseToWorkspaces, as: Migration
  alias Fountain.Repo.Migrations.DropSandboxLeaseColumns, as: Drop
  alias Fountain.Workspaces.Workspace

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261018210000_add_machine_lease_to_workspaces.exs",
      __DIR__
    )
  end

  unless Code.ensure_loaded?(Drop) do
    Code.require_file(
      "../../priv/repo/migrations/20261019150100_drop_sandbox_lease_columns.exs",
      __DIR__
    )
  end

  defp run(version, module, direction) do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        version,
        module,
        :forward,
        direction,
        direction,
        log: false
      )
    end)
  end

  # The sandbox's lease columns back, as a release before #3000 has them.
  setup do
    run(20_261_019_150_100, Drop, :down)
    :ok
  end

  # Down, then up, then the drop: what a deploy of this release does to rows
  # an earlier release left, run against the real `up/0`s.
  defp migrate do
    run(20_261_018_210_000, Migration, :down)
    run(20_261_018_210_000, Migration, :up)
  end

  defp migrate_and_drop do
    migrate()
    run(20_261_019_150_100, Drop, :up)
  end

  # Written as an earlier release wrote them: on the sandbox's own row.
  defp stamp(%Sandbox{id: id} = sandbox, attrs) do
    attrs = Map.new(attrs)

    Repo.query!(
      """
      UPDATE sandboxes
         SET transition = $1, transition_reason = $2,
             lease_epoch = $3, lease_node = $4
       WHERE id = $5
      """,
      [
        attrs[:transition],
        attrs[:transition_reason],
        attrs[:lease_epoch] || 0,
        attrs[:lease_node],
        Ecto.UUID.dump!(id)
      ]
    )

    sandbox
  end

  test "the fill, the repoint and the carry, from the rows an earlier release left" do
    user = insert_verified_user()

    # Made by a release before ADR 0097: live, no workspace, and a destroy
    # fenced on it there.
    bare =
      insert_sandbox(user_id: user.id, workspace_id: nil, status: "ready")
      |> stamp(transition: "destroying", transition_reason: "terminated", lease_epoch: 5)

    conv = insert_conversation(user_id: user.id, sandbox: bare)

    # Ownerless: account deletion nilified it after its destroy raised.
    orphan = insert_sandbox(user_id: user.id, workspace_id: nil, status: "suspended")
    Repo.update_all(from(s in Sandbox, where: s.id == ^orphan.id), set: [user_id: nil])

    # Has a workspace, and a resume an earlier boot left unfinished.
    ws = insert_workspace(user_id: user.id)

    resuming =
      insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "suspended")
      |> stamp(transition: "resuming", lease_epoch: 2, lease_node: "0000/<0.1.0>")

    terminal = insert_sandbox(user_id: user.id, workspace_id: nil, status: "terminated")

    migrate_and_drop()

    bare_ws = Repo.get!(Workspace, Repo.reload!(bare).workspace_id)

    assert %Workspace{
             implicit: true,
             user_id: user_id,
             transition: "destroying",
             transition_reason: "terminated",
             lease_epoch: 5
           } = bare_ws

    assert user_id == user.id
    assert Repo.get!(Conversation, conv.id).workspace_id == bare_ws.id

    assert %Workspace{user_id: nil} = Repo.get!(Workspace, Repo.reload!(orphan).workspace_id)

    assert %Workspace{transition: "resuming", lease_epoch: 2, lease_node: "0000/<0.1.0>"} =
             Repo.reload!(ws)

    assert Fountain.Machines.Lease.get(resuming.id).transition == "resuming"
    assert Repo.reload!(terminal).workspace_id == nil
  end

  test "is idempotent" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, workspace_id: nil, status: "ready")

    migrate()
    first = Repo.reload!(sandbox).workspace_id
    migrate()
    run(20_261_019_150_100, Drop, :up)

    assert Repo.reload!(sandbox).workspace_id == first
    assert Repo.aggregate(from(w in Workspace, where: w.user_id == ^user.id), :count) == 1
  end
end
