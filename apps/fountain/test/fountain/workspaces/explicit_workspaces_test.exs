defmodule Fountain.Workspaces.ExplicitWorkspacesTest do
  @moduledoc """
  ADR 0097, step 5: explicit workspaces in the context. Create reserves the
  workspace and its first sandbox in one commit and provisions it at once,
  with no conversation, under a network of the workspace's own (the broker's
  floor and CA, a relay owned by the workspace, a broker session minted from
  its environment and vault and released when the setup ends); the status
  settles with the provision and is broadcast; a failure carries a redacted
  error; a secret write reaches a live setup session; delete ends every live
  conversation and destroys the machine with the caller's attribution.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Broker.Native.Session
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Network
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.Workspace
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "make setup")
    vault = insert_vault(user_id: user.id)

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    {:ok, user: user, env: env, vault: vault}
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{"name" => "work", "environment_id" => ctx.env.id, "vault_id" => ctx.vault.id},
      extra
    )
  end

  # Create without running the provision: `Provisioner.run/2` is driven
  # synchronously where a test needs it.
  defp create!(ctx, extra \\ %{}) do
    stub(Provisioner, :start, fn _workspace, _sandbox_id -> {:ok, self()} end)
    {:ok, workspace} = Workspaces.create_workspace(ctx.user.id, attrs(ctx, extra), actor: "api")
    workspace
  end

  defp sandbox_of(workspace),
    do: Repo.one!(from s in Sandbox, where: s.workspace_id == ^workspace.id)

  defp workspace_sessions(workspace_id),
    do: Repo.all(from s in Session, where: s.workspace_id == ^workspace_id)

  # The provider calls a workspace's provision makes, recorded in order: the
  # CA install, the floor, the env file and the setup script.
  defp record_provider(test, setup_exit \\ 0, setup_output \\ "") do
    stub(Managoat.Sandbox, :write_file, fn _handle, path, _body, _opts ->
      send(test, {:write_file, path})
      :ok
    end)

    stub(Managoat.Sandbox, :apply_network_policy, fn _handle, %NetworkPolicy{allow: allow} ->
      send(test, {:floor, allow})
      :ok
    end)

    # The test broker is plain HTTP, where the relay is a no-op; its owner is
    # what this records.
    stub(Fountain.Broker.TransportRelay, :ensure, fn _handle, owner ->
      send(test, {:relay, owner})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn
      _handle, "bash", ["-c", _wrapper, "fountain-setup", script], opts ->
        send(test, {:setup_script, script, Keyword.get(opts, :env)})
        {:ok, setup_output, setup_exit}

      _handle, "bash", ["-c", install], _opts ->
        if String.contains?(install, "update-ca-certificates"), do: send(test, :ca_install)
        {:ok, "", 0}

      _handle, _cmd, _args, _opts ->
        {:ok, "", 0}
    end)
  end

  describe "create_workspace/3" do
    test "reserves the workspace and its first sandbox together, provisioning, and audits it",
         ctx do
      :ok = Workspaces.subscribe(ctx.user.id)
      workspace = create!(ctx, %{"name" => "  work  "})

      assert %Workspace{implicit: false, status: "provisioning", name: "work"} = workspace
      assert workspace.environment_id == ctx.env.id
      assert workspace.vault_id == ctx.vault.id
      assert workspace.provider == "sprites"

      sandbox = sandbox_of(workspace)
      assert sandbox.status == "pending"
      assert sandbox.environment_id == ctx.env.id
      assert sandbox.vault_id == ctx.vault.id
      assert sandbox.user_id == ctx.user.id

      assert [event] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.created")
      assert event.actor == "api"
      assert event.resource_id == workspace.id
      assert event.metadata["environment_id"] == ctx.env.id

      assert_receive {:workspace_status, %{workspace_id: id, status: "provisioning"}}
      assert id == workspace.id
    end

    test "another account's environment or vault reads as not found, and nothing is written",
         ctx do
      other = insert_verified_user()
      foreign_env = insert_env(user_id: other.id)
      foreign_vault = insert_vault(user_id: other.id)
      reject(&Provisioner.start/2)

      assert {:error, :environment_not_found} =
               Workspaces.create_workspace(
                 ctx.user.id,
                 attrs(ctx, %{"environment_id" => foreign_env.id})
               )

      assert {:error, :vault_not_found} =
               Workspaces.create_workspace(
                 ctx.user.id,
                 attrs(ctx, %{"vault_id" => foreign_vault.id})
               )

      assert {:error, :environment_not_found} =
               Workspaces.create_workspace(ctx.user.id, attrs(ctx, %{"environment_id" => "nope"}))

      assert Workspaces.list_workspaces(ctx.user.id) == []
      assert Workspaces.list_workspaces(other.id) == []
    end

    test "an environment and a name are required; a vault is not", ctx do
      reject(&Provisioner.start/2)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.create_workspace(ctx.user.id, %{"vault_id" => ctx.vault.id})

      assert %{environment_id: _, name: _} = errors_on(changeset)

      assert {:error, %Ecto.Changeset{}} =
               Workspaces.create_workspace(ctx.user.id, attrs(ctx, %{"name" => "   "}))
    end

    test "a vault is optional", ctx do
      workspace = create!(ctx, %{"vault_id" => nil})
      assert workspace.vault_id == nil
    end

    test "an unknown provider is refused", ctx do
      reject(&Provisioner.start/2)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Workspaces.create_workspace(
                 ctx.user.id,
                 attrs(ctx, %{"sandbox_provider" => "mars"})
               )

      assert %{sandbox_provider: _} = errors_on(changeset)
    end

    test "a full fleet refuses the create and leaves nothing behind", ctx do
      fill_fleet()
      reject(&Provisioner.start/2)

      assert {:error, :fleet_full} = Workspaces.create_workspace(ctx.user.id, attrs(ctx))
      assert Workspaces.list_workspaces(ctx.user.id) == []
      assert Audit.list_for_user(ctx.user.id, action_prefix: "workspace.created") == []
    end
  end

  describe "reads" do
    test "are scoped to the owner, and implicit workspaces are listed only when asked", ctx do
      workspace = create!(ctx)
      implicit = insert_workspace(user_id: ctx.user.id)
      other = insert_verified_user()

      assert Workspaces.get_workspace(workspace.id, ctx.user.id).id == workspace.id
      refute Workspaces.get_workspace(workspace.id, other.id)
      refute Workspaces.get_workspace("not-a-uuid", ctx.user.id)

      assert [%{id: id}] = Workspaces.list_workspaces(ctx.user.id)
      assert id == workspace.id

      assert MapSet.new(Workspaces.list_workspaces(ctx.user.id, implicit: true), & &1.id) ==
               MapSet.new([workspace.id, implicit.id])

      assert Workspaces.list_workspaces(other.id, implicit: true) == []
    end

    test "the current sandbox is the live one, else the newest", ctx do
      workspace = create!(ctx)
      first = sandbox_of(workspace)
      assert Workspaces.current_sandbox(workspace).id == first.id

      {:ok, _} = update_sandbox(first, %{status: "failed"})
      assert Workspaces.current_sandbox(workspace).id == first.id
    end
  end

  describe "the provision on create" do
    test "settles the network before the setup runs, under a session of the workspace's own",
         ctx do
      test = self()

      insert_vault_secret(ctx.vault, %{
        "key" => "GITHUB_TOKEN",
        "value" => "ghp_realvaluefromvault"
      })

      record_provider(test)
      :ok = Workspaces.subscribe(ctx.user.id)
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      stub(Provisioning, :run_setup_script, fn handle, env, sprite_env, conv_id ->
        # Mid-setup, the workspace's session is live and the setup carries it.
        "http://" <> userinfo = sprite_env |> Map.new() |> Map.fetch!("HTTPS_PROXY")
        [token | _] = String.split(userinfo, ":")

        send(
          test,
          {:sessions_mid_setup, workspace_sessions(workspace.id), Sessions.lookup(token)}
        )

        call_original(Provisioning, :run_setup_script, [handle, env, sprite_env, conv_id])
      end)

      capture_log(fn ->
        assert {:ok, :provisioned, :set_up} = Provisioner.run(workspace.id, sandbox.id)
      end)

      # The trust store, the relay and the floor first, then the env file,
      # then the script: in that order in the mailbox.
      {:messages, messages} = Process.info(self(), :messages)

      order =
        Enum.flat_map(messages, fn
          :ca_install -> [:ca]
          {:relay, _owner} -> [:relay]
          {:floor, _} -> [:floor]
          {:write_file, "/home/sprite/.env"} -> [:env_file]
          {:setup_script, _, _} -> [:script]
          _ -> []
        end)

      assert order == [:ca, :relay, :floor, :env_file, :script]

      assert_received {:relay, owner}
      assert owner == workspace.id
      assert_received {:floor, [host]}
      assert host == Fountain.Broker.proxy_host()
      assert_received {:setup_script, "make setup", env}

      env = Map.new(env)
      assert "http://" <> userinfo = env["HTTPS_PROXY"]
      [token | _] = String.split(userinfo, ":")
      # The vault's GitHub token is brokered: the setup holds its placeholder.
      assert env["GITHUB_TOKEN"] == Fountain.Broker.placeholder("GITHUB_TOKEN")
      refute Enum.any?(Map.values(env), &(&1 == "ghp_realvaluefromvault"))
      refute Map.has_key?(env, "MANAGOAT_TOKEN")

      assert_received {:sessions_mid_setup, [%Session{conversation_id: nil} = session],
                       {:ok, %Managoat.Broker.Session{rules: rules}}}

      assert session.user_id == ctx.user.id
      assert Enum.any?(rules, &(&1.credential == "ghp_realvaluefromvault"))

      # Released when the setup ends.
      assert workspace_sessions(workspace.id) == []
      assert Sessions.lookup(token) == :error

      ready = Repo.reload!(sandbox)
      assert ready.status == "ready"
      # What it was built from (#2987).
      assert ready.built_from_revision == ctx.env.revision
      assert %Workspace{status: "ready", error: nil} = Repo.reload!(workspace)
      assert_receive {:workspace_status, %{status: "ready", stale: false, changed_fields: []}}

      assert [%{actor: "system:workspace_setup"}] =
               Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.provisioned")
    end

    test "a failed setup fails the workspace with an error, and releases the session", ctx do
      record_provider(self(), 3, "nope\n")
      :ok = Workspaces.subscribe(ctx.user.id)
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      capture_log(fn ->
        assert {:error, {:setup_exit, 3}, %{}} = Provisioner.run(workspace.id, sandbox.id)
      end)

      assert Repo.reload!(sandbox).status == "failed"

      assert %Workspace{status: "failed", error: "the environment's setup script exited 3"} =
               Repo.reload!(workspace)

      assert_receive {:workspace_status, %{status: "failed", error: error}}
      assert error =~ "exited 3"
      assert workspace_sessions(workspace.id) == []
    end

    test "a provider that cannot hold the floor is refused before anything runs", ctx do
      record_provider(self())
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      stub(Provisioning, :check_broker_support, fn _provider, nil ->
        {:error, {:broker, :backend_lacks_network_policy}}
      end)

      capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

      refute_received {:setup_script, _, _}
      refute_received {:floor, _}
      assert %Workspace{status: "failed", error: error} = Repo.reload!(workspace)
      assert error =~ "network floor"
      assert workspace_sessions(workspace.id) == []
    end

    test "dates the machine's clock from the moment it is ready", ctx do
      record_provider(self())
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)
      old = DateTime.add(DateTime.utc_now(), -3600, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [inserted_at: old])

      capture_log(fn ->
        {:ok, :provisioned, :set_up} = Provisioner.run(workspace.id, sandbox.id)
      end)

      ready = Repo.reload!(sandbox)
      assert DateTime.diff(DateTime.utc_now(), ready.last_resumed_at) < 60
      assert Fountain.Conversations.Lifecycle.clock_start(ready) == ready.last_resumed_at
    end

    test "past its deadline the machine is failed, the task stopped and the session released",
         ctx do
      test = self()
      record_provider(test)
      previous = Application.get_env(:fountain, :provision_deadline_ms)
      Application.put_env(:fountain, :provision_deadline_ms, 500)
      on_exit(fn -> restore_env(:provision_deadline_ms, previous) end)

      stub(Provisioning, :run_setup_script, fn _handle, _env, _sprite_env, nil ->
        send(test, :setting_up)
        Process.sleep(:infinity)
      end)

      {:ok, workspace} = Workspaces.create_workspace(ctx.user.id, attrs(ctx))
      sandbox = sandbox_of(workspace)
      assert_receive :setting_up, 5_000

      capture_log(fn ->
        wait_until(fn -> Repo.reload!(sandbox).status == "failed" end)
        wait_until(fn -> not Provisioner.running?(workspace.id) end)
      end)

      wait_until(fn -> workspace_sessions(workspace.id) == [] end)

      assert %Workspace{
               status: "failed",
               error: "the provision did not finish within its deadline"
             } =
               Repo.reload!(workspace)
    end

    test "start/2 runs it in the background, once per workspace", ctx do
      record_provider(self())
      {:ok, workspace} = Workspaces.create_workspace(ctx.user.id, attrs(ctx))
      sandbox = sandbox_of(workspace)

      wait_until(fn -> Repo.reload!(sandbox).status == "ready" end)
      assert %Workspace{status: "ready"} = Repo.reload!(workspace)
      wait_until(fn -> not Provisioner.running?(workspace.id) end)
    end
  end

  describe "the redacted error" do
    test "takes out the workspace's secrets and the quoted output's cut first line", ctx do
      insert_vault_secret(ctx.vault, %{"key" => "API_SECRET", "value" => "s3cret-value-123"})
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      tail = "et-value-123 cut here\nusing s3cret-value-123 for apt\nE: failed"

      error = Workspaces.describe_failure(sandbox, {:packages, 100, tail})

      assert error =~ "exited 100"
      assert error =~ "using [REDACTED] for apt"
      refute error =~ "s3cret-value-123"
      refute error =~ "et-value-123"
    end

    test "takes out each line of a value that spans lines", ctx do
      key = "-----BEGIN KEY-----\nAAAAsecretline1AAAA\nBBBBsecretline2BBBB\n-----END KEY-----"
      insert_vault_secret(ctx.vault, %{"key" => "DEPLOY_KEY", "value" => key})
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      # The tail begins inside the value: its first line is the cut one.
      tail = "secretline1AAAA\nBBBBsecretline2BBBB\n-----END KEY-----\nfailed"
      error = Workspaces.describe_failure(sandbox, {:packages, 1, tail})

      refute error =~ "secretline2"
      refute error =~ "secretline1"
      assert error =~ "failed"
    end

    test "says nothing it cannot redact when the tenant's key cannot be read", ctx do
      insert_vault_secret(ctx.vault, %{"key" => "API_SECRET", "value" => "s3cret-value-123"})
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)
      stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :unavailable} end)

      assert Workspaces.describe_failure(sandbox, {:packages, 1, "x\ns3cret-value-123"}) ==
               "the sandbox could not be provisioned"
    end

    test "keeps a step's output out of the sandbox row and the audit trail", ctx do
      record_provider(self())
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      stub(Provisioning, :install_packages, fn _handle, _env, _sprite_env, nil ->
        {:error, {:packages, 100, "first\nE: printed secret-ish output\n"}}
      end)

      capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

      assert Repo.reload!(sandbox).transition_reason == "{:packages, 100}"

      assert [event] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.provision_failed")
      assert event.metadata["reason"] == "{:packages, 100}"
      assert Repo.reload!(workspace).error =~ "printed secret-ish output"
    end

    test "the setup takes its own session token out of a failure before it is recorded", ctx do
      test = self()
      record_provider(test)
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)

      stub(Provisioning, :install_packages, fn _handle, _env, sprite_env, nil ->
        proxy = sprite_env |> Map.new() |> Map.fetch!("HTTPS_PROXY")
        send(test, {:proxy, proxy})
        {:error, {:packages, 1, "first\nproxy is #{proxy}\n"}}
      end)

      capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

      assert_received {:proxy, "http://" <> userinfo}
      [token | _] = String.split(userinfo, ":")
      assert %Workspace{status: "failed", error: error} = Repo.reload!(workspace)
      assert error =~ "proxy is"
      refute error =~ token
      refute Repo.reload!(sandbox).transition_reason =~ token
    end
  end

  describe "a secret write during the provision on create" do
    test "rewrites the live setup session's rules in place", ctx do
      insert_vault_secret(ctx.vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_before"})
      workspace = create!(ctx)
      {:ok, %{network: net}} = Network.inputs(Repo.reload!(workspace))

      {:ok, session} =
        Fountain.Broker.prepare_workspace(workspace.id, net.brokered, net.bindings,
          user_id: ctx.user.id
        )

      insert_vault_secret(ctx.vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_after"})

      wait_until(fn ->
        {:ok, %{rules: rules}} = Sessions.lookup(session.token)
        Enum.any?(rules, &(&1.credential == "ghp_after"))
      end)

      {:ok, %{rules: rules}} = Sessions.lookup(session.token)
      refute Enum.any?(rules, &(&1.credential == "ghp_before"))
    end

    test "leaves another account's workspace alone", ctx do
      workspace = create!(ctx)
      other = insert_verified_user()
      reject(&Fountain.Broker.refresh_workspace/4)

      assert :ok = Network.refresh_live(:vault, ctx.vault.id, other.id)
      assert :ok = Network.refresh_live(:environment, ctx.env.id, ctx.user.id)
      assert workspace_sessions(workspace.id) == []
    end
  end

  describe "the relay owner" do
    test "is the conversation on an implicit machine and the workspace on an explicit one",
         ctx do
      implicit = insert_sandbox(user_id: ctx.user.id, status: "ready")
      assert Workspaces.relay_owner(implicit.id, "conv-1") == "conv-1"

      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)
      assert Workspaces.relay_owner(sandbox.id, "conv-1") == workspace.id
      assert Workspaces.relay_owner(nil, "conv-1") == "conv-1"
    end
  end

  describe "delete_workspace/2" do
    setup ctx do
      workspace = create!(ctx)
      sandbox = sandbox_of(workspace)
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      agent = insert_agent(user_id: ctx.user.id)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: agent,
          sandbox: sandbox,
          workspace_id: workspace.id,
          status: "idle"
        )

      %{workspace: Repo.reload!(workspace), sandbox: sandbox, conv: conv}
    end

    test "ends every live conversation, destroys the machine and audits it with the caller",
         ctx do
      test = self()

      stub(Managoat.Sandbox, :destroy, fn handle ->
        send(test, {:destroyed, handle.name}) && :ok
      end)

      capture_log(fn ->
        assert {:ok, _} =
                 Workspaces.delete_workspace(ctx.workspace, actor: "api", request_ip: "10.0.0.1")
      end)

      assert_received {:destroyed, name}
      assert name == ctx.sandbox.machine_name
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      # Transcripts are kept: the conversation is terminated, not deleted.
      assert Repo.reload!(ctx.conv).status == "terminated"
      refute Repo.get(Workspace, ctx.workspace.id)

      assert [deleted] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.deleted")
      assert deleted.actor == "api"
      assert deleted.request_ip == "10.0.0.1"
      assert deleted.metadata["sandbox_destroyed"] == true
      assert deleted.metadata["conversations_terminated"] == 1

      assert [destroyed] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.destroyed")
      assert destroyed.actor == "api"
      assert destroyed.metadata["reason"] == "workspace_deleted"

      assert [terminated] =
               Audit.list_for_user(ctx.user.id, action_prefix: "conversation.terminated")

      assert terminated.actor == "api"
    end

    test "an implicit workspace, or one already gone, is not deleted", ctx do
      implicit = insert_workspace(user_id: ctx.user.id)
      assert {:error, :not_found} = Workspaces.delete_workspace(implicit)

      capture_log(fn -> {:ok, _} = Workspaces.delete_workspace(ctx.workspace) end)
      assert {:error, :not_found} = Workspaces.delete_workspace(ctx.workspace)
    end

    test "no machine is rebuilt in a workspace being deleted", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "failed"})

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
          set: [user_id: nil]
        )

      capture_log(fn ->
        assert {:error, :fenced} =
                 Fountain.Machines.Provision.rebuild(
                   ctx.sandbox.id,
                   fn _h, _e -> {:ok, :built} end,
                   actor: "system:wake",
                   attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"}
                 )
      end)

      assert Repo.aggregate(
               from(s in Sandbox, where: s.workspace_id == ^ctx.workspace.id),
               :count
             ) ==
               1
    end

    test "stops a provision on create still running and destroys what it was building", ctx do
      test = self()
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "pending"})
      record_provider(test)

      stub(Provisioner, :start, fn workspace, sandbox_id ->
        call_original(Provisioner, :start, [workspace, sandbox_id])
      end)

      stub(Provisioning, :run_setup_script, fn _handle, _env, _sprite_env, nil ->
        send(test, :setting_up)
        Process.sleep(:infinity)
      end)

      stub(Managoat.Sandbox, :destroy, fn handle ->
        send(test, {:destroyed, handle.name}) && :ok
      end)

      {:ok, _pid} = Provisioner.start(ctx.workspace, ctx.sandbox.id)
      assert_receive :setting_up, 5_000
      assert [_live] = workspace_sessions(ctx.workspace.id)
      assert Lease.live?(Lease.get(ctx.sandbox.id))

      capture_log(fn ->
        assert {:ok, _} = Workspaces.delete_workspace(ctx.workspace, actor: "api")
      end)

      refute Provisioner.running?(ctx.workspace.id)
      assert_received {:destroyed, _}
      assert Repo.reload!(ctx.sandbox).status == "terminated"
      refute Repo.get(Workspace, ctx.workspace.id)
      assert workspace_sessions(ctx.workspace.id) == []
    end
  end

  describe "the reaper" do
    test "parks a ready workspace that never had a conversation, on the idle bound", ctx do
      workspace = create!(ctx)
      {:ok, sandbox} = update_sandbox(sandbox_of(workspace), %{status: "ready"})
      old = DateTime.add(DateTime.utc_now(), -3 * 3600, :second) |> DateTime.truncate(:second)

      {1, _} =
        Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
          set: [inserted_at: old, updated_at: old]
        )

      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      reject(&Managoat.Sandbox.destroy/1)
      previous = Application.get_env(:fountain, :sandbox_idle_timeout_minutes)
      Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 60)

      try do
        capture_log(fn ->
          assert {1, 0, 0, 0} = Fountain.Workers.SandboxReaper.sweep_abandoned_sandboxes()
        end)
      after
        Application.put_env(:fountain, :sandbox_idle_timeout_minutes, previous)
      end

      assert Repo.reload!(sandbox).status == "suspended"
    end
  end

  describe "account deletion" do
    test "deletes the account's explicit workspaces and their sandboxes", ctx do
      workspace = create!(ctx)
      {:ok, sandbox} = update_sandbox(sandbox_of(workspace), %{status: "ready"})

      capture_log(fn -> {:ok, _} = Fountain.Accounts.Deletion.delete_user(ctx.user) end)

      assert Repo.reload!(sandbox).status == "terminated"
      refute Repo.get(Workspace, workspace.id)
    end

    test "stops a provision still running and destroys the machine it was building", ctx do
      test = self()
      record_provider(test)

      stub(Provisioning, :run_setup_script, fn _handle, _env, _sprite_env, nil ->
        send(test, :setting_up)
        Process.sleep(:infinity)
      end)

      {:ok, workspace} = Workspaces.create_workspace(ctx.user.id, attrs(ctx))
      sandbox = sandbox_of(workspace)
      assert_receive :setting_up, 5_000

      capture_log(fn -> {:ok, _} = Fountain.Accounts.Deletion.delete_user(ctx.user) end)

      refute Provisioner.running?(workspace.id)
      assert Repo.reload!(sandbox).status == "terminated"
      refute Repo.get(Workspace, workspace.id)
      assert workspace_sessions(workspace.id) == []
    end
  end

  defp restore_env(key, nil), do: Application.delete_env(:fountain, key)
  defp restore_env(key, value), do: Application.put_env(:fountain, key, value)

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
end
