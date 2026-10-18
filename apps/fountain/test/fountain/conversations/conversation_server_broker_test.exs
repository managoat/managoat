defmodule Fountain.Conversations.ConversationServerBrokerTest do
  # Egress credential brokerage through a real ConversationServer (ADR 0019
  # gate 1a). Two guarantees, one per describe: an unbrokered conversation is
  # byte-for-byte what it was — the broker is never called — and a brokered
  # one gets placeholders, a process-only proxy address, the network floor,
  # the CA, and a clone that can reach GitHub through the proxy.
  use Fountain.ConversationServerCase

  alias Fountain.Environments
  alias Fountain.Machines.Lease
  alias Fountain.Vaults

  @dek <<0::256>>
  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}

  setup do
    user = insert_verified_user()
    # ConversationServerCase resolves this fixed test DEK. The broker reads
    # the durable wrapped key directly, so it must describe the same key.
    Fountain.Accounts.UserDataKey
    |> Repo.get_by!(user_id: user.id)
    |> Ecto.Changeset.change(wrapped_key: Fountain.Crypto.wrap_dek(@dek))
    |> Repo.update!()

    env = insert_env(user_id: user.id, env_vars: %{"FROM_ENVIRONMENT" => "yes"})

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_real"}, @dek)

    {:ok, _} =
      Environments.upsert_secret(env, %{"key" => "DATABASE_URL", "value" => "postgres://x"}, @dek)

    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    previous =
      for key <- [:broker_listen_port, :broker_proxy_url],
          do: {key, Application.get_env(:fountain, key)}

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:fountain, key),
          else: Application.put_env(:fountain, key, value)
      end
    end)

    {:ok, user: user, agent: agent, env: env}
  end

  defp configure_broker do
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
  end

  defp stub_turn_boundary do
    test = self()
    ref = make_ref()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)
    ref
  end

  defp stage_events(conv_id, stage) do
    conv_id
    |> Conversations._unsafe_list_log_events()
    |> Enum.filter(&(&1.kind == "stage" and &1.stage == stage))
  end

  describe "reattaching an existing machine" do
    setup %{user: user, agent: agent} do
      sandbox = insert_sandbox(user_id: user.id, status: "ready", machine_name: "existing")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
      stub_happy_sprite("existing")
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, _opts -> {:ok, @session} end)
      {:ok, conv: conv, sandbox: sandbox}
    end

    test "a newly brokered tenant gets the floor before credentials are written", %{
      user: user,
      conv: conv
    } do
      configure_broker()
      test = self()

      stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _h, policy ->
        send(test, {:wake_step, {:policy, policy}})
        :ok
      end)

      stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, _env ->
        send(test, {:wake_step, :env})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:wake_step, first_step}
      assert first_step == {:policy, %Managoat.Sandbox.NetworkPolicy{allow: ["broker.test"]}}

      assert_receive {:wake_step, :env}
      assert Enum.map(stage_events(conv.id, "network"), & &1.state) == ["started", "done"]
    end

    for reason <- [:not_found, :forbidden] do
      test "a policy refusal #{reason} stops the wake without retiring the disk", %{
        user: user,
        conv: conv,
        sandbox: sandbox
      } do
        configure_broker()

        stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _h, _policy ->
          {:error, unquote(reason)}
        end)

        reject(Fountain.Conversations.Provisioning, :write_env_file, 2)
        reject(Managoat.Sandbox.Sprites, :list_sessions, 1)
        reject(Managoat.Sandbox.Sprites, :destroy, 1)

        {_pid, ref, :stopped} = start_server(conv)
        assert assert_stopped(ref) == :normal
        assert Fountain.Repo.reload!(sandbox).status == "ready"
        assert Fountain.Repo.reload!(conv).status == "idle"
        assert [event] = stage_events(conv.id, "reattach")
        assert event.state == "failed"
        assert Jason.decode!(event.data)["retryable"]
      end
    end

    for initial <- ["ready", "suspended"],
        terminal <- ["terminated", "failed", "reset_pending"] do
      @tag initial: initial, terminal: terminal
      test "retirement during #{initial} wake with another validation error preserves #{terminal} and the replacement",
           %{
             user: user,
             conv: conv,
             sandbox: sandbox,
             initial: initial,
             terminal: terminal
           } do
        configure_broker()
        {:ok, sandbox} = update_sandbox(sandbox, %{status: initial})
        test = self()

        stub(Fountain.Broker, :prepare, fn id, secrets, bindings, opts ->
          {:ok, session} = Fountain.Broker.Native.prepare(id, secrets, bindings, opts)
          send(test, {:original_token, session.token})
          {:ok, session}
        end)

        # `Conversations.claim_sandbox/2` was stubbed here to plant a second
        # validation error on the `ready` claim; the server stopped making that
        # claim in ADR 0058 stage 7b (the provision bracket writes the row by
        # compare-and-set), so the stub fired on nothing, and the function is
        # gone since 8b. What the case still pins is below: the retirement wins
        # and the replacement is preserved.

        stub(Fountain.Conversations.Provisioning, :prepare_runtime_sprite, fn _h,
                                                                              _r,
                                                                              _m,
                                                                              _a,
                                                                              _e,
                                                                              _s,
                                                                              _u ->
          send(test, {:wake_paused, self()})
          receive do: (:resume_wake -> :ok)
        end)

        reject(Managoat.Sandbox.Sprites, :destroy, 1)
        reject(Managoat.Sandbox.Sprites, :list_sessions, 1)
        reject(Managoat.Sandbox.Sprites, :spawn, 4)

        {:ok, pid} =
          GenServer.start(ConversationServer,
            conversation_id: conv.id,
            sandbox_id: sandbox.id,
            runtime_module: Managoat.Runtimes.Testing.FakeRuntime
          )

        ref = Process.monitor(pid)
        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        assert_receive {:wake_paused, ^pid}, 5_000
        assert_receive {:original_token, original}
        callback_id = Fountain.Repo.reload!(conv).callback_api_key_id
        assert is_binary(callback_id)

        retired =
          if terminal == "reset_pending" do
            sandbox
            |> put_lease(transition: "destroying", transition_reason: "reset")
          else
            {:ok, retired} = update_sandbox(sandbox, %{status: terminal})
            retired
          end

        replacement =
          insert_sandbox(user_id: user.id, status: "ready", machine_name: "replacement")

        {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})

        {:ok, replacement_session} =
          Fountain.Broker.Native.prepare(conv.id, %{}, %{}, user_id: user.id)

        ConversationServer.queue_initial_prompt(pid, "must never run")
        send(pid, :resume_wake)

        assert :normal = assert_stopped(ref, 5_000)
        assert Fountain.Repo.reload!(sandbox).status == retired.status
        assert Fountain.Repo.reload!(sandbox).terminated_at == retired.terminated_at
        assert Fountain.Repo.reload!(sandbox).transition == retired.transition
        assert Fountain.Repo.reload!(conv).sandbox_id == replacement.id
        assert Fountain.Repo.reload!(conv).status == "idle"
        assert Fountain.Repo.reload!(replacement).status == "ready"
        assert :error = Fountain.Broker.Native.Sessions.lookup(original)
        assert {:ok, _} = Fountain.Broker.Native.Sessions.lookup(replacement_session.token)
        assert Fountain.Repo.get(Fountain.Accounts.ApiKey, callback_id).revoked_at
        refute Enum.any?(stage_events(conv.id, "reattach"), &(&1.state == "done"))
      end
    end

    for initial <- ["ready", "suspended"] do
      test "an ordinary #{initial} wake succeeds and preserves the lifetime rule", %{
        conv: conv,
        sandbox: sandbox
      } do
        resumed = DateTime.add(DateTime.utc_now(), -600) |> DateTime.truncate(:second)

        {:ok, _} =
          update_sandbox(sandbox, %{
            status: unquote(initial),
            last_resumed_at: resumed
          })

        {pid, _ref, :alive} = start_server(conv)
        on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

        current = Fountain.Repo.reload!(sandbox)
        assert current.status == "ready"

        if unquote(initial) == "ready",
          do: assert(current.last_resumed_at == resumed),
          else: assert(DateTime.compare(current.last_resumed_at, resumed) == :gt)

        assert Enum.any?(stage_events(conv.id, "reattach"), &(&1.state == "done"))
      end
    end

    test "an unrelated ready-write failure is not treated as retirement", %{
      conv: conv,
      sandbox: sandbox
    } do
      # The write is `Machine.confirm_up/2`'s compare-and-set since ADR 0058
      # stage 7b. What is pinned is unchanged and is the point of the test: a
      # write that failed for a reason that is *not* retirement leaves the row
      # and the conversation alone and publishes no `reattach/done`.
      #
      # One behaviour change, and it is deliberate. `main` reached this through
      # a `raise MatchError` — its `claim_sandbox/2` case had no clause for an
      # arbitrary error — so the server died abnormally and Horde restarted it
      # into the same failure. The owner answers instead, and the server stops
      # `:normal` after releasing what it prepared. Nothing about the rows
      # changes; a crash loop does not start.
      stub(Lease, :cas_update, fn _id, _epoch, _attrs, _opts ->
        {:error, {:database, :some_sqlstate}}
      end)

      {_pid, ref, :stopped} = start_server(conv)
      assert :normal = assert_stopped(ref)
      assert Fountain.Repo.reload!(sandbox).status == "ready"
      assert Fountain.Repo.reload!(conv).status == "idle"
      refute Enum.any?(stage_events(conv.id, "reattach"), &(&1.state == "done"))
    end
  end

  describe "a brokered conversation" do
    setup do
      configure_broker()
      :ok
    end

    test "placeholders in the sandbox, the value at the broker, the token off the disk", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn conv_id, brokered, _bindings, _opts ->
        send(test, {:prepared, conv_id, brokered})
        {:ok, @session}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, env ->
        send(test, {:env_file, env})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _h, policy ->
        send(test, {:policy, policy})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, _opts ->
        send(test, {:wrote, path, data})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, args, _opts ->
        send(test, {:exec, args})
        {:ok, "", 0}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :clone_repositories, fn _h,
                                                                              _e,
                                                                              secrets,
                                                                              sprite_env,
                                                                              _c ->
        send(test, {:clone, secrets, sprite_env})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The broker got the value; only the catalog key, not the rest.
      assert_receive {:prepared, conv_id, %{"GITHUB_TOKEN" => "ghp_real"} = brokered}, 2_000
      assert conv_id == conv.id
      refute Map.has_key?(brokered, "DATABASE_URL")

      # The process env: placeholder, proxy with the token, CA path.
      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      assert {"GITHUB_TOKEN", "__github_token__"} in spawn_env
      assert {"DATABASE_URL", "postgres://x"} in spawn_env
      assert {"HTTPS_PROXY", "http://av_sess_conv:c-test@broker.test:14322"} in spawn_env
      assert {"NODE_EXTRA_CA_CERTS", Fountain.Broker.ca_path()} in spawn_env
      refute Enum.any?(spawn_env, fn {_, v} -> v == "ghp_real" end)

      # The disk env: placeholder yes, proxy address (and its token) no.
      assert_receive {:env_file, file_env}, 2_000
      assert {"GITHUB_TOKEN", "__github_token__"} in file_env
      refute Enum.any?(file_env, fn {k, _} -> k in Fountain.Broker.process_only_keys() end)
      refute Enum.any?(file_env, fn {_, v} -> String.contains?(v, "av_sess_conv") end)

      # The floor: the broker's host, and nothing else, whatever the env said.
      assert_receive {:policy, %Managoat.Sandbox.NetworkPolicy{allow: ["broker.test"]}}, 2_000

      # The CA, in the OS trust store — under the lock, and only if it
      # differs from what is already there (#1674).
      assert_receive {:wrote, "/tmp/agent-vault-ca.crt." <> _, "PEM"}, 2_000
      assert_receive {:exec, ["-c", "( trap 'rm -f -- " <> _]}, 2_000

      # The clone sees the placeholder and the proxy, so git goes through the
      # broker and the broker rewrites the auth header.
      assert_receive {:clone, %{"GITHUB_TOKEN" => "__github_token__"}, clone_env}, 2_000
      assert {"HTTPS_PROXY", "http://av_sess_conv:c-test@broker.test:14322"} in clone_env

      assert Enum.map(stage_events(conv.id, "broker"), & &1.state) == ["started", "done"]
    end

    test "an unreachable broker fails the conversation before any sandbox is created", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)

      stub_happy_sprite()

      stub(Fountain.Broker, :preflight, fn -> {:error, {:broker, :unreachable, :econnrefused}} end)

      reject(Managoat.Sandbox.Sprites, :create, 2)
      reject(Fountain.Broker, :prepare, 4)

      {_pid, _mon, :stopped} = start_server(conv)

      assert [event] = stage_events(conv.id, "broker")
      assert event.state == "failed"
      assert %{"reason" => "broker_unreachable"} = Jason.decode!(event.data)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "the runtime's inference credential is a placeholder; the value goes to the broker", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()

      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(
          user.id,
          <<0::256>>,
          :claude_code_oauth_token,
          "sk-ant-oat01-realtoken"
        )

      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn _c, brokered, bindings, _opts ->
        send(test, {:prepared, brokered, bindings})
        {:ok, @session}
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:prepared, brokered, bindings}, 2_000
      assert brokered["CLAUDE_CODE_OAUTH_TOKEN"] == "sk-ant-oat01-realtoken"

      assert [%{host: "api.anthropic.com", auth_type: "substitute"}] =
               bindings["CLAUDE_CODE_OAUTH_TOKEN"]

      # The harness runtime ignores credentials; the real one is handed the
      # placeholder (see the Broker unit tests), and the value is nowhere in
      # what reaches the sandbox.
      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      spawn_env = Keyword.fetch!(opts, :env)
      refute Enum.any?(spawn_env, fn {_, v} -> v == "sk-ant-oat01-realtoken" end)

      # The credential entries only: the runtime also sets flags of its own.
      env =
        Managoat.Runtimes.Claude.default_env(nil, %{
          claude_code_oauth_token: "sk-ant-oat01-__claude_code_oauth_token__"
        })

      assert Enum.filter(env, fn {k, _} -> k in ~w(ANTHROPIC_API_KEY CLAUDE_CODE_OAUTH_TOKEN) end) ==
               [{"CLAUDE_CODE_OAUTH_TOKEN", "sk-ant-oat01-__claude_code_oauth_token__"}]
    end

    test "a limited environment is brokered with its allowlist enforced at the broker", %{
      user: user
    } do
      env =
        insert_env(
          user_id: user.id,
          networking_type: "limited",
          networking_config: %{"allowed_hosts" => ["registry.npmjs.org", "api.anthropic.com"]}
        )

      agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, opts ->
        send(test, {:prepared_with, opts[:network]})
        {:ok, @session}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _h, policy ->
        send(test, {:policy, policy})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:prepared_with, {:limited, ["registry.npmjs.org", "api.anthropic.com"]}},
                     2_000

      # The sandbox's own policy is still the floor, whatever the environment listed.
      assert_receive {:policy, %Managoat.Sandbox.NetworkPolicy{allow: ["broker.test"]}}, 2_000
      assert_receive {:spawned, _, _, _}, 2_000
    end

    test "a failed session mint tears the sandbox down without revoking other sessions", %{
      user: user,
      agent: agent
    } do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      stub(Fountain.Broker, :preflight, fn -> :ok end)

      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, _opts ->
        {:error, {:broker, :session, :timeout}}
      end)

      reject(Fountain.Broker, :release, 1)
      reject(Fountain.Broker, :release_session, 3)

      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn _h ->
        send(test, :destroyed)
        :ok
      end)

      {_pid, _mon, :stopped} = start_server(conv)

      assert_receive :destroyed, 2_000
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "failed provisioning preserves a replacement token", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()
      stub_happy_sprite()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      # Use real session rows and deletion; only the provider boundary is fake.
      stub(Fountain.Broker, :prepare, fn id, secrets, bindings, opts ->
        {:ok, session} = Fountain.Broker.Native.prepare(id, secrets, bindings, opts)
        send(test, {:original_token, session.token})
        {:ok, session}
      end)

      stub(Fountain.Conversations.Provisioning, :install_packages, fn _h, _e, _se, _id ->
        {:ok, replacement} =
          Fountain.Broker.Native.prepare(conv.id, %{}, %{}, user_id: user.id)

        send(test, {:replacement_token, replacement.token})
        {:error, :apt_failed}
      end)

      {_pid, ref, :stopped} = start_server(conv)
      assert :normal = assert_stopped(ref)
      assert_receive {:original_token, original}
      assert_receive {:replacement_token, replacement}
      assert :error = Fountain.Broker.Native.Sessions.lookup(original)
      assert {:ok, _} = Fountain.Broker.Native.Sessions.lookup(replacement)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    for terminal <- ["terminated", "failed", "reset_pending"] do
      @tag terminal: terminal
      test "retirement during provision with another validation error preserves the #{terminal} row and replacement",
           %{
             user: user,
             agent: agent,
             terminal: terminal
           } do
        conv = insert_conversation(user_id: user.id, agent: agent, sandbox_api_access: "owner")
        sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
        test = self()
        handle = stub_happy_sprite(sandbox.machine_name)
        stub(Fountain.Broker, :preflight, fn -> :ok end)
        stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

        stub(Fountain.Broker, :prepare, fn id, secrets, bindings, opts ->
          {:ok, session} = Fountain.Broker.Native.prepare(id, secrets, bindings, opts)
          send(test, {:original_token, session.token})
          {:ok, session}
        end)

        # The `ready` write is the provision bracket's compare-and-set since ADR
        # 0058 stage 7b, not `claim_sandbox/2`, so the observation moved with
        # it. The injected `mode: "invalid"` went with the changeset it was
        # injected into: `Lease.cas_update/4` writes named columns, and the
        # retirement this pins is refused by the row's own state rather than by
        # a validation racing it.
        stub(Lease, :cas_update, fn id, epoch, attrs, opts ->
          if attrs[:status] == "ready", do: send(test, :ready_claimed)
          Mimic.call_original(Lease, :cas_update, [id, epoch, attrs, opts])
        end)

        # Pause after inference reservation so the final ready write, rather
        # than the source's configuration check, observes the retirement race.
        stub(Fountain.Conversations.Provisioning, :prepare_runtime_sandbox, fn _h,
                                                                               _r,
                                                                               _m,
                                                                               _a,
                                                                               _e,
                                                                               _s,
                                                                               _u ->
          send(test, {:provision_paused, self()})
          receive do: (:resume_provision -> :ok)
        end)

        stub(Managoat.Sandbox.Sprites, :destroy, fn destroyed ->
          send(test, {:destroyed, destroyed})
          :ok
        end)

        reject(Managoat.Sandbox.Sprites, :spawn, 4)

        {:ok, pid} =
          GenServer.start(ConversationServer,
            conversation_id: conv.id,
            sandbox_id: sandbox.id,
            runtime_module: Managoat.Runtimes.Testing.FakeRuntime
          )

        ref = Process.monitor(pid)
        on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
        assert_receive {:provision_paused, ^pid}, 5_000
        assert_receive {:original_token, original}
        callback_id = Fountain.Repo.reload!(conv).callback_api_key_id
        assert is_binary(callback_id)

        retired =
          if terminal == "reset_pending" do
            sandbox
            |> Fountain.Repo.reload!()
            |> put_lease(transition: "destroying", transition_reason: "reset")
          else
            {:ok, retired} = update_sandbox(sandbox, %{status: terminal})
            retired
          end

        replacement =
          insert_sandbox(user_id: user.id, status: "ready", machine_name: "replacement")

        {:ok, _} =
          Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

        {:ok, replacement_session} =
          Fountain.Broker.Native.prepare(conv.id, %{}, %{}, user_id: user.id)

        ConversationServer.queue_initial_prompt(pid, "must never run")
        send(pid, :resume_provision)

        assert :normal = assert_stopped(ref, 5_000)
        assert_received :ready_claimed
        assert Fountain.Repo.reload!(sandbox).status == retired.status
        assert Fountain.Repo.reload!(sandbox).terminated_at == retired.terminated_at
        assert Fountain.Repo.reload!(sandbox).transition == retired.transition
        assert Fountain.Repo.reload!(conv).status == "idle"
        assert Fountain.Repo.reload!(conv).sandbox_id == replacement.id
        assert Fountain.Repo.reload!(replacement).status == "ready"
        assert_receive {:destroyed, ^handle}
        refute_received {:destroyed, _}
        assert :error = Fountain.Broker.Native.Sessions.lookup(original)
        assert {:ok, _} = Fountain.Broker.Native.Sessions.lookup(replacement_session.token)
        assert Fountain.Repo.get(Fountain.Accounts.ApiKey, callback_id).revoked_at
        refute Enum.any?(stage_events(conv.id, "provision"), &(&1.state in ["done", "failed"]))
      end
    end

    test "an unrelated ready-write error still fails provisioning", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      stub_happy_sprite()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, _opts -> {:ok, @session} end)

      # As above: the `ready` write is the bracket's compare-and-set now. A
      # failure that is neither a takeover nor a retirement still fails the
      # provision — the machine is torn down, both rows go `failed` and the
      # stage says so.
      stub(Lease, :cas_update, fn id, epoch, attrs, opts ->
        if attrs[:status] == "ready" do
          {:error, {:database, :some_sqlstate}}
        else
          Mimic.call_original(Lease, :cas_update, [id, epoch, attrs, opts])
        end
      end)

      {_pid, ref, :stopped} = start_server(conv)
      assert :normal = assert_stopped(ref)
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
      assert Fountain.Repo.reload!(conv).status == "failed"
      assert Enum.any?(stage_events(conv.id, "provision"), &(&1.state == "failed"))
      refute Enum.any?(stage_events(conv.id, "provision"), &(&1.state == "done"))
    end

    test "terminating the conversation releases the vault", %{user: user, agent: agent} do
      conv = insert_conversation(user_id: user.id, agent: agent)
      test = self()

      stub_happy_sprite()
      _ref = stub_turn_boundary()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, _opts -> {:ok, @session} end)

      stub(Fountain.Broker, :release, fn conv_id ->
        send(test, {:released, conv_id})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      assert_receive {:spawned, _, _, _}, 2_000

      # The harness starts servers outside the conversation supervisor, so the registry lookup the
      # public API does would miss it; the call is the same one it makes.
      :ok = GenServer.call(pid, {:terminate_conv, []})

      assert_receive {:released, conv_id}, 2_000
      assert conv_id == conv.id
    end
  end

  # #1736. The broker's copy of a vault or environment secret was split once,
  # at init; a value edited during the conversation never reached it. And the
  # session token sits in the env of every process the sandbox already runs,
  # the idle ACP peer that carries the next turn included, so a new session
  # would not have reached them either: the live session's rules are
  # rewritten in place. Turn two goes through that idle peer here, which is
  # the path a client app's second prompt takes.
  describe "a secret edited between two turns" do
    @caps %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}

    setup %{user: user, agent: agent, env: env} do
      configure_broker()

      # The tenant's real key, not `stub_happy_sprite/1`'s zeros: the vault
      # secrets below are encrypted under it.
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "GITHUB_TOKEN", "value" => "ghp_real"}, dek)

      vault = insert_vault(user_id: user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_from_vault"}, dek)

      conv = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)
      test = self()

      # A session with an end in sight: `@session`'s nil end reads as
      # expiring, and a session that is expiring is re-minted every turn,
      # which would hide what these tests are about.
      session = %{@session | expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)}

      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:ok, dek} end)
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      stub(Fountain.Broker, :prepare, fn conv_id, brokered, _bindings, _opts ->
        send(test, {:prepared, conv_id, brokered})
        {:ok, session}
      end)

      stub(Fountain.Broker, :refresh, fn conv_id, brokered, _bindings, _opts ->
        send(test, {:refreshed, conv_id, brokered})
        {:ok, 1}
      end)

      ref = make_ref()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
        send(test, {:spawned, cmd, args, opts})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "first")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      # The harness's servers are outside the registry; a secret write finds
      # this one the way it finds a registered one (#2548).
      stub_registered(conv, pid)

      # Turn one: the vault's value went to the broker, the placeholder and
      # the session token into the process env.
      assert_receive {:prepared, _, %{"GITHUB_TOKEN" => "ghp_from_vault"}}, 2_000
      assert_receive {:spawned, _cmd, _args, opts}, 2_000
      assert {"GITHUB_TOKEN", "__github_token__"} in Keyword.fetch!(opts, :env)

      prompt_id = drive_to_prompt(pid, ref)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      peer = :sys.get_state(pid).acp_peer
      assert is_pid(peer)

      {:ok, conv: conv, vault: vault, dek: dek, pid: pid, ref: ref, peer: peer, session: session}
    end

    test "a vault value edited between two turns reaches the live session, token kept", %{
      conv: conv,
      vault: vault,
      dek: dek,
      pid: pid,
      ref: ref,
      peer: peer
    } do
      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_rotated"}, dek)

      # A new session would reach nothing: the peer holds its token.
      reject(Fountain.Broker, :prepare, 4)

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})

      assert_receive {:refreshed, conv_id, %{"GITHUB_TOKEN" => "ghp_rotated"}}, 2_000
      assert conv_id == conv.id

      # The same peer carries the turn, on the same session.
      assert %{"method" => "session/prompt"} = next_prompt(pid, ref)
      refute_receive {:spawned, _, _, _}, 50
      assert :sys.get_state(pid).acp_peer == peer
      assert :sys.get_state(pid).broker.token == @session.token
    end

    test "a deleted vault key hands the name back to the environment", %{
      vault: vault,
      pid: pid,
      ref: ref
    } do
      # Ownership: the vault is this test's own row.
      secret = vault |> Vaults._unsafe_list_secrets() |> Enum.find(&(&1.key == "GITHUB_TOKEN"))
      {:ok, _} = Vaults.delete_secret(vault, secret)

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})

      # The environment's value, which the vault had been masking.
      assert_receive {:refreshed, _, %{"GITHUB_TOKEN" => "ghp_real"}}, 2_000
      assert %{"method" => "session/prompt"} = next_prompt(pid, ref)
    end

    # #2548: a live rewrite that fails must not swallow the change, or the
    # refresh before the next turn would find nothing to do.
    test "a live rewrite that fails mid-turn leaves the change for the next turn", %{
      vault: vault,
      dek: dek,
      pid: pid,
      ref: ref,
      peer: peer
    } do
      test = self()
      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      %{"method" => "session/prompt", "id" => prompt_id} = next_prompt(pid, ref)

      stub(Fountain.Broker, :refresh, fn _c, _b, _bindings, _opts ->
        send(test, :rewrite_failed)
        {:error, :unreachable}
      end)

      reject(Fountain.Broker, :prepare, 4)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_rotated"}, dek)

      assert_receive :rewrite_failed, 2_000
      state = :sys.get_state(pid)
      assert state.brokered["GITHUB_TOKEN"] == "ghp_from_vault"
      assert state.current_turn
      assert state.acp_peer == peer

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      stub(Fountain.Broker, :refresh, fn conv_id, brokered, _bindings, _opts ->
        send(test, {:refreshed, conv_id, brokered})
        {:ok, 1}
      end)

      # Rewritten before the turn, on the same token: still no new session.
      assert :ok = GenServer.call(pid, {:send_prompt, "once more", []})
      assert_receive {:refreshed, _, %{"GITHUB_TOKEN" => "ghp_rotated"}}, 2_000
      assert %{"method" => "session/prompt"} = next_prompt(pid, ref)
    end

    test "an unchanged secret writes nothing", %{pid: pid, ref: ref} do
      reject(Fountain.Broker, :prepare, 4)
      reject(Fountain.Broker, :refresh, 4)

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert %{"method" => "session/prompt"} = next_prompt(pid, ref)
    end

    test "a rewrite that finds no live session mints a fresh one, and the idle peer goes with it",
         %{vault: vault, dek: dek, pid: pid, peer: peer, session: session} do
      test = self()
      # Before the write: the write's own live refresh (#2548) finds no
      # session either, and leaves the change for the turn.
      stub(Fountain.Broker, :refresh, fn _c, _b, _bindings, _opts -> {:ok, 0} end)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_rotated"}, dek)

      stub(Fountain.Broker, :prepare, fn _c, brokered, _bindings, _opts ->
        send(test, {:prepared, brokered})
        {:ok, %{session | token: "av_sess_fresh"}}
      end)

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})

      # The peer held the old token in its env; nothing could hand it the
      # new one, so the turn is a fresh spawn carrying the new session.
      assert_receive {:prepared, %{"GITHUB_TOKEN" => "ghp_rotated"}}, 2_000
      assert_receive {:spawned, _cmd, _args, opts}, 2_000

      assert {"HTTPS_PROXY", "http://av_sess_fresh:c-test@broker.test:14322"} in Keyword.fetch!(
               opts,
               :env
             )

      refute Process.alive?(peer)
      assert :sys.get_state(pid).broker.token == "av_sess_fresh"
    end

    test "an expiring session is replaced before the turn, and the idle peer with it", %{
      pid: pid,
      peer: peer,
      session: session
    } do
      test = self()
      reject(Fountain.Broker, :refresh, 4)
      stub(Fountain.Broker, :expiring?, fn _session -> true end)

      stub(Fountain.Broker, :prepare, fn _c, _b, _bindings, _opts ->
        send(test, :reminted)
        {:ok, %{session | token: "av_sess_fresh"}}
      end)

      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})

      assert_receive :reminted, 2_000
      assert_receive {:spawned, _cmd, _args, opts}, 2_000

      assert {"HTTPS_PROXY", "http://av_sess_fresh:c-test@broker.test:14322"} in Keyword.fetch!(
               opts,
               :env
             )

      refute Process.alive?(peer)
    end

    test "a vault edited while the machine was parked reaches the broker on the wake", %{
      user: user,
      agent: agent
    } do
      # The reattach path: a new server reads the vault at init, so the
      # edit is in the session it mints before anything is written.
      vault = insert_vault(user_id: user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_parked"}, @dek)

      sandbox = insert_sandbox(user_id: user.id, status: "ready", machine_name: "parked")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          status: "idle",
          vault_id: vault.id
        )

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_woken"}, @dek)

      stub_happy_sprite("parked")
      {pid, _ref, :alive} = start_server(conv)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      assert_receive {:prepared, conv_id, %{"GITHUB_TOKEN" => "ghp_woken"}}, 2_000
      assert conv_id == conv.id
    end
  end

  # #2548. A GitHub App token lives an hour, and a turn can outlive it: the
  # client writes a fresh one to the vault while the turn runs. The native
  # broker reads a session's rules once per tunnel, and each `git push` is a
  # new tunnel, so the rewrite has to land on the session the running turn's
  # processes already hold. No stubbed broker here: the token is looked up
  # the way the broker's listener looks it up.
  describe "a secret written during a turn" do
    setup %{user: user, agent: agent} do
      configure_broker()

      vault = insert_vault(user_id: user.id)

      {:ok, _} =
        Vaults.upsert_secret(vault, %{"key" => "GITHUB_TOKEN", "value" => "ghp_hour_one"}, @dek)

      conv = insert_conversation(user_id: user.id, agent: agent, vault_id: vault.id)
      test = self()

      stub_happy_sprite()
      stub(Fountain.Broker, :preflight, fn -> :ok end)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      ref = make_ref()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
        send(test, {:spawned, cmd, args, opts})
        {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: ref}}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, data ->
        send(test, {:wrote, IO.iodata_to_binary(data)})
        :ok
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "push in an hour")
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
      # The harness's servers are outside the registry; a secret write finds
      # this one the way it finds a registered one (#2548).
      stub_registered(conv, pid)

      # The turn is running: the prompt is out and nothing has answered it.
      assert_receive {:spawned, _cmd, _args, _opts}, 2_000
      prompt_id = drive_to_prompt(pid, ref)

      {:ok, conv: conv, vault: vault, pid: pid, ref: ref, prompt_id: prompt_id}
    end

    test "the next tunnel of the running turn carries the new value, token and turn kept", %{
      conv: conv,
      vault: vault,
      pid: pid,
      ref: ref,
      prompt_id: prompt_id
    } do
      %{broker: %{token: token}, acp_peer: peer, current_turn: turn} = :sys.get_state(pid)
      assert turn
      assert github_credential(token) == "ghp_hour_one"

      reject(Fountain.Broker, :prepare, 4)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {:ok, _} =
            Vaults.upsert_secret(
              vault,
              %{"key" => "GITHUB_TOKEN", "value" => "ghp_hour_two"},
              @dek
            )

          settle(pid)
        end)

      # What the listener resolves the sandbox's token to now.
      assert github_credential(token) == "ghp_hour_two"

      state = :sys.get_state(pid)
      assert state.broker.token == token
      assert state.acp_peer == peer
      assert state.current_turn == turn
      refute_received {:spawned, _, _, _}

      # Registered before the rules could inject it.
      assert Fountain.Conversations.Redaction.redact(conv.id, "ghp_hour_two") != "ghp_hour_two"

      # The turn ends on its own terms.
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert :sys.get_state(pid).current_turn == nil

      refute log =~ "ghp_hour_two"

      for event <- Conversations._unsafe_list_log_events(conv.id),
          do: refute(inspect(event) =~ "ghp_hour_two")
    end

    test "a server with no broker session takes the write as a no-op", %{pid: pid} do
      # The same cast, to a server with no broker session: nothing to rewrite.
      :sys.replace_state(pid, &%{&1 | broker: nil})
      before = :sys.get_state(pid)
      GenServer.cast(pid, :refresh_secrets)
      assert :sys.get_state(pid) == before
    end
  end

  defp stub_registered(conv, pid) do
    conv_id = conv.id

    stub(Fountain.Conversations.ConversationServer, :whereis, fn
      ^conv_id -> pid
      _ -> nil
    end)
  end

  defp github_credential(token) do
    {:ok, %{rules: rules}} = Fountain.Broker.Native.Sessions.lookup(token)
    Enum.find_value(rules, &(&1.name == "github-api" && &1.credential))
  end

  # The ACP wire, as `conversation_server_acp_test.exs` drives it: every byte
  # the server writes to stdin arrives as `{:wrote, line}`, and the command's
  # ref is ours so a test can feed stdout back.
  defp next_write do
    assert_receive {:wrote, line}, 1_000
    Jason.decode!(line)
  end

  defp reply(pid, ref, id, result) do
    line = Jason.encode!(%{"jsonrpc" => "2.0", "id" => id, "result" => result}) <> "\n"
    send(pid, {:stdout, %{ref: ref}, line})
    settle(pid)
  end

  defp settle(pid) do
    peer = :sys.get_state(pid).acp_peer

    if is_pid(peer) do
      try do
        _ = :sys.get_state(peer)
      catch
        :exit, _ -> :ok
      end
    end

    _ = :sys.get_state(pid)
    :ok
  end

  defp drive_to_prompt(pid, ref) do
    %{"id" => init_id, "method" => "initialize"} = next_write()
    reply(pid, ref, init_id, %{"agentCapabilities" => @caps})

    %{"id" => new_id, "method" => "session/new"} = next_write()
    reply(pid, ref, new_id, %{"sessionId" => "sess_1", "models" => %{}})
    %{"id" => set_id, "method" => "session/set_model"} = next_write()
    reply(pid, ref, set_id, %{})

    %{"id" => prompt_id, "method" => "session/prompt"} = next_write()
    settle(pid)
    prompt_id
  end

  # The next prompt on an idle peer, answering a model check on the way.
  defp next_prompt(pid, ref) do
    case next_write() do
      %{"method" => "session/set_model", "id" => id} ->
        reply(pid, ref, id, %{})
        next_prompt(pid, ref)

      other ->
        other
    end
  end
end
