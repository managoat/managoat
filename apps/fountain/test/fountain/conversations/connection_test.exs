defmodule Fountain.Conversations.ConnectionTest do
  @moduledoc """
  The connection that outlives the turn (#817), driven without a server: what
  counts as open, what counts as busy, riding an idle peer, letting one go,
  and the autonomous turn an out-of-turn line opens (#1301).

  The peer is a stand-in process answering the one call `Peer.prompt/3`
  makes; the sandbox is the `Managoat.Sandbox` facade, stubbed.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.Connection
  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    conv = insert_conversation(user_id: user.id, status: "idle")
    {:ok, user: user, conv: conv}
  end

  defp handle, do: %Handle{provider: :sprites, name: "s"}
  defp command, do: %Command{provider: :sprites, ref: make_ref()}

  test "fresh Codex connections on Sprites clear capabilities and preserve spawn options" do
    handle = handle()
    command = command()
    env = [{"MANAGOAT_CONVERSATION_ID", "test-conversation"}]
    opts = [env: env, dir: "/track", stdin: true]
    state = %{handle: handle, sprite_env: env, broker: nil}

    expect(Fountain.Conversations.Provisioning, :check_acp_adapter, fn ^handle, "codex", ^env ->
      :ok
    end)

    expect(Managoat.Sandbox, :spawn, fn ^handle,
                                        "/usr/bin/setpriv",
                                        [
                                          "--inh-caps=-all",
                                          "--ambient-caps=-all",
                                          "--",
                                          "env",
                                          "MANAGOAT_CONVERSATION_ID=test-conversation",
                                          "codex-acp"
                                        ],
                                        ^opts ->
      {:ok, command}
    end)

    assert {:ok, ^command} =
             Connection.spawn_command(
               state,
               "codex",
               "env",
               [
                 "MANAGOAT_CONVERSATION_ID=test-conversation",
                 "codex-acp"
               ],
               opts
             )
  end

  test "a refused adapter pin check reports its reason and spawns nothing" do
    handle = handle()
    env = []
    state = %{handle: handle, sprite_env: env, broker: nil}

    expect(Fountain.Conversations.Provisioning, :check_acp_adapter, fn ^handle, "claude", ^env ->
      {:error, {:acp_adapter_install_exit, 1, "boom"}}
    end)

    stub(Managoat.Sandbox, :spawn, fn _, _, _, _ -> flunk("spawned after a refused check") end)

    assert {:error, {:acp_adapter_install_exit, 1, "boom"}} =
             Connection.spawn_command(state, "claude", "claude-acp", [], env: env)
  end

  test "a spawn that fails keeps its reason" do
    handle = handle()
    env = []
    state = %{handle: handle, sprite_env: env, broker: nil}

    expect(Fountain.Conversations.Provisioning, :check_acp_adapter, fn _, _, _ -> :ok end)
    expect(Managoat.Sandbox, :spawn, fn _, _, _, _ -> {:error, :sandbox_gone} end)

    assert {:error, :sandbox_gone} =
             Connection.spawn_command(state, "claude", "claude-acp", [], env: env)
  end

  # A stand-in peer: answers `Peer.prompt/3`'s call with `reply` and stays
  # alive, the way an idle adapter does between turns.
  defp fake_peer(reply) do
    test = self()

    spawn_link(fn ->
      receive do
        {:"$gen_call", from, {:prompt, prompt, images, _opts}} ->
          send(test, {:prompted, prompt, images})
          GenServer.reply(from, reply)
          Process.sleep(:infinity)
      end
    end)
  end

  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  describe "the server boundary" do
    test "from_state/1 and into_state/2 round-trip the five fields" do
      cmd = command()

      state = %{
        acp_peer: self(),
        acp_peer_mon: :mon,
        current_command: cmd,
        current_command_ref: cmd.ref,
        autonomous_quiet: :timer,
        other: 1
      }

      assert %Connection{peer: peer, peer_mon: :mon, command: ^cmd, quiet_timer: :timer} =
               conn = Connection.from_state(state)

      assert peer == self()
      assert conn.command_ref == cmd.ref
      assert Connection.into_state(state, conn) == state
    end
  end

  describe "alive?/1" do
    test "an idle peer still on the machine is alive" do
      assert Connection.alive?(%Connection{peer: self()})
    end

    test "no peer, and a peer that has gone, are both not alive" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      refute Connection.alive?(%Connection{})
      refute Connection.alive?(%Connection{peer: dead})
    end
  end

  describe "user_turn_running?/1" do
    test "no turn is not busy" do
      refute Connection.user_turn_running?(nil)
    end

    test "an autonomous turn is not busy: a prompt supersedes it" do
      refute Connection.user_turn_running?(%{origin: "autonomous"})
    end

    test "a user turn is busy" do
      assert Connection.user_turn_running?(%{origin: "user"})
    end
  end

  describe "resume/7" do
    setup %{conv: conv} do
      {:ok, turn: insert_turn(conv, status: "running")}
    end

    test "rides the open peer and hands back the span, tracer and stamp", %{
      conv: conv,
      user: user,
      turn: turn
    } do
      conn = %Connection{peer: fake_peer(:ok)}

      assert {:ok, _span, tracer, started_mono} =
               Connection.resume(conn, conv.id, user.id, conv, turn, "go on", [])

      assert is_integer(started_mono)
      refute is_nil(tracer)
      assert_receive {:prompted, "go on", []}

      assert [{"started", meta}] = stages(conv.id, "turn")
      assert meta["mode"] == "continue"
      assert meta["connection"] == "reused"
      assert meta["turn_id"] == turn.id
    end

    test "a peer that refuses the prompt is an error the caller respawns from", %{
      conv: conv,
      user: user,
      turn: turn
    } do
      conn = %Connection{peer: fake_peer({:error, :wedged})}

      log =
        capture_log(fn ->
          assert {:error, :wedged} =
                   Connection.resume(conn, conv.id, user.id, conv, turn, "go on", [])
        end)

      assert log =~ "idle peer refused prompt"
      # The caller's fresh launch announces the row when reuse is refused.
      assert [] = stages(conv.id, "turn")
    end
  end

  describe "close/1" do
    test "EOFs the adapter, stops it, and clears the connection" do
      test = self()
      cmd = command()

      Mimic.stub(Managoat.Sandbox, :close_stdin, fn c -> send(test, {:closed_stdin, c.ref}) end)
      Mimic.stub(Managoat.Sandbox, :stop_command, fn c -> send(test, {:stopped, c.ref}) end)

      conn = %Connection{command: cmd, command_ref: cmd.ref, quiet_timer: arm_a_timer()}

      assert %Connection{peer: nil, peer_mon: nil, command: nil, command_ref: nil} =
               closed = Connection.close(conn)

      assert closed.quiet_timer == nil
      assert_receive {:closed_stdin, ref}
      assert ref == cmd.ref
      assert_receive {:stopped, ^ref}
    end

    test "is safe on a connection that has nothing open" do
      assert Connection.close(%Connection{}) == %Connection{}
    end
  end

  describe "lost/4" do
    test "records the loss on the transcript and clears the connection", %{conv: conv} do
      cmd = command()
      conn = %Connection{peer: self(), peer_mon: :mon, command: cmd, command_ref: cmd.ref}

      assert %Connection{peer: nil, peer_mon: nil, command: nil, command_ref: nil} =
               Connection.lost(conn, conv.id, "adapter_exited", %{exit_code: 3})

      assert [{"done", meta}] = stages(conv.id, "sandbox")
      assert meta["event"] == "connection_lost"
      assert meta["reason"] == "adapter_exited"
      assert meta["exit_code"] == 3
    end
  end

  describe "stop_peer/1" do
    test "no peer is nothing to stop" do
      assert Connection.stop_peer(%Connection{}) == :ok
    end

    test "stops the peer and flushes the monitor it was watched by" do
      {:ok, peer} = Agent.start(fn -> :ok end)
      mon = Process.monitor(peer)

      assert Connection.stop_peer(%Connection{peer: peer, peer_mon: mon}) == :ok
      refute Process.alive?(peer)
      # Demonitored with :flush, so the peer's own exit does not arrive as a
      # :DOWN that would fail the turn we just finished.
      refute_receive {:DOWN, ^mon, :process, ^peer, _}
    end

    test "a peer that has already gone is not an error" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}

      assert Connection.stop_peer(%Connection{peer: dead}) == :ok
    end
  end

  describe "the quiet timer (#1301)" do
    test "quiet_ms/0 is ten minutes of silence" do
      assert Connection.quiet_ms() == :timer.minutes(10)
    end

    test "arm_quiet/2 arms against the turn it will close" do
      turn = %{id: "t-1"}
      assert %Connection{quiet_timer: timer} = Connection.arm_quiet(%Connection{}, turn)
      assert is_reference(timer)
      assert Process.read_timer(timer) > 0
    end

    test "arming again replaces the timer rather than leaving two" do
      first = Connection.arm_quiet(%Connection{}, %{id: "t-1"})
      second = Connection.arm_quiet(first, %{id: "t-2"})

      refute second.quiet_timer == first.quiet_timer
      assert Process.read_timer(first.quiet_timer) == false
    end

    test "no turn, no timer" do
      assert %Connection{quiet_timer: nil} = Connection.arm_quiet(%Connection{}, nil)
    end

    test "cancel_quiet/1 disarms, and is safe when nothing is armed" do
      armed = Connection.arm_quiet(%Connection{}, %{id: "t-1"})
      assert %Connection{quiet_timer: nil} = Connection.cancel_quiet(armed)
      assert Process.read_timer(armed.quiet_timer) == false
      assert Connection.cancel_quiet(%Connection{}) == %Connection{}
    end
  end

  describe "open_autonomous_turn/5" do
    test "opens a real turn row so the budget and the stage events apply", %{
      conv: conv,
      user: user
    } do
      assert {turn, _span, tracer} =
               Connection.open_autonomous_turn(
                 conv.id,
                 user.id,
                 conv.sandbox_id,
                 conv.inference_source
               )

      assert is_nil(conv.inference_source)
      assert is_nil(turn.inference_source)
      assert turn.origin == "autonomous"
      assert turn.status == "running"
      assert turn.prompt == "(background task follow-up)"
      assert turn.conversation_id == conv.id
      refute is_nil(tracer)

      assert [{"started", meta}] = stages(conv.id, "turn")
      assert meta["origin"] == "autonomous"
      assert meta["turn_id"] == turn.id

      assert Conversations._unsafe_get_conversation!(conv.id).status == "running"
    end

    for initial_source <- [:unbound, :bound] do
      test "a #{initial_source} caller cannot adopt a changed source", %{
        conv: conv,
        user: user
      } do
        source = Fountain.InferenceCredentials.Source.none()

        old_source =
          if unquote(initial_source) == :bound,
            do: Fountain.InferenceCredentials.Source.dump(source)

        current_source = Fountain.InferenceCredentials.Source.dump(%{source | model: "new-model"})
        conv |> Ecto.Changeset.change(inference_source: current_source) |> Repo.update!()

        assert {:error, :inference_source_changed} =
                 Connection.open_autonomous_turn(
                   conv.id,
                   user.id,
                   conv.sandbox_id,
                   old_source
                 )

        assert Conversations._unsafe_list_turns(conv.id) == []
        assert stages(conv.id, "turn") == []
        assert Repo.reload!(conv).status == "idle"
        assert Repo.reload!(conv).inference_source == current_source
      end
    end

    test "takes the next turn number", %{conv: conv, user: user} do
      insert_turn(conv, status: "completed")

      assert {turn, _span, _tracer} =
               Connection.open_autonomous_turn(
                 conv.id,
                 user.id,
                 conv.sandbox_id,
                 conv.inference_source
               )

      assert turn.turn_number == 2
    end
  end

  defp arm_a_timer, do: Process.send_after(self(), :never, :timer.minutes(10))
end
