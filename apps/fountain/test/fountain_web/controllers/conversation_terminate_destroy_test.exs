defmodule FountainWeb.ConversationTerminateDestroyTest do
  @moduledoc """
  #2561: terminate answers once the conversation is terminated and its
  machine fenced, and destroys the machine at the provider behind the
  response. Internal callers, which act on the machine being gone, still
  destroy before they return.
  """
  # Global, so the provider stub reaches the destroy's task.
  use FountainWeb.ConnCase, async: false
  use Mimic

  alias Fountain.Conversations.{Conversation, Sandbox, Termination}
  alias Fountain.Repo

  setup :set_mimic_global

  setup do
    user = insert_active_user()
    {_record, raw_key} = insert_api_key(user)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{raw_key: raw_key, conv: conv, sandbox: sandbox}
  end

  test "answers before the provider destroy, which finishes behind it", ctx do
    test_pid = self()

    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle ->
      send(test_pid, {:destroying, self()})
      receive do: (:finish -> :ok)
    end)

    conn =
      build_conn()
      |> authed_with_key(ctx.raw_key)
      |> post("/api/conversations/#{ctx.conv.id}/terminate")

    assert conn.status == 204
    assert Repo.get!(Conversation, ctx.conv.id).status == "terminated"

    # Answered, and the destroy is still at the provider: the row is fenced, so
    # nothing else can reach the machine meanwhile.
    assert_receive {:destroying, destroyer}, 2_000

    assert %Sandbox{transition: "destroying"} =
             sandbox = Fountain.Machines.Lease.get(ctx.sandbox.id)

    refute sandbox.status == "terminated"

    send(destroyer, :finish)

    assert eventually(fn ->
             Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
           end)
  end

  test "an internal caller still destroys before it returns", ctx do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)

    assert :ok = Termination.terminate_conversation(ctx.conv.id, actor: "test")
    assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, tries - 1)
    end
  end
end
