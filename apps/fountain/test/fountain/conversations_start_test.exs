defmodule Fountain.ConversationsStartTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.Launch
  alias Fountain.Conversations.Wake

  # start_conversation/1 and the per-launch environment override (#783).
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # start_conversation/1
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2 — provider resume" do
    test "a failed resume leaves the row suspended and fails retryably" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "parked-wont-wake")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{}}}
      end)

      stub(Managoat.Sandbox.Sprites, :resume, fn _handle ->
        {:error, {:unavailable, :timeout}}
      end)

      assert {:error, :sandbox_resume_failed} = Wake.wake_conversation(conv.id)
      assert Repo.reload(sandbox).status == "suspended"
    end
  end

  describe "wake_conversation/2 — provider stickiness" do
    test "a suspended sandbox on a disabled provider refuses to wake rather than retire" do
      # Falling through to :create_new would retire the row and orphan (or
      # lose) the parked disk; a retryable error keeps the agent's memory
      # safe until the operator restores the provider's credentials.
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "parked-on-e2b")

      {:ok, sandbox} =
        update_sandbox(sandbox, %{status: "suspended", provider: "e2b"})

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      assert {:error, {:sandbox_provider_disabled, :e2b}} =
               Wake.wake_conversation(conv.id)

      assert Repo.reload(sandbox).status == "suspended"
    end
  end

  describe "start_conversation/1 machine_name scoping (#1632)" do
    # The bug this closes: a sandbox name is the machine's identity at the
    # provider, and provider names are unique per deployment token rather than
    # per tenant. A verbatim caller-supplied name let two rows in two accounts
    # name one machine — and that machine holds a tenant's decrypted
    # environment and vault values on disk.
    test "one account cannot name the machine another account's sandbox already names" do
      victim = insert_active_user()
      attacker = insert_active_user()
      agent = insert_agent(user_id: attacker.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      # Named the way Fountain names one, so this is the collision a caller
      # can actually mount: read a name off your own transcript, hand it back.
      target =
        insert_sandbox(
          user_id: victim.id,
          status: "ready",
          machine_name: "fountain-" <> binary_part(victim.id, 0, 8) <> "-deadbeef"
        )

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => attacker.id,
                 "machine_name" => target.machine_name
               })

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name !=
               target.machine_name
    end

    test "a supplied name becomes the suffix of this account's prefix" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "machine_name" => "review-loop-7"
               })

      prefix = "fountain-" <> binary_part(user.id, 0, 8) <> "-"

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name ==
               prefix <> "review-loop-7"
    end

    test "a name that already carries this account's prefix is not prefixed twice" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      full = "fountain-" <> binary_part(user.id, 0, 8) <> "-again"

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "machine_name" => full
               })

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name == full
    end

    test "a suffix outside the allowed shape is refused before any row is allocated" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      before = active_sandbox_count(user.id)

      for name <- ["has a space", "slash/es", "-leading-dash", String.duplicate("x", 41)] do
        assert {:error, :invalid_sprite_name} =
                 Launch.start_conversation(%{
                   "agent_id" => agent.id,
                   "user_id" => user.id,
                   "machine_name" => name
                 })
      end

      assert active_sandbox_count(user.id) == before
    end

    test "an empty machine_name is no override rather than an error" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "machine_name" => ""
               })

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name =~
               ~r/\Afountain-#{binary_part(user.id, 0, 8)}-[0-9a-f]{8}\z/
    end

    # ADR 0045 promises a `none` conversation a machine no other conversation
    # can reach, and checks it by counting rows that point at the sandbox.
    # Naming the machine is how a caller reaches one that check cannot see.
    for key <- ~w(machine_name sprite_name) do
      test "sandbox_api_access none refuses a caller-supplied #{key}" do
        user = insert_active_user()
        agent = insert_agent(user_id: user.id)
        before = active_sandbox_count(user.id)

        assert {:error, :invalid_sandbox_api_access} =
                 Launch.start_conversation(%{
                   "agent_id" => agent.id,
                   "user_id" => user.id,
                   "sandbox_mode" => "ephemeral",
                   "sandbox_api_access" => "none",
                   unquote(key) => "worker-1"
                 })

        assert active_sandbox_count(user.id) == before
      end
    end

    # `sprite_name` is machine_name's deprecated old name (#2108), accepted
    # until the Fountain-name aliases go (#2776).
    test "the deprecated sprite_name still names the machine" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "sprite_name" => "old-key"
               })

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name ==
               "fountain-" <> binary_part(user.id, 0, 8) <> "-old-key"
    end

    test "the same name under both keys is one name" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "machine_name" => "both",
                 "sprite_name" => "both"
               })

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).machine_name ==
               "fountain-" <> binary_part(user.id, 0, 8) <> "-both"
    end

    test "two different names are refused before any row is allocated" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      before = active_sandbox_count(user.id)

      assert {:error, :machine_name_conflict} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "machine_name" => "new",
                 "sprite_name" => "old"
               })

      assert active_sandbox_count(user.id) == before
    end

    test "sandbox_api_access none is still fine without a name" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "sandbox_mode" => "ephemeral",
                 "sandbox_api_access" => "none"
               })

      assert conv.sandbox_api_access == "none"
    end
  end

  describe "start_conversation/1" do
    test "the sandbox row is stamped with the resolved provider" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
      assert sandbox.provider == "sprites"
    end

    test "the conversation is stamped with the agent's current version" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      {:ok, _} = Agents.update_agent(agent, %{"description" => "edited"})
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert conv.agent_version_id == Agents.get_agent_version(agent.id, 2, user.id).id
    end

    test "an agent pinned to a disabled provider is refused before any row is allocated" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      # Simulate drift: the override was saved while the provider was
      # configured, and its credentials/adapter have since gone away. The
      # changeset guards saves, so write the column directly.
      {1, _} =
        Repo.update_all(
          Ecto.Query.from(a in Fountain.Agents.Agent, where: a.id == ^agent.id),
          set: [sandbox_provider: "e2b"]
        )

      before = active_sandbox_count(user.id)

      assert {:error, {:sandbox_provider_disabled, :e2b}} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      assert active_sandbox_count(user.id) == before
    end

    test "returns {:error, :vault_not_found} when vault_id belongs to a different user" do
      user1 = insert_active_user()
      user2 = insert_active_user()
      agent = insert_agent(user_id: user1.id)
      # vault belongs to user2, not user1
      vault = insert_vault(user_id: user2.id)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user1.id,
        "vault_id" => vault.id
      }

      assert {:error, :vault_not_found} = Launch.start_conversation(attrs)
    end

    test "is refused once the fleet is at its ceiling" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_fleet()

      assert {:error, :fleet_full} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end

    test "another provider's full fleet does not refuse the launch (#2667)" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_fleet(0, "e2b")
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, _} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end

    test "the ceiling is checked before any sandbox row is allocated" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_fleet()

      before = Fountain.Quotas.fleet_count()

      assert {:error, _} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      # A denial that still allocated would let a caller ratchet past the
      # ceiling by retrying, which is the failure mode the ceiling prevents.
      assert Fountain.Quotas.fleet_count() == before
    end

    test "one account may use every slot the fleet has" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      for _ <- 1..(Fountain.Quotas.fleet_ceiling("sprites") - 1),
          do: insert_sandbox(user_id: user.id, status: "ready")

      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, _} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end

    test "terminated sandboxes free capacity" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      [first | _] = fill_fleet()

      assert {:error, :fleet_full} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      {:ok, _} = update_sandbox(first, %{status: "terminated"})
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, _} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})
    end

    test "creates sandbox, conversation, and starts server", %{} do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user.id,
        "prompt" => "hello"
      }

      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.agent_id == agent.id
      assert conv.user_id == user.id
      assert conv.status == "pending"
    end

    test "the sandbox and the conversation share a new implicit workspace (ADR 0097)" do
      user = insert_active_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      agent = insert_agent(user_id: user.id, environment_id: env.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, conv} =
               Launch.start_conversation(%{
                 "agent_id" => agent.id,
                 "user_id" => user.id,
                 "vault_id" => vault.id
               })

      sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
      assert is_binary(conv.workspace_id)
      assert sandbox.workspace_id == conv.workspace_id

      ws = Repo.get!(Fountain.Workspaces.Workspace, conv.workspace_id)
      assert ws.implicit
      assert ws.status == "provisioning"

      # The environment the launch resolved (the agent's, since the launch
      # named none), not the conversation's own nil override.
      assert conv.environment_id == nil

      assert {ws.user_id, ws.environment_id, ws.vault_id, ws.provider} ==
               {user.id, env.id, vault.id, sandbox.provider}
    end

    test "a refused reservation leaves no workspace behind" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      fill_fleet()

      assert {:error, :fleet_full} =
               Launch.start_conversation(%{"agent_id" => agent.id, "user_id" => user.id})

      refute Repo.exists?(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
    end

    test "broadcasts graph update when parent_conversation_id is set", %{} do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{
        "agent_id" => agent.id,
        "user_id" => user.id,
        "parent_conversation_id" => parent_conv.id
      }

      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.parent_conversation_id == parent_conv.id
    end

    test "succeeds when vault_id is empty string", %{} do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => ""}
      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert is_nil(conv.vault_id)
    end

    test "succeeds and links vault when valid vault_id provided", %{} do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      vault = insert_vault(user_id: user.id)

      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => vault.id}
      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.vault_id == vault.id
    end

    test "a foreign vault is refused even when unrestricted or explicitly allowlisted", %{} do
      user = insert_active_user()
      foreign = insert_vault(user_id: insert_verified_user().id)

      for ids <- [nil, [foreign.id]] do
        agent = insert_agent(user_id: user.id, allowed_vault_ids: ids)
        attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => foreign.id}
        assert {:error, :vault_not_found} = Launch.start_conversation(attrs)
      end
    end

    test "allows a vault on the agent's allowed_vault_ids list", %{} do
      user = insert_active_user()
      vault = insert_vault(user_id: user.id)
      agent = insert_agent(user_id: user.id, allowed_vault_ids: [vault.id])

      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => vault.id}
      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.vault_id == vault.id
    end

    test "returns {:error, :vault_not_allowed} for a vault outside the allowlist", %{} do
      user = insert_active_user()
      allowed = insert_vault(user_id: user.id)
      other = insert_vault(user_id: user.id)
      agent = insert_agent(user_id: user.id, allowed_vault_ids: [allowed.id])

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => other.id}
      assert {:error, :vault_not_allowed} = Launch.start_conversation(attrs)
    end

    test "returns {:error, :vault_not_allowed} for any vault when the allowlist is empty", %{} do
      user = insert_active_user()
      vault = insert_vault(user_id: user.id)
      agent = insert_agent(user_id: user.id, allowed_vault_ids: [])

      attrs = %{"agent_id" => agent.id, "user_id" => user.id, "vault_id" => vault.id}
      assert {:error, :vault_not_allowed} = Launch.start_conversation(attrs)
    end

    test "empty allowlist still permits starting with no vault at all", %{} do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id, allowed_vault_ids: [])

      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      attrs = %{"agent_id" => agent.id, "user_id" => user.id}
      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert is_nil(conv.vault_id)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # start_conversation/2 — per-launch environment override (#783)
  # ────────────────────────────────────────────────────────────────────────────

  describe "start_conversation/2 permission_policy override (#939)" do
    setup do
      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      user = insert_active_user()
      %{user: user}
    end

    defp launch(ctx, agent, policy) do
      attrs = %{"agent_id" => agent.id, "user_id" => ctx.user.id}
      attrs = if policy, do: Map.put(attrs, "permission_policy", policy), else: attrs
      Launch.start_conversation(attrs)
    end

    test "no override leaves the column nil, and the agent's policy stands alone", ctx do
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"Bash" => "auto_deny"})

      assert {:ok, conv} = launch(ctx, agent, nil)
      assert conv.permission_policy == nil

      effective =
        Managoat.ACP.Permissions.effective(agent.permission_policy, conv.permission_policy)

      assert Managoat.ACP.Permissions.verdict_for(effective, "Bash") == "auto_deny"
    end

    test "a launch may narrow the agent's policy", ctx do
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"default" => "auto_allow"})

      assert {:ok, conv} = launch(ctx, agent, %{"Bash" => "auto_deny"})
      assert conv.permission_policy == %{"Bash" => "auto_deny"}

      effective =
        Managoat.ACP.Permissions.effective(agent.permission_policy, conv.permission_policy)

      assert Managoat.ACP.Permissions.verdict_for(effective, "Bash") == "auto_deny"
      assert Managoat.ACP.Permissions.verdict_for(effective, "Read") == "auto_allow"
    end

    test "a launch may not widen it, and the error names the tool", ctx do
      # The no-escalation rule, and the reason there is no allowlist beside it:
      # a launch cannot reach a permission the agent did not already grant.
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"Bash" => "auto_deny"})

      assert {:error, {:permission_policy_widens, "Bash"}} =
               launch(ctx, agent, %{"Bash" => "auto_allow"})
    end

    test "a launch may not widen via the default either", ctx do
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"default" => "auto_deny"})

      assert {:error, {:permission_policy_widens, _}} =
               launch(ctx, agent, %{"default" => "auto_allow"})
    end

    test "widening is refused rather than silently clamped", ctx do
      # `effective/2` would clamp this to a safe value anyway. Refusing is about
      # the caller: someone who asked to loosen a policy and got a tighter one
      # without being told has no way to find out the ask was a mistake.
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"Bash" => "auto_deny"})

      assert {:error, _} = launch(ctx, agent, %{"Bash" => "auto_allow"})
      assert Repo.aggregate(Fountain.Conversations.Conversation, :count) == 0
    end

    test "a launch may narrow to ask, now that #940 gave it somewhere to ask", ctx do
      agent = insert_agent(user_id: ctx.user.id)

      assert {:ok, conv} = launch(ctx, agent, %{"Bash" => "ask"})
      assert conv.permission_policy == %{"Bash" => "ask"}
    end

    test "ask is a narrowing of auto_allow but a widening of auto_deny", ctx do
      lenient = insert_agent(user_id: ctx.user.id, permission_policy: %{"Bash" => "auto_allow"})
      strict = insert_agent(user_id: ctx.user.id, permission_policy: %{"Bash" => "auto_deny"})

      assert {:ok, _} = launch(ctx, lenient, %{"Bash" => "ask"})

      assert {:error, {:permission_policy_widens, "Bash"}} =
               launch(ctx, strict, %{"Bash" => "ask"})
    end

    test "ask_timeout is no longer a policy key (#2676)", ctx do
      agent = insert_agent(user_id: ctx.user.id, permission_policy: %{"execute" => "ask"})

      assert {:error, :permission_policy_invalid} =
               launch(ctx, agent, %{"execute" => "ask", "ask_timeout" => 600})
    end

    test "an unknown verdict is refused", ctx do
      agent = insert_agent(user_id: ctx.user.id)
      assert {:error, :permission_policy_invalid} = launch(ctx, agent, %{"Bash" => "banana"})
    end

    test "the launch override is readable back on the conversation", ctx do
      # A client that set a policy at launch has to be able to see what it got.
      # The response schema promises this field; a view that never emitted it
      # would make the spec a lie, which is how the agent side shipped in #939.
      agent = insert_agent(user_id: ctx.user.id)
      {:ok, conv} = launch(ctx, agent, %{"Bash" => "auto_deny"})

      rendered = FountainWeb.ConversationJSON.show(%{conversation: conv})
      assert rendered.data.permission_policy == %{"Bash" => "auto_deny"}
    end

    test "an empty override is the same as none", ctx do
      agent = insert_agent(user_id: ctx.user.id)
      assert {:ok, conv} = launch(ctx, agent, %{})
      assert conv.permission_policy == nil
    end
  end

  describe "start_conversation/2 environment_id override" do
    setup do
      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      user = insert_active_user()
      agent_env = insert_env(user_id: user.id)
      other_env = insert_env(user_id: user.id)
      agent = insert_agent(user_id: user.id, environment_id: agent_env.id)
      %{user: user, agent: agent, agent_env: agent_env, other_env: other_env}
    end

    test "pins the conversation and its sandbox to the named environment", ctx do
      attrs = %{
        "agent_id" => ctx.agent.id,
        "user_id" => ctx.user.id,
        "environment_id" => ctx.other_env.id
      }

      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.environment_id == ctx.other_env.id

      assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).environment_id ==
               ctx.other_env.id
    end

    test "nil and blank mean the agent's environment", ctx do
      for value <- [nil, ""] do
        attrs = %{
          "agent_id" => ctx.agent.id,
          "user_id" => ctx.user.id,
          "environment_id" => value
        }

        assert {:ok, conv} = Launch.start_conversation(attrs)
        assert is_nil(conv.environment_id)

        assert Conversations._unsafe_get_sandbox!(conv.sandbox_id).environment_id ==
                 ctx.agent_env.id
      end
    end

    test "a foreign environment reads as not found — same as an unknown id", ctx do
      stranger = insert_active_user()
      foreign = insert_env(user_id: stranger.id)

      for id <- [foreign.id, Ecto.UUID.generate()] do
        attrs = %{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id, "environment_id" => id}
        assert {:error, :environment_not_found} = Launch.start_conversation(attrs)
      end
    end

    test "a foreign environment is refused even when explicitly allowlisted", ctx do
      foreign = insert_env(user_id: insert_active_user().id)
      {:ok, agent} = Agents.update_agent(ctx.agent, %{allowed_environment_ids: [foreign.id]})

      attrs = %{"agent_id" => agent.id, "user_id" => ctx.user.id, "environment_id" => foreign.id}
      assert {:error, :environment_not_found} = Launch.start_conversation(attrs)
    end

    test "an unrestricted policy reaches an environment created after the agent", ctx do
      future = insert_env(user_id: ctx.user.id)
      assert ctx.agent.environment_access == "all_tenant_environments"

      attrs = %{
        "agent_id" => ctx.agent.id,
        "user_id" => ctx.user.id,
        "environment_id" => future.id
      }

      assert {:ok, conv} = Launch.start_conversation(attrs)
      assert conv.environment_id == future.id
    end

    test "allowed_environment_ids: a listed environment passes, an unlisted one is refused",
         ctx do
      third = insert_env(user_id: ctx.user.id)

      {:ok, agent} =
        Agents.update_agent(ctx.agent, %{allowed_environment_ids: [ctx.other_env.id]})

      ok = %{
        "agent_id" => agent.id,
        "user_id" => ctx.user.id,
        "environment_id" => ctx.other_env.id
      }

      assert {:ok, conv} = Launch.start_conversation(ok)
      assert conv.environment_id == ctx.other_env.id

      refused = %{"agent_id" => agent.id, "user_id" => ctx.user.id, "environment_id" => third.id}
      assert {:error, :environment_not_allowed} = Launch.start_conversation(refused)
    end

    test "an empty allowlist forbids every override but still permits the agent's own", ctx do
      {:ok, agent} = Agents.update_agent(ctx.agent, %{allowed_environment_ids: []})

      refused = %{
        "agent_id" => agent.id,
        "user_id" => ctx.user.id,
        "environment_id" => ctx.other_env.id
      }

      assert {:error, :environment_not_allowed} = Launch.start_conversation(refused)

      # Naming the agent's own environment is not an override — it is pinned
      # (a later change of the agent's environment does not move it), but it
      # needs no allowlist entry.
      own = %{
        "agent_id" => agent.id,
        "user_id" => ctx.user.id,
        "environment_id" => ctx.agent_env.id
      }

      assert {:ok, conv} = Launch.start_conversation(own)
      assert conv.environment_id == ctx.agent_env.id
    end

    test "the allowlist is checked before the fetch, so a foreign id is refused not probed",
         ctx do
      stranger = insert_active_user()
      foreign = insert_env(user_id: stranger.id)
      {:ok, agent} = Agents.update_agent(ctx.agent, %{allowed_environment_ids: []})

      attrs = %{"agent_id" => agent.id, "user_id" => ctx.user.id, "environment_id" => foreign.id}
      assert {:error, :environment_not_allowed} = Launch.start_conversation(attrs)
    end

    test "channel resume keys on the override: a different environment is a different binding",
         ctx do
      base = %{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id, "channel_id" => "chan-783"}

      assert {:ok, first, :created} =
               Launch.start_or_resume_conversation(
                 Map.put(base, "environment_id", ctx.other_env.id)
               )

      # Same channel, same environment: resumed.
      assert {:ok, again, :resumed} =
               Launch.start_or_resume_conversation(
                 Map.put(base, "environment_id", ctx.other_env.id)
               )

      assert again.id == first.id

      # Same channel, no override: a fresh conversation, not the pinned one.
      assert {:ok, plain, :created} = Launch.start_or_resume_conversation(base)
      refute plain.id == first.id
      assert is_nil(plain.environment_id)

      # And the plain one is now what a plain launch resumes.
      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(base)
      assert resumed.id == plain.id
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # start_or_resume_conversation/2 — the binding follows the machine (#779)
  # ────────────────────────────────────────────────────────────────────────────

  # A conversation bound to the #779 channel whose sandbox is in `status`.
  defp bound_conversation(ctx, sandbox_status) do
    sandbox = insert_sandbox(user_id: ctx.user.id, status: sandbox_status)

    insert_conversation(
      user_id: ctx.user.id,
      agent: ctx.agent,
      sandbox: sandbox,
      status: "idle",
      channel_id: "chan-779"
    )
  end

  describe "start_or_resume_conversation/2 sandbox liveness" do
    setup do
      stub_server_start(fn _sup, _spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      user = insert_active_user()
      agent = insert_agent(user_id: user.id)

      %{
        user: user,
        agent: agent,
        attrs: %{"agent_id" => agent.id, "user_id" => user.id, "channel_id" => "chan-779"}
      }
    end

    for status <- ~w(terminated failed) do
      test "a conversation whose sandbox is #{status} is not resumed", ctx do
        # The 24 hour ceiling destroys the sandbox and leaves the conversation
        # `idle`. Resuming it wakes onto a fresh machine with the workspace
        # gone, in a transcript that reads as continuous — the channel is
        # better served by a new conversation on a working machine.
        dead = bound_conversation(ctx, unquote(status))

        assert {:ok, fresh, :created} = Launch.start_or_resume_conversation(ctx.attrs)
        refute fresh.id == dead.id

        # And the new one is what the channel resumes from here.
        assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(ctx.attrs)
        assert resumed.id == fresh.id
      end
    end

    test "a suspended sandbox is parked, not gone, and still resumes", ctx do
      parked = bound_conversation(ctx, "suspended")

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(ctx.attrs)
      assert resumed.id == parked.id
    end

    test "a ready sandbox resumes, as before", ctx do
      live = bound_conversation(ctx, "ready")

      assert {:ok, resumed, :resumed} = Launch.start_or_resume_conversation(ctx.attrs)
      assert resumed.id == live.id
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # _unsafe_list_turns/1 — image preloads
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_list_turns/1 image preloads" do
    test "preloads images association on each turn" do
      user = insert_active_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      %Fountain.Conversations.TurnImage{}
      |> Fountain.Conversations.TurnImage.changeset(%{
        turn_id: turn.id,
        position: 0,
        media_type: "image/png",
        data: <<1, 2, 3>>
      })
      |> Ecto.Changeset.put_change(:inserted_at, DateTime.utc_now() |> DateTime.truncate(:second))
      |> Repo.insert!()

      [loaded_turn] = Conversations._unsafe_list_turns(conv.id)
      assert length(loaded_turn.images) == 1
      [img] = loaded_turn.images
      assert img.media_type == "image/png"
      assert img.data == <<1, 2, 3>>
    end

    test "returns turns with empty images list when no images have been inserted" do
      user = insert_active_user()
      conv = insert_conversation(user_id: user.id)
      _turn = insert_turn(conv)

      [loaded_turn] = Conversations._unsafe_list_turns(conv.id)
      assert loaded_turn.images == []
    end

    test "orders images by position ascending when multiple images exist" do
      user = insert_active_user()
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv)

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      for {mt, data, pos} <- [
            {"image/png", <<10>>, 0},
            {"image/jpeg", <<20>>, 1},
            {"image/gif", <<30>>, 2}
          ] do
        %Fountain.Conversations.TurnImage{}
        |> Fountain.Conversations.TurnImage.changeset(%{
          turn_id: turn.id,
          position: pos,
          media_type: mt,
          data: data
        })
        |> Ecto.Changeset.put_change(:inserted_at, now)
        |> Repo.insert!()
      end

      [loaded_turn] = Conversations._unsafe_list_turns(conv.id)
      positions = Enum.map(loaded_turn.images, & &1.position)
      assert positions == Enum.sort(positions)
    end
  end

  describe "insert_sandbox/1 factory — no explicit user_id" do
    test "creates a new user when no user_id is provided" do
      # Triggers the insert_active_user().id fallback in insert_sandbox (factory.ex line 129)
      sandbox = insert_sandbox()
      assert is_binary(sandbox.user_id)
    end
  end

  describe "insert_conversation/1 factory — agent without explicit user_id" do
    test "derives user_id from agent when no user_id is provided" do
      user = insert_active_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(agent: agent)
      assert conv.user_id == user.id
      assert conv.agent_id == agent.id
    end

    test "creates a new user when neither user_id nor agent is provided" do
      # Triggers the insert_active_user().id fallback (factory.ex line 147)
      conv = insert_conversation()
      assert is_binary(conv.user_id)
      assert is_nil(conv.agent_id)
    end
  end

  describe "factory to_atom_map — safe_to_existing_atom fallback" do
    test "to_atom_map with an unknown string key does not crash and returns the string as fallback" do
      # \"xyzquuxfoo_novel_key_never_an_atom\" is not an existing Elixir atom,
      # so safe_to_existing_atom triggers its rescue clause and returns the string key.
      result =
        Fountain.Factory.to_atom_map(%{
          "machine_name" => "test-sprite",
          "xyzquuxfoo_novel_key_never_an_atom" => "ignored_value"
        })

      assert Map.get(result, :machine_name) == "test-sprite"
      # The unknown key is preserved as a string (fallback)
      assert Map.get(result, "xyzquuxfoo_novel_key_never_an_atom") == "ignored_value"
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
