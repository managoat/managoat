defmodule Fountain.Machines.RebuildFollowTest do
  @moduledoc """
  ADR 0097 step 4: the conversations of a workspace follow its rebuilt
  machine. `Provision.rebuild/3` moves every live conversation of the
  workspace to the new row in the succession's commit (transcript kept,
  runtime session and skills record cleared), ends the old machine's turns
  while they are still bound to it, and tells every moved conversation's
  server but the caller's `machine_gone`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox, Turn}
  alias Fountain.Machines.Provision
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    ws = insert_workspace(user_id: user.id, status: "ready", implicit: false, name: "shared")

    old =
      insert_sandbox(user_id: user.id, agent_id: agent.id, workspace_id: ws.id, status: "ready")

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    mine = conversation(user, agent, old, "idle")
    theirs = conversation(user, agent, old, "idle")
    ended = conversation(user, agent, old, "terminated")

    {:ok, user: user, agent: agent, ws: ws, old: old, mine: mine, theirs: theirs, ended: ended}
  end

  defp conversation(user, agent, sandbox, status) do
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: status)

    conv
    |> Ecto.Changeset.change(
      runtime_session_id: "session-#{conv.id}",
      applied_skills: [%{"x" => 1}]
    )
    |> Repo.update!()
  end

  defp opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        actor: "system:conversation_server",
        conversation_id: ctx.mine.id,
        provider: :already_gone,
        attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"}
      ],
      extra
    )
  end

  defp stand_in_server(conversation_id) do
    test = self()

    start_supervised!(
      {Task,
       fn ->
         {:ok, _} = Registry.register(Fountain.ConversationRegistry, conversation_id, nil)
         receive do: (msg -> send(test, {:told, conversation_id, msg}))
       end},
      id: {:stand_in, conversation_id}
    )

    assert {:ok, _} = ConversationServer.await_registered(conversation_id, 2_000)
  end

  test "every live conversation of the workspace follows the new machine, in one commit", ctx do
    test = self()

    # The pipeline is handed the new row, and mid-build every live
    # conversation is already bound to it: there is no moment at which a
    # conversation names the retired machine while the workspace has a live
    # one.
    builder = fn next ->
      fn _handle, _epoch ->
        send(test, {:building, next, Repo.all(Conversation)})
        {:ok, :built}
      end
    end

    capture_log(fn ->
      assert {:ok, :rebuilt, %Sandbox{} = next, :built} =
               Provision.rebuild(ctx.old.id, builder, opts(ctx))

      send(test, {:next, next})
    end)

    assert_received {:next, next}
    assert_received {:building, %Sandbox{id: next_id}, mid_build}
    assert next_id == next.id

    for conv <- mid_build, conv.id in [ctx.mine.id, ctx.theirs.id] do
      assert conv.sandbox_id == next.id
      assert conv.workspace_id == ctx.ws.id
      assert conv.runtime_session_id == nil
      assert conv.applied_skills == []
    end

    # An ended conversation keeps its history where it was.
    ended = Repo.reload!(ctx.ended)
    assert ended.sandbox_id == ctx.old.id
    assert ended.runtime_session_id == "session-#{ctx.ended.id}"
  end

  test "the old machine's running turns are ended while still bound to it", ctx do
    turn = insert_turn(ctx.theirs, %{status: "running", started_at: DateTime.utc_now()})

    capture_log(fn ->
      assert {:ok, :rebuilt, _next, :built} =
               Provision.rebuild(ctx.old.id, fn _h, _e -> {:ok, :built} end, opts(ctx))
    end)

    assert %Turn{status: "interrupted"} = Repo.reload!(turn)
  end

  test "every moved conversation's server but the caller's is told machine_gone", ctx do
    stand_in_server(ctx.theirs.id)
    stand_in_server(ctx.mine.id)
    old_id = ctx.old.id
    theirs = ctx.theirs.id

    capture_log(fn ->
      assert {:ok, :rebuilt, _next, :built} =
               Provision.rebuild(ctx.old.id, fn _h, _e -> {:ok, :built} end, opts(ctx))
    end)

    assert_receive {:told, ^theirs,
                    {:"$gen_cast", {:machine_gone, ^old_id, "reclaimed", "rebuilt", _message}}},
                   2_000

    refute_receive {:told, _, _}, 200
  end

  test "a refused succession moves nobody", ctx do
    # One more than the ceiling's worth besides the old machine.
    fill_fleet(0)
    insert_sandbox(status: "ready")

    assert {:error, :fleet_full} =
             Provision.rebuild(ctx.old.id, fn _h, _e -> {:ok, :built} end, opts(ctx))

    assert Repo.reload!(ctx.theirs).sandbox_id == ctx.old.id
    assert Repo.reload!(ctx.theirs).runtime_session_id == "session-#{ctx.theirs.id}"
  end

  test "a second rebuild of a workspace that has its machine is refused as occupied", ctx do
    capture_log(fn ->
      assert {:ok, :rebuilt, _next, :built} =
               Provision.rebuild(ctx.old.id, fn _h, _e -> {:ok, :built} end, opts(ctx))
    end)

    # The co-tenant's own prompt, arriving through the row it was moved from.
    assert {:error, :occupied} =
             Provision.rebuild(
               ctx.old.id,
               fn _h, _e -> flunk("built twice") end,
               opts(ctx, conversation_id: ctx.theirs.id)
             )
  end
end
