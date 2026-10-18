defmodule Fountain.Conversations.WorkspaceRebuildTest do
  @moduledoc """
  ADR 0097 step 4b: a lost machine is rebuilt in its workspace on the next
  prompt, by the waking conversation's server, and the workspace's
  conversations follow it; a second conversation's server follows the
  rebuilt machine; the watchdog and the wake reach the workspace's current
  machine.
  """

  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Rebuild, Sandbox, Wake}
  alias Fountain.Workspaces.Workspace

  defp lost_conversation(opts \\ []) do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: Keyword.get(opts, :status, "terminated"))

    # `pending`: what the wake sets before it starts a server to rebuild.
    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: Keyword.get(opts, :conv_status, "pending")
      )

    conv =
      conv |> Ecto.Changeset.change(runtime_session_id: "old-session") |> Repo.update!()

    {user, agent, conv, sandbox}
  end

  describe "a server started on its conversation's lost row" do
    test "rebuilds the machine in the same workspace, and the conversation follows", _ctx do
      {_user, _agent, conv, old} = lost_conversation()
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      state = :sys.get_state(pid)
      next = Repo.get!(Sandbox, state.sandbox_id)

      assert next.id != old.id
      assert next.workspace_id == old.workspace_id
      assert next.status == "ready"
      assert Repo.reload!(old).status == "terminated"

      moved = Repo.reload!(conv)
      assert moved.sandbox_id == next.id
      assert moved.workspace_id == old.workspace_id
      assert moved.runtime_session_id == nil
      assert is_nil(state.runtime_session_id)
      assert Repo.get(Workspace, old.workspace_id).status == "ready"
    end

    test "a server restarted with no wake asking does not build a machine", _ctx do
      # A crash restart replays the child spec, with no prompt: the
      # conversation is `idle`, not marked by a wake.
      {_user, _agent, conv, _old} = lost_conversation(conv_status: "idle")
      stub_happy_sprite()
      reject(&Managoat.Sandbox.Sprites.create/2)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)
    end

    test "a create that fails after the succession fails the conversation where it now is",
         _ctx do
      {_user, _agent, conv, old} = lost_conversation()
      stub_happy_sprite()
      stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts -> {:error, :boom} end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      moved = Repo.reload!(conv)
      assert moved.sandbox_id != old.id
      assert moved.status == "failed"
      assert Repo.get!(Sandbox, moved.sandbox_id).status == "failed"

      assert Enum.any?(
               Conversations._unsafe_list_log_events(conv.id),
               &(&1.kind == "stage" and &1.stage == "provision" and &1.state == "failed")
             )
    end

    test "a pipeline that raises after the succession fails the conversation where it now is",
         _ctx do
      {_user, _agent, conv, old} = lost_conversation()
      stub_happy_sprite()

      stub(Fountain.Conversations.Provisioning, :record_sandbox_url, fn _sandbox,
                                                                        _handle,
                                                                        _epoch ->
        raise "boom"
      end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      moved = Repo.reload!(conv)
      assert moved.sandbox_id != old.id
      assert moved.status == "failed"
      assert Repo.get!(Sandbox, moved.sandbox_id).status == "failed"
    end

    test "a co-tenant moved by the rebuild is told on its own transcript", _ctx do
      {user, agent, conv, old} = lost_conversation()
      explicit_workspace!(old)

      other =
        insert_conversation(user_id: user.id, agent: agent, sandbox: old, status: "idle")

      stub_happy_sprite()
      {_pid, _ref, :alive} = start_server(conv)

      assert Repo.reload!(other).sandbox_id == Repo.reload!(conv).sandbox_id

      assert Enum.any?(Conversations._unsafe_list_log_events(other.id), fn e ->
               e.kind == "stage" and e.stage == "sandbox" and
                 Jason.decode!(e.data)["reason"] == "rebuilt"
             end)
    end

    test "an ended conversation's server still stops (#394)", _ctx do
      {_user, _agent, conv, _old} = lost_conversation()
      {:ok, _} = Conversations.update_conversation(conv, %{status: "failed"})
      stub_happy_sprite()
      reject(&Managoat.Sandbox.Sprites.create/2)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)
    end

    test "follows a co-tenant's rebuilt machine instead of building a second", _ctx do
      {user, agent, conv, old} = lost_conversation()
      explicit_workspace!(old)
      stub_happy_sprite()

      # Another conversation's prompt rebuilt the workspace's machine and
      # moved this conversation to it while its own server was starting.
      next =
        insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          workspace_id: old.workspace_id,
          status: "ready"
        )

      stale = conv
      {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: next.id})
      reject(&Managoat.Sandbox.Sprites.create/2)

      {pid, _ref, :alive} = start_server(stale)
      assert :sys.get_state(pid).sandbox_id == next.id
      assert Repo.reload!(conv).sandbox_id == next.id
    end
  end

  describe "the wake" do
    test "keeps an implicit workspace whose resolution still matches", _ctx do
      {_user, agent, conv, old} = lost_conversation()
      assert {:rebuild, %Sandbox{id: id}} = Rebuild.wake_target(conv, agent)
      assert id == old.id
    end

    test "gives a fresh implicit workspace when the agent moved environment", _ctx do
      {user, agent, conv, _old} = lost_conversation()
      env = insert_env(user_id: user.id)
      {:ok, agent} = Fountain.Agents.update_agent(agent, %{environment_id: env.id})
      assert :fresh = Rebuild.wake_target(conv, agent)
    end

    test "always keeps an explicit workspace", _ctx do
      {user, agent, conv, old} = lost_conversation()
      explicit_workspace!(old)
      env = insert_env(user_id: user.id)
      {:ok, agent} = Fountain.Agents.update_agent(agent, %{environment_id: env.id})
      assert {:rebuild, _} = Rebuild.wake_target(conv, agent)
    end

    test "a wake meeting its own conversation's server mid-rebuild hands it the prompt", _ctx do
      {_user, _agent, conv, old} = lost_conversation(status: "ready", conv_status: "idle")
      test = self()

      server =
        spawn(fn ->
          receive do
            {:"$gen_cast", {:initial_prompt, prompt, _images}} -> send(test, {:handed, prompt})
          end
        end)

      # The rebuilding server holds the workspace's lease and is registered.
      stub(Fountain.Machines.Machine, :busy?, fn _ -> true end)
      stub(ConversationServer, :whereis, fn id -> if id == conv.id, do: server end)
      stub_server_start(fn _sup, _spec -> flunk("no second server") end)

      assert {:ok, _} = Wake.wake_conversation(conv.id, "hello")
      assert_receive {:handed, "hello"}
      assert Repo.reload!(old).status == "ready"
    end

    test "retires a machine the provider reports gone, then starts the server on it", _ctx do
      {_user, _agent, conv, old} = lost_conversation(status: "ready", conv_status: "idle")
      test = self()
      stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:error, :not_found} end)

      stub_server_start(fn _sup, spec ->
        send(test, {:spec, spec})
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      capture_log(fn -> assert {:ok, _} = Wake.wake_conversation(conv.id, "hello") end)

      assert_received {:spec, spec}
      assert spec |> inspect() |> String.contains?(old.id)
      assert Repo.reload!(old).status == "terminated"
      # The wake's marker for the server it started.
      assert Repo.reload!(conv).status == "pending"
    end
  end

  describe "the provisioning watchdog" do
    test "retires the conversation's current machine in the workspace", _ctx do
      {user, agent, conv, old} = lost_conversation()

      next =
        insert_sandbox(
          user_id: user.id,
          agent_id: agent.id,
          workspace_id: old.workspace_id,
          status: "starting"
        )

      {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: next.id})
      test = self()
      next_id = next.id

      stub(Fountain.Machines.Machine, :fail_provision, fn id, _opts ->
        send(test, {:failed, id})
        {:ok, :not_provisioning}
      end)

      previous = Application.get_env(:fountain, :provision_deadline_ms)
      Application.put_env(:fountain, :provision_deadline_ms, 50)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:fountain, :provision_deadline_ms, previous),
          else: Application.delete_env(:fountain, :provision_deadline_ms)
      end)

      # The watchdog of a server started on the lost row, whose rebuild has
      # moved its conversation to the next one.
      spawn(fn ->
        _ = Fountain.Conversations.ProvisionWatchdog.start(conv.id, old.id)
        Process.sleep(2_000)
      end)

      assert_receive {:failed, ^next_id}, 2_000
    end
  end
end
