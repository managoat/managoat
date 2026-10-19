defmodule Fountain.Conversations.ConversationServerTest do
  @moduledoc """
  First tests for `ConversationServer`.

  1,183 lines that provision sandboxes, hold decrypted tenant secrets, mint API
  keys and spend money on sprites — with no test file at all since launch, and
  excluded from the coverage gate on top of that. Every caller `Mimic.copy`'d it
  away, so the module was verified only by running the product.

  These cover the lifecycle: provisioning succeeds and the sandbox reaches
  `ready`; each way provisioning can fail leaves the sandbox and conversation
  marked `failed` rather than stuck; teardown revokes the sprite's callback key;
  and a terminate against a dead server still cleans up the rows.
  """

  use Fountain.ConversationServerCase

  import Fountain.ConversationServerCase.ACP

  alias Fountain.{Accounts, Environments}
  alias Fountain.Repo
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Termination

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes and the assertions stay about the rows and the trail. Stubbed at
  # `Managoat.Sandbox.Sprites` rather than at the `Managoat.Sandbox` facade so
  # a test that drives either layer itself still overrides it.
  # What `ConversationServer.send_prompt/4` reads: the server's registry value.
  defp setting_up?(conv_id) do
    match?(
      [{_pid, :setting_up}],
      Registry.lookup(Fountain.ConversationRegistry, conv_id)
    )
  end

  # A conversation on an agent whose environment is `env`.
  defp conversation_on(user, env) do
    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    insert_conversation(
      user_id: user.id,
      agent: agent,
      runtime: "claude",
      sandbox_id: sandbox.id,
      status: "pending"
    )
  end

  # `start_server/2` without waiting for the provision to settle, for a test
  # that holds a step open while it looks.
  defp start_unsettled(conv) do
    Managoat.Runtimes.Testing.FakeRuntime.observe(self())

    args = [
      conversation_id: conv.id,
      sandbox_id: conv.sandbox_id,
      runtime_module: Managoat.Runtimes.Testing.FakeRuntime
    ]

    pid =
      start_supervised!(%{
        id: make_ref(),
        start: {GenServer, :start_link, [Fountain.Conversations.ConversationServer, args]},
        restart: :temporary
      })

    {pid, Process.monitor(pid)}
  end

  # A stubbed step that tells the test it is running, then waits to be let go.
  defp hold(test_pid, what) do
    send(test_pid, {:held, what, self()})

    receive do
      :release -> :ok
    end
  end

  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_verified_user()
    env = insert_env(user_id: user.id)

    agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        runtime: "claude",
        sandbox_id: sandbox.id,
        status: "pending"
      )

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  describe "provisioning — happy path" do
    test "a provision outlasting the system-call timeout is still alive", %{conv: conv} do
      handle = stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        # Deliberately cross :sys.get_state/1's five-second timeout. This
        # reproduces #1702 without relying on scheduler load to delay startup.
        Process.send_after(self(), :finish_create, 5_100)
        receive do: (:finish_create -> {:ok, handle})
      end)

      {pid, _ref, settled} = start_server(conv)

      try do
        assert settled == :alive
        assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      after
        # Also drain the old helper's timed-out, still-provisioning server when
        # running this regression against the parent commit.
        GenServer.stop(pid, :normal, :infinity)
      end
    end

    test "drives the sandbox to ready", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    # #2577: the registry says a server is setting up while it provisions,
    # so the API queues a prompt instead of waiting on a call it cannot
    # answer, and stops saying so once it can.
    test "says it is setting up while it provisions, and not after", %{conv: conv} do
      handle = stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        send(test_pid, {:mid_setup, setting_up?(conv.id)})
        {:ok, handle}
      end)

      # Registered by name, as production registers it; `start_server/2`
      # keeps its servers out of the conversation supervisor.
      args = [
        conversation_id: conv.id,
        sandbox_id: conv.sandbox_id,
        runtime_module: Managoat.Runtimes.Testing.FakeRuntime
      ]

      pid =
        start_supervised!(%{
          id: make_ref(),
          start:
            {GenServer, :start_link,
             [ConversationServer, args, [name: ConversationServer.via(conv.id)]]},
          restart: :temporary
        })

      assert_receive {:mid_setup, true}, 5_000
      _ = :sys.get_state(pid, 10_000)
      refute setting_up?(conv.id)
      GenServer.stop(pid)
    end

    test "asks the runtime to write its config and prepare the sprite", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert_received :write_config
      assert_received :prepare_sandbox
      GenServer.stop(pid)
    end

    test "mints a sprite-scoped callback key and records it on the conversation", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      reloaded = Conversations._unsafe_get_conversation!(conv.id)
      assert reloaded.callback_api_key_id

      key = Repo.get(Accounts.ApiKey, reloaded.callback_api_key_id)
      assert key.scopes == ["sprite"]
      assert key.expires_at
      refute key.revoked_at

      GenServer.stop(pid)
    end

    test "runs the first turn when a prompt is supplied", %{conv: conv} do
      stub_happy_sprite()
      ref = stub_acp_transport()

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello there")
      prompt_id = drive_to_prompt(pid, ref)
      assert :sys.get_state(pid).acp_peer
      assert is_integer(prompt_id)
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "hello there"

      GenServer.stop(pid)
    end

    test "does not start a turn without a prompt", %{conv: conv} do
      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert Conversations._unsafe_list_turns(conv.id) == []
      GenServer.stop(pid)
    end

    test "the prompt reaches a server the registry cannot resolve", %{conv: conv} do
      # The #367 regression: queue_initial_prompt used to cast through the
      # registry, and Horde's CRDT registrations propagated asynchronously —
      # a cast fired right after start_child could hit an unresolved via-name
      # and vanish. The server provisioned, the user's
      # first prompt was silently gone. Delivery now targets the pid, which
      # this harness proves by construction: its servers run outside the conversation supervisor,
      # so the registry genuinely cannot resolve them.
      stub_happy_sprite()

      ref = stub_acp_transport()
      {pid, _ref, :alive} = start_server(conv, initial_prompt: "first prompt")
      drive_to_prompt(pid, ref)

      # Guards the premise, not the fix: the harness must keep its servers
      # out of the registry, or the turn assertion below stops demonstrating
      # anything about registry-independent delivery. It can only fail if
      # the harness changes (#406 item 11).
      assert Registry.lookup(Fountain.ConversationRegistry, conv.id) == []
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.prompt == "first prompt"

      GenServer.stop(pid)
    end
  end

  describe "the resolved MCP configuration (#1404)" do
    # The server's half of the fix. Resolution happens once, at provision, and
    # the resolved document is carried on state — so the turn path, which
    # re-reads the agent row on every prompt, has the resolved copy to send to
    # `session/new` instead of the raw one. `McpServersTest` covers what that
    # copy then becomes on the wire.
    test "provision resolves the agent's MCP config onto the server state", %{
      user: user,
      env: env,
      sandbox: sandbox
    } do
      {:ok, env} =
        Environments.update_environment(env, %{"env_vars" => %{"SALON_HOST" => "salon.example"}})

      agent =
        insert_agent(
          user_id: user.id,
          environment_id: env.id,
          runtime: "claude",
          mcp_servers: %{
            "salon" => %{
              "type" => "http",
              "url" => "https://${SALON_HOST}/mcp",
              "headers" => %{"Authorization" => "Bearer $${MANAGOAT_TOKEN}"}
            }
          }
        )

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      resolved = :sys.get_state(pid).resolved_mcp_servers

      # The environment reference is resolved by Fountain, and the escaped one
      # is left as a single-`$` reference for the runtime to expand from the
      # sandbox's own process env — where the credential is always current,
      # which is why a reattached or resumed turn cannot send a stale token.
      assert resolved == %{
               "salon" => %{
                 "type" => "http",
                 "url" => "https://salon.example/mcp",
                 "headers" => %{"Authorization" => "Bearer ${MANAGOAT_TOKEN}"}
               }
             }

      # The stored agent still holds the unresolved document: the resolved
      # values live only on the live conversation path.
      assert Fountain.Agents._unsafe_get_agent!(agent.id).mcp_servers["salon"]["url"] ==
               "https://${SALON_HOST}/mcp"

      GenServer.stop(pid)
    end

    test "an agentless conversation carries no resolved config", %{
      user: user,
      sandbox: sandbox
    } do
      conv =
        insert_conversation(
          user_id: user.id,
          agent_id: nil,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()

      {pid, _ref, :alive} = start_server(conv)

      assert :sys.get_state(pid).resolved_mcp_servers == nil

      GenServer.stop(pid)
    end
  end

  describe "provisioning — per-launch environment override (#783)" do
    # The observable difference between two environments at provision is which
    # one the packages are installed from, so that is what the assertion reads.
    test "the conversation's environment_id is provisioned from, not the agent's", %{
      user: user,
      env: agent_env
    } do
      override = insert_env(user_id: user.id)

      agent = insert_agent(user_id: user.id, environment_id: agent_env.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          environment_id: override.id,
          status: "pending"
        )

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, e, _se, _c ->
        send(test_pid, {:packages_for, e && e.id})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      override_id = override.id
      agent_env_id = agent_env.id
      assert_received {:packages_for, ^override_id}
      refute_received {:packages_for, ^agent_env_id}
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    test "a cross-tenant environment_id on the conversation is not materialised", %{
      user: attacker,
      conv: conv,
      sandbox: sandbox
    } do
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)

      # Inserted through the bare changeset — start_conversation refuses this,
      # so only a row that bypassed it could carry a foreign id.
      {:ok, conv} =
        conv
        |> Fountain.Conversations.Conversation.changeset(%{"environment_id" => victim_env.id})
        |> Repo.update()

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, e, _se, _c ->
        send(test_pid, {:packages_for, e && e.id})
        :ok
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {pid, _ref, :alive} = start_server(conv)
          victim_env_id = victim_env.id
          refute_received {:packages_for, ^victim_env_id}
          assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
          GenServer.stop(pid)
        end)

      assert log =~ "not owned by user #{attacker.id}"
    end
  end

  describe "provisioning — tenant isolation" do
    test "a cross-tenant environment_id on the agent is not materialised" do
      attacker = insert_verified_user()
      victim = insert_verified_user()
      victim_env = insert_env(user_id: victim.id)

      # A legacy row from before create_agent validated environment ownership,
      # inserted through the bare changeset the context no longer exposes to
      # cross-tenant ids. The server must refuse to load it.
      {:ok, agent} =
        %Fountain.Agents.Agent{}
        |> Fountain.Agents.Agent.changeset(%{
          "name" => "legacy-cross-tenant",
          "model" => "google/gemini-3.1-pro-preview",
          "runtime" => "gemini",
          "user_id" => attacker.id,
          "environment_id" => victim_env.id
        })
        |> Repo.insert()

      sandbox = insert_sandbox(user_id: attacker.id, status: "pending")

      conv =
        insert_conversation(
          user_id: attacker.id,
          agent: agent,
          sandbox_id: sandbox.id,
          status: "pending"
        )

      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, e, _se, _c ->
        send(test_pid, {:packages_for, e && e.id})
        :ok
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {pid, _ref, :alive} = start_server(conv)

          # The victim's environment must never be materialised in the
          # attacker's sprite; the conversation still provisions, just
          # without the foreign environment.
          victim_env_id = victim_env.id
          refute_received {:packages_for, ^victim_env_id}
          assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
          GenServer.stop(pid)
        end)

      assert log =~ "not owned by user #{attacker.id}"
    end
  end

  describe "stage metrics — the producer end of #310" do
    # These drive the real server and read the Prometheus scrape before and
    # after. The reporter is node-global and cumulative and other tests in
    # this file emit the very same events, so "a sample exists" is satisfied
    # before these tests even run (#406) — only the delta across this test's
    # own action is evidence the action emitted.
    defp scrape_body do
      # The reporter aggregates synchronously on the telemetry event, but give
      # the handler a moment before scraping.
      Process.sleep(50)
      conn = FountainWeb.MetricsPlug.call(Plug.Test.conn(:get, "/metrics"), [])
      assert conn.status == 200
      conn.resp_body
    end

    # Current value of the {stage, status} counter series, 0 when absent.
    # stage and status are the metric's only tags, so at most one line matches.
    defp stage_count(body, stage, status) do
      body
      |> String.split("\n")
      |> Enum.find_value(0, fn line ->
        if String.starts_with?(line, "fountain_stage_count{") and
             line =~ ~s(stage="#{stage}") and line =~ ~s(status="#{status}") do
          {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
          value
        end
      end)
    end

    # Total observations recorded by a histogram (its _count line), 0 when absent.
    defp histogram_count(body, prefix) do
      body
      |> String.split("\n")
      |> Enum.filter(fn line ->
        String.starts_with?(line, prefix) and line =~ "_count"
      end)
      |> Enum.map(fn line ->
        {value, ""} = line |> String.split(" ") |> List.last() |> Integer.parse()
        value
      end)
      |> Enum.sum()
    end

    test "a successful provision lands in the scrape as provision/done", %{conv: conv} do
      stub_happy_sprite()
      before_body = scrape_body()

      {pid, _ref, :alive} = start_server(conv)
      GenServer.stop(pid)

      after_body = scrape_body()

      # Exactly this provision — and a *successful* one: done moved, failed
      # did not.
      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done") + 1

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed")

      # The span around fresh provisioning feeds the duration histogram.
      assert histogram_count(after_body, "fountain_fresh_provision_stop_duration") ==
               histogram_count(before_body, "fountain_fresh_provision_stop_duration") + 1
    end

    test "a failed provision lands in the scrape as provision/failed", %{conv: conv} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        {:error, :quota_exceeded}
      end)

      before_body = scrape_body()

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      after_body = scrape_body()

      assert stage_count(after_body, "provision", "failed") ==
               stage_count(before_body, "provision", "failed") + 1

      assert stage_count(after_body, "provision", "done") ==
               stage_count(before_body, "provision", "done")
    end

    test "a completed turn lands in the scrape as turn/done", %{conv: conv} do
      before_body = scrape_body()
      {pid, ref, prompt_id} = start_with_turn(conv, "count me")
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      GenServer.stop(pid)

      after_body = scrape_body()

      assert stage_count(after_body, "turn", "done") ==
               stage_count(before_body, "turn", "done") + 1
    end
  end

  describe "provisioning — the floor precedes the packages (#2597)" do
    test "the cold arm applies the broker floor before any package command runs", %{
      user: user
    } do
      # The package commands run with the conversation's full process env,
      # broker session token included, and apt/npm hooks are code the tenant
      # chose. Before the floor is applied the sandbox has the provider's open
      # egress, so the policy has to land first and the packages come after.
      stub_happy_sprite()
      test_pid = self()

      env =
        insert_env(
          user_id: user.id,
          packages: %{"apt" => ["jq"]},
          networking_type: "limited",
          networking_config: %{"allowed_hosts" => ["archive.ubuntu.com"]}
        )

      agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        send(test_pid, :packages)
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      # Both ran, and in this order: the mailbox keeps arrival order.
      assert_received :network_policy
      assert_received :packages
      refute_received :network_policy
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
      GenServer.stop(pid)
    end

    # A Sprites floor write resets the guest's open flows when it takes effect
    # (#2964), so it goes before the CA install starts the relay, whose
    # readiness is a real handshake to the broker, and the provision holds
    # the conversation's first prompt for what is left of the settle window.
    test "on Sprites the floor is written before the CA and relay, and the settle is recorded",
         %{user: user} do
      stub_happy_sprite()
      test_pid = self()
      ref = make_ref()

      :telemetry.attach(
        "floor-settle-#{inspect(ref)}",
        [:fountain, :floor, :settle],
        fn _name, measurements, metadata, _ ->
          send(test_pid, {:settle, measurements, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach("floor-settle-#{inspect(ref)}") end)

      agent = insert_agent(user_id: user.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :install_broker_ca, fn _h, _c ->
        send(test_pid, :broker_ca)
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      # The first of the two in the mailbox, which keeps arrival order.
      assert_received first when first in [:network_policy, :broker_ca]
      assert first == :network_policy
      assert_received :broker_ca
      refute_received :network_policy

      conv_id = conv.id

      assert_received {:settle, %{held_ms: 0, gap_ms: gap},
                       %{conv_id: ^conv_id, provider: :sprites, path: "fresh"}}

      assert gap >= 0
      GenServer.stop(pid)
    end

    test "a GitHub skill installs after the floor, through the proxy", %{user: user} do
      stub_happy_sprite()
      test_pid = self()

      agent =
        insert_agent(
          user_id: user.id,
          runtime: "claude",
          skills: [%{"source" => "obra/superpowers"}]
        )

      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.stub(Fountain.SandboxSkills, :mount_fresh, fn _h, _r, skills, opts ->
        send(test_pid, {:skills, skills, opts[:env]})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      # Raced against the floor and the CA, npx could not resolve the
      # registry (2026-10-15). The mailbox keeps arrival order.
      assert_received :network_policy
      assert_received {:skills, [%{"source" => "obra/superpowers"}], env}
      assert List.keymember?(env, "HTTPS_PROXY", 0)
      assert List.keymember?(env, "NODE_EXTRA_CA_CERTS", 0)
      assert Enum.all?(env, fn {key, _} -> key in Fountain.Broker.env_keys() end)
      GenServer.stop(pid)
    end

    test "the adapter installs after the floor, beside the packages, and the runtime's own files after them",
         %{user: user} do
      # The adapter install is a download through the proxy, so it waits for
      # the floor and the CA, but nothing the packages, the clone or the setup
      # script do. Each stub below holds its step open until the test lets it
      # go, so both having started at once is the proof they overlap.
      stub_happy_sprite()
      test_pid = self()

      env = insert_env(user_id: user.id, packages: %{"apt" => ["jq"]}, setup_script: "true")
      conv = conversation_on(user, env)

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _h,
                                                                               "claude",
                                                                               env ->
        hold(test_pid, {:adapter, env})
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        hold(test_pid, :packages)
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :run_setup_script, fn _h, _e, _se, _c ->
        send(test_pid, :setup)
        :ok
      end)

      Mimic.stub(
        Fountain.Conversations.Provisioning,
        :prepare_runtime_sandbox,
        fn _h, _conv, "claude", _m, _a, _se, _s ->
          send(test_pid, :runtime_prepare)
          :ok
        end
      )

      {pid, _ref} = start_unsettled(conv)

      assert_receive :network_policy
      assert_receive {:held, {:adapter, adapter_env}, adapter}
      assert_receive {:held, :packages, packages}
      assert List.keymember?(adapter_env, "HTTPS_PROXY", 0)

      # Neither is done, so nothing after them has started.
      refute_received :setup
      send(packages, :release)
      assert_receive :setup
      refute_receive :runtime_prepare, 50

      # The setup script has run; the runtime's files wait for the adapter.
      send(adapter, :release)
      assert_receive :runtime_prepare
      _ = :sys.get_state(pid, :infinity)
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      GenServer.stop(pid)
    end

    test "the runtime template goes into the config home after the setup script and Managoat's own files",
         %{user: user} do
      # #2998: the setup script fills the template, and Managoat's files in
      # the home are the ones that win, so the copy comes after both.
      stub_happy_sprite()
      test_pid = self()

      env = insert_env(user_id: user.id, setup_script: "true")
      conv = conversation_on(user, env)

      conv =
        conv
        |> Ecto.Changeset.change(config_home: Managoat.Runtimes.Layout.config_home(conv.id))
        |> Repo.update!()

      Mimic.stub(Fountain.Conversations.Provisioning, :run_setup_script, fn _h, _e, _se, _c ->
        send(test_pid, :setup)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :write_runtime_config, fn _h, _m, _a, _ho ->
        send(test_pid, :runtime_config)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_runtime_sandbox, fn _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _ ->
        send(test_pid, :runtime_prepare)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.ConfigHome, :seed, fn _h, seeded, _agent, mode ->
        send(test_pid, {:seed, seeded.id, mode})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      conv_id = conv.id
      assert_received :runtime_config
      assert_received :setup
      assert_received :runtime_prepare
      assert_received {:seed, ^conv_id, :into}
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      GenServer.stop(pid)
    end

    test "a runtime template that cannot be copied fails the provision", %{user: user} do
      stub_happy_sprite()
      conv = conversation_on(user, insert_env(user_id: user.id, setup_script: "true"))

      Mimic.stub(Fountain.Conversations.ConfigHome, :seed, fn _h, _c, _a, :into ->
        {:error, {:runtime_template, {:not_a_json_object, "settings.json"}}}
      end)

      {pid, ref} = start_unsettled(conv)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}, 5_000
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    end

    test "with no setup script there is no template to copy", %{user: user} do
      stub_happy_sprite()
      conv = conversation_on(user, insert_env(user_id: user.id))
      reject(&Fountain.Conversations.ConfigHome.seed/4)

      {pid, _ref, :alive} = start_server(conv)
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      GenServer.stop(pid)
    end

    test "a pushed bundle installs the adapter beside the CA, and nothing installs after the floor",
         %{user: user} do
      stub_happy_sprite()
      test_pid = self()
      conv = conversation_on(user, insert_env(user_id: user.id))

      Mimic.stub(Fountain.Conversations.Provisioning, :preload_acp_adapter, fn _h, "claude" ->
        hold(test_pid, :preload)
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.reject(&Fountain.Conversations.Provisioning.prepare_acp_adapter/3)

      {pid, _ref} = start_unsettled(conv)

      # The floor goes on while the preload is still running: they overlap.
      assert_receive {:held, :preload, preload}
      assert_receive :network_policy
      send(preload, :release)

      _ = :sys.get_state(pid, :infinity)
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      GenServer.stop(pid)
    end

    test "an adapter the preload did not install installs after the floor", %{user: user} do
      stub_happy_sprite()
      test_pid = self()
      conv = conversation_on(user, insert_env(user_id: user.id))

      Mimic.stub(Fountain.Conversations.Provisioning, :preload_acp_adapter, fn _h, "claude" ->
        {:error, :acp_adapter_not_preloaded}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        send(test_pid, :network_policy)
        :ok
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _h,
                                                                               "claude",
                                                                               env ->
        send(test_pid, {:adapter, env})
        :ok
      end)

      {pid, _ref, :alive} = start_server(conv)

      assert_received :network_policy
      assert_received {:adapter, env}
      assert List.keymember?(env, "HTTPS_PROXY", 0)
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "ready"
      GenServer.stop(pid)
    end

    test "an adapter that fails to install fails the provision and destroys the sprite", %{
      user: user
    } do
      stub_happy_sprite()
      test_pid = self()
      conv = conversation_on(user, insert_env(user_id: user.id, packages: %{"apt" => ["jq"]}))

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _h, _r, _e ->
        {:error, {:acp_adapter_install_exit, 1, "nope"}}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_runtime_sandbox, fn _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _,
                                                                                   _ ->
        send(test_pid, :runtime_prepare)
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test_pid, {:destroyed, handle.name})
        :ok
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert_received {:destroyed, "test-sprite"}
      refute_received :runtime_prepare
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a package step that fails stops the adapter install still running beside it", %{
      user: user
    } do
      stub_happy_sprite()
      test_pid = self()
      conv = conversation_on(user, insert_env(user_id: user.id, packages: %{"apt" => ["jq"]}))

      Mimic.stub(Fountain.Conversations.Provisioning, :prepare_acp_adapter, fn _h, _r, _e ->
        hold(test_pid, :adapter)
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        # Fails only once the test has seen the adapter underway, so there
        # is a task to stop.
        :ok = hold(test_pid, :packages)
        {:error, {:packages, 100, "E: Unable to locate package jq"}}
      end)

      {_pid, ref} = start_unsettled(conv)
      assert_receive {:held, :adapter, adapter}
      assert_receive {:held, :packages, packages}
      monitor = Process.monitor(adapter)
      send(packages, :release)

      assert_stopped(ref)
      assert_receive {:DOWN, ^monitor, :process, ^adapter, _}
      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).status == "failed"
    end

    test "a policy that cannot be applied stops the provision before the packages", %{
      user: user
    } do
      stub_happy_sprite()
      test_pid = self()

      env =
        insert_env(
          user_id: user.id,
          packages: %{"apt" => ["jq"]},
          networking_type: "limited",
          networking_config: %{"allowed_hosts" => ["archive.ubuntu.com"]}
        )

      agent = insert_agent(user_id: user.id, environment_id: env.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      Mimic.stub(Fountain.Conversations.Provisioning, :apply_broker_floor, fn _h, _c ->
        {:error, {:network_policy, :unreachable}}
      end)

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        send(test_pid, :packages)
        :ok
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      refute_received :packages
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "provisioning — failure paths" do
    test "a sprite that cannot be created marks both rows failed", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts ->
        {:error, :quota_exceeded}
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a failing provisioning step destroys the sprite rather than leaking it", %{conv: conv} do
      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        {:error, :apt_failed}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test_pid, {:destroyed, handle.name})
        :ok
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      # The sprite is billed until it is destroyed, so a failed provision that
      # leaves it running costs money indefinitely.
      assert_received {:destroyed, "test-sprite"}
    end

    test "a step's failure quoting its output reaches the provision stage without it", %{
      conv: conv
    } do
      # A cut tail may begin part-way through a value that redaction would no
      # longer recognise, so the stage metadata carries the step and its code
      # only; the transcript has the output (#3009 review).
      stub_happy_sprite()

      Mimic.stub(Fountain.Conversations.Provisioning, :install_packages, fn _s, _e, _se, _c ->
        {:error, {:setup_exit, 1, "cret-tail-fragment-0987\nmore output"}}
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      failed =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "provision" and &1.state == "failed"))

      assert [_ | _] = failed

      for event <- failed do
        refute inspect(event) =~ "cret-tail-fragment"
        refute inspect(event) =~ "more output"
      end

      assert Enum.any?(failed, &(inspect(&1) =~ "{:setup_exit, 1}"))
    end

    test "a runtime that fails to prepare marks the sandbox failed", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      {_pid, ref, _} = start_server(conv, runtime: Managoat.Runtimes.Testing.FailingRuntime)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end

    test "a runtime whose config cannot be written marks the sandbox failed", %{
      conv: conv,
      sandbox: sandbox
    } do
      # Used to be `_ =` in the provision `with`: a config-write error was
      # meant to be non-fatal, but the runtime crashed on it instead, and had
      # it not, the agent would have run without its MCP servers under a
      # `provision/done`. Now it is a step like any other.
      stub_happy_sprite()

      {_pid, ref, _} = start_server(conv, runtime: Managoat.Runtimes.Testing.ConfigFailingRuntime)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "an unexpected exception is caught and does not leave the sandbox pending", %{
      conv: conv,
      sandbox: sandbox
    } do
      # The provision path wraps itself in a rescue precisely so a bug in any
      # step cannot strand a conversation in `pending` forever.
      stub_happy_sprite()

      Mimic.stub(Fountain.SandboxSkills, :mount_fresh, fn _s, _r, _sk, _opts ->
        raise "boom"
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    # The sandbox config steps run concurrently, each in its own process. An
    # exception there must still reach the provision's rescue, not crash the
    # server past it.
    test "an exception in a concurrent config step is caught the same way", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, _env ->
        raise "boom"
      end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"
    end

    test "a backend that cannot enforce the broker floor fails before any sandbox exists",
         %{user: user} do
      # A backend that does not advertise `:network_policy` cannot hold a
      # brokered sandbox to the broker. It is refused up front, by name
      # (#935), before a sandbox is created. Every shipped adapter advertises
      # it, so Sprites is made to say it does not.
      stub_happy_sprite()
      test_pid = self()

      Mimic.stub(Managoat.Sandbox, :supports?, fn
        _provider, :network_policy ->
          false

        provider, capability ->
          Mimic.call_original(Managoat.Sandbox, :supports?, [provider, capability])
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :create, fn name, _opts ->
        send(test_pid, {:created, name})
        {:ok, Managoat.Sandbox.Sprites.build_handle(name)}
      end)

      limited =
        insert_env(user_id: user.id, networking_type: "limited", networking_config: %{})

      agent = insert_agent(user_id: user.id, environment_id: limited.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: user.id, status: "pending")

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          runtime: "claude",
          sandbox_id: sandbox.id,
          status: "pending"
        )

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "failed"

      # Nothing was provisioned, so there is nothing to bill or to leak.
      refute_received {:created, _}

      events =
        Fountain.Repo.all(
          from(e in Fountain.Conversations.LogEvent,
            where: e.conversation_id == ^conv.id and e.kind == "stage" and e.stage == "broker"
          )
        )

      assert [%{state: "failed"} = event] = events
      assert Jason.decode!(event.data)["reason"] == "backend_lacks_network_policy"
    end

    test "unreadable tenant credentials fail the conversation rather than provisioning blind", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :unwrap_failed} end)

      {_pid, ref, _} = start_server(conv)
      assert_stopped(ref)

      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "reattach — failure paths (#799)" do
    # A `ready` sandbox routes the server down the reattach branch: probe the
    # sprite, then re-arm. Only a definitive not-found may retire the row —
    # on 2026-08-18 a 70 s DNS outage during a Horde failover ran this path
    # for nine live sandboxes at once, every probe answered nxdomain, and the
    # old error arm marked all nine `failed`, which is what the reaper's
    # destroy pass keys on.
    setup %{sandbox: sandbox, conv: conv} do
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      {:ok, conv} = Conversations.update_conversation(conv, %{status: "idle"})
      {:ok, sandbox: sandbox, conv: conv}
    end

    defp reattach_stage(conv_id) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == "reattach" and &1.state == "failed"))
    end

    test "a transient probe failure leaves the sandbox row untouched", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      # The whole point: the disk is still there, so nothing may route it to
      # the reaper's destroy pass.
      Mimic.reject(&Managoat.Sandbox.Sprites.destroy/1)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "ready"
      assert is_nil(reloaded.terminated_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The operator can still see it happened, and that it will be retried.
      assert %{data: data} = reattach_stage(conv.id)
      assert %{"retryable" => true, "reason" => reason} = Jason.decode!(data)
      assert reason =~ "nxdomain"
    end

    test "a 5xx from the provider is transient too", %{conv: conv, sandbox: sandbox} do
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, {:http, 503, %{}}}}
      end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
    end

    test "a reattach that never reaches the sprite announces nothing", %{conv: conv} do
      # #971: a Horde child is stopped and started by cluster churn, and every
      # rebalance re-enters this path. Announcing on the way in wrote 51
      # `started` events for one conversation in one second — fifty of them
      # describing a process that was replaced before it touched anything.
      # The provider round trip outlives a rebalance, so a start that will be
      # replaced is replaced before the announcement.
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      stages =
        conv.id
        |> Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "stage" and &1.stage == "reattach"))

      # The failure is announced; the arrival is not.
      assert Enum.map(stages, & &1.state) == ["failed"]
    end

    test "a definitive not-found retires the sandbox so the next prompt provisions fresh", %{
      conv: conv,
      sandbox: sandbox
    } do
      stub_happy_sprite()
      Mimic.stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      {_pid, ref, _} = start_server(conv)
      assert :normal = assert_stopped(ref)

      # `terminated`, where `main` wrote `failed` (ADR 0058 stage 7b). The row is
      # retired through the machine's owner now, with the provider step skipped
      # because this server has just been told the machine does not exist — and
      # a destroy writes `terminated`. Both are terminal, both stop counting
      # against the quota and both read as "gone" to every caller;
      # what the change buys is that the retirement is the same operation, with
      # the same `sandbox.destroyed` event, as every other way a machine ends.
      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "terminated"
      refute is_nil(reloaded.terminated_at)
      # The conversation itself is not failed — the user can still prompt it.
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert %{data: data} = reattach_stage(conv.id)
      assert %{"retryable" => false, "reason" => "not_found"} = Jason.decode!(data)
    end
  end

  describe "turn lifecycle on a running server" do
    defp start_with_turn(conv, prompt \\ "first") do
      stub_happy_sprite()
      ref = stub_acp_transport()
      {pid, _mon, :alive} = start_server(conv, initial_prompt: prompt)
      {pid, ref, drive_to_prompt(pid, ref)}
    end

    # Stage events persist their metadata as JSON in `data`.
    defp turn_stage_meta(conv_id, state) do
      conv_id
      |> Conversations._unsafe_list_log_events()
      |> Enum.find(&(&1.kind == "stage" and &1.stage == "turn" and &1.state == state))
      |> then(& &1.data)
      |> Jason.decode!()
    end

    test "an answered ACP prompt closes the turn and returns the conversation to idle", %{
      conv: conv
    } do
      {pid, ref, prompt_id} = start_with_turn(conv)

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "completed"
      assert is_nil(turn.exit_code)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "the first turn leaves titles unchanged without a harness title", %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      assert is_nil(Conversations._unsafe_get_conversation!(conv.id).title)
      GenServer.stop(pid)
    end

    test "a non-zero exit marks the turn failed but keeps the conversation usable", %{conv: conv} do
      {pid, ref, _prompt_id} = start_with_turn(conv)

      send(pid, {:exit, %{ref: ref}, 1})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.exit_code == 1

      # A failed turn is not a failed conversation — the user can prompt again.
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a conversation deleted before provisioning stops the server instead of crash-looping",
         %{
           conv: conv
         } do
      # This used to raise Ecto.NoResultsError out of
      # handle_continue(:provision) — unrescued, restart: :transient, so
      # Horde restarted it straight back into the same raise, burning the
      # supervisor's SHARED restart budget until it terminated and took
      # every conversation on the node with it.
      {:ok, _} = Repo.delete(Repo.get!(Fountain.Conversations.Conversation, conv.id))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, ref, settled} = start_server(conv)
          assert settled == :stopped
          assert assert_stopped(ref) == :normal
        end)

      assert log =~ "row missing before provisioning"
    end

    test "a sandbox deleted before provisioning stops the server instead of crash-looping", %{
      conv: conv,
      sandbox: sandbox
    } do
      {:ok, _} = Repo.delete(Fountain.Machines.Lease.get(sandbox.id))

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {_pid, ref, settled} = start_server(conv)
          assert settled == :stopped
          assert assert_stopped(ref) == :normal
        end)

      assert log =~ "row missing before provisioning"
    end

    test "a spawn that never starts returns the conversation to idle", %{conv: conv} do
      # The conversation is set to "running" just before the spawn attempt.
      # Before this reset, a failed spawn marked the turn failed but left the
      # conversation reporting "running" in the API and UI indefinitely.
      stub_happy_sprite()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:error, :econnrefused}
      end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "a spawn failure after reassignment leaves the replacement binding running", %{
      conv: conv
    } do
      stub_happy_sprite()
      replacement = insert_sandbox(user_id: conv.user_id, status: "ready")

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        {:ok, _} =
          Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "running"})

        {:error, :econnrefused}
      end)

      {pid, _ref, :alive} = start_server(conv, initial_prompt: "hello")
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "running"
      assert turn.ended_at == nil
      assert turn.exit_code == nil
      current = Conversations._unsafe_get_conversation!(conv.id)
      assert current.sandbox_id == replacement.id
      assert current.status == "running"

      refute Repo.exists?(
               from e in Fountain.Conversations.LogEvent,
                 where:
                   e.conversation_id == ^conv.id and e.stage == "turn" and e.state == "failed"
             )

      GenServer.stop(pid)
      assert Repo.reload!(turn).status == "running"
    end

    # The handshake succeeds; only the actual session/prompt write reaches a
    # real Sprites.Command process that exits during GenServer.call. This
    # exercises the SDK's safe-write boundary from the ACP writer process.
    defp exit_on_prompt_write(conv, exit_code \\ nil) do
      stub_happy_sprite()
      ref = stub_acp_transport()
      test = self()

      Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, _cmd, _args, _opts ->
        owner = self()

        command_pid =
          spawn(fn ->
            receive do
              {:"$gen_call", _from, _request} ->
                if exit_code do
                  send(owner, {:stderr, %{ref: ref}, "invalid api key\n"})
                  send(owner, {:exit, %{ref: ref}, exit_code})
                end

                exit(:normal)
            end
          end)

        {:ok,
         %Managoat.Sandbox.Command{
           provider: :sprites,
           ref: ref,
           private: %Sprites.Command{ref: ref, pid: command_pid, tty_mode: false}
         }}
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn command, data ->
        line = IO.iodata_to_binary(data)
        send(test, {:wrote, line})

        if Jason.decode!(line)["method"] == "session/prompt" do
          Mimic.call_original(Managoat.Sandbox.Sprites, :write_stdin, [command, data])
        else
          :ok
        end
      end)

      {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
      drive_to_prompt(pid, ref)
      pid
    end

    test "a runtime that exits during the ACP prompt write fails the turn (#603)", %{conv: conv} do
      pid = exit_on_prompt_write(conv)

      assert Process.alive?(pid)
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"
      assert %{"reason" => reason} = turn_stage_meta(conv.id, "failed")
      assert reason =~ "command_exited"

      GenServer.stop(pid)
    end

    test "a runtime that exits during the ACP prompt write keeps its diagnostics (#608)", %{
      conv: conv
    } do
      pid = exit_on_prompt_write(conv, 1)

      assert Process.alive?(pid)
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert turn.exit_code == 1
      assert %{"exit_code" => 1} = turn_stage_meta(conv.id, "done")
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      events = Conversations._unsafe_list_log_events(conv.id)
      assert stderr = Enum.find(events, &(&1.stream == "stderr" and &1.data =~ "invalid api key"))
      assert stderr.turn_id == turn.id

      GenServer.stop(pid)
    end

    test "ACP agent output is persisted as log events", %{conv: conv} do
      {pid, ref, _prompt_id} = start_with_turn(conv)

      notify(pid, ref, %{
        "sessionUpdate" => "agent_message_chunk",
        "content" => %{"type" => "text", "text" => "hello from the sprite."}
      })

      events = Conversations._unsafe_list_log_events(conv.id)
      assert Enum.any?(events, &(&1.data =~ "hello from the sprite"))

      GenServer.stop(pid)
    end

    test "a dropped sprite WebSocket fails the turn and frees the conversation (#413)", %{
      conv: conv
    } do
      # Sprites.Command sends {:error, %{ref: ...}, reason} when the socket
      # drops mid-run, then stops. Pre-#413 the handler logged and kept
      # current_command set, so the turn stayed "running" forever, every
      # prompt got {:error, :busy}, and both reclaim paths were suppressed —
      # the sprite billed until max_lifetime.
      {pid, ref, _prompt_id} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      refute is_nil(turn.ended_at)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      # The recovery the user actually needs: prompting again works.
      assert :ok = GenServer.call(pid, {:send_prompt, "again", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "a close before the exit frame fails the turn, it does not complete it", %{conv: conv} do
      # The frame this replaces. Until managoat_sandbox 0.2.0 a socket that
      # closed with no exit frame was reported as {:exit, _, 0}, so this
      # landed on the :exit handler and wrote a *completed* turn with exit
      # code 0 — a turn that never finished, recorded as a clean one, which
      # is the shape of managoat/fountain#880.
      {pid, ref, _prompt_id} = start_with_turn(conv)

      send(pid, {:error, %{ref: ref}, :closed_before_exit})
      _ = :sys.get_state(pid)

      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "failed"
      assert is_nil(turn.exit_code)
      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      GenServer.stop(pid)
    end

    test "an error for a stale command ref does not touch the current turn", %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)

      send(pid, {:error, %{ref: make_ref()}, :closed})
      _ = :sys.get_state(pid)

      # Still mid-turn: the running turn is untouched and busy is still busy.
      assert [turn] = Conversations._unsafe_list_turns(conv.id)
      assert turn.status == "running"
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})
      GenServer.stop(pid)
    end

    test "prompting while a turn is running is refused rather than queued", %{conv: conv} do
      {pid, _ref, _prompt_id} = start_with_turn(conv)

      # There is no queue, so a second prompt mid-turn must be rejected rather
      # than silently dropped or interleaved.
      assert {:error, :busy} = GenServer.call(pid, {:send_prompt, "second", []})

      GenServer.stop(pid)
    end

    test "a prompt after the turn finishes starts a new turn", %{conv: conv} do
      {pid, ref, prompt_id} = start_with_turn(conv)
      reply(pid, ref, prompt_id, %{"stopReason" => "end_turn"})

      assert :ok = GenServer.call(pid, {:send_prompt, "second", []})
      assert length(Conversations._unsafe_list_turns(conv.id)) == 2

      GenServer.stop(pid)
    end

    test "interrupt with nothing running reports idle rather than pretending to act", %{
      conv: conv
    } do
      stub_happy_sprite()
      {pid, _mon, :alive} = start_server(conv)

      assert {:error, :idle} = GenServer.call(pid, :interrupt)
      GenServer.stop(pid)
    end
  end

  describe "secret redaction wiring" do
    test "the server registers the sprite env for redaction", %{conv: conv, env: env} do
      # The registry only protects anything if something populates it: verify
      # from the operation, not from the helper.
      {:ok, _} =
        Fountain.Environments.upsert_secret(
          env,
          %{"key" => "LEAKY_TOKEN", "value" => "tenant-secret-cccccccccccc"},
          <<0::256>>
        )

      stub_happy_sprite()
      Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:ok, <<0::256>>} end)

      {pid, _ref, :alive} = start_server(conv)

      values = Fountain.Conversations.Redaction.lookup(conv.id)
      assert "tenant-secret-cccccccccccc" in values

      GenServer.stop(pid)
    end

    test "registered values are forgotten when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      GenServer.stop(pid)
      assert_stopped(ref)

      assert Fountain.Conversations.Redaction.lookup(conv.id) == []
    end
  end

  describe "teardown" do
    test "the harness stops a surviving server before releasing its database owner", %{conv: conv} do
      stub_happy_sprite()
      {pid, _ref, :alive} = start_server(conv)
      key_id = Conversations._unsafe_get_conversation!(conv.id).callback_api_key_id
      refute Repo.get!(Accounts.ApiKey, key_id).revoked_at

      # ExUnit stops supervised children before on_exit callbacks; DataCase's
      # separate owner stays alive until its later callback releases the DB.
      on_exit(fn ->
        refute Process.alive?(pid)
        assert Repo.get!(Accounts.ApiKey, key_id).revoked_at
      end)
    end

    test "revokes the sprite's callback key when the server stops", %{conv: conv} do
      stub_happy_sprite()

      {pid, ref, :alive} = start_server(conv)
      key_id = Conversations._unsafe_get_conversation!(conv.id).callback_api_key_id
      refute Repo.get(Accounts.ApiKey, key_id).revoked_at

      GenServer.stop(pid)
      assert_stopped(ref)

      # Otherwise the sandbox's credential outlives the sandbox.
      assert Repo.get(Accounts.ApiKey, key_id).revoked_at
    end
  end

  describe "terminate/1 with no running server" do
    test "still marks the conversation and sandbox terminated", %{conv: conv, sandbox: sandbox} do
      # After a BEAM restart the GenServer is gone but the rows remain, and a
      # user still needs to be able to clean up.
      assert :ok = Termination.terminate_conversation(conv.id)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "terminated"
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "terminated"
    end

    test "reports not_running for an unknown conversation" do
      assert {:error, :not_running} =
               Termination.terminate_conversation(Ecto.UUID.generate())
    end

    test "does not resurrect an already-failed sandbox", %{conv: conv, sandbox: sandbox} do
      {:ok, _} = update_sandbox(sandbox, %{status: "failed"})

      assert :ok = Termination.terminate_conversation(conv.id)
      assert Conversations._unsafe_get_sandbox!(sandbox.id).status == "failed"
    end
  end

  describe "interrupt/1 and send_prompt/3 with no running server" do
    test "interrupt reports not_running", %{conv: conv} do
      assert {:error, :not_running} = Interruption.interrupt(conv.id)
    end

    # The two misses are different answers (#1179). A conversation that exists
    # but has nothing running is a conflict; only a missing row is a 404, and
    # conflating them is what left `interrupt` telling an owner their own
    # conversation belonged to someone else.
    test "interrupt for an unknown conversation reports not_found" do
      assert {:error, :not_found} = Interruption.interrupt(Ecto.UUID.generate())
    end

    test "interrupt of a terminated conversation reports not_running, not not_found", %{
      conv: conv
    } do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :not_running} = Interruption.interrupt(conv.id)
    end

    test "send_prompt for an unknown conversation reports not_running" do
      assert {:error, :not_running} =
               ConversationServer.send_prompt(Ecto.UUID.generate(), "hi", [])
    end

    test "send_prompt to a terminated conversation reports gone", %{conv: conv} do
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})

      assert {:error, :gone} = ConversationServer.send_prompt(conv.id, "hi", [])
    end
  end

  describe "interrupt/1 against a dead server holding a running turn (#1179)" do
    # An autonomous turn ("background task follow-up") — or any turn — can be
    # left `status: "running"` in the DB with no ConversationServer left to
    # answer for it: the process exited (deploy, rebalance, a plain
    # `{:stop, :normal, _}` return) without closing the turn first, and
    # nothing wakes the conversation again until the next prompt. Before this
    # fix, `interrupt/2` only ever checked `whereis/1` and gave up with
    # `{:error, :not_running}` — indistinguishable, from the API, to a caller
    # hitting a conversation that plain does not exist. The fix mirrors
    # `send_prompt/4`'s existing wake-on-miss fallback: reattach, which
    # either resumes the real session or (as here, with no active sprite
    # session) reconciles the orphaned turn.
    test "wakes the conversation; reattach finds no live session and reconciles the stuck turn" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      conv =
        insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "running")

      {:ok, turn} =
        Conversations._unsafe_create_turn(%{
          conversation_id: conv.id,
          turn_number: 1,
          prompt: "(background task follow-up)",
          origin: "autonomous",
          status: "running",
          started_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })

      stub_happy_sprite()

      on_exit(fn ->
        case ConversationServer.whereis(conv.id) do
          nil -> :ok
          pid -> if Process.alive?(pid), do: GenServer.stop(pid, :normal)
        end
      end)

      # No server is registered for this conversation at all — exactly the
      # state a dead process leaves behind. `list_sessions` (stubbed to `[]`
      # by stub_happy_sprite/1) means reattach finds nothing to resume.
      assert {:error, :idle} = Interruption.interrupt(conv.id)

      assert Conversations._unsafe_get_conversation!(conv.id).status == "idle"

      assert [%{id: turn_id, status: "interrupted"}] = Conversations._unsafe_list_turns(conv.id)
      assert turn_id == turn.id
    end
  end
end
