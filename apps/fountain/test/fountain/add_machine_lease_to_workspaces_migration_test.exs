defmodule Fountain.AddMachineLeaseToWorkspacesMigrationTest do
  @moduledoc """
  `20261018210000_add_machine_lease_to_workspaces` (ADR 0097, step 3a): the
  backfill run again, an ownerless live sandbox included, stale conversation
  pointers repointed, and every live sandbox's in-flight stamp carried to its
  workspace. The columns themselves are exercised by every suite that runs
  against the migrated schema.
  """

  # The test runs the migration down and up again inside its own SQL sandbox
  # transaction, which takes `ACCESS EXCLUSIVE` on two tables until it rolls
  # back, so it runs alone.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo.Migrations.AddMachineLeaseToWorkspaces, as: Migration
  alias Fountain.Workspaces.Workspace

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261018210000_add_machine_lease_to_workspaces.exs",
      __DIR__
    )
  end

  defp run(direction) do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_018_210_000,
        Migration,
        :forward,
        direction,
        direction,
        log: false
      )
    end)
  end

  # Down, then up: what a deploy of this release does to rows an earlier
  # release left, run against the real `up/0`.
  defp migrate do
    run(:down)
    run(:up)
  end

  defp stamp(%Sandbox{} = sandbox, attrs),
    do: sandbox |> Ecto.Changeset.change(attrs) |> Repo.update!()

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

    migrate()

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

    assert Repo.reload!(resuming).transition == "resuming"
    assert Repo.reload!(terminal).workspace_id == nil
  end

  test "is idempotent" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, workspace_id: nil, status: "ready")

    migrate()
    first = Repo.reload!(sandbox).workspace_id
    migrate()

    assert Repo.reload!(sandbox).workspace_id == first
    assert Repo.aggregate(from(w in Workspace, where: w.user_id == ^user.id), :count) == 1
  end
end
