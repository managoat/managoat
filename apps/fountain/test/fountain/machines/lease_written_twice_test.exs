defmodule Fountain.Machines.LeaseWrittenTwiceTest do
  @moduledoc """
  ADR 0097, step 3a: every write of a sandbox's lease columns is copied onto
  its workspace in the same transaction, so the two agree at every commit and
  step 3b can read the workspace's. The sandbox's columns are still the ones
  this release reads; these tests only pin the copy.
  """
  use Fountain.DataCase, async: true

  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Lease
  alias Fountain.Workspaces.Workspace

  @columns [:lease_epoch, :lease_node, :transition, :transition_reason]

  setup do
    user = insert_verified_user()
    ws = insert_workspace(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "ready")
    %{user: user, ws: ws, sandbox: sandbox}
  end

  defp lease_of(%Sandbox{id: id}), do: Repo.get!(Sandbox, id) |> Map.take(@columns)
  defp lease_of(%Workspace{id: id}), do: Repo.get!(Workspace, id) |> Map.take(@columns)

  defp assert_agree(ctx) do
    assert lease_of(ctx.ws) == lease_of(ctx.sandbox)
    lease_of(ctx.ws)
  end

  test "a claim, a state write and a release are copied as they commit", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    assert %{lease_epoch: 1, lease_node: holder} = assert_agree(ctx)
    assert holder == Lease.holder(self())

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1, transition: "parking", transition_reason: "idle")

    assert %{transition: "parking", transition_reason: "idle"} = assert_agree(ctx)

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1,
        status: "suspended",
        transition: nil,
        transition_reason: nil
      )

    assert %{transition: nil} = assert_agree(ctx)

    :ok = Lease.release(ctx.sandbox.id, 1)
    assert %{lease_epoch: 1, lease_node: nil} = assert_agree(ctx)
  end

  test "a refused write copies nothing", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    :ok = Lease.release(ctx.sandbox.id, 1)
    {:ok, 2} = Lease.claim(ctx.sandbox.id)

    # A sentinel only the workspace carries: a copy run on the refusal would
    # overwrite it with the sandbox's nil.
    ctx.ws |> Ecto.Changeset.change(transition_reason: "sentinel") |> Repo.update!()

    assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, transition: "parking")
    assert {:error, :lost} = Lease.release(ctx.sandbox.id, 1)
    assert %{lease_epoch: 2, transition_reason: "sentinel"} = lease_of(ctx.ws)
  end

  test "a nested write that commits with its caller is copied", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, [transition: "resuming"], nest: true)
      end)

    assert %{transition: "resuming"} = assert_agree(ctx)
  end

  test "a superseding claim is copied", ctx do
    holder = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, 1} = Lease.claim(ctx.sandbox.id, holder: holder)
    {:ok, 2} = Lease.claim(ctx.sandbox.id, supersede: holder)

    assert %{lease_epoch: 2, lease_node: node} = assert_agree(ctx)
    assert node == Lease.holder(self())
    send(holder, :stop)
  end

  test "a retired sandbox is copied while it is its workspace's only one, not beside a live one",
       ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, status: "terminated")
    :ok = Lease.release(ctx.sandbox.id, 1)
    assert %{lease_node: nil} = assert_agree(ctx)

    # A later release may rebuild a lost machine in the same workspace. A
    # write to the retired row must then leave the live one's lease alone.
    live = insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.ws.id, status: "ready")
    {:ok, epoch} = Lease.claim(live.id)
    {:ok, _} = Lease.cas_update(live.id, epoch, transition: "parking")

    ctx.sandbox
    |> Ecto.Changeset.change(lease_node: nil, transition: nil)
    |> Repo.update!()

    :ok = Lease.copy_to_workspace(ctx.sandbox.id)

    assert lease_of(ctx.ws) == lease_of(live)
    assert %{transition: "parking"} = lease_of(ctx.ws)
  end

  test "the destroying stamp rides through a write that would clear it, on both rows", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1, transition: "destroying", transition_reason: "idle")

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1,
        status: "suspended",
        transition: nil,
        transition_reason: nil
      )

    assert %{transition: "destroying", transition_reason: "idle"} = assert_agree(ctx)
  end

  test "a nested write that rolls back with its caller leaves neither row written", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    {:error, :refused} =
      Repo.transaction(fn ->
        {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, [transition: "resuming"], nest: true)
        Repo.rollback(:refused)
      end)

    assert %{transition: nil} = assert_agree(ctx)
  end

  test "the teardown fence's stamp is copied in its own transaction", ctx do
    {:ok, _} =
      Lifecycle.fence_sandbox_for_teardown(Repo.get!(Sandbox, ctx.sandbox.id),
        actor: "api",
        reason: "conversation_terminated",
        transition_reason: :terminated
      )

    assert %{transition: "destroying", transition_reason: "terminated"} = assert_agree(ctx)
  end

  test "registration's clearing of an abandoned stamp is copied", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, transition: "parking")
    :ok = Lease.release(ctx.sandbox.id, 1)

    {:ok, 1} =
      Repo.transaction(fn -> Binding.clear_abandoned_transition(ctx.sandbox.id) end)

    assert %{transition: nil} = assert_agree(ctx)
  end

  test "the boot sweep clears a retired sandbox's dead holder off its workspace too", ctx do
    ctx.sandbox
    |> Ecto.Changeset.change(
      status: "terminated",
      lease_epoch: 3,
      lease_node: "0000000000000000/<0.1.0>"
    )
    |> Repo.update!()

    :ok = Lease.copy_to_workspace(ctx.sandbox.id)
    Lease.sweep_boot()

    assert %{lease_node: nil, lease_epoch: 3} = assert_agree(ctx)
  end

  test "the boot sweep's clearing is copied, and the durable stamps stay on both", ctx do
    other_ws = insert_workspace(user_id: ctx.user.id)

    resuming =
      insert_sandbox(user_id: ctx.user.id, workspace_id: other_ws.id, status: "suspended")

    for {sandbox, transition} <- [{ctx.sandbox, "parking"}, {resuming, "resuming"}] do
      sandbox
      |> Ecto.Changeset.change(
        lease_epoch: 4,
        lease_node: "0000000000000000/<0.1.0>",
        transition: transition
      )
      |> Repo.update!()

      :ok = Lease.copy_to_workspace(sandbox.id)
    end

    Lease.sweep_boot()

    assert %{lease_node: nil, transition: nil, lease_epoch: 4} = assert_agree(ctx)

    assert lease_of(other_ws) == lease_of(resuming)
    assert %{lease_node: nil, transition: "resuming"} = lease_of(other_ws)
  end

  test "the copy never moves a workspace's epoch backwards", ctx do
    ctx.ws |> Ecto.Changeset.change(lease_epoch: 10) |> Repo.update!()

    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    assert %{lease_epoch: 10, lease_node: holder} = lease_of(ctx.ws)
    assert holder == Lease.holder(self())
  end

  test "a sandbox with no workspace is written as before", ctx do
    bare = insert_sandbox(user_id: ctx.user.id, status: "ready")

    {:ok, 1} = Lease.claim(bare.id)
    {:ok, _} = Lease.cas_update(bare.id, 1, transition: "parking")
    :ok = Lease.release(bare.id, 1)

    assert %{lease_epoch: 1, transition: "parking"} = lease_of(bare)
    assert %{lease_epoch: 0, transition: nil} = lease_of(ctx.ws)
  end
end
