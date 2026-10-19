defmodule Fountain.Conversations.WorkspaceDisabledProviderTest do
  @moduledoc """
  #3004: a conversation in a workspace whose provider has since been disabled
  is told what to do about the workspace's provider, not the agent's
  `sandbox_provider` override, which a workspace does not read (ADR 0097).
  The advice matches what `POST /api/workspaces` gives (#3003).

  `e2b` has no credentials in the test configuration, so it reads as disabled.
  """

  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.Wake

  setup do
    refute Fountain.SandboxProviders.enabled?(:e2b)
    :ok
  end

  defp workspace_conversation(status) do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    workspace = insert_workspace(user_id: user.id, provider: "e2b")

    sandbox =
      insert_sandbox(user_id: user.id, workspace_id: workspace.id, machine_name: "ws-on-e2b")

    {:ok, sandbox} = update_sandbox(sandbox, %{status: status, provider: "e2b"})
    explicit_workspace!(sandbox)

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {conv, sandbox}
  end

  defp stages(conv_id, stage) do
    Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  # The background wake's report resolves the prompt's receipt last; waiting
  # for it lets the task finish before the test's database owner goes.
  defp receipt_resolved(conv) do
    eventually(fn ->
      not Repo.exists?(
        from(r in Fountain.Conversations.PromptReceipt, where: r.conversation_id == ^conv.id)
      )
    end)
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case fun.() do
      falsy when falsy in [nil, false, []] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          eventually(fun, deadline)
        else
          flunk("condition never held")
        end

      value ->
        value
    end
  end

  test "a parked workspace machine on a disabled provider is refused with the workspace's advice" do
    {conv, sandbox} = workspace_conversation("suspended")

    assert {:error, {:sandbox_provider_disabled, :e2b, :workspace}} =
             Wake.wake_conversation(conv.id)

    # The parked disk is kept for the provider's return.
    assert Repo.reload!(sandbox).status == "suspended"
  end

  test "the background wake's failure stage carries the workspace's advice" do
    {conv, _sandbox} = workspace_conversation("suspended")

    :ok = Wake.wake_in_background(conv.id, {"hello", [client_request_id: "r-1"]}, [])

    [{"failed", data}] = eventually(fn -> stages(conv.id, "wake") end)

    assert data["reason"] == "sandbox_provider_disabled"
    assert data["retryable"] == false
    assert data["client_request_id"] == "r-1"
    assert data["advice"] =~ "sandbox provider e2b is not configured"
    assert data["advice"] =~ "this workspace runs on it"
    assert data["advice"] =~ "create a workspace with another sandbox_provider"
    refute data["advice"] =~ "agent"
    # The code stays the label: `message` is what the SDK's `run()` shows.
    refute Map.has_key?(data, "message")
    receipt_resolved(conv)
  end

  test "a lost workspace machine on a disabled provider is not rebuilt there" do
    {conv, sandbox} = workspace_conversation("terminated")

    assert {:error, {:sandbox_provider_disabled, :e2b, :workspace}} =
             Wake.wake_conversation(conv.id, "hello")

    # Refused before the succession: nothing was retired, built or moved, and
    # no server was started. The conversation is as it was, and its next
    # prompt rebuilds once the provider is back.
    conv = Repo.reload!(conv)
    assert conv.status == "idle"
    assert conv.sandbox_id == sandbox.id
    assert Repo.reload!(sandbox).status == "terminated"
    assert is_nil(Fountain.Conversations.ConversationServer.whereis(conv.id))

    assert Repo.aggregate(
             from(s in Fountain.Conversations.Sandbox,
               where: s.workspace_id == ^sandbox.workspace_id
             ),
             :count
           ) == 1
  end

  test "the fresh path's refusal of the agent's provider keeps the agent's advice" do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)

    {1, _} =
      Repo.update_all(from(a in Fountain.Agents.Agent, where: a.id == ^agent.id),
        set: [sandbox_provider: "e2b"]
      )

    # Its own machine is gone, so the wake places a fresh one on the agent's
    # provider.
    sandbox = insert_sandbox(user_id: user.id, status: "terminated")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    :ok = Wake.wake_in_background(conv.id, "hello", [])

    [{"failed", data}] = eventually(fn -> stages(conv.id, "wake") end)
    assert data["reason"] == "sandbox_provider_disabled"
    assert data["advice"] =~ "clear the agent's sandbox_provider override"
    receipt_resolved(conv)
  end

  test "a conversation's own parked sandbox gets advice about that sandbox" do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, machine_name: "own-on-e2b")
    {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended", provider: "e2b"})
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    :ok = Wake.wake_in_background(conv.id, "hello", [])

    [{"failed", data}] = eventually(fn -> stages(conv.id, "wake") end)
    assert data["reason"] == "sandbox_provider_disabled"
    assert data["advice"] =~ "this conversation's sandbox is parked on it"
    refute data["advice"] =~ "agent"
    receipt_resolved(conv)
  end

  test "a wake failure with nothing to act on carries no advice" do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

    Wake.report_unrun_prompt(conv.id, :fleet_full)

    assert [{"failed", data}] = stages(conv.id, "wake")
    refute Map.has_key?(data, "advice")
  end

  describe "the API's refusal" do
    test "renders whose provider it is" do
      for {whose, says} <- [
            {:workspace, "this workspace runs on it"},
            {:sandbox, "this conversation's sandbox is parked on it"}
          ] do
        conn =
          FountainWeb.FallbackController.call(
            Phoenix.ConnTest.build_conn(),
            {:error, {:sandbox_provider_disabled, :e2b, whose}}
          )

        assert %{"error" => "sandbox_provider_disabled", "message" => message} =
                 Phoenix.ConnTest.json_response(conn, 422)

        assert message =~ says
        refute message =~ "agent"
      end
    end

    test "the agent's override keeps its advice" do
      conn =
        FountainWeb.FallbackController.call(
          Phoenix.ConnTest.build_conn(),
          {:error, {:sandbox_provider_disabled, :e2b}}
        )

      assert %{"message" => message} = Phoenix.ConnTest.json_response(conn, 422)
      assert message =~ "clear the agent's sandbox_provider override"
    end
  end
end
