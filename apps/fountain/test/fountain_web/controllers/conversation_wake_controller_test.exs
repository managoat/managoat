defmodule FountainWeb.ConversationWakeControllerTest do
  @moduledoc """
  `POST /api/conversations/:id/wake`: bring a conversation's sandbox and
  server up without opening a turn.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer

  setup do
    user = insert_active_user()
    {_key, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, machine_name: "sprite-wake")
    {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    {:ok, user: user, raw_key: raw_key, agent: agent, conv: conv}
  end

  defp wake(ctx, conv \\ nil) do
    ctx.conn
    |> authed_with_key(ctx.raw_key)
    |> post_json("/api/conversations/#{(conv || ctx.conv).id}/wake", %{})
  end

  defp woken_events(user_id) do
    user_id
    |> Fountain.Audit.list_for_user()
    |> Enum.filter(&(&1.action == "conversation.woken"))
  end

  describe "a parked conversation" do
    setup do
      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "sprite-wake"}}}
      end)

      server = spawn(fn -> Process.sleep(:infinity) end)
      test_pid = self()

      stub_server_start(fn _supervisor, _child_spec ->
        send(test_pid, :server_started)
        {:ok, server}
      end)

      reject(&ConversationServer.queue_initial_prompt/2)
      reject(&ConversationServer.queue_initial_prompt/3)
      reject(&ConversationServer.queue_initial_prompt/4)
      :ok
    end

    # The wake runs behind the answer (#2584), so the start and the audit
    # are waited for rather than expected on return.
    test "200 waking starts a server on its sandbox and opens no turn", ctx do
      assert %{"status" => "waking"} = ctx |> wake() |> json_response(200)
      assert_receive :server_started, 2_000
      assert Fountain.Repo.all(Fountain.Conversations.Turn) == []

      assert [event] = eventually(fn -> woken_events(ctx.user.id) end)
      assert event.resource_id == ctx.conv.id
      assert event.actor == "api"
    end
  end

  test "a refusal that needs no provider still answers the call, and nothing is woken", ctx do
    put_lease(ctx.conv.sandbox_id, transition: "destroying")

    stub_server_start(fn _supervisor, _child_spec -> flunk("woke a machine being reset") end)

    assert ctx |> wake() |> json_response(409)
    assert woken_events(ctx.user.id) == []
  end

  test "200 awake does nothing for a conversation whose server is running", ctx do
    stub(ConversationServer, :whereis, fn _id -> self() end)
    stub_server_start(fn _supervisor, _child_spec -> flunk("started a second server") end)

    assert %{"status" => "awake"} = ctx |> wake() |> json_response(200)
    assert woken_events(ctx.user.id) == []
  end

  test "410 for a conversation that has ended", ctx do
    conv = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, status: "terminated")

    assert ctx |> wake(conv) |> json_response(410)
    assert woken_events(ctx.user.id) == []
  end

  test "404 for another account's conversation", ctx do
    other = insert_active_user()
    conv = insert_conversation(user_id: other.id, agent: insert_agent(user_id: other.id))

    assert ctx |> wake(conv) |> json_response(404)
  end

  defp eventually(fun, tries \\ 50) do
    case fun.() do
      [] when tries > 0 ->
        Process.sleep(20)
        eventually(fun, tries - 1)

      result ->
        result
    end
  end
end
