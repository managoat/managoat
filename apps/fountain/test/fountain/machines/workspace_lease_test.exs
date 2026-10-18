defmodule Fountain.Machines.WorkspaceLeaseTest do
  @moduledoc """
  ADR 0097, step 3b: the lease is the workspace's, and every write of it is
  copied onto the workspace's live sandbox (and the sandbox written) in the
  same transaction, so a rollback to the release before, which reads only
  the sandbox's columns, finds the machine as this one left it. Also the
  sandbox with no workspace, which nothing owns.
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
    assert lease_of(ctx.sandbox) == lease_of(ctx.ws)
    lease_of(ctx.ws)
  end

  test "the lease is taken and written on the workspace, and copied as it commits", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    assert %{lease_epoch: 1, lease_node: holder} = assert_agree(ctx)
    assert holder == Lease.holder(self())

    assert {:ok, %Sandbox{transition: "parking", lease_epoch: 1}} =
             Lease.cas_update(ctx.sandbox.id, 1, transition: "parking", transition_reason: "idle")

    assert %{transition: "parking", transition_reason: "idle"} = assert_agree(ctx)

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1,
        status: "suspended",
        transition: nil,
        transition_reason: nil
      )

    assert %{transition: nil} = assert_agree(ctx)
    assert Repo.get!(Sandbox, ctx.sandbox.id).status == "suspended"

    :ok = Lease.release(ctx.sandbox.id, 1)
    assert %{lease_epoch: 1, lease_node: nil} = assert_agree(ctx)
  end

  test "the workspace is the one read: a stamp on the sandbox's copy alone is not the lease",
       ctx do
    # What a release before this one would have written: its own columns.
    ctx.sandbox
    |> Ecto.Changeset.change(lease_epoch: 7, transition: "destroying")
    |> Repo.update!()

    assert %Sandbox{transition: nil, lease_epoch: 0} = Lease.get(ctx.sandbox.id)
    assert {:ok, 1} = Lease.claim(ctx.sandbox.id)
  end

  test "a refused write copies nothing", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    :ok = Lease.release(ctx.sandbox.id, 1)
    {:ok, 2} = Lease.claim(ctx.sandbox.id)

    # A sentinel only the sandbox's copy carries: a copy run on the refusal
    # would overwrite it.
    ctx.sandbox |> Ecto.Changeset.change(transition_reason: "sentinel") |> Repo.update!()

    assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, transition: "parking")
    assert {:error, :lost} = Lease.release(ctx.sandbox.id, 1)
    assert %{transition_reason: "sentinel"} = lease_of(ctx.sandbox)
    assert %{lease_epoch: 2, transition_reason: nil} = lease_of(ctx.ws)
  end

  test "the destroying stamp rides through a write that would clear it, on both rows", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    {:ok, _} =
      Lease.cas_update(ctx.sandbox.id, 1, transition: "destroying", transition_reason: "idle")

    assert {:ok, %Sandbox{status: "suspended", transition: "destroying"}} =
             Lease.cas_update(ctx.sandbox.id, 1,
               status: "suspended",
               transition: nil,
               transition_reason: nil
             )

    assert %{transition: "destroying", transition_reason: "idle"} = assert_agree(ctx)
  end

  test "a nested write rolls back with its caller, and commits with it", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)

    {:error, :refused} =
      Repo.transaction(fn ->
        {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, [transition: "resuming"], nest: true)
        Repo.rollback(:refused)
      end)

    assert %{transition: nil} = assert_agree(ctx)

    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, [transition: "resuming"], nest: true)
      end)

    assert %{transition: "resuming"} = assert_agree(ctx)
  end

  test "the teardown fence's stamp is on the workspace, copied, and moves updated_at", ctx do
    past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id), set: [updated_at: past])

    {:ok, %Sandbox{transition: "destroying"}} =
      Lifecycle.fence_sandbox_for_teardown(Lease.get(ctx.sandbox.id),
        actor: "api",
        reason: "conversation_terminated",
        transition_reason: :terminated
      )

    assert %{transition: "destroying", transition_reason: "terminated"} = assert_agree(ctx)
    assert DateTime.compare(Repo.get!(Sandbox, ctx.sandbox.id).updated_at, past) == :gt
  end

  test "registration's clearing of an abandoned stamp is on the workspace, and copied", ctx do
    put_lease(ctx.sandbox, transition: "parking")

    {:ok, 1} = Repo.transaction(fn -> Binding.clear_abandoned_transition(ctx.sandbox.id) end)

    assert %{transition: nil} = assert_agree(ctx)
  end

  test "the boot sweep clears the workspaces and copies onto their live sandboxes", ctx do
    other_ws = insert_workspace(user_id: ctx.user.id)

    resuming =
      insert_sandbox(user_id: ctx.user.id, workspace_id: other_ws.id, status: "suspended")

    put_lease(ctx.sandbox, lease_epoch: 4, lease_node: dead_lease_holder(), transition: "parking")
    put_lease(resuming, lease_node: dead_lease_holder(), transition: "resuming")

    assert Lease.sweep_boot() >= 2

    assert %{lease_node: nil, transition: nil, lease_epoch: 4} = assert_agree(ctx)
    assert lease_of(resuming) == lease_of(other_ws)
    assert %{lease_node: nil, transition: "resuming"} = lease_of(other_ws)
  end

  test "a retired sandbox's write does not reach a live sibling's copy", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, status: "terminated")
    :ok = Lease.release(ctx.sandbox.id, 1)

    live = insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.ws.id, status: "ready")
    {:ok, 2} = Lease.claim(live.id)

    assert %{lease_epoch: 2} = lease_of(live)
    assert %{lease_node: nil, lease_epoch: 1} = lease_of(ctx.sandbox)
    :ok = Lease.release(live.id, 2)
  end

  describe "keyed by workspace" do
    test "the owner, the advisory lock and the lease are the workspace's", ctx do
      assert Fountain.Machines.Machine.owner_key(ctx.sandbox.id) == ctx.ws.id

      assert Fountain.Conversations.sandbox_lock_key(ctx.sandbox.id) ==
               :erlang.phash2(ctx.ws.id)

      {:ok, pid} = Fountain.Machines.Machine.ensure_started(ctx.sandbox.id)
      assert [{^pid, _}] = Registry.lookup(Fountain.MachineRegistry, ctx.ws.id)
      DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)
    end

    test "every sandbox a workspace has shares one owner, one lock and one lease", ctx do
      # Retired, then a successor in the same workspace: what a rebuild after
      # a loss will make. One holder at a time across the two.
      {:ok, 1} = Lease.claim(ctx.sandbox.id)
      {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, status: "terminated")
      next = insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.ws.id, status: "pending")

      assert {:error, {:held, _}} = Lease.claim(next.id)

      :ok = Lease.release(ctx.sandbox.id, 1)
      assert {:ok, 2} = Lease.claim(next.id)

      assert Fountain.Machines.Machine.owner_key(next.id) ==
               Fountain.Machines.Machine.owner_key(ctx.sandbox.id)

      assert Fountain.Conversations.sandbox_lock_key(next.id) ==
               Fountain.Conversations.sandbox_lock_key(ctx.sandbox.id)
    end

    test "a stale epoch from before a claim on the workspace writes nothing", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id)
      :ok = Lease.release(ctx.sandbox.id, 1)
      {:ok, 2} = Lease.claim(ctx.sandbox.id)

      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, status: "failed")
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "ready"
    end

    test "the fleet count reads a resume and a destroy off the workspace", ctx do
      count = fn -> Fountain.Quotas.fleet_count(provider: "sprites") end
      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended")
      before = count.()

      # On the sandbox's copy alone, as a release before this one would leave
      # it, it is not a reservation.
      parked
      |> Ecto.Changeset.change(transition: "resuming", lease_node: Lease.holder(self()))
      |> Repo.update!()

      assert count.() == before

      put_lease(parked.id, transition: "resuming", lease_node: Lease.holder(self()))
      assert count.() == before + 1
    end
  end

  describe "a sandbox with no workspace" do
    setup ctx do
      %{bare: insert_sandbox(user_id: ctx.user.id, workspace_id: nil, status: "terminated")}
    end

    test "has no owner: a claim is refused, and its lease reads as nobody's", ctx do
      ctx.bare |> Ecto.Changeset.change(transition: "destroying") |> Repo.update!()

      assert {:error, :no_workspace} = Lease.claim(ctx.bare.id)
      assert %Sandbox{transition: nil, lease_node: nil, lease_epoch: 0} = Lease.get(ctx.bare.id)
      assert {:terminal, %Sandbox{}} = Lease.unowned(ctx.bare.id)
    end

    test "a live one is refused as busy, and said loudly", ctx do
      live = insert_sandbox(user_id: ctx.user.id, workspace_id: nil, status: "ready")

      log =
        ExUnit.CaptureLog.capture_log(fn -> assert :live = Lease.unowned(live.id) end)

      assert log =~ "no workspace"
    end

    test "the protocols answer it as the terminal row it is", ctx do
      assert {:ok, :already_terminal} =
               Fountain.Machines.Machine.destroy(ctx.bare.id, actor: "api", reason: :terminated)

      assert {:ok, :already_terminal} =
               Fountain.Machines.Machine.park(ctx.bare.id, actor: "api", reason: :idle)

      assert {:ok, :already_terminal} =
               Fountain.Machines.Machine.ensure_up(ctx.bare.id, actor: "api")
    end
  end
end
