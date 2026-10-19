defmodule Fountain.Conversations.ActorStatusBindingTest do
  use Fountain.ConversationServerCase

  alias Fountain.Conversations.Connection
  alias Fountain.Conversations.ProvisionWatchdog
  alias Fountain.Machines.Machine

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    conv = insert_conversation(user_id: user.id, agent: agent)
    replacement = insert_sandbox(user_id: user.id, status: "ready")
    stub_happy_sprite()
    %{user: user, agent: agent, conv: conv, replacement: replacement}
  end

  defp rebind(conv, replacement) do
    {:ok, _} =
      Conversations.update_conversation(Repo.reload!(conv), %{
        sandbox_id: replacement.id,
        status: "idle"
      })
  end

  defp failed_stages(conv) do
    conv.id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == "provision" and &1.state == "failed"))
  end

  defp configure_failure(ctx, failure, stale?) do
    conv =
      if failure == :mcp_vars do
        {:ok, agent} =
          Fountain.Agents.update_agent(ctx.agent, %{
            "mcp_servers" => %{
              "missing" => %{"type" => "http", "url" => "https://${ABSENT_HOST}/mcp"}
            }
          })

        %{ctx.conv | agent: agent}
      else
        ctx.conv
      end

    case failure do
      :credentials ->
        stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :key_unavailable} end)

      :mcp_vars ->
        :ok

      other ->
        stub(Fountain.Conversations.Provisioning, :install_packages, fn _, _, _, _ ->
          if stale?, do: rebind(conv, ctx.replacement)

          if other == :exception,
            do: raise("provision exploded"),
            else: {:error, :install_failed}
        end)
    end

    if stale? and failure in [:credentials, :mcp_vars] do
      # Preflight has already failed. Retiring the old machine may block;
      # a wake rebinds the conversation before the delayed failure returns.
      stub(Machine, :fail_provision, fn sandbox_id, opts ->
        rebind(conv, ctx.replacement)
        Mimic.call_original(Machine, :fail_provision, [sandbox_id, opts])
      end)
    end

    conv
  end

  for failure <- [:credentials, :mcp_vars, :pipeline, :exception], stale? <- [false, true] do
    test "#{failure} failure with stale binding #{stale?}", ctx do
      failure = unquote(failure)
      stale? = unquote(stale?)

      conv = configure_failure(ctx, failure, stale?)

      {_pid, ref, :stopped} = start_server(conv)
      assert :normal = assert_stopped(ref)

      if stale? do
        assert Repo.reload!(conv).status == "idle"
        assert Repo.reload!(conv).sandbox_id == ctx.replacement.id
        assert failed_stages(conv) == []
      else
        assert Repo.reload!(conv).status == "failed"
        assert [_] = failed_stages(conv)
      end
    end
  end

  for stale? <- [false, true] do
    test "successful provider attach with stale binding #{stale?}", ctx do
      stale? = unquote(stale?)
      sandbox = Fountain.Machines.Lease.get(ctx.conv.sandbox_id)
      Repo.update!(Ecto.Changeset.change(sandbox, status: "ready"))
      conv = Repo.update!(Ecto.Changeset.change(ctx.conv, status: "running"))
      turn = insert_turn(conv, status: "running", acp_prompt_id: 4)
      test = self()

      stub(Managoat.Sandbox.Sprites, :list_sessions, fn _ ->
        # Listing runs after the actor reads the running turn; a wake can
        # commit before the attach path refreshes its conversation snapshot.
        if stale?, do: rebind(conv, ctx.replacement)

        {:ok,
         [
           %Managoat.Sandbox.Session{
             id: "old-session",
             command: "env MANAGOAT_CONVERSATION_ID=#{conv.id} claude-agent-acp"
           }
         ]}
      end)

      stub(Managoat.Sandbox.Sprites, :attach, fn _, "old-session", _ ->
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
      end)

      stub(Managoat.Sandbox.Sprites, :write_stdin, fn _, _ -> :ok end)
      stub(Managoat.Sandbox.Sprites, :close_stdin, fn _ -> :ok end)

      stub(Managoat.Sandbox.Sprites, :stop_command, fn _ ->
        send(test, :command_stopped)
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)
      state = :sys.get_state(pid)

      stages =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.stage == "reattach" and &1.data =~ "session_attached"))

      if stale? do
        assert Repo.reload!(conv).status == "idle"
        assert state.current_turn == nil
        assert state.acp_peer == nil
        assert stages == []
        assert_receive :command_stopped
      else
        assert Repo.reload!(conv).status == "running"
        assert state.current_turn.id == turn.id
        assert is_pid(state.acp_peer)
        assert [_] = stages
      end
    end
  end

  test "autonomous admission cannot overwrite a rebind after its transaction", ctx do
    conv = Repo.update!(Ecto.Changeset.change(ctx.conv, status: "idle"))

    stub(Machine, :admit_turn, fn sandbox_id, attrs ->
      result = Mimic.call_original(Machine, :admit_turn, [sandbox_id, attrs])
      assert {:ok, _} = result
      assert Repo.reload!(conv).status == "running"
      rebind(conv, ctx.replacement)
      result
    end)

    assert {turn, _, _} =
             Connection.open_autonomous_turn(
               conv.id,
               ctx.user.id,
               conv.sandbox_id,
               conv.inference_source
             )

    assert turn.origin == "autonomous"
    assert Repo.reload!(conv).status == "idle"
  end

  for outcome <- [:retired, :exhausted], stale? <- [false, true] do
    test "watchdog #{outcome} with stale binding #{stale?}", ctx do
      stale? = unquote(stale?)
      test = self()

      stub(Machine, :fail_provision, fn _, _ ->
        if stale?, do: rebind(ctx.conv, ctx.replacement)
        send(test, {:retire_attempt, self()})
        if unquote(outcome) == :retired, do: {:ok, :failed}, else: {:error, :sandbox_unavailable}
      end)

      server =
        start_supervised!(
          {Task,
           fn ->
             watchdog = ProvisionWatchdog.start(ctx.conv.id, ctx.conv.sandbox_id)
             send(test, {:watchdog, watchdog})
             Process.sleep(:infinity)
           end}
        )

      monitor = Process.monitor(server)
      assert_receive {:watchdog, watchdog}

      attempts =
        if unquote(outcome) == :retired, do: 1, else: ProvisionWatchdog.max_retire_attempts()

      for _ <- 1..attempts do
        send(watchdog, :provision_deadline)
        assert_receive {:retire_attempt, ^watchdog}
      end

      assert_receive {:DOWN, ^monitor, :process, ^server, :killed}, 2_000

      if stale? do
        assert Repo.reload!(ctx.conv).status == "idle"
        assert failed_stages(ctx.conv) == []
      else
        assert Repo.reload!(ctx.conv).status == "failed"
        assert [_] = failed_stages(ctx.conv)
      end
    end
  end
end
