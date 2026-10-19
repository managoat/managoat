defmodule Fountain.Machines.WorkspaceLeaseTest do
  @moduledoc """
  ADR 0097, step 3b: the lease is the workspace's, and a sandbox read through
  `Machines.Lease` carries it in its four virtual fields. The sandbox's own
  copy was dropped (#3000). Also the sandbox with no workspace, which
  nothing owns.
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

  defp lease_of(%Sandbox{id: id}), do: Fountain.Machines.Lease.get(id) |> Map.take(@columns)
  defp lease_of(%Workspace{id: id}), do: Repo.get!(Workspace, id) |> Map.take(@columns)

  defp assert_agree(ctx) do
    assert lease_of(ctx.sandbox) == lease_of(ctx.ws)
    lease_of(ctx.ws)
  end

  test "the lease is taken and written on the workspace, and read with the sandbox", ctx do
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
    assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"

    :ok = Lease.release(ctx.sandbox.id, 1)
    assert %{lease_epoch: 1, lease_node: nil} = assert_agree(ctx)
  end

  test "the sandbox keeps no lease of its own: the four fields are virtual, the columns gone" do
    assert Enum.sort(Sandbox.__schema__(:virtual_fields)) ==
             Enum.sort([:lease_epoch, :lease_node, :transition, :transition_reason])

    %{rows: rows} =
      Repo.query!("""
      SELECT column_name FROM information_schema.columns
       WHERE table_name = 'sandboxes'
         AND column_name IN ('lease_epoch', 'lease_node', 'transition', 'transition_reason',
                             'applied_skills')
      """)

    assert rows == []
  end

  test "a row loaded without Lease reads no lease, so readers go through Lease", ctx do
    put_lease(ctx.sandbox, lease_epoch: 3, transition: "destroying")

    assert %Sandbox{transition: nil, lease_epoch: 0} = Repo.get!(Sandbox, ctx.sandbox.id)
    assert %Sandbox{transition: "destroying", lease_epoch: 3} = Lease.get(ctx.sandbox.id)
  end

  test "a refused write writes nothing", ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    :ok = Lease.release(ctx.sandbox.id, 1)
    {:ok, 2} = Lease.claim(ctx.sandbox.id)
    before = lease_of(ctx.ws)

    assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, transition: "parking")
    assert {:error, :lost} = Lease.release(ctx.sandbox.id, 1)
    assert lease_of(ctx.ws) == before
    assert %{lease_epoch: 2, transition: nil} = assert_agree(ctx)
  end

  test "the destroying stamp rides through a write that would clear it", ctx do
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

  test "the teardown fence's stamp is on the workspace, and moves updated_at", ctx do
    past = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)
    Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id), set: [updated_at: past])

    {:ok, %Sandbox{transition: "destroying"}} =
      Lifecycle.fence_sandbox_for_teardown(Lease.get(ctx.sandbox.id),
        actor: "api",
        reason: "conversation_terminated",
        transition_reason: :terminated
      )

    assert %{transition: "destroying", transition_reason: "terminated"} = assert_agree(ctx)
    assert DateTime.compare(Fountain.Machines.Lease.get(ctx.sandbox.id).updated_at, past) == :gt
  end

  test "registration's clearing of an abandoned stamp is on the workspace", ctx do
    put_lease(ctx.sandbox, transition: "parking")

    {:ok, 1} = Repo.transaction(fn -> Binding.clear_abandoned_transition(ctx.sandbox.id) end)

    assert %{transition: nil} = assert_agree(ctx)
  end

  test "the boot sweep clears the workspaces", ctx do
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

  test "a retired sandbox beside a live sibling reads the workspace's lease and no transition",
       ctx do
    {:ok, 1} = Lease.claim(ctx.sandbox.id)
    {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, status: "terminated")
    :ok = Lease.release(ctx.sandbox.id, 1)

    live = insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.ws.id, status: "ready")
    {:ok, 2} = Lease.claim(live.id)
    {:ok, _} = Lease.cas_update(live.id, 2, transition: "parking")

    assert %{lease_epoch: 2, transition: "parking"} = lease_of(live)
    assert %{lease_epoch: 2, transition: nil} = lease_of(ctx.sandbox)

    # A fence's stamp on the retired row has nowhere to go; a clear is a no-op.
    {:ok, 0} =
      Repo.transaction(fn -> Lease.put_transition!(ctx.sandbox.id, "destroying", "idle") end)

    {:ok, 1} = Repo.transaction(fn -> Lease.put_transition!(ctx.sandbox.id, nil, nil) end)
    assert %{transition: "parking"} = lease_of(live)
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
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
    end

    test "the fleet count reads a resume and a destroy off the workspace", ctx do
      count = fn -> Fountain.Quotas.fleet_count(provider: "sprites") end
      parked = insert_sandbox(user_id: ctx.user.id, status: "suspended")
      before = count.()

      put_lease(parked.id, transition: "resuming", lease_node: Lease.holder(self()))
      assert count.() == before + 1
    end
  end

  describe "the boot sweep" do
    test "a retired sandbox's workspace loses its dead holder", ctx do
      put_lease(ctx.sandbox,
        status: "terminated",
        lease_epoch: 3,
        lease_node: dead_lease_holder()
      )

      Lease.sweep_boot()

      assert %{lease_node: nil, lease_epoch: 3} = lease_of(ctx.ws)
    end
  end

  test "a superseding claim takes the workspace's lease", ctx do
    holder = spawn(fn -> receive do: (:stop -> :ok) end)
    {:ok, 1} = Lease.claim(ctx.sandbox.id, holder: holder)
    {:ok, 2} = Lease.claim(ctx.sandbox.id, supersede: holder)

    assert %{lease_epoch: 2, lease_node: node} = assert_agree(ctx)
    assert node == Lease.holder(self())
    send(holder, :stop)
  end

  describe "a sandbox with no workspace" do
    setup ctx do
      %{bare: insert_sandbox(user_id: ctx.user.id, workspace_id: nil, status: "terminated")}
    end

    test "has no owner: a claim is refused, and it reads no lease and no transition", ctx do
      assert {:error, :no_workspace} = Lease.claim(ctx.bare.id)

      assert %Sandbox{transition: nil, transition_reason: nil, lease_node: nil, lease_epoch: 0} =
               Lease.get(ctx.bare.id)

      assert {:terminal, %Sandbox{}} = Lease.unowned(ctx.bare.id)

      # Nothing holds a stamp for it; a clear is already true of it.
      {:ok, 0} =
        Repo.transaction(fn -> Lease.put_transition!(ctx.bare.id, "destroying", "idle") end)

      {:ok, 1} = Repo.transaction(fn -> Lease.put_transition!(ctx.bare.id, nil, nil) end)
    end

    test "a live one's fence is refused as busy, and stamps nothing", ctx do
      live = insert_sandbox(user_id: ctx.user.id, workspace_id: nil, status: "ready")

      assert {:error, :machine_busy} =
               Lifecycle.fence_sandbox_for_teardown(Lease.get(live.id),
                 actor: "api",
                 reason: "conversation_terminated",
                 transition_reason: :terminated
               )

      assert %Sandbox{transition: nil, status: "ready"} = Lease.get(live.id)
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
