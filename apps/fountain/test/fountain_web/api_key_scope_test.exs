defmodule FountainWeb.ApiKeyScopeTest do
  @moduledoc """
  Privilege-escalation cover for the sandbox callback token.

  Every conversation hands its sprite a tenant API key. Before scoping, that key
  was unrestricted, so code running in a sandbox could mint a second key — one
  the conversation-scoped revoke at teardown knows nothing about — and hold
  standing tenant access long after the conversation ended.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Accounts
  alias Fountain.Accounts.ApiKey

  describe "sprite-scoped keys cannot manage API keys" do
    setup do
      user = insert_verified_user()
      {_rec, sprite_key} = insert_sprite_api_key(user)
      {:ok, user: user, sprite_key: sprite_key}
    end

    test "POST /api/auth/api-keys is forbidden — the escalation path", %{
      conn: conn,
      sprite_key: key
    } do
      conn =
        conn
        |> authed_with_key(key)
        |> post_json("/api/auth/api-keys", %{"name" => "escalated"})

      body = json_response(conn, 403)
      assert body["error"] == "insufficient_scope"
      assert body["reason"] == "insufficient_scope"
      assert body["required_scope"] == "full"
      assert is_binary(body["message"])
    end

    test "no key is created when the attempt is refused", %{
      conn: conn,
      user: user,
      sprite_key: key
    } do
      before = length(Accounts.list_api_keys(user.id))

      conn
      |> authed_with_key(key)
      |> post_json("/api/auth/api-keys", %{"name" => "escalated"})
      |> json_response(403)

      assert length(Accounts.list_api_keys(user.id)) == before
    end

    test "GET /api/auth/api-keys is forbidden", %{conn: conn, sprite_key: key} do
      conn = conn |> authed_with_key(key) |> get("/api/auth/api-keys")
      assert json_response(conn, 403)["reason"] == "insufficient_scope"
    end

    test "DELETE /api/auth/api-keys/:id is forbidden", %{conn: conn, user: user, sprite_key: key} do
      {victim, _raw} = insert_api_key(user, "victim")

      conn = conn |> authed_with_key(key) |> delete("/api/auth/api-keys/#{victim.id}")
      assert json_response(conn, 403)["reason"] == "insufficient_scope"

      # And it is genuinely still usable, not merely un-listed.
      assert {:ok, _user, _key} =
               Accounts.authenticate_api_key(elem(insert_api_key(user, "probe"), 1))

      refute Accounts.list_api_keys(user.id) |> Enum.find(&(&1.id == victim.id)) |> is_nil()
    end
  end

  describe "sprite-scoped keys cannot write what a sandbox is built from" do
    # A sandbox's own token rewriting an agent, environment or vault changes
    # what the next launch runs: an agent pointed at the self-hosted runner
    # with any `runtime_command` is a shell on the owner's machine (ADR 0039,
    # amended 2026-10-14).
    setup do
      user = insert_verified_user()
      {_rec, sprite_key} = insert_sprite_api_key(user)
      env = insert_env(user_id: user.id)
      env_secret = insert_secret(env)
      vault = insert_vault(user_id: user.id)
      vault_secret = insert_vault_secret(vault)
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(agent: agent)

      {:ok,
       user: user,
       sprite_key: sprite_key,
       env: env,
       env_secret: env_secret,
       vault: vault,
       vault_secret: vault_secret,
       agent: agent,
       conv: conv}
    end

    test "every config write is refused with insufficient_scope", ctx do
      %{env: env, vault: vault, agent: agent, conv: conv} = ctx

      escalated_agent = %{
        "name" => "escalated",
        "runtime" => "acp",
        "runtime_command" => "sh -c id",
        "sandbox_provider" => "e2b"
      }

      writes = [
        {:post, "/api/agents", escalated_agent},
        {:patch, "/api/agents/#{agent.id}", escalated_agent},
        {:put, "/api/agents/#{agent.id}", escalated_agent},
        {:delete, "/api/agents/#{agent.id}", nil},
        {:put, "/api/agents/#{agent.id}/avatar", %{}},
        {:delete, "/api/agents/#{agent.id}/avatar", nil},
        {:post, "/api/environments", %{"name" => "from-sprite"}},
        {:patch, "/api/environments/#{env.id}", %{"setup_script" => "id"}},
        {:put, "/api/environments/#{env.id}", %{"setup_script" => "id"}},
        {:delete, "/api/environments/#{env.id}", nil},
        {:post, "/api/environments/#{env.id}/secrets", %{"key" => "K", "value" => "v"}},
        {:delete, "/api/environments/#{env.id}/secrets/#{ctx.env_secret.key}", nil},
        {:post, "/api/vaults", %{"name" => "from-sprite"}},
        {:patch, "/api/vaults/#{vault.id}", %{"name" => "renamed"}},
        {:put, "/api/vaults/#{vault.id}", %{"name" => "renamed"}},
        {:delete, "/api/vaults/#{vault.id}", nil},
        {:post, "/api/vaults/#{vault.id}/copy", %{"name" => "copy"}},
        {:post, "/api/vaults/#{vault.id}/secrets", %{"key" => "K", "value" => "v"}},
        {:patch, "/api/vaults/#{vault.id}/secrets/#{ctx.vault_secret.key}", %{"value" => "v"}},
        {:delete, "/api/vaults/#{vault.id}/secrets/#{ctx.vault_secret.key}", nil},
        {:post, "/api/apply", %{"resources" => []}}
      ]

      for {verb, path, body} <- writes do
        conn = request(ctx.conn |> authed_with_key(ctx.sprite_key), verb, path, body)
        body = json_response(conn, 403)

        assert body["reason"] == "insufficient_scope",
               "#{verb} #{path} should refuse a sandbox token"

        assert body["required_scope"] == "full"
      end
    end

    test "a refused write changes nothing", ctx do
      %{user: user, agent: agent, env: env} = ctx

      ctx.conn
      |> authed_with_key(ctx.sprite_key)
      |> patch_json("/api/agents/#{agent.id}", %{"sandbox_provider" => "e2b"})
      |> json_response(403)

      ctx.conn
      |> authed_with_key(ctx.sprite_key)
      |> patch_json("/api/environments/#{env.id}", %{"setup_script" => "id"})
      |> json_response(403)

      assert Fountain.Agents.get_agent(agent.id, user.id).sandbox_provider ==
               agent.sandbox_provider

      assert Fountain.Environments.get_environment(env.id, user.id).setup_script ==
               env.setup_script
    end

    test "a full-scope key still writes them", %{conn: conn, user: user, agent: agent} do
      {_rec, full} = insert_api_key(user)

      assert conn
             |> authed_with_key(full)
             |> post_json("/api/environments", %{"name" => "from-owner"})
             |> json_response(201)

      assert conn
             |> authed_with_key(full)
             |> patch_json("/api/agents/#{agent.id}", %{"description" => "edited"})
             |> json_response(200)
    end

    defp request(conn, :post, path, body), do: post_json(conn, path, body)
    defp request(conn, :put, path, body), do: put_json(conn, path, body)
    defp request(conn, :patch, path, body), do: patch_json(conn, path, body)
    defp request(conn, :delete, path, _body), do: delete(conn, path)
  end

  describe "sprite-scoped keys keep the access they legitimately need" do
    # Spawning sub-agents from inside a sprite is a supported workflow
    # (the bundled `managoat` skill), so scoping must not reduce these tokens to read-only.
    setup do
      user = insert_verified_user()
      {_rec, sprite_key} = insert_sprite_api_key(user)
      {:ok, user: user, sprite_key: sprite_key}
    end

    test "can read /api/auth/me", %{conn: conn, sprite_key: key} do
      conn = conn |> authed_with_key(key) |> get("/api/auth/me")
      assert json_response(conn, 200)
    end

    test "can read agents, environments, vaults and their secrets' metadata", %{
      conn: conn,
      user: user,
      sprite_key: key
    } do
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      agent = insert_agent(user_id: user.id)

      for path <- [
            "/api/agents",
            "/api/agents/#{agent.id}",
            "/api/agents/#{agent.id}/versions",
            "/api/environments",
            "/api/environments/#{env.id}",
            "/api/environments/#{env.id}/secrets",
            "/api/vaults",
            "/api/vaults/#{vault.id}",
            "/api/vaults/#{vault.id}/secrets"
          ] do
        assert conn |> authed_with_key(key) |> get(path) |> json_response(200),
               "GET #{path} should stay open to a sandbox token"
      end
    end

    test "can spawn a sub-agent conversation", %{conn: conn, user: user} do
      {record, key} = insert_sprite_api_key(user)
      own = insert_conversation(user_id: user.id, callback_api_key_id: record.id)
      agent = insert_agent(user_id: user.id)
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      conn =
        conn
        |> authed_with_key(key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 201)["data"]["parent_conversation_id"] == own.id
    end
  end

  describe "full-scoped keys are unaffected" do
    test "can still create, list and revoke", %{conn: conn} do
      user = insert_verified_user()
      {_rec, key} = insert_api_key(user)

      created =
        conn |> authed_with_key(key) |> post_json("/api/auth/api-keys", %{"name" => "ci"})

      assert json_response(created, 201)
      assert conn |> authed_with_key(key) |> get("/api/auth/api-keys") |> json_response(200)
    end

    test "keys default to full scope so existing keys keep working" do
      user = insert_verified_user()
      {record, _raw} = insert_api_key(user)

      assert record.scopes == ["full"]
      assert ApiKey.may_manage_keys?(record)
    end
  end

  describe "expiry" do
    test "an expired key is rejected with a distinguishable reason", %{conn: conn} do
      user = insert_verified_user()

      {_rec, key} =
        insert_api_key(user, "stale",
          expires_at:
            DateTime.utc_now() |> DateTime.add(-60, :second) |> DateTime.truncate(:second)
        )

      conn = conn |> authed_with_key(key) |> get("/api/agents")

      body = json_response(conn, 401)
      assert body["reason"] == "api_key_expired"
    end

    test "a key expiring in the future still works", %{conn: conn} do
      user = insert_verified_user()

      {_rec, key} =
        insert_api_key(user, "fresh",
          expires_at:
            DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)
        )

      assert conn |> authed_with_key(key) |> get("/api/agents") |> json_response(200)
    end

    test "a key with no expiry never expires" do
      user = insert_verified_user()
      {record, _raw} = insert_api_key(user)

      assert record.expires_at == nil
      refute ApiKey.expired?(record)
    end

    test "revocation still takes precedence over expiry", %{conn: conn} do
      user = insert_verified_user()
      {record, key} = insert_api_key(user, "revoked")
      {:ok, _} = Accounts.revoke_api_key(user.id, record.id)

      conn = conn |> authed_with_key(key) |> get("/api/agents")
      assert json_response(conn, 401)["reason"] == "api_key_revoked"
    end
  end

  describe "sprite callback tokens as actually minted" do
    alias Fountain.Conversations.ConversationServer

    test "carry the sprite scope, not full" do
      assert Keyword.fetch!(ConversationServer.callback_api_key_opts(), :scopes) == ["sprite"]
    end

    test "carry an expiry so a token orphaned by a hard crash does not live forever" do
      expires_at = Keyword.fetch!(ConversationServer.callback_api_key_opts(), :expires_at)

      assert DateTime.compare(expires_at, DateTime.utc_now()) == :gt
    end

    test "a key minted with those options cannot manage keys", %{conn: conn} do
      user = insert_verified_user()

      {:ok, {_rec, raw}} =
        Accounts.create_api_key(
          user.id,
          "sprite:test",
          ConversationServer.callback_api_key_opts()
        )

      conn =
        conn
        |> authed_with_key(raw)
        |> post_json("/api/auth/api-keys", %{"name" => "escalated"})

      assert json_response(conn, 403)["reason"] == "insufficient_scope"
    end

    test "the TTL is configurable" do
      original = Application.get_env(:fountain, :callback_key_ttl_seconds)

      on_exit(fn ->
        # put_env(nil) would leave the key present-but-nil, so the default in
        # callback_key_ttl_seconds/0 would stop applying and DateTime.add would
        # be handed nil.
        case original do
          nil -> Application.delete_env(:fountain, :callback_key_ttl_seconds)
          value -> Application.put_env(:fountain, :callback_key_ttl_seconds, value)
        end
      end)

      Application.put_env(:fountain, :callback_key_ttl_seconds, 60)
      expires_at = Keyword.fetch!(ConversationServer.callback_api_key_opts(), :expires_at)

      assert DateTime.diff(expires_at, DateTime.utc_now()) <= 61
    end
  end

  describe "ApiKey predicates" do
    test "may_manage_keys?/1" do
      assert ApiKey.may_manage_keys?(%ApiKey{scopes: ["full"]})
      refute ApiKey.may_manage_keys?(%ApiKey{scopes: ["sprite"]})
    end

    test "expired?/1 compares against now" do
      refute ApiKey.expired?(%ApiKey{expires_at: nil})
      refute ApiKey.expired?(%ApiKey{expires_at: DateTime.add(DateTime.utc_now(), 60)})
      assert ApiKey.expired?(%ApiKey{expires_at: DateTime.add(DateTime.utc_now(), -60)})
    end

    test "an unknown scope is rejected at the changeset" do
      user = insert_verified_user()

      assert {:error, cs} = Accounts.create_api_key(user.id, "bad", scopes: ["root"])
      assert Keyword.has_key?(cs.errors, :scopes)
    end
  end
end
