defmodule Fountain.AuditGuardrailTest do
  @moduledoc """
  The rule this campaign established, enforced (#552).

  #540 found auditing scattered across callers: a blanket plug on the `:api`
  pipeline, a handful of LiveViews that remembered, and seven contexts with no
  audit calls at all. Every fix in that campaign moved the recording **into the
  context function**, so a mutation is audited whichever door it came through.

  That property is invisible to the compiler. Without a test, the next context
  function to be added joins the gap list silently — which is exactly how the
  original gap grew. This file is the guard; ADR 0013 is the decision it
  guards.

  ## Adding a mutation

  If you add a context function that changes tenant-owned state, add it to
  `@must_audit` with a call that exercises it. If it genuinely should not audit
  (high-volume machine state — see the `Fountain.Audit` moduledoc), add it to
  `@deliberately_silent` with the reason, so the exclusion is a decision on the
  record rather than an omission.
  """

  use Fountain.DataCase, async: true
  use Mimic

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes and the assertions stay about the rows and the trail. Stubbed at
  # `Managoat.Sandbox.Sprites` rather than at the `Managoat.Sandbox` facade so
  # a test that drives either layer itself still overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :exec, fn _, "true", [], _ -> {:ok, "", 0} end)
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    :ok
  end

  alias Fountain.{
    Agents,
    Audit,
    Conversations,
    Environments,
    InferenceCredentials,
    OAuth,
    Vaults
  }

  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Termination
  alias Fountain.Conversations.Wake
  alias Fountain.Machines.Machine

  defmodule OkProbe do
    @moduledoc false
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(_message, _from, state), do: {:reply, :ok, state}
  end

  # {label, fun/1 taking the user, expected action}
  #
  # Each entry performs the mutation and names the event it must leave. The
  # point is coverage of the *rule*, not of each function's behaviour — the
  # per-child test files cover metadata, actors and redaction in depth.
  @must_audit [
    {"agent create", &__MODULE__.do_agent_create/1, "agent.created"},
    {"agent update", &__MODULE__.do_agent_update/1, "agent.updated"},
    {"agent source reference cleanup", &__MODULE__.do_agent_source_cleanup/1, "agent.updated"},
    {"agent delete", &__MODULE__.do_agent_delete/1, "agent.deleted"},
    {"environment create", &__MODULE__.do_env_create/1, "environment.created"},
    {"environment update", &__MODULE__.do_env_update/1, "environment.updated"},
    {"environment delete", &__MODULE__.do_env_delete/1, "environment.deleted"},
    {"chatgpt subscription connect", &__MODULE__.do_chatgpt_connect/1,
     "chatgpt_subscription.connected"},
    {"chatgpt subscription disconnect", &__MODULE__.do_chatgpt_disconnect/1,
     "chatgpt_subscription.disconnected"},
    {"connection create", &__MODULE__.do_connection_create/1, "connection.created"},
    {"connection complete", &__MODULE__.do_connection_complete/1, "connection.connected"},
    {"connection delete", &__MODULE__.do_connection_delete/1, "connection.deleted"},
    {"vault create", &__MODULE__.do_vault_create/1, "vault.created"},
    {"vault update", &__MODULE__.do_vault_update/1, "vault.updated"},
    {"vault delete", &__MODULE__.do_vault_delete/1, "vault.deleted"},
    {"vault copy", &__MODULE__.do_vault_copy/1, "vault.created"},
    # Explicit workspaces (ADR 0097, step 5): made and deleted by their owner.
    {"workspace create", &__MODULE__.do_workspace_create/1, "workspace.created"},
    {"workspace delete", &__MODULE__.do_workspace_delete/1, "workspace.deleted"},
    {"api key mint", &__MODULE__.do_key_create/1, "api_key.created"},
    {"api key revoke", &__MODULE__.do_key_revoke/1, "api_key.revoked"},
    {"conversation key mint", &__MODULE__.do_conversation_key_create/1, "api_key.created"},
    {"api key expiry change", &__MODULE__.do_key_expiry/1, "api_key.expiry_changed"},
    {"inference credential write", &__MODULE__.do_cred_write/1, "inference_credential.write"},
    {"inference credential clear", &__MODULE__.do_cred_clear/1, "inference_credential.delete"},
    {"conversation delete", &__MODULE__.do_conv_delete/1, "conversation.deleted"},
    # The lifecycle verbs (#2209). These were recorded by a private GenServer
    # client function until the client halves moved to
    # `Conversations.Termination`; the four entries are what keeps them in the
    # context and out of any caller.
    {"conversation prompt", &__MODULE__.do_conv_prompt/1, "conversation.prompted"},
    {"conversation interrupt", &__MODULE__.do_conv_interrupt/1, "conversation.interrupted"},
    {"conversation wake without a prompt", &__MODULE__.do_conv_wake/1, "conversation.woken"},
    {"conversation terminate", &__MODULE__.do_conv_terminate/1, "conversation.terminated"},
    {"conversation labels", &__MODULE__.do_labels/1, "conversation.labels_set"},
    {"sandbox teardown fence", &__MODULE__.do_teardown_fence/1, "sandbox.teardown_requested"},
    # The completed destroy, beside the intent above (ADR 0058 stage 5). The
    # machine's owner records it, so every door onto a destroy — terminate, a
    # reclaim, and the forced teardowns of stage 5b — is covered by one entry.
    {"machine destroy", &__MODULE__.do_machine_destroy/1, "sandbox.destroyed"},
    # The third completed-operation event, one per owner verb (ADR 0058 stage
    # 7a). `main` recorded nothing at all when a parked machine came back, so a
    # tenant's trail showed the suspend and not the wake.
    {"machine resume", &__MODULE__.do_machine_resume/1, "sandbox.resumed"},
    # The fourth and fifth, from the provision bracket (ADR 0058 stage 7b).
    # `main` recorded neither: a tenant's trail began at the first turn, and a
    # machine that never came up left no trace at all.
    {"machine provision", &__MODULE__.do_machine_provision/1, "sandbox.provisioned"},
    {"machine provision failure", &__MODULE__.do_machine_provision_failed/1,
     "sandbox.provision_failed"},
    # Two of stage 5b's forced-teardown doors, named separately from the entry
    # above. That one drives `Machine.destroy/2` itself and would stay green if
    # a site stopped going through it; these drive the sites.
    {"admin reap of a machine with no server", &__MODULE__.do_machine_reap/1,
     "sandbox.destroyed"},
    {"account compute teardown", &__MODULE__.do_account_compute_teardown/1,
     "sandbox.teardown_requested"},
    {"role change", &__MODULE__.do_role_change/1, "account.role_changed"},
    # Secrets and credentials (#593). These had five and four call sites
    # respectively before the recording moved into the context; the entries
    # below are what stops a sixth from being silent.
    {"environment secret write", &__MODULE__.do_env_secret_write/1, "environment.secret.write"},
    {"environment secret delete", &__MODULE__.do_env_secret_delete/1,
     "environment.secret.delete"},
    {"vault secret write", &__MODULE__.do_vault_secret_write/1, "vault.secret.write"},
    {"vault secret update", &__MODULE__.do_vault_secret_update/1, "vault.secret.update"},
    {"vault secret delete", &__MODULE__.do_vault_secret_delete/1, "vault.secret.delete"},
    {"password reset", &__MODULE__.do_password_reset/1, "auth.password.reset"},
    {"password change", &__MODULE__.do_password_change/1, "auth.password.changed"},
    {"email verification", &__MODULE__.do_verify_email/1, "auth.email.verified"},
    # Secret bindings (ADR 0019 gate 1b): where a credential goes is as
    # auditable as the credential's existence.
    {"secret binding create", &__MODULE__.do_binding_create/1, "secret_binding.created"},
    {"secret binding update", &__MODULE__.do_binding_update/1, "secret_binding.updated"},
    {"secret binding delete", &__MODULE__.do_binding_delete/1, "secret_binding.deleted"},
    {"oauth client create", &__MODULE__.do_oauth_client_create/1, "oauth_client.created"},
    {"oauth client update", &__MODULE__.do_oauth_client_update/1, "oauth_client.updated"},
    {"oauth client delete", &__MODULE__.do_oauth_client_delete/1, "oauth_client.deleted"},
    # OAuth (#1343). The state machine (Managoat.OAuth.Codes and .Device)
    # audits through the host, not beside its Repo calls; it cannot complete any of
    # these three mutations without calling Fountain.OAuth.Host.audit/3, and
    # that is where the recording lives now. These entries are what prove the
    # host still records them, whichever door the grant came through.
    {"oauth authorize", &__MODULE__.do_oauth_authorize/1, "oauth.authorized"},
    {"oauth device approve", &__MODULE__.do_oauth_device_approve/1, "oauth.device_approved"},
    {"oauth device deny", &__MODULE__.do_oauth_device_deny/1, "oauth.device_denied"}
  ]

  # Documented non-coverage. Mirrors the `Fountain.Audit` moduledoc; if the two
  # ever disagree, the moduledoc is the one to trust and this list is stale.
  @deliberately_silent %{
    "Termination._unsafe_finish_conversation_termination/2" =>
      "internal conditional status write; terminate_conversation/2 audits the successful action once",
    "Conversations._unsafe_complete_turn/4" =>
      "conditional per-turn bookkeeping; the turn stage records completion outside its transaction",
    "Interruption._unsafe_interrupt_turn/2 and _unsafe_idle_interrupted_turn/1 (delegated from Conversations)" =>
      "conditional interrupt bookkeeping; its turn stage and public lifecycle action carry the trail",
    "Conversations._unsafe_finish_machine_gone/2" =>
      "conditional actor bookkeeping; the sandbox stage records a current notification, and " <>
        "releasing a parent the rebind stranded repairs machine state rather than tenant state",
    "PromptReceipt accept/2, resolve/2 and recover/0" =>
      "internal submission bookkeeping; prompt acceptance audits at its door and recovery persists wake/failed",
    "ConversationServer per-turn state" => "high-volume machine state; log_events covers it",
    "ActorStatus.fail/2 and running/1" =>
      "conditional actor bookkeeping; accepted provision and reattach stages carry the trail",
    "Fountain.Machines.Destroy.run/2 with audit: false, from Accounts.Deletion.delete_user/2" =>
      "the delete that follows nilifies audit_events.user_id, so a per-machine sandbox.destroyed " <>
        "would survive as an anonymous row describing a cascade; account.deleted carries the " <>
        "identity, and the fence's sandbox.teardown_requested is still recorded (#2344, ADR 0058)",
    "Fountain.Machines.Destroy.run/2 on a row whose user_id is nil" =>
      "account deletion nilifies user_id before its machines are torn down (#2329), so the " <>
        "destroy has no tenant to attribute; the deletion's own trail is the record of it",
    "Workspaces.insert_implicit/1, settle_provision/2 and delete_for_account/1" =>
      "an implicit workspace is made inside the launch's reservation transaction, where no " <>
        "audit can be recorded, and only gives the launch's own sandbox an owner record; " <>
        "conversation.created and sandbox.provisioned/provision_failed describe it, and " <>
        "account.deleted records the account deletion that removes them; an explicit " <>
        "workspace's status follows its provision, which sandbox.provisioned/provision_failed " <>
        "record (ADR 0097)",
    "Workspaces.Network's setup broker session" =>
      "provisioning machinery created and released with the setup it serves, as a " <>
        "conversation's broker session is; workspace.created and sandbox.provisioned record it",
    "Accounts.touch_api_key/1" => "a last-used stamp on every authenticated request",
    "ChatGPT.refresh/1 on success" =>
      "a token rotation keeps the subscription as it was; a refusal that revokes it is audited",
    "Connections.authorize/2" =>
      "starts a login on an existing connection; the grant it may produce is audited " <>
        "as connection.connected when it lands",
    "Connections.refresh/1 on success" =>
      "a token rotation keeps the connection as it was; a refusal that revokes it is audited",
    "Conversations.mark_read/2" => "reading is not a state change anyone audits",
    "Conversations._unsafe_update_harness_title/2" =>
      "harness-set display state, like a status transition; the ACP line that carried the " <>
        "title lands in log_events while a turn is open, and an owner's rename is audited as before",
    "theme and display preferences" => "not tenant data anyone reconstructs an incident from"
  }

  for {label, fun, action} <- @must_audit do
    test "#{label} leaves an audit event" do
      user = insert_active_user()

      unquote(fun).(user)

      actions =
        user.id
        |> Audit.list_recent_for_user(200)
        |> Enum.map(& &1.action)

      assert unquote(action) in actions, """
      #{unquote(label)} produced no #{unquote(action)} event.

      Mutations audit in the context, not the caller (#540). If this function
      genuinely should not audit, move it to @deliberately_silent with a reason
      and update the Fountain.Audit moduledoc — do not delete the assertion.

      Events seen: #{inspect(actions)}
      """
    end
  end

  test "the exclusion list is documented, not empty" do
    # Guard the guard: an empty list would mean the exclusions had been quietly
    # dropped, and the moduledoc claim would be stale.
    assert map_size(@deliberately_silent) > 0

    for {what, reason} <- @deliberately_silent do
      assert is_binary(reason) and byte_size(reason) > 10,
             "#{what} is excluded from auditing with no stated reason"
    end
  end

  test "every audited context function takes an attribution opts list" do
    # The other half of the rule: a context that audits but cannot be told who
    # the caller was records everything as "self", which is worse than useless
    # on an admin-driven or system-driven path.
    for {mod, fun, arity} <- [
          {Agents, :create_agent, 2},
          {Agents, :update_agent, 3},
          {Agents, :delete_agent, 2},
          {Environments, :create_environment, 2},
          {Environments, :update_environment, 3},
          {Environments, :delete_environment, 2},
          {Vaults, :create_vault, 2},
          {Vaults, :update_vault, 3},
          {Vaults, :delete_vault, 2},
          {Vaults, :copy_vault, 4},
          {Fountain.Connections, :create, 3},
          {Fountain.Connections, :complete, 3},
          {Fountain.Connections, :delete, 3},
          {InferenceCredentials, :put_credential, 5},
          {Launch, :start_conversation, 2},
          {Lifecycle, :fence_sandbox_for_teardown, 2},
          {Fountain.Accounts.Deletion, :destroy_sprites, 2},
          {Conversations, :delete_conversation, 2},
          {Fountain.OAuth, :authorize, 3},
          {Fountain.OAuth, :approve_device_grant, 3},
          {Fountain.OAuth, :deny_device_grant, 3}
        ] do
      # `Code.ensure_loaded?/1` first: `function_exported?/3` answers about
      # *loaded* modules, so on a seed where this test ran before anything had
      # referenced the context it reported a perfectly present function as
      # missing.
      assert Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity),
             "#{inspect(mod)}.#{fun}/#{arity} is missing — an audited context " <>
               "function must accept an opts list carrying :actor and :request_ip"
    end
  end

  ## ── the mutations ─────────────────────────────────────────────────────────

  def do_agent_create(user),
    do: {:ok, _} = Agents.create_agent(agent_attrs(%{"user_id" => user.id}))

  def do_agent_source_cleanup(user) do
    env = insert_env(user_id: user.id)
    insert_agent(user_id: user.id, environment_id: env.id)
    Agents.delete_source_and_version_agents(env)
  end

  def do_agent_update(user) do
    agent = insert_agent(user_id: user.id)
    {:ok, _} = Agents.update_agent(agent, %{"model" => "anthropic/claude-opus-4-5"})
  end

  def do_agent_delete(user) do
    {:ok, _} = Agents.delete_agent(insert_agent(user_id: user.id))
  end

  def do_env_create(user),
    do: {:ok, _} = Environments.create_environment(env_attrs(%{"user_id" => user.id}))

  def do_env_update(user) do
    {:ok, _} =
      Environments.update_environment(insert_env(user_id: user.id), %{"setup_script" => "x"})
  end

  def do_env_delete(user) do
    {:ok, _} = Environments.delete_environment(insert_env(user_id: user.id))
  end

  def do_chatgpt_connect(user) do
    {:ok, _} = Fountain.ChatGPT.connect_auth_json(user.id, chatgpt_auth_json())
  end

  def do_chatgpt_disconnect(user) do
    do_chatgpt_connect(user)
    Req.Test.stub(Fountain.ChatGPT.OAuth, &Req.Test.json(&1, %{}))
    :ok = Fountain.ChatGPT.disconnect(user.id)
  end

  def do_connection_create(user) do
    Fountain.Connections.FakeProvider.stub()

    {:ok, conn, url} =
      Fountain.Connections.create(user.id, %{
        "url" => Fountain.Connections.FakeProvider.server_url()
      })

    {conn, url}
  end

  def do_connection_complete(user) do
    {_conn, url} = do_connection_create(user)
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")

    {:ok, conn} =
      Fountain.Connections.complete(user.id, %{"state" => state, "code" => "good-code"})

    conn
  end

  def do_connection_delete(user) do
    conn = do_connection_complete(user)
    :ok = Fountain.Connections.delete(user.id, conn.id)
  end

  defp chatgpt_auth_json do
    claims = %{"https://api.openai.com/auth" => %{"chatgpt_account_id" => "acct_1"}}
    id_token = "e30." <> Base.url_encode64(Jason.encode!(claims), padding: false) <> ".x"

    Jason.encode!(%{
      "auth_mode" => "chatgpt",
      "tokens" => %{"id_token" => id_token, "access_token" => "at", "refresh_token" => "rt"}
    })
  end

  def do_vault_create(user),
    do: {:ok, _} = Vaults.create_vault(vault_attrs(%{"user_id" => user.id}))

  def do_vault_update(user) do
    {:ok, _} = Vaults.update_vault(insert_vault(user_id: user.id), %{"description" => "x"})
  end

  def do_vault_delete(user) do
    {:ok, _} = Vaults.delete_vault(insert_vault(user_id: user.id))
  end

  def do_workspace_create(user) do
    stub(Fountain.Workspaces.Provisioner, :start, fn _workspace, _sandbox_id -> {:ok, self()} end)
    env = insert_env(user_id: user.id)

    {:ok, _} =
      Fountain.Workspaces.create_workspace(user.id, %{"name" => "w", "environment_id" => env.id})
  end

  def do_workspace_delete(user) do
    {:ok, workspace} = do_workspace_create(user)
    {:ok, _} = Fountain.Workspaces.delete_workspace(workspace)
  end

  def do_vault_copy(user) do
    source = insert_vault(user_id: user.id)
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)

    {:ok, _} =
      Vaults.copy_vault(source, %{"name" => "copy-#{System.unique_integer([:positive])}"}, dek)
  end

  def do_binding_create(user) do
    {:ok, _} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })
  end

  def do_binding_update(user) do
    {:ok, b} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K2",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })

    {:ok, _} = Fountain.SecretBindings.update_binding(b, %{"enabled" => false})
  end

  def do_binding_delete(user) do
    {:ok, b} =
      Fountain.SecretBindings.create_binding(user.id, %{
        "key" => "K3",
        "host" => "api.example.com",
        "auth_type" => "bearer"
      })

    {:ok, _} = Fountain.SecretBindings.delete_binding(b)
  end

  def do_key_create(user), do: {:ok, {_, _}} = Fountain.Accounts.create_api_key(user.id, "guard")

  # A sprite key to mint from (#2934); its own mint is audited too, so the
  # check below finds the conversation key's event by its scope.
  def do_conversation_key_create(user) do
    {:ok, {parent, _}} =
      Fountain.Accounts.create_api_key(user.id, "guard-parent", scopes: ["sprite"])

    conv = Fountain.Factory.insert_conversation(user_id: user.id)

    {:ok, {_, _}} =
      Fountain.Accounts.create_conversation_api_key(user.id, parent.id, conv.id)
  end

  def do_key_expiry(user) do
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(user.id, "guard-expiry")
    at = DateTime.add(DateTime.utc_now(), 600)
    :ok = Fountain.Accounts.set_api_key_expiry(user.id, key.id, at)
  end

  def do_key_revoke(user) do
    {:ok, {key, _}} = Fountain.Accounts.create_api_key(user.id, "guard-revoke")
    {:ok, _} = Fountain.Accounts.revoke_api_key(user.id, key.id)
  end

  def do_cred_write(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-guard")
  end

  def do_cred_clear(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, nil)
  end

  def do_conv_delete(user) do
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)
    {:ok, _} = Conversations.delete_conversation(conv)
  end

  # Prompt and interrupt need a server or a wake; the trail is the point here,
  # not the turn pipeline, so the wake is stubbed and the actor is a probe
  # that answers any call with `:ok`. Terminate and release take their
  # no-server paths, which write the rows for real.
  def do_conv_prompt(user) do
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))
    stub(Wake, :wake_conversation, fn _id, _prompt, _images -> {:ok, conv} end)
    :ok = ConversationServer.send_prompt(conv.id, "hello", [], actor: "ui")
  end

  def do_conv_wake(user) do
    sandbox = insert_sandbox(user_id: user.id, machine_name: "sprite-woken")
    {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox_id: sandbox.id)

    stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, %{status: :running, raw: %{name: "sprite-woken"}}}
    end)

    server = spawn(fn -> Process.sleep(:infinity) end)
    test_pid = self()

    stub_server_start(fn _supervisor, _child_spec ->
      send(test_pid, :server_started)
      {:ok, server}
    end)

    {:ok, :waking} = Fountain.Conversations.Wake.wake_without_prompt(conv.id, actor: "ui")

    # The wake, and its audit, run behind the answer (#2584): wait for the
    # server to start, then for the audit the same task writes after it.
    assert_receive :server_started, 2_000
    await_audit(user.id, "conversation.woken")
  end

  defp await_audit(user_id, action, tries \\ 50) do
    actions = user_id |> Audit.list_recent_for_user(200) |> Enum.map(& &1.action)

    if action in actions or tries == 0 do
      :ok
    else
      Process.sleep(20)
      await_audit(user_id, action, tries - 1)
    end
  end

  def do_conv_interrupt(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: insert_agent(user_id: user.id),
        sandbox_id: sandbox.id,
        status: "running"
      )

    {:ok, probe} = GenServer.start_link(OkProbe, nil)
    # The client half moved to Fountain.Conversations.Interruption (#2213)
    # and calls its own local wake_for_interrupt/1, so the stub must target
    # that module for ConversationServer.interrupt/2 (a defdelegate to it)
    # to pick it up.
    stub(Fountain.Conversations.Interruption, :wake_for_interrupt, fn _id -> {:ok, probe} end)
    :ok = Interruption.interrupt(conv.id, actor: "ui")
  end

  def do_conv_terminate(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: insert_agent(user_id: user.id),
        sandbox_id: sandbox.id
      )

    :ok = Termination.terminate_conversation(conv.id, actor: "ui")
  end

  def do_labels(user) do
    conv = insert_conversation(user_id: user.id, agent: insert_agent(user_id: user.id))

    {:ok, _} = Conversations._unsafe_merge_labels(conv, %{"env" => "prod"})
  end

  def do_account_compute_teardown(user) do
    insert_sandbox(user_id: user.id, status: "ready")
    stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> :ok end)
    1 = Fountain.Accounts.Deletion.destroy_sprites(user)
  end

  def do_machine_destroy(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    {:ok, :destroyed} = Machine.destroy(sandbox.id, actor: "api", reason: :terminated)
  end

  def do_machine_resume(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "suspended")
    Mimic.stub(Managoat.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)
    {:ok, :resumed} = Machine.ensure_up(sandbox.id, actor: "system:wake")
  end

  def do_machine_provision(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "pending")
    handle = Managoat.Sandbox.Sprites.build_handle(sandbox.machine_name)
    Mimic.stub(Managoat.Sandbox.Sprites, :create, fn _name, _opts -> {:ok, handle} end)

    {:ok, :provisioned, :built} =
      Machine.provision(sandbox.id, fn _handle, _epoch -> {:ok, :built} end,
        actor: "system:conversation_server"
      )
  end

  def do_machine_provision_failed(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "pending")

    {:ok, :failed} =
      Machine.fail_provision(sandbox.id,
        actor: "system:conversation_server",
        reason: :server_start_failed
      )
  end

  def do_machine_reap(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    admin = insert_verified_user()
    {:ok, :released} = Termination.reap_sandbox(sandbox.id, admin_user_id: admin.id)
  end

  def do_teardown_fence(user) do
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    {:ok, _} = Lifecycle.fence_sandbox_for_teardown(sandbox)
  end

  def do_role_change(user), do: {:ok, _} = Fountain.Accounts.update_user_role(user, "admin")

  defp dek!(user_id) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user_id)
    dek
  end

  def do_env_secret_write(user) do
    env = insert_env(user_id: user.id)
    {:ok, _} = Environments.upsert_secret(env, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_env_secret_delete(user) do
    env = insert_env(user_id: user.id)
    secret = insert_secret(env, %{"key" => "GONE"})
    {:ok, _} = Environments.delete_secret(env, secret)
  end

  def do_vault_secret_write(user) do
    vault = insert_vault(user_id: user.id)
    {:ok, _} = Vaults.upsert_secret(vault, %{"key" => "K", "value" => "v"}, dek!(user.id))
  end

  def do_vault_secret_update(user) do
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, key: "TOKEN")

    {:ok, _} =
      Vaults.update_secret_metadata(vault, secret.key, %{"expires_at" => "2027-01-15T00:00:00Z"})
  end

  def do_vault_secret_delete(user) do
    vault = insert_vault(user_id: user.id)
    secret = insert_vault_secret(vault, %{"key" => "GONE"})
    {:ok, _} = Vaults.delete_secret(vault, secret)
  end

  def do_password_reset(user), do: {:ok, _} = Fountain.Accounts.reset_password(user, "newpass123")

  def do_password_change(user) do
    {:ok, _} = Fountain.Accounts.change_password(user, "password123", "newpass123")
  end

  def do_verify_email(user), do: {:ok, _} = Fountain.Accounts.verify_email(user)

  # The consent request the test client in config/test.exs accepts.
  defp oauth_request do
    verifier = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    %{
      "client_id" => "test-app",
      "redirect_uri" => "https://app.test/callback",
      "code_challenge" => Base.url_encode64(:crypto.hash(:sha256, verifier), padding: false),
      "code_challenge_method" => "S256"
    }
  end

  def do_oauth_authorize(user), do: {:ok, _} = Fountain.OAuth.authorize(user.id, oauth_request())

  def do_oauth_client_create(user) do
    {:ok, _} = OAuth.create_client(user.id, oauth_client_attrs())
  end

  def do_oauth_client_update(user) do
    {:ok, _} = OAuth.update_client(insert_oauth_client(user_id: user.id), %{"name" => "renamed"})
  end

  def do_oauth_client_delete(user) do
    {:ok, _} = OAuth.delete_client(insert_oauth_client(user_id: user.id))
  end

  def do_oauth_device_approve(user) do
    {:ok, %{user_code: code}} = Fountain.OAuth.start_device_grant()
    :ok = Fountain.OAuth.approve_device_grant(code, user.id)
  end

  def do_oauth_device_deny(user) do
    {:ok, %{user_code: code}} = Fountain.OAuth.start_device_grant()
    :ok = Fountain.OAuth.deny_device_grant(code, user.id)
  end
end
