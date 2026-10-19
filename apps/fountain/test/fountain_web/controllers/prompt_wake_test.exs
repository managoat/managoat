defmodule FountainWeb.PromptWakeTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Repo
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Wake

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {_key, raw} = insert_api_key(user)
    owner = self()

    stub(Managoat.Sandbox.Sprites, :get, fn handle ->
      send(owner, :provider_probe)
      {:ok, %{status: :running, raw: %{name: handle.name}}}
    end)

    stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
      send(owner, :provider_resume)
      {:ok, handle}
    end)

    stub_server_start(fn _, _ ->
      send(owner, :worker_start)
      {:ok, owner}
    end)

    stub(ConversationServer, :queue_initial_prompt, fn _, _, _ ->
      send(owner, :prompt_queued)
      :ok
    end)

    %{user: user, agent: agent, raw: raw}
  end

  test "another tenant's conversation remains a 404", ctx do
    other = insert_conversation()

    ctx.conn
    |> authed_with_key(ctx.raw)
    |> post_json("/api/conversations/#{other.id}/prompts", %{prompt: "continue"})
    |> json_response(404)

    refute_side_effects()
  end

  test "a prompt wakes a dormant conversation and queues itself", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    assert {:ok, _} = Wake.wake_conversation(conv.id, "continue")
    assert_received :provider_probe
    assert_received :worker_start
    assert_received :prompt_queued
  end

  test "a queued prompt survives a cold readiness probe beyond the former owner wait", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "suspended"))
    owner = self()

    # Scale the production owner bound and the observed 35s cold wake by 100.
    # The former 20s owner bound would fail at 200ms and lose this prompt.
    stub(Fountain.Machines.Machine, :ensure_up, fn id, opts ->
      opts =
        Keyword.merge(opts,
          resume_timeout_ms: div(Fountain.Machines.Machine.resume_timeout_ms(), 100),
          readiness_timeout_ms: 600,
          readiness_retry_ms: 1
        )

      Mimic.call_original(Fountain.Machines.Machine, :ensure_up, [id, opts])
    end)

    stub(Managoat.Sandbox.Sprites, :exec, fn _, "true", [], _ ->
      send(owner, :readiness_started)
      Process.sleep(350)
      {:ok, "", 0}
    end)

    stub(Fountain.Conversations, :publish_stage, fn id, stage, state, metadata ->
      if stage == "wake" and state == "failed", do: send(owner, :wake_failed)
      Mimic.call_original(Fountain.Conversations, :publish_stage, [id, stage, state, metadata])
    end)

    ctx.conn
    |> authed_with_key(ctx.raw)
    |> post_json("/api/conversations/#{conv.id}/prompts", %{prompt: "continue"})
    |> json_response(200)

    assert_receive :readiness_started
    refute_received {:"$gen_cast", {:initial_prompt, _, _, _}}
    assert_receive {:"$gen_cast", {:initial_prompt, "continue", [], _timing}}, 3_000
    refute_received :wake_failed
    assert Fountain.Machines.Lease.get(conv.sandbox_id).status == "ready"
  end

  test "an interrupt reconnects to a running turn", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    conv = conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()
    owner = self()

    peer =
      spawn(fn ->
        receive do
          {:"$gen_call", from, :interrupt} ->
            send(owner, :interrupted)
            GenServer.reply(from, :ok)
        end
      end)

    on_exit(fn -> Process.exit(peer, :kill) end)
    stub_server_start(fn _, _ -> {:ok, peer} end)

    # Two lookups of the conversation, in order: none running, then the peer.
    # Only the conversation registry: the wake asks the machine registry too,
    # for the owner that resumes the machine.
    {:ok, answers} = Agent.start_link(fn -> [[], [{peer, nil}]] end)
    on_exit(fn -> if Process.alive?(answers), do: Agent.stop(answers) end)

    stub(Registry, :lookup, fn
      Fountain.ConversationRegistry, id ->
        assert id == conv.id
        Agent.get_and_update(answers, fn [next | rest] -> {next, rest} end)

      registry, key ->
        Mimic.call_original(Registry, :lookup, [registry, key])
    end)

    assert :ok = Interruption.interrupt(conv.id)
    assert Agent.get(answers, & &1) == []
    assert_received :interrupted
    assert_received :provider_probe
    refute_received :prompt_queued
  end

  test "cancellation does not wake an idle conversation", ctx do
    conv = conversation(ctx, insert_sandbox(user_id: ctx.user.id, status: "ready"))
    assert {:error, :not_running} = Interruption.wake_for_interrupt(conv.id)
    refute_side_effects()
  end

  defp conversation(ctx, sandbox),
    do:
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: sandbox,
        status: "idle"
      )

  defp refute_side_effects do
    refute_received :provider_probe
    refute_received :provider_resume
    refute_received :worker_start
    refute_received :prompt_queued
  end
end
