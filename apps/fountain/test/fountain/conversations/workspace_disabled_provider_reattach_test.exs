defmodule Fountain.Conversations.WorkspaceDisabledProviderReattachTest do
  @moduledoc """
  #3004's last gap: a machine whose row says `ready`, on a sandbox provider
  disabled since (its credential gone at the last boot), is reached without a
  wake by a launch into its workspace and by a server reattaching to it, the
  boot sweep's included. Neither may call the provider: the adapter raises on
  its missing credential, and a server that met the raise was restarted into
  it until the restart budget every conversation server shares ran out and
  took them all down. Both now give the advice the wake's refusal gives.

  `e2b` has no credentials in the test configuration, so it reads as
  disabled. Not async: the servers run under the application's supervisor.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog
  import Ecto.Query

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, Launch, Rehydrator}

  setup :set_mimic_global

  setup do
    refute Fountain.SandboxProviders.enabled?(:e2b)

    # No provider call may be made for these machines, whatever answers it.
    stub(Managoat.Sandbox, :get, fn handle -> flunk("provider called for #{inspect(handle)}") end)

    user = insert_active_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    {:ok, user: user, agent: agent}
  end

  defp ready_machine(user, kind) do
    workspace = insert_workspace(user_id: user.id, provider: "e2b", status: "ready")

    sandbox =
      insert_sandbox(
        user_id: user.id,
        workspace_id: workspace.id,
        machine_name: "on-e2b-#{System.unique_integer([:positive])}",
        status: "ready"
      )

    {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready", provider: "e2b"})
    if kind == :explicit, do: explicit_workspace!(sandbox)
    {workspace, sandbox}
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

  defp receipt_resolved(conv_id) do
    eventually(fn ->
      not Repo.exists?(
        from(r in Fountain.Conversations.PromptReceipt, where: r.conversation_id == ^conv_id)
      )
    end)
  end

  defp workspace_advice?(advice) do
    advice =~ "sandbox provider e2b is not configured" and
      advice =~ "this workspace runs on it" and
      advice =~ "create a workspace with another sandbox_provider" and
      not (advice =~ "agent")
  end

  describe "a launch onto the workspace's ready machine" do
    test "starts no server, and its prompt is refused with the workspace's advice", ctx do
      {workspace, sandbox} = ready_machine(ctx.user, :explicit)

      {:ok, conv} =
        Launch.start_conversation(%{
          "agent_id" => ctx.agent.id,
          "user_id" => ctx.user.id,
          "workspace_id" => workspace.id,
          "prompt" => "hello",
          "client_request_id" => "r-1"
        })

      [{"failed", data}] = eventually(fn -> stages(conv.id, "wake") end)
      assert data["reason"] == "sandbox_provider_disabled"
      assert data["retryable"] == false
      assert data["client_request_id"] == "r-1"
      assert workspace_advice?(data["advice"])
      receipt_resolved(conv.id)

      assert is_nil(ConversationServer.whereis(conv.id))
      assert stages(conv.id, "reattach") == []
      # Kept for the provider's return; the next prompt is refused the same way.
      assert Repo.reload!(sandbox).status == "ready"
      assert Repo.reload!(conv).sandbox_id == sandbox.id
    end

    test "without a prompt is left alone", ctx do
      {workspace, sandbox} = ready_machine(ctx.user, :explicit)

      {:ok, conv} =
        Launch.start_conversation(%{
          "agent_id" => ctx.agent.id,
          "user_id" => ctx.user.id,
          "workspace_id" => workspace.id
        })

      assert is_nil(ConversationServer.whereis(conv.id))

      assert Repo.all(from(e in Conversations.LogEvent, where: e.conversation_id == ^conv.id)) ==
               []

      assert Repo.reload!(sandbox).status == "ready"
    end
  end

  describe "a server reattaching to the ready machine" do
    test "the boot sweep's fails the reattach with the workspace's advice, and nothing crashes",
         ctx do
      {_workspace, sandbox} = ready_machine(ctx.user, :explicit)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      supervisor = Process.whereis(Fountain.ConversationSupervisor)

      log =
        capture_log(fn ->
          Rehydrator.run()
          [{"failed", data}] = eventually(fn -> stages(conv.id, "reattach") end)
          send(self(), {:stage, data})
          eventually(fn -> is_nil(ConversationServer.whereis(conv.id)) end)
        end)

      assert_received {:stage, data}
      assert data["reason"] == "sandbox_provider_disabled"
      assert data["retryable"] == false
      assert workspace_advice?(data["advice"])

      # Stopped, not crashed into a restart loop: one stage, and the
      # supervisor every conversation server shares is the one it was.
      refute log =~ "terminating"
      assert Process.whereis(Fountain.ConversationSupervisor) == supervisor
      assert length(stages(conv.id, "reattach")) == 1

      # The row and the conversation are as they were; with no prompt held
      # there is nothing to report as not run.
      assert Repo.reload!(sandbox).status == "ready"
      assert Repo.reload!(conv).status == "idle"
      assert stages(conv.id, "wake") == []
    end

    test "a conversation's own ready sandbox gets the advice about that sandbox", ctx do
      {_workspace, sandbox} = ready_machine(ctx.user, :implicit)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      capture_log(fn ->
        Rehydrator.run()
        eventually(fn -> stages(conv.id, "reattach") end)
        eventually(fn -> is_nil(ConversationServer.whereis(conv.id)) end)
      end)

      [{"failed", data}] = stages(conv.id, "reattach")
      assert data["reason"] == "sandbox_provider_disabled"
      assert data["advice"] =~ "this conversation's sandbox is parked on it"
      refute data["advice"] =~ "agent"
      assert Repo.reload!(sandbox).status == "ready"
    end

    test "a prompt the server holds is reported as not run, with the advice", ctx do
      {_workspace, sandbox} = ready_machine(ctx.user, :explicit)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      {:ok, runtime_module} = Fountain.RuntimeDispatch.for_agent(ctx.agent)

      # The check waits for the prompt to be queued, as a launch's is right
      # after the server starts, so the server holds it when it refuses.
      stub(Fountain.Conversations.Wake, :machine_provider_usable, fn sandbox ->
        receive do
          :queued -> :ok
        end

        call_original(Fountain.Conversations.Wake, :machine_provider_usable, [sandbox])
      end)

      capture_log(fn ->
        {:ok, pid} =
          Conversations.register_server(
            sandbox.id,
            Launch.child_spec(conv.id, sandbox.id, runtime_module)
          )

        Fountain.Conversations.PromptDelivery.queue(
          pid,
          "hello",
          [],
          Fountain.Conversations.PromptReceipt.accept(conv.id, client_request_id: "r-2")
        )

        send(pid, :queued)
        eventually(fn -> stages(conv.id, "wake") end)
        eventually(fn -> is_nil(ConversationServer.whereis(conv.id)) end)
      end)

      [{"failed", wake}] = stages(conv.id, "wake")
      assert wake["reason"] == "sandbox_provider_disabled"
      assert wake["retryable"] == false
      assert wake["client_request_id"] == "r-2"
      assert workspace_advice?(wake["advice"])
      receipt_resolved(conv.id)
    end
  end
end
