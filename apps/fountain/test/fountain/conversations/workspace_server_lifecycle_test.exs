defmodule Fountain.Conversations.WorkspaceServerLifecycleTest do
  @moduledoc """
  A live `ConversationServer` on a workspace (ADR 0097, step 4): ending it
  keeps an explicit workspace's machine and ends an implicit one's with its
  workspace, and the max-lifetime ceiling parks an explicit workspace's
  machine after cutting every turn on it.
  """

  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Turn
  alias Fountain.Workspaces.Workspace

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp conversation(hours \\ 0) do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    at = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(s in Fountain.Conversations.Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: at]
    )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    {conv, Repo.reload!(sandbox)}
  end

  describe "ending a conversation with a live server" do
    test "on an explicit workspace keeps the machine for the others", _ctx do
      {conv, sandbox} = conversation()
      explicit_workspace!(sandbox)
      stub_happy_sprite()
      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> send(test, :destroyed) && :ok end)

      {pid, ref, :alive} = start_server(conv)
      assert :ok = GenServer.call(pid, {:terminate_conv, []})
      assert :normal = assert_stopped(ref)

      assert Repo.reload!(conv).status == "terminated"
      sandbox = Fountain.Machines.Lease.get(sandbox.id)
      assert sandbox.status == "ready"
      assert is_nil(sandbox.transition)
      assert Repo.get(Workspace, sandbox.workspace_id)
      refute_receive :destroyed, 200
    end

    test "on an implicit workspace destroys the machine and ends the workspace", _ctx do
      {conv, sandbox} = conversation()
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      capture_log(fn -> assert :ok = GenServer.call(pid, {:terminate_conv, []}) end)
      assert :normal = assert_stopped(ref)

      assert Repo.reload!(sandbox).status == "terminated"
      refute Repo.get(Workspace, sandbox.workspace_id)
    end
  end

  describe "the ceiling on an explicit workspace" do
    test "cuts every turn on the machine, parks it, and keeps the disk", _ctx do
      {conv, sandbox} = conversation(48)
      explicit_workspace!(sandbox)
      stub_happy_sprite()
      test = self()
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> send(test, :destroyed) && :ok end)

      other = insert_conversation(user_id: conv.user_id, sandbox: sandbox, status: "running")
      theirs = insert_turn(other, %{status: "running", started_at: DateTime.utc_now()})

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        {pid, ref, :alive} = start_server(conv)
        mine = insert_turn(conv, %{status: "running", started_at: DateTime.utc_now()})
        :sys.replace_state(pid, fn state -> %{state | current_turn: mine} end)

        capture_log(fn ->
          send(pid, :lifecycle_check)
          assert :normal = assert_stopped(ref)
        end)

        assert %Turn{status: "interrupted"} = Repo.reload!(mine)
      end)

      assert %Turn{status: "interrupted"} = Repo.reload!(theirs)
      assert Repo.reload!(sandbox).status == "suspended"
      assert Repo.reload!(conv).status == "idle"
      refute_receive :destroyed, 200

      [parked] =
        conv.id
        |> Fountain.Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "sandbox"))

      assert %{"event" => "suspended", "reason" => "max_lifetime", "message" => message} =
               Jason.decode!(parked.data)

      assert message =~ "parked"
    end
  end
end
