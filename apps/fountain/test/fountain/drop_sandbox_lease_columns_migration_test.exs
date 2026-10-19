defmodule Fountain.DropSandboxLeaseColumnsMigrationTest do
  @moduledoc """
  `20261019150100_drop_sandbox_lease_columns` (#3000): `down/0` gives the
  sandbox its four lease columns back as copies of its workspace's, which a
  release with ADR 0097 step 3b needs so its boot carry is a no-op; `up/0`
  carries a stamp a release before 3b wrote on the sandbox row onto the
  workspace once, then drops the columns.
  """

  # Runs the migration down and up inside its own SQL sandbox transaction,
  # which takes `ACCESS EXCLUSIVE` on `sandboxes` until it rolls back.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Repo.Migrations.DropSandboxLeaseColumns, as: Migration
  alias Fountain.Workspaces.Workspace

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261019150100_drop_sandbox_lease_columns.exs",
      __DIR__
    )
  end

  defp run(direction) do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_019_150_100,
        Migration,
        :forward,
        direction,
        direction,
        log: false
      )
    end)
  end

  defp columns_of(sandbox_id) do
    %{rows: [row]} =
      Repo.query!(
        "SELECT lease_epoch, lease_node, transition, transition_reason FROM sandboxes WHERE id = $1",
        [Ecto.UUID.dump!(sandbox_id)]
      )

    row
  end

  defp sandbox_columns do
    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
       WHERE table_name = 'sandboxes'
         AND column_name IN ('lease_epoch', 'lease_node', 'transition', 'transition_reason')
      """)

    List.flatten(rows)
  end

  test "down copies each workspace's lease onto its live sandbox, and up drops it again" do
    live = insert_sandbox(status: "ready")

    put_lease(live,
      lease_epoch: 7,
      lease_node: "0000/<0.1.0>",
      transition: "destroying",
      transition_reason: "terminated"
    )

    retired = insert_sandbox(status: "terminated")
    put_lease(retired, lease_epoch: 3, transition: "destroying", transition_reason: "idle")

    run(:down)

    assert columns_of(live.id) == [7, "0000/<0.1.0>", "destroying", "terminated"]
    # A retired row is not copied onto, as step 3b's boot sweep did not.
    assert columns_of(retired.id) == [0, nil, nil, nil]

    run(:up)

    assert sandbox_columns() == []
    # Nothing the copy agreed with is carried back as a change.
    assert %Workspace{lease_epoch: 7, transition: "destroying", transition_reason: "terminated"} =
             Repo.get!(Workspace, live.workspace_id)
  end

  test "up carries a stamp a release before 3b wrote on the sandbox row, the epoch never lowered" do
    stamped = insert_sandbox(status: "suspended")
    put_lease(stamped, lease_epoch: 4)
    lowered = insert_sandbox(status: "ready")
    put_lease(lowered, lease_epoch: 9)
    retired = insert_sandbox(status: "terminated")

    run(:down)

    for {sandbox, epoch, transition} <- [
          {stamped, 6, "resuming"},
          {lowered, 2, "destroying"},
          {retired, 8, "destroying"}
        ] do
      Repo.query!(
        "UPDATE sandboxes SET lease_epoch = $1, transition = $2, transition_reason = 'x' WHERE id = $3",
        [epoch, transition, Ecto.UUID.dump!(sandbox.id)]
      )
    end

    run(:up)

    assert %Workspace{lease_epoch: 6, transition: "resuming", transition_reason: "x"} =
             Repo.get!(Workspace, stamped.workspace_id)

    assert %Workspace{lease_epoch: 9, transition: "destroying"} =
             Repo.get!(Workspace, lowered.workspace_id)

    # A retired sandbox's leftovers are not intent.
    assert %Workspace{lease_epoch: 0, transition: nil} =
             Repo.get!(Workspace, retired.workspace_id)

    assert sandbox_columns() == []
  end

  test "up gives a live sandbox with no workspace one before it carries, so its stamp survives" do
    user = insert_verified_user()

    run(:down)

    # What a release before ADR 0097 leaves after a rollback: no workspace,
    # and a destroy fenced on the sandbox row.
    bare = insert_sandbox(user_id: user.id, workspace_id: nil, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: bare)

    Repo.query!(
      "UPDATE sandboxes SET lease_epoch = 5, transition = 'destroying', transition_reason = 'terminated' WHERE id = $1",
      [Ecto.UUID.dump!(bare.id)]
    )

    run(:up)

    workspace_id = Repo.reload!(bare).workspace_id
    assert workspace_id

    assert %Workspace{
             implicit: true,
             lease_epoch: 5,
             transition: "destroying",
             transition_reason: "terminated"
           } = Repo.get!(Workspace, workspace_id)

    assert Repo.get!(Fountain.Conversations.Conversation, conv.id).workspace_id == workspace_id
    assert %{transition: "destroying"} = Fountain.Machines.Lease.get(bare.id)
  end
end
