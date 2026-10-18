defmodule Fountain.Conversations.ConversationServerInstructionsTest do
  @moduledoc """
  The agent's `system` prompt must reach the sandbox (#848).

  #849 wired `Managoat.Runtimes.Instructions.write/3` into provision and
  reattach; #850 — branched before #849 landed — removed both call sites in
  its squash-merge and nothing failed, because the only tests were
  module-level. Every agent provisioned after that ran on the CLI's default
  persona. These tests pin the *wiring*: a provision (and a reattach) of an
  agent with a `system` prompt must write the runtime's user-level
  instructions file into the sandbox.
  """

  use Fountain.ConversationServerCase

  @prompt "You are Desk, a dedicated operator. Never mutate without an approved plan."

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)

    agent =
      insert_agent(
        user_id: user.id,
        environment_id: env.id,
        runtime: "gemini",
        system: @prompt
      )

    {:ok, user: user, agent: agent}
  end

  defp capture_writes do
    test = self()

    Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _handle, path, data, _opts ->
      send(test, {:wrote, path, data})
      :ok
    end)
  end

  defp assert_instructions_written do
    # The factory's conversation predates config homes, so it has the legacy one.
    path =
      Managoat.Runtimes.Instructions.path(
        "gemini",
        Fountain.Conversations.ConfigHome.legacy_home("gemini")
      )

    assert is_binary(path)

    assert_receive {:wrote, ^path, data}, 2_000
    assert data =~ @prompt
    assert data =~ "Written by Managoat"
  end

  test "a fresh provision writes the runtime's instructions file", %{user: user, agent: agent} do
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox_id: sandbox.id,
        status: "pending"
      )

    stub_happy_sprite()
    capture_writes()

    {pid, _ref, :alive} = start_server(conv)
    assert_instructions_written()
    GenServer.stop(pid)
  end

  test "a reattach rewrites it, so an edited prompt reaches the existing computer", %{
    user: user,
    agent: agent
  } do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id, status: "idle")

    stub_happy_sprite()
    capture_writes()

    {pid, _ref, :alive} = start_server(conv)
    assert_instructions_written()
    GenServer.stop(pid)
  end
end
