defmodule Fountain.Machines.RebuildTest do
  @moduledoc """
  ADR 0097, step 3c: a lost machine is rebuilt in its workspace as one
  transition of one owner (`Provision.rebuild/3`), and a workspace's
  transition belongs to its current sandbox, so a retired sandbox beside its
  successor reads none and writes none. Also the setup seam: an owner builds a
  machine with no conversation on it (`Machine.set_up/3`).

  Nothing in `lib/` calls the rebuild or the seam yet; step 4 and step 5 do.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Provision
  alias Fountain.Machines.Setup
  alias Fountain.Workspaces.Workspace
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    ws = insert_workspace(user_id: user.id, status: "ready")

    old =
      insert_sandbox(user_id: user.id, agent_id: agent.id, workspace_id: ws.id, status: "ready")

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    {:ok, user: user, agent: agent, ws: ws, old: old}
  end

  defp opts(extra \\ []) do
    Keyword.merge(
      [
        actor: "system:wake",
        attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"}
      ],
      extra
    )
  end

  defp built(_handle, _epoch), do: {:ok, :built}

  defp workspace(ctx), do: Repo.get!(Workspace, ctx.ws.id)

  describe "rebuild/3" do
    test "retires the old machine and builds the next in the same workspace, under one epoch",
         ctx do
      test = self()

      pipeline = fn handle, epoch ->
        # Mid-build: one lease, the workspace's, stamped for the rebuild, and
        # the new row live beside the retired one.
        send(test, {:building, handle.name, epoch, Lease.get(ctx.old.id), workspace(ctx)})
        {:ok, :built}
      end

      capture_log(fn ->
        assert {:ok, :rebuilt, %Sandbox{} = next, :built} =
                 Provision.rebuild(ctx.old.id, pipeline, opts())

        send(test, {:next, next})
      end)

      assert_received {:next, next}
      assert_received {:building, name, epoch, retired_mid, ws_mid}

      assert name == next.machine_name
      assert retired_mid.status == "terminated"
      assert retired_mid.transition == nil, "a retired sandbox beside its successor reads none"
      assert {ws_mid.transition, ws_mid.transition_reason} == {"provisioning", "rebuild"}
      assert ws_mid.lease_epoch == epoch

      assert %Sandbox{status: "ready", workspace_id: ws_id, agent_id: agent_id} = next
      assert {ws_id, agent_id} == {ctx.ws.id, ctx.agent.id}
      assert %Sandbox{status: "terminated", terminated_at: %DateTime{}} = Repo.reload!(ctx.old)
      assert %Workspace{transition: nil, lease_node: nil, lease_epoch: ^epoch} = workspace(ctx)

      # The old machine went at the provider, and the trail says so.
      assert [%{metadata: %{"reason" => "replaced"}}] =
               Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.destroyed")

      assert [_] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.provisioned")
    end

    test "the succession is stamped for the rebuild until the build takes over", ctx do
      test = self()

      on_claim = fn interrupted? ->
        send(test, {:claimed, interrupted?, workspace(ctx)})
        :ok
      end

      capture_log(fn ->
        assert {:ok, :rebuilt, _next, :built} =
                 Provision.rebuild(ctx.old.id, &built/2, opts(on_claim: on_claim))
      end)

      assert_received {:claimed, false, %Workspace{transition: "provisioning"} = ws}
      assert ws.transition_reason == "rebuild"
    end

    test "provider: :already_gone does not call the provider for the old machine", ctx do
      old_name = ctx.old.machine_name

      stub(Managoat.Sandbox, :destroy, fn
        %Handle{name: ^old_name} -> flunk("destroyed a machine the caller said was gone")
        _ -> :ok
      end)

      capture_log(fn ->
        assert {:ok, :rebuilt, _, :built} =
                 Provision.rebuild(ctx.old.id, &built/2, opts(provider: :already_gone))
      end)
    end

    test "a machine somebody asked to destroy is not rebuilt", ctx do
      put_lease(ctx.old.id, transition: "destroying", transition_reason: "terminated")
      reject(Managoat.Sandbox, :create, 2)

      assert {:error, :fenced} = Provision.rebuild(ctx.old.id, &built/2, opts())
      assert Repo.reload!(ctx.old).status == "ready"
    end

    test "a machine still being provisioned is not rebuilt", ctx do
      provisioning =
        insert_sandbox(user_id: ctx.user.id, status: "pending")

      assert {:error, {:not_rebuildable, "pending"}} =
               Provision.rebuild(provisioning.id, &built/2, opts())
    end

    test "the machine it replaces does not count against its slot", ctx do
      # Every slot taken, the old machine's included: the rebuild's net
      # change is none, so it goes ahead.
      fill_fleet(0)

      capture_log(fn ->
        assert {:ok, :rebuilt, %Sandbox{status: "ready"}, :built} =
                 Provision.rebuild(ctx.old.id, &built/2, opts())
      end)
    end

    test "a full fleet refuses it and writes nothing", ctx do
      # One more than the ceiling's worth besides the old machine.
      fill_fleet(0)
      insert_sandbox(status: "ready")
      reject(Managoat.Sandbox, :create, 2)

      assert {:error, :fleet_full} = Provision.rebuild(ctx.old.id, &built/2, opts())
      assert Repo.reload!(ctx.old).status == "ready"

      assert Repo.aggregate(from(s in Sandbox, where: s.workspace_id == ^ctx.ws.id), :count) ==
               1

      assert %Workspace{transition: nil, lease_node: nil} = workspace(ctx)
    end

    test "the workspace provisions again, and settles with the new machine", ctx do
      capture_log(fn ->
        assert {:error, :boom, %{}} =
                 Provision.rebuild(ctx.old.id, fn _, _ -> {:error, :boom, %{}} end, opts())
      end)

      assert %Workspace{status: "failed"} = workspace(ctx)
    end

    test "the new machine may not take the old one's name", ctx do
      reject(Managoat.Sandbox, :create, 2)

      assert {:error, :name_reused} =
               Provision.rebuild(
                 ctx.old.id,
                 &built/2,
                 opts(attrs: %{machine_name: ctx.old.machine_name})
               )

      assert Repo.reload!(ctx.old).status == "ready"
    end

    test "a held lease is waited out and refused as somebody else's", ctx do
      holder = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, _} = Lease.claim(ctx.old.id, holder: holder)

      assert {:ok, :claimed_elsewhere} =
               Machine.rebuild(ctx.old.id, &built/2, opts(busy_wait_ms: 50))

      send(holder, :stop)
    end

    test "a failed build fails the new row and leaves the old one retired", ctx do
      capture_log(fn ->
        assert {:error, :boom, %{}} =
                 Provision.rebuild(ctx.old.id, fn _, _ -> {:error, :boom, %{}} end, opts())
      end)

      assert [next] =
               Repo.all(
                 from s in Sandbox,
                   where: s.workspace_id == ^ctx.ws.id and s.id != ^ctx.old.id
               )

      assert next.status == "failed"
      assert Repo.reload!(ctx.old).status == "terminated"
      assert %Workspace{transition: nil} = workspace(ctx)
    end
  end

  describe "a retired sandbox beside its successor" do
    setup ctx do
      {:ok, epoch} = Lease.claim(ctx.old.id)
      {:ok, _} = Lease.cas_update(ctx.old.id, epoch, status: "terminated")
      :ok = Lease.release(ctx.old.id, epoch)

      next = insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.ws.id, status: "ready")
      put_lease(next.id, transition: "destroying", transition_reason: "terminated")
      %{next: next}
    end

    test "reads no transition, while its successor reads the workspace's", ctx do
      assert %Sandbox{transition: nil} = Lease.get(ctx.old.id)
      assert %Sandbox{transition: "destroying"} = Lease.get(ctx.next.id)
    end

    test "a write to it leaves the successor's stamp where it is", ctx do
      {:ok, epoch} = Lease.claim(ctx.old.id)

      assert {:ok, %Sandbox{transition: nil}} =
               Lease.cas_update(ctx.old.id, epoch, transition: nil, transition_reason: nil)

      :ok = Lease.release(ctx.old.id, epoch)

      assert %Workspace{transition: "destroying", transition_reason: "terminated"} =
               workspace(ctx)

      assert %Sandbox{transition: "destroying"} = Lease.get(ctx.next.id)
    end

    test "registration's clearing on it does not clear the successor's stamp", ctx do
      {:ok, _} = Repo.transaction(fn -> Lease.put_transition!(ctx.old.id, nil, nil) end)
      assert %Workspace{transition: "destroying"} = workspace(ctx)
    end
  end

  describe "the setup seam" do
    test "is refused until the caller says the network is settled", ctx do
      pending = insert_sandbox(user_id: ctx.user.id, status: "pending")
      reject(Managoat.Sandbox, :create, 2)

      assert {:error, :network_unsettled} =
               Machine.set_up(pending.id, %Setup{environment: nil, sprite_env: []})

      assert Repo.reload!(pending).status == "pending"
    end

    setup ctx do
      env = insert_env(user_id: ctx.user.id, setup_script: "echo hi")
      pending = insert_sandbox(user_id: ctx.user.id, status: "pending")

      setup = %Setup{
        environment: Repo.reload!(env),
        sprite_env: [{"FOO", "bar"}],
        write_env_file?: true
      }

      %{pending: pending, setup: setup}
    end

    test "an owner builds a machine with no conversation: env file, then the setup script",
         ctx do
      test = self()

      stub(Fountain.Conversations.Provisioning, :write_env_file, fn _handle, _env ->
        send(test, :env_file)
        :ok
      end)

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", _wrapper, name, script], _opts ->
        send(test, {:exec, name, script})
        {:ok, "", 0}
      end)

      capture_log(fn ->
        assert {:ok, :provisioned, :set_up} =
                 Machine.set_up(ctx.pending.id, ctx.setup, network: :floored)
      end)

      assert_received :env_file
      assert_received {:exec, "fountain-setup", "echo hi"}
      assert Repo.reload!(ctx.pending).status == "ready"

      assert [%{actor: "system:machine"}] =
               Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.provisioned")
    end

    test "a failed setup script fails the machine, and nothing is written to a transcript",
         ctx do
      stub(Fountain.Conversations.Provisioning, :write_env_file, fn _, _ -> :ok end)
      stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "nope\n", 3} end)
      reject(Fountain.Conversations, :log!, 1)

      capture_log(fn ->
        assert {:error, {:setup_exit, 3}, %{}} =
                 Machine.set_up(ctx.pending.id, ctx.setup, network: :floored)
      end)

      assert Repo.reload!(ctx.pending).status == "failed"
    end
  end
end
