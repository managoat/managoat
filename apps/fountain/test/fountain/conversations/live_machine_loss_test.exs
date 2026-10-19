defmodule Fountain.Conversations.LiveMachineLossTest do
  @moduledoc """
  #3005, from the v0.37.0 prod proof of ADR 0097: a conversation's server is
  up between turns, the provider loses its machine, and the next prompt
  reaches that live server. Its adapter install then fails at the provider
  (`spawn failed: {:acp_adapter_install, {:provider, :sprites, %APIError{status:
  404}}}`), and nothing marked the machine lost, so every prompt failed the
  same way and the workspace kept reporting `ready`.

  Each test reproduces that sequence against real servers in the real
  registry and supervisor: a live server on a `ready` machine, the machine
  destroyed at the provider, then a prompt through the public door
  (`ConversationServer.send_prompt/4`).
  """

  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Sandbox, Turn}
  alias Fountain.Workspaces.Workspace

  @fake Managoat.Runtimes.Testing.FakeRuntime

  setup do
    test = self()
    @fake.observe(test)
    stub_happy_sprite()

    # Every conversation server, the live ones and the ones a wake starts, runs
    # under the real supervisor and registry, on the fake runtime.
    stub_server_start(fn supervisor, {ConversationServer, args} ->
      args = Keyword.put(args, :runtime_module, @fake)

      with {:ok, pid} = started <-
             Mimic.call_original(DynamicSupervisor, :start_child, [
               supervisor,
               {ConversationServer, args}
             ]) do
        send(test, {:server, Keyword.fetch!(args, :conversation_id), pid})
        started
      end
    end)

    # A machine the provider created answers to the name it was asked for.
    stub(Managoat.Sandbox.Sprites, :create, fn name, _opts ->
      {:ok, Managoat.Sandbox.Sprites.build_handle(name)}
    end)

    stub(Managoat.Sandbox.Sprites, :write_stdin, fn _command, _data -> :ok end)
    stub(Managoat.Sandbox.Sprites, :close_stdin, fn _command -> :ok end)
    stub(Managoat.Sandbox.Sprites, :stop_command, fn _command -> :ok end)

    on_exit(fn -> stop_servers() end)
    :ok
  end

  # The servers this test started, by conversation, stopped before the
  # database owner goes.
  defp stop_servers do
    for {_id, pid, _type, _mods} <-
          DynamicSupervisor.which_children(Fountain.ConversationSupervisor),
        is_pid(pid) do
      ref = Process.monitor(pid)
      DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, pid)

      receive do
        {:DOWN, ^ref, :process, ^pid, _} -> :ok
      after
        2_000 -> Process.demonitor(ref, [:flush])
      end
    end
  end

  defp live_server(conv) do
    {:ok, pid} =
      Conversations.register_server(
        conv.sandbox_id,
        Fountain.Conversations.Launch.child_spec(conv.id, conv.sandbox_id, @fake)
      )

    # The reattach has run once a call is answered.
    _ = :sys.get_state(pid, :infinity)
    assert Process.alive?(pid)
    pid
  end

  # The provider loses the machine named `name`: it answers 404 for it, as
  # Sprites did in prod, and answers for every other machine as before. A
  # spawn on any other machine is reported to the test.
  defp lose_machine(name) do
    test = self()

    not_found =
      {:error,
       {:provider, :sprites,
        %Sprites.Error.APIError{
          status: 404,
          message: "sprite not found",
          error_code: "sprite not found"
        }}}

    stub(Managoat.Sandbox.Sprites, :get, fn handle ->
      if handle.name == name,
        do: {:error, :not_found},
        else: {:ok, %{status: :running, raw: %{}}}
    end)

    stub(Managoat.Sandbox.Sprites, :exec, fn handle, _cmd, _args, _opts ->
      if handle.name == name, do: not_found, else: {:ok, "", 0}
    end)

    stub(Managoat.Sandbox.Sprites, :spawn, fn handle, _cmd, _args, _opts ->
      if handle.name == name do
        not_found
      else
        send(test, {:spawned, handle.name})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
      end
    end)
  end

  # The adapter exits between turns, as the machine's destruction killed it
  # in prod (137), so the server records `connection_lost` and stays up.
  defp drop_connection(pid) do
    ref = make_ref()

    :sys.replace_state(pid, fn state ->
      command = %Managoat.Sandbox.Command{provider: :sprites, ref: ref}
      %{state | current_command: command, current_command_ref: ref}
    end)

    send(pid, {:exit, %{ref: ref}, 137})
    _ = :sys.get_state(pid)
    assert Process.alive?(pid)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 10_000) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(50)
          eventually(fun, deadline)
        else
          flunk("condition never held")
        end

      value ->
        value
    end
  end

  defp moved_off(conv, old) do
    eventually(fn ->
      case Repo.reload!(conv) do
        %{sandbox_id: id} = moved when id != old.id ->
          sandbox = Repo.get!(Sandbox, id)
          if sandbox.status == "ready", do: {moved, sandbox}

        _ ->
          nil
      end
    end)
  end

  defp stages(conv_id, stage) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == stage))
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp turns(conv_id) do
    Repo.all(from t in Turn, where: t.conversation_id == ^conv_id, order_by: t.turn_number)
  end

  defp setup_conversation(user, agent, sandbox) do
    insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
  end

  describe "a prompt to a live server whose machine the provider lost" do
    test "an explicit workspace with two conversations is rebuilt, both follow, and the prompt runs there",
         _ctx do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      explicit_workspace!(old)
      a = setup_conversation(user, agent, old)
      b = setup_conversation(user, agent, old)

      for conv <- [a, b] do
        conv |> Ecto.Changeset.change(runtime_session_id: "old-#{conv.id}") |> Repo.update!()
      end

      server_a = live_server(a)
      server_b = live_server(b)
      ref_a = Process.monitor(server_a)
      ref_b = Process.monitor(server_b)

      lose_machine(old.machine_name)

      capture_log(fn ->
        drop_connection(server_a)
        assert :ok = ConversationServer.send_prompt(a.id, "hello", [])

        {moved_a, next} = moved_off(a, old)
        assert_receive {:spawned, name}, 10_000
        assert name == next.machine_name

        # The machine is classified lost through its owner, and the next is
        # built in the same workspace.
        assert Repo.reload!(old).status == "terminated"
        assert next.workspace_id == old.workspace_id
        # The old session is gone with the disk; the prompt's turn starts a
        # new one.
        assert moved_a.runtime_session_id != "old-#{a.id}"
        assert Repo.get!(Workspace, old.workspace_id).status == "ready"

        # Every conversation follows, with its session cleared.
        moved_b = Repo.reload!(b)
        assert moved_b.sandbox_id == next.id
        assert moved_b.runtime_session_id == nil

        # The servers on the lost machine stopped; the prompt runs in a new
        # one on the rebuilt machine, as turn 1, the turn it was admitted as.
        assert_receive {:DOWN, ^ref_a, :process, _, _}, 5_000
        assert_receive {:DOWN, ^ref_b, :process, _, _}, 5_000
        assert [%Turn{turn_number: 1, prompt: "hello", status: "running"}] = turns(a.id)
        assert ConversationServer.whereis(a.id) not in [nil, server_a]
      end)

      # No turn failed on the lost machine, and the prompt was not reported
      # as lost.
      refute Enum.any?(stages(a.id, "turn"), &match?({"failed", _}, &1))
      refute Enum.any?(stages(a.id, "wake"), &match?({"failed", _}, &1))

      assert Enum.any?(stages(a.id, "provision"), fn {state, data} ->
               state == "started" and data["retry"] =~ "lost"
             end)

      # One accurate note for the conversation that followed, not a
      # `replaced` one beside it.
      assert [{"done", note}] =
               Enum.filter(stages(b.id, "sandbox"), &match?({_, %{"message" => _}}, &1))

      assert note["reason"] == "rebuilt"
      assert note["message"] =~ "lost"
    end

    test "a plain conversation gets a new machine in its workspace, and the prompt runs there",
         _ctx do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      conv = setup_conversation(user, agent, old)
      conv |> Ecto.Changeset.change(runtime_session_id: "old-session") |> Repo.update!()

      server = live_server(conv)
      ref = Process.monitor(server)
      lose_machine(old.machine_name)

      capture_log(fn ->
        drop_connection(server)
        assert :ok = ConversationServer.send_prompt(conv.id, "hello", [])

        {moved, next} = moved_off(conv, old)
        assert_receive {:spawned, name}, 10_000
        assert name == next.machine_name
        assert_receive {:DOWN, ^ref, :process, _, _}, 5_000

        assert Repo.reload!(old).status == "terminated"
        assert next.workspace_id == old.workspace_id
        assert moved.runtime_session_id != "old-session"
        assert [%Turn{turn_number: 1, prompt: "hello", status: "running"}] = turns(conv.id)
      end)

      refute Enum.any?(stages(conv.id, "turn"), &match?({"failed", _}, &1))
    end

    test "a 404 from the adapter's start while the provider still has the machine fails only the turn",
         _ctx do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      conv = setup_conversation(user, agent, old)
      server = live_server(conv)

      # The exec endpoint answers 404 once; the machine itself still answers.
      lose_machine(old.machine_name)

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{}}}
      end)

      reject(&Managoat.Sandbox.Sprites.create/2)

      capture_log(fn ->
        assert :ok = ConversationServer.send_prompt(conv.id, "hello", [])
        _ = :sys.get_state(server)
      end)

      assert Process.alive?(server)
      assert Repo.reload!(old).status == "ready"
      assert Repo.reload!(conv).sandbox_id == old.id
      assert [%Turn{status: "failed"}] = turns(conv.id)
    end

    test "a provider that cannot answer the probe is not a lost machine", _ctx do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      old = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
      conv = setup_conversation(user, agent, old)
      server = live_server(conv)

      lose_machine(old.machine_name)

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, {:unavailable, :timeout}} end)
      reject(&Managoat.Sandbox.Sprites.create/2)

      capture_log(fn ->
        assert :ok = ConversationServer.send_prompt(conv.id, "hello", [])
        _ = :sys.get_state(server)
      end)

      assert Process.alive?(server)
      assert Repo.reload!(old).status == "ready"
      assert [%Turn{status: "failed"}] = turns(conv.id)
    end
  end
end
