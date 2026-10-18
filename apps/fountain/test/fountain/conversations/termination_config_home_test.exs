defmodule Fountain.Conversations.TerminationConfigHomeTest do
  @moduledoc """
  Ending a conversation removes its config home (ADR 0097), from the live
  server's terminate path: only on an awake machine, and never a legacy home.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Termination

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "termination-home"}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox)
    home = "/home/sprite/.managoat/c/#{conv.id}"
    conv = conv |> Ecto.Changeset.change(config_home: home) |> Repo.update!()

    state = %{handle: @handle, sandbox_id: sandbox.id, conversation_id: conv.id}
    %{conv: conv, sandbox: sandbox, home: home, state: state}
  end

  test "an awake machine has the conversation's own home removed", ctx do
    home = ctx.home

    expect(Managoat.Sandbox, :exec, fn @handle, "bash", ["-c", script], _opts ->
      assert script == "rm -rf -- '#{home}'"
      {:ok, "", 0}
    end)

    assert :ok = Termination.remove_config_home_now(ctx.state)
  end

  test "a parked machine is not resumed to delete a directory", ctx do
    ctx.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
    reject(&Managoat.Sandbox.exec/4)
    assert :ok = Termination.remove_config_home_now(ctx.state)
  end

  test "a legacy home is shared and stays", ctx do
    ctx.conv |> Ecto.Changeset.change(config_home: nil) |> Repo.update!()
    reject(&Managoat.Sandbox.exec/4)
    assert :ok = Termination.remove_config_home_now(ctx.state)
  end

  test "no handle or no machine is nothing to do", ctx do
    reject(&Managoat.Sandbox.exec/4)
    assert :ok = Termination.remove_config_home_now(%{ctx.state | handle: nil})
    assert :ok = Termination.remove_config_home(%{ctx.state | handle: nil})
    assert :ok = Termination.remove_config_home_now(%{ctx.state | sandbox_id: nil})
  end

  test "a failed removal does not fail the terminate", ctx do
    expect(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "busy", 1} end)
    assert :ok = Termination.remove_config_home_now(ctx.state)
  end
end
