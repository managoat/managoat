defmodule Fountain.Conversations.LaunchCommitBoundaryTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Wake

  setup do
    user = insert_active_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        status: "ready",
        agent_id: agent.id,
        environment_id: env.id
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  for path <- [:create, :wake] do
    @tag path: path
    test "#{path} refuses an enclosing transaction before external work or row changes", ctx do
      reject_server_start()
      reject(Managoat.Sandbox.Sprites, :get, 1)
      reject(Managoat.Sandbox.Sprites, :create, 2)
      reject(Managoat.Sandbox.Sprites, :resume, 1)
      counts = {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
      attrs = %{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id, "prompt" => "hello"}

      # The caller deliberately commits. Refusal must leave no pending rows,
      # even when the caller does not turn the returned error into a rollback.
      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 case ctx.path do
                   :create ->
                     Launch.start_conversation(attrs)

                   :wake ->
                     Wake.wake_conversation(ctx.conv.id, "hello")
                 end
               end)

      assert counts == {Repo.aggregate(Conversation, :count), Repo.aggregate(Sandbox, :count)}
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      assert Repo.reload!(ctx.conv).status == "idle"
    end
  end
end
