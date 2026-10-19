defmodule Fountain.Workspaces.WorkspaceRetryTest do
  @moduledoc """
  #3013: a failed explicit workspace's setup run again with no prompt
  (`Fountain.Workspaces.retry_workspace/2`). The retry rebuilds the machine
  from the failed row under the workspace's lease, with the environment and
  vault as they are then; it settles the workspace as a create does, with the
  same redacted error; two retries start one setup; a rebuild already made
  from the failed row is followed rather than repeated; a retry that reaches
  no machine goes back to `failed`; and a delete stops it.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Broker.Native.Session
  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.Workspace
  alias Managoat.Sandbox.Handle

  setup :set_mimic_global

  # A retry checks its provider is enabled; the test config has no token.
  setup {Fountain.DataCase, :configure_sprites}

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "make setup")
    vault = insert_vault(user_id: user.id)
    test = self()

    stub(Managoat.Sandbox, :create, fn provider, name ->
      send(test, {:created, name})
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
    stub(Managoat.Sandbox, :write_file, fn _handle, _path, _body, _opts -> :ok end)
    stub(Managoat.Sandbox, :apply_network_policy, fn _handle, _policy -> :ok end)
    stub(Fountain.Broker.TransportRelay, :ensure, fn _handle, _owner -> :ok end)

    stub(Managoat.Sandbox, :exec, fn
      _handle, "bash", ["-c", _wrapper, "fountain-setup", script], _opts ->
        send(test, {:setup_script, script})
        {:ok, "", 0}

      _handle, _cmd, _args, _opts ->
        {:ok, "", 0}
    end)

    {:ok, user: user, env: env, vault: vault}
  end

  # A workspace whose setup on create failed, as `Provisioner.run/2` leaves
  # it: its one sandbox `failed`, the workspace `failed` with an error.
  defp failed_workspace!(ctx) do
    stub(Provisioner, :start, fn _workspace, _sandbox_id -> {:ok, self()} end)

    {:ok, workspace} =
      Workspaces.create_workspace(
        ctx.user.id,
        %{"name" => "work", "environment_id" => ctx.env.id, "vault_id" => ctx.vault.id},
        actor: "api"
      )

    sandbox = sandbox_of(workspace)

    stub(Provisioning, :run_setup_script, fn _h, _e, _se, nil -> {:error, {:setup_exit, 3}} end)
    capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

    stub(Provisioning, :run_setup_script, fn h, e, se, c ->
      call_original(Provisioning, :run_setup_script, [h, e, se, c])
    end)

    assert %Workspace{status: "failed"} = workspace = Repo.reload!(workspace)
    assert Repo.reload!(sandbox).status == "failed"
    flush_created()
    {workspace, sandbox}
  end

  defp flush_created do
    receive do
      {:created, _} -> flush_created()
    after
      0 -> :ok
    end
  end

  defp sandbox_of(workspace),
    do: Repo.one!(from s in Sandbox, where: s.workspace_id == ^workspace.id, limit: 1)

  defp sandboxes_of(workspace),
    do: Repo.all(from s in Sandbox, where: s.workspace_id == ^workspace.id)

  defp workspace_sessions(workspace_id),
    do: Repo.all(from s in Session, where: s.workspace_id == ^workspace_id)

  defp wait_until(fun, attempts \\ 100) do
    cond do
      fun.() ->
        :ok

      attempts == 0 ->
        flunk("condition never held")

      true ->
        Process.sleep(50)
        wait_until(fun, attempts - 1)
    end
  end

  describe "retry_workspace/2" do
    test "sets the workspace up again from the environment as it is now", ctx do
      {workspace, failed} = failed_workspace!(ctx)

      {:ok, _} =
        Fountain.Environments.update_environment(ctx.env, %{"setup_script" => "make fixed"})

      :ok = Workspaces.subscribe(ctx.user.id)

      assert {:ok, %Workspace{status: "provisioning", error: nil}} =
               Workspaces.retry_workspace(workspace, actor: "api", request_ip: "10.0.0.1")

      assert_receive {:workspace_status, %{status: "provisioning"}}
      assert_receive {:workspace_status, %{status: "ready", error: nil}}, 5_000
      assert_received {:setup_script, "make fixed"}
      assert_received {:created, _name}
      refute_received {:created, _}

      wait_until(fn -> not Provisioner.running?(workspace.id) end)
      assert %Workspace{status: "ready", error: nil} = Repo.reload!(workspace)
      assert Repo.reload!(failed).status == "failed"
      assert [next] = Enum.reject(sandboxes_of(workspace), &(&1.id == failed.id))
      assert next.status == "ready"
      assert next.environment_id == ctx.env.id
      assert next.vault_id == ctx.vault.id
      # Built from the edited environment (#2987), not the failed machine's.
      edited = Repo.reload!(ctx.env)
      assert next.built_from_revision == edited.revision
      assert next.predecessor_id == failed.id
      assert Repo.reload!(failed).built_from_revision != edited.revision
      assert workspace_sessions(workspace.id) == []

      assert [event] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.retried")
      assert event.actor == "api"
      assert event.request_ip == "10.0.0.1"
      assert event.metadata["failed_sandbox_id"] == failed.id
      refute Map.has_key?(event.metadata, "error")
    end

    test "moves the workspace's conversations to the new machine", ctx do
      {workspace, failed} = failed_workspace!(ctx)
      agent = insert_agent(user_id: ctx.user.id)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: agent,
          sandbox: failed,
          workspace_id: workspace.id,
          status: "idle"
        )

      capture_log(fn ->
        {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")
        wait_until(fn -> Repo.reload!(workspace).status == "ready" end)
      end)

      wait_until(fn -> not Provisioner.running?(workspace.id) end)
      moved = Repo.reload!(conv)
      assert moved.sandbox_id != failed.id
      assert Repo.get!(Sandbox, moved.sandbox_id).status == "ready"
    end

    test "a setup that fails again fails the workspace with a redacted error", ctx do
      insert_vault_secret(ctx.vault, %{"key" => "API_SECRET", "value" => "s3cret-value-123"})
      {workspace, _failed} = failed_workspace!(ctx)

      stub(Provisioning, :install_packages, fn _handle, _env, _sprite_env, nil ->
        {:error, {:packages, 100, "first\nusing s3cret-value-123 for apt\n"}}
      end)

      :ok = Workspaces.subscribe(ctx.user.id)

      capture_log(fn ->
        {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")
        assert_receive {:workspace_status, %{status: "failed", error: error}}, 5_000
        assert error =~ "using [REDACTED] for apt"
        refute error =~ "s3cret-value-123"
        wait_until(fn -> not Provisioner.running?(workspace.id) end)
      end)

      assert %Workspace{status: "failed", error: error} = Repo.reload!(workspace)
      refute error =~ "s3cret"
      assert workspace_sessions(workspace.id) == []

      for event <- Audit.list_for_user(ctx.user.id) do
        refute inspect(event.metadata) =~ "s3cret"
      end

      # Failed again, so it may be retried again.
      stub(Provisioning, :install_packages, fn _h, _e, _se, nil -> :ok end)

      capture_log(fn ->
        assert {:ok, _} = Workspaces.retry_workspace(Repo.reload!(workspace), actor: "api")
        wait_until(fn -> Repo.reload!(workspace).status == "ready" end)
      end)
    end

    test "is refused unless the workspace is failed, and two retries start one setup", ctx do
      {workspace, _failed} = failed_workspace!(ctx)
      test = self()

      stub(Provisioner, :retry, fn workspace, sandbox_id ->
        send(test, {:retry_started, workspace.id, sandbox_id})
        {:ok, self()}
      end)

      # Both hold the row as it was read: failed.
      assert {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")

      assert {:error, {:workspace_not_failed, "provisioning"}} =
               Workspaces.retry_workspace(workspace, actor: "api")

      assert_received {:retry_started, _, _}
      refute_received {:retry_started, _, _}
      assert [_one] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.retried")

      ready = insert_workspace(user_id: ctx.user.id, implicit: false, name: "r", status: "ready")

      assert {:error, {:workspace_not_failed, "ready"}} =
               Workspaces.retry_workspace(ready, actor: "api")
    end

    test "a rebuild (#2986) whose machine is made while a retry's task is registered is built",
         ctx do
      {workspace, failed} = failed_workspace!(ctx)
      test = self()

      # The retry's task, registered under the workspace after the rebuild
      # looked (so the rebuild was not refused), and about to follow it.
      holder =
        spawn(fn ->
          {:ok, _} = Registry.register(Fountain.WorkspaceSetupRegistry, workspace.id, failed.id)
          send(test, :registered)

          receive do
            :go -> :ok
          end
        end)

      assert_receive :registered
      stub(Provisioner, :running?, fn _id -> false end)
      stub(Provisioner, :start, fn w, id -> call_original(Provisioner, :start, [w, id]) end)

      capture_log(fn ->
        assert {:ok, %Workspace{status: "provisioning"}} =
                 Workspaces.rebuild_workspace(workspace, actor: "api")

        [next] = Enum.reject(sandboxes_of(workspace), &(&1.id == failed.id))
        assert Repo.reload!(next).status == "pending"

        # Its provision waits for the retry's task, then builds it.
        send(holder, :go)
        wait_until(fn -> Repo.reload!(next).status == "ready" end)
        wait_until(fn -> Repo.reload!(workspace).status == "ready" end)
      end)
    end

    test "an implicit workspace, and one being deleted, are not found", ctx do
      implicit = insert_workspace(user_id: ctx.user.id, status: "failed")
      assert {:error, :not_found} = Workspaces.retry_workspace(implicit, actor: "api")

      {workspace, _failed} = failed_workspace!(ctx)
      reject(&Provisioner.retry/2)

      # Disowned by a delete after the caller's read.
      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id), set: [user_id: nil])

      assert {:error, :not_found} = Workspaces.retry_workspace(workspace, actor: "api")
      assert Audit.list_for_user(ctx.user.id, action_prefix: "workspace.retried") == []
    end

    test "a full fleet at the rebuild puts the workspace back to failed, with the reason", ctx do
      {workspace, _failed} = failed_workspace!(ctx)

      # The check at the door passes; the reservation inside the rebuild
      # finds the fleet full.
      stub(Fountain.Quotas, :check_fleet_ceiling, fn _opts -> :ok end)
      fill_fleet()
      :ok = Workspaces.subscribe(ctx.user.id)

      capture_log(fn ->
        {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")
        assert_receive {:workspace_status, %{status: "failed", error: error}}, 5_000
        assert error =~ "every sandbox slot"
      end)

      refute_received {:created, _}
      assert %Workspace{status: "failed"} = Repo.reload!(workspace)
      assert length(sandboxes_of(workspace)) == 1
    end

    test "a delete stops a retry in progress and destroys what it was building", ctx do
      {workspace, _failed} = failed_workspace!(ctx)
      test = self()

      stub(Provisioning, :run_setup_script, fn _h, _e, _se, nil ->
        send(test, :setting_up)
        Process.sleep(:infinity)
      end)

      {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")
      assert_receive :setting_up, 5_000

      capture_log(fn ->
        assert {:ok, _} = Workspaces.delete_workspace(Repo.reload!(workspace), actor: "api")
      end)

      refute Provisioner.running?(workspace.id)
      wait_until(fn -> workspace_sessions(workspace.id) == [] end)

      for sandbox <- sandboxes_of(workspace),
          do: assert(sandbox.status in ~w(terminated failed))
    end
  end

  describe "Provisioner.rerun/3" do
    test "follows a rebuild already made from the failed machine instead of building again",
         ctx do
      {workspace, failed} = failed_workspace!(ctx)

      # A prompt into the workspace rebuilt it from the failed row while this
      # retry waited for the lease, and that setup failed too.
      later = DateTime.add(failed.inserted_at, 1, :second)

      newer =
        insert_sandbox(user_id: ctx.user.id, workspace_id: workspace.id, status: "failed")

      {1, _} =
        Repo.update_all(from(s in Sandbox, where: s.id == ^newer.id), set: [inserted_at: later])

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
          set: [status: "provisioning"]
        )

      assert {:error, :occupied} = Provisioner.rerun(workspace.id, failed.id)
      refute_received {:created, _}

      # Not this retry's to settle: the rebuild that made the newer row did.
      :ok = Workspaces.abandon_retry(workspace.id, failed.id, :occupied)
      assert Repo.reload!(workspace).status == "provisioning"
    end
  end

  describe "rows inserted in the same second" do
    # Sandbox timestamps are to the second; a successor in the failed row's
    # second is told apart by naming it as its predecessor.
    defp same_second!(row, of, predecessor_id) do
      {1, _} =
        Repo.update_all(from(s in Sandbox, where: s.id == ^row.id),
          set: [inserted_at: of.inserted_at, predecessor_id: predecessor_id]
        )
    end

    test "a successor born in the failed row's second is still followed", ctx do
      {workspace, failed} = failed_workspace!(ctx)

      newer =
        insert_sandbox(user_id: ctx.user.id, workspace_id: workspace.id, status: "failed")

      same_second!(newer, failed, failed.id)

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^workspace.id),
          set: [status: "provisioning"]
        )

      assert {:error, :occupied} = Provisioner.rerun(workspace.id, failed.id)
      :ok = Workspaces.abandon_retry(workspace.id, failed.id, :occupied)
      assert Repo.reload!(workspace).status == "provisioning"
      refute_received {:created, _}
    end

    test "a predecessor in the failed row's second does not stop the retry", ctx do
      {workspace, failed} = failed_workspace!(ctx)

      older =
        insert_sandbox(user_id: ctx.user.id, workspace_id: workspace.id, status: "terminated")

      same_second!(older, failed, nil)

      capture_log(fn ->
        assert {:ok, :rebuilt, %Sandbox{status: "ready"}, _} =
                 Provisioner.rerun(workspace.id, failed.id)
      end)

      assert_received {:created, _}
    end
  end

  describe "the boot sweep" do
    test "puts back to failed a retry the server stopped before it built anything", ctx do
      {workspace, _failed} = failed_workspace!(ctx)
      stub(Provisioner, :retry, fn _workspace, _sandbox_id -> {:ok, self()} end)
      {:ok, _} = Workspaces.retry_workspace(workspace, actor: "api")

      # A workspace a create is provisioning is left alone.
      stub(Provisioner, :start, fn _workspace, _sandbox_id -> {:ok, self()} end)

      {:ok, creating} =
        Workspaces.create_workspace(ctx.user.id, %{"name" => "c", "environment_id" => ctx.env.id})

      capture_log(fn -> :ok = Workspaces._unsafe_settle_stranded_retries() end)

      assert %Workspace{status: "failed", error: error} = Repo.reload!(workspace)
      assert error =~ "server restarted"
      assert Repo.reload!(creating).status == "provisioning"
    end
  end
end
