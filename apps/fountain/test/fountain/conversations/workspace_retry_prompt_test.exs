defmodule Fountain.Conversations.WorkspaceRetryPromptTest do
  @moduledoc """
  #3013: a retry of a failed workspace and a prompt into it compose. Both
  rebuild the workspace's machine from its failed row under the workspace's
  lease, so they set it up once: a prompt whose server starts while the
  retry is building follows the retry's machine, and a retry that arrives
  while a prompt's rebuild is under way is refused as not failed. Driven
  through a real `ConversationServer`.
  """

  use Fountain.ConversationServerCase

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.Workspace

  # A retry checks its provider is enabled; the test config has no token.
  setup {Fountain.DataCase, :configure_sprites}

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    failed = insert_sandbox(user_id: user.id, status: "failed") |> explicit_workspace!()

    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^failed.workspace_id),
        set: [status: "failed", error: "the environment's setup script exited 1"]
      )

    # `pending`: what the wake sets before it starts a server to rebuild.
    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: failed, status: "pending")

    stub_happy_sprite()
    test = self()

    stub(Managoat.Sandbox.Sprites, :create, fn name, _opts ->
      send(test, {:created, name})
      {:ok, Managoat.Sandbox.Sprites.build_handle(name)}
    end)

    stub(Fountain.Broker.TransportRelay, :ensure, fn _handle, _owner -> :ok end)

    {:ok,
     user: user, conv: conv, failed: failed, workspace: Repo.get!(Workspace, failed.workspace_id)}
  end

  defp successor(ctx),
    do:
      Repo.one(
        from s in Sandbox, where: s.workspace_id == ^ctx.workspace.id and s.id != ^ctx.failed.id
      )

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(25)
        wait_until(fun, attempts - 1)
    end
  end

  test "a prompt whose server starts during a retry follows the retry's machine", ctx do
    # The retry's setup (no conversation) takes a moment.
    stub(Fountain.Conversations.Provisioning, :install_packages, fn
      _handle, _env, _sprite_env, nil ->
        Process.sleep(600)
        :ok

      _handle, _env, _sprite_env, _conv_id ->
        :ok
    end)

    capture_log(fn ->
      {:ok, %Workspace{status: "provisioning"}} =
        Workspaces.retry_workspace(ctx.workspace, actor: "api")

      wait_until(fn -> successor(ctx) != nil end)

      # The wake started the server on the conversation's failed row before
      # the retry's succession moved it.
      {pid, _ref, :alive} = start_server(ctx.conv)
      next = successor(ctx)

      assert :sys.get_state(pid).sandbox_id == next.id
      assert Repo.get!(Sandbox, next.id).status == "ready"
      assert Repo.reload!(ctx.conv).sandbox_id == next.id
      wait_until(fn -> not Provisioner.running?(ctx.workspace.id) end)
    end)

    assert_received {:created, _}
    refute_received {:created, _}
    assert Repo.reload!(ctx.workspace).status == "ready"
  end

  test "a prompt woken during a retry's setup waits for it and fails with it", ctx do
    previous = Application.get_env(:fountain, :conversation_registry_settle_ms)
    Application.put_env(:fountain, :conversation_registry_settle_ms, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :conversation_registry_settle_ms, previous),
        else: Application.delete_env(:fountain, :conversation_registry_settle_ms)
    end)

    # The retry's setup fails again, after a moment.
    stub(Fountain.Conversations.Provisioning, :install_packages, fn
      _handle, _env, _sprite_env, nil ->
        Process.sleep(500)
        {:error, {:packages, 1, "first\nE: still broken\n"}}

      _handle, _env, _sprite_env, _conv_id ->
        :ok
    end)

    capture_log(fn ->
      {:ok, _} = Workspaces.retry_workspace(ctx.workspace, actor: "api")
      wait_until(fn -> successor(ctx) != nil end)

      # The conversation is on the retry's machine, mid-setup, with no server.
      assert Repo.reload!(ctx.conv).sandbox_id == successor(ctx).id

      assert {:error, :workspace_setup_failed} =
               Fountain.Conversations.Wake.wake_conversation(ctx.conv.id, "hello")

      wait_until(fn -> not Provisioner.running?(ctx.workspace.id) end)
    end)

    assert_received {:created, _}
    refute_received {:created, _}
    assert Repo.get!(Sandbox, successor(ctx).id).status == "failed"
    assert %Workspace{status: "failed"} = Repo.reload!(ctx.workspace)
    # The wake's `pending` mark is undone with it.
    assert Repo.reload!(ctx.conv).status == "idle"
  end

  test "a prompt whose server started before a retry that failed again fails with it", ctx do
    # The retry built a new machine from the failed row, moving the
    # conversation, and that setup failed too.
    later = DateTime.add(ctx.failed.inserted_at, 1, :second)

    again =
      insert_sandbox(user_id: ctx.user.id, workspace_id: ctx.workspace.id, status: "failed")

    {1, _} =
      Repo.update_all(from(s in Sandbox, where: s.id == ^again.id), set: [inserted_at: later])

    {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: again.id})

    capture_log(fn ->
      # Started on the failed row it was woken for, as the wake did.
      {_pid, ref, _} = start_server(ctx.conv)
      assert :normal = assert_stopped(ref)
    end)

    refute_received {:created, _}
    assert length(Repo.all(from s in Sandbox, where: s.workspace_id == ^ctx.workspace.id)) == 2

    assert Enum.any?(
             Conversations._unsafe_list_log_events(ctx.conv.id),
             &(&1.kind == "stage" and &1.stage == "provision" and &1.state == "failed")
           )
  end

  test "a retry while a prompt's rebuild is under way is refused, and the prompt sets it up",
       ctx do
    test = self()

    # The prompt's own provision, in the conversation's pipeline, takes a
    # moment after its succession has made the new row.
    stub(Fountain.Conversations.Provisioning, :install_packages, fn
      _handle, _env, _sprite_env, nil ->
        :ok

      _handle, _env, _sprite_env, _conv_id ->
        Process.sleep(400)
        :ok
    end)

    spawn(fn ->
      wait_until(fn -> successor(ctx) != nil end)
      send(test, {:retry, Workspaces.retry_workspace(ctx.workspace, actor: "api")})
    end)

    capture_log(fn ->
      {pid, _ref, :alive} = start_server(ctx.conv)
      assert :sys.get_state(pid).sandbox_id == successor(ctx).id
    end)

    assert_receive {:retry, {:error, {:workspace_not_failed, "provisioning"}}}, 5_000
    assert_received {:created, _}
    refute_received {:created, _}
    refute Provisioner.running?(ctx.workspace.id)
    assert Repo.reload!(ctx.workspace).status == "ready"
  end
end
