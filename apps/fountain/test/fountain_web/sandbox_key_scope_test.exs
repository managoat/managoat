defmodule FountainWeb.SandboxKeyScopeTest do
  @moduledoc """
  A sandbox's own key (`sprite` scope, `MANAGOAT_TOKEN`) reaches its own
  conversation tree and the read-only inputs to spawn, and nothing else
  (#2981, ADR 0096).

  Before, the key authenticated as the account on every tenant-scoped route:
  code in one sandbox could list every conversation, read every transcript
  and prompt, end or start any of them.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Termination
  alias FountainWeb.Plugs.SandboxKeyScope

  # A tree on one account:
  #
  #     parent
  #     ├── own        <- the key's conversation
  #     │   └── child
  #     │       └── grandchild
  #     └── sibling
  #
  #     unrelated      (no relation to any of them)
  setup do
    user = insert_verified_user()
    {key, raw} = insert_sprite_api_key(user)
    agent = insert_agent(user_id: user.id)

    parent = insert_conversation(user_id: user.id, agent: agent)

    own =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        parent_conversation_id: parent.id,
        callback_api_key_id: key.id
      )

    child = insert_conversation(user_id: user.id, agent: agent, parent_conversation_id: own.id)

    grandchild =
      insert_conversation(user_id: user.id, agent: agent, parent_conversation_id: child.id)

    sibling =
      insert_conversation(user_id: user.id, agent: agent, parent_conversation_id: parent.id)

    unrelated = insert_conversation(user_id: user.id, agent: agent)

    {:ok,
     user: user,
     key: key,
     raw: raw,
     agent: agent,
     parent: parent,
     own: own,
     child: child,
     grandchild: grandchild,
     sibling: sibling,
     unrelated: unrelated}
  end

  defp call(raw, method, path, body \\ "{}") do
    build_conn()
    |> authed_with_key(raw)
    |> put_req_header("content-type", "application/json")
    |> dispatch(@endpoint, method, path, body)
  end

  describe "inside the tree" do
    test "reads itself, its child and its grandchild", ctx do
      for conv <- [ctx.own, ctx.child, ctx.grandchild],
          path <- ["", "/turns", "/events", "/stream?wait=false"] do
        resp = call(ctx.raw, :get, "/api/conversations/#{conv.id}#{path}")
        assert resp.status == 200, "GET #{path} on #{conv.id}: #{resp.status} #{resp.resp_body}"
      end
    end

    test "terminates and deletes a descendant", ctx do
      stub(Termination, :terminate_conversation, fn _id, _opts -> :ok end)

      assert call(ctx.raw, :post, "/api/conversations/#{ctx.grandchild.id}/terminate").status ==
               204

      assert call(ctx.raw, :delete, "/api/conversations/#{ctx.grandchild.id}").status == 204
      assert is_nil(Conversations.get_conversation(ctx.grandchild.id, ctx.user.id))
    end

    test "a conversation it starts is its child, so the tree stays closed", ctx do
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      data =
        build_conn()
        |> authed_with_key(ctx.raw)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["parent_conversation_id"] == ctx.own.id
      assert call(ctx.raw, :get, "/api/conversations/#{data["id"]}").status == 200
    end

    test "a start naming another conversation as its parent is refused", ctx do
      body =
        build_conn()
        |> authed_with_key(ctx.raw)
        |> put_req_header("x-managoat-parent-conversation-id", ctx.sibling.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(404)

      assert body["error"] == "parent_conversation_not_found"
    end
  end

  describe "outside the tree" do
    test "the parent, a sibling and an unrelated conversation read as not found", ctx do
      for conv <- [ctx.parent, ctx.sibling, ctx.unrelated],
          {method, path} <- [
            {:get, ""},
            {:get, "/turns"},
            {:get, "/events"},
            {:get, "/stream?wait=false"},
            {:post, "/prompts"},
            {:post, "/interrupt"},
            {:post, "/wake"},
            {:post, "/terminate"},
            {:patch, "/labels"},
            {:delete, ""}
          ] do
        resp = call(ctx.raw, method, "/api/conversations/#{conv.id}#{path}")

        assert resp.status == 404,
               "#{method} #{path} on #{conv.id}: #{resp.status} #{resp.resp_body}"

        # The body of another account's conversation, so an id is not confirmed.
        assert Jason.decode!(resp.resp_body) == %{"error" => "not_found"}
      end
    end

    test "a refused delete leaves the conversation", ctx do
      assert call(ctx.raw, :delete, "/api/conversations/#{ctx.sibling.id}").status == 404
      assert Conversations.get_conversation(ctx.sibling.id, ctx.user.id)
    end

    test "a key no conversation names has no tree", ctx do
      {_key, stray} = insert_sprite_api_key(ctx.user)

      assert call(stray, :get, "/api/conversations/#{ctx.own.id}").status == 404
    end

    test "a full-scope key of the same account is unaffected", ctx do
      {_rec, full} = insert_api_key(ctx.user)

      for conv <- [ctx.parent, ctx.sibling, ctx.unrelated] do
        assert call(full, :get, "/api/conversations/#{conv.id}").status == 200
      end

      assert call(full, :get, "/api/search?q=x").status == 200
    end
  end

  describe "account-wide routes" do
    test "apply, search, the account stream and the listings are refused", ctx do
      for {method, path} <- [
            {:post, "/api/apply"},
            {:get, "/api/search?q=secret"},
            {:get, "/api/events/stream"},
            {:get, "/api/conversations"},
            {:get, "/api/conversations/#{ctx.own.id}/tree"},
            {:post, "/api/conversations/#{ctx.own.id}/read"},
            {:get, "/api/conversations/#{ctx.own.id}/egress"},
            {:get, "/api/sandboxes"},
            {:get, "/api/sandboxes/#{ctx.own.sandbox_id}"},
            {:get, "/api/audit"},
            {:get, "/api/connections"},
            {:get, "/api/account/inference-credentials"},
            {:post, "/api/oauth/revoke"},
            {:get, "/api/no-such-route"}
          ] do
        resp = call(ctx.raw, method, path)
        assert resp.status == 403, "#{method} #{path}: #{resp.status} #{resp.resp_body}"
        body = Jason.decode!(resp.resp_body)
        assert body["error"] == "insufficient_scope"
        assert body["reason"] == "insufficient_scope"
        assert body["required_scope"] == "full"
        assert body["message"] =~ "only its own conversation tree"
      end
    end

    test "the inputs to spawn stay readable", ctx do
      env = insert_env(user_id: ctx.user.id)
      vault = insert_vault(user_id: ctx.user.id)

      for path <- [
            "/api/auth/me",
            "/api/catalog",
            "/api/agents",
            "/api/agents/#{ctx.agent.id}",
            "/api/agents/#{ctx.agent.id}/versions",
            "/api/environments",
            "/api/environments/#{env.id}",
            "/api/environments/#{env.id}/secrets",
            "/api/vaults",
            "/api/vaults/#{vault.id}",
            "/api/vaults/#{vault.id}/secrets"
          ] do
        resp = call(ctx.raw, :get, path)
        assert resp.status == 200, "GET #{path}: #{resp.status} #{resp.resp_body}"
      end
    end

    test "vault and environment secret values are never in a response", ctx do
      vault = insert_vault(user_id: ctx.user.id)
      vault_secret = insert_vault_secret(vault, %{"value" => "vault-value-do-not-leak"})
      env = insert_env(user_id: ctx.user.id)
      insert_secret(env, %{"value" => "env-value-do-not-leak"})

      bodies =
        for path <- [
              "/api/vaults",
              "/api/vaults/#{vault.id}",
              "/api/vaults/#{vault.id}/secrets",
              "/api/environments/#{env.id}",
              "/api/environments/#{env.id}/secrets"
            ] do
          resp = call(ctx.raw, :get, path)
          assert resp.status == 200
          resp.resp_body
        end

      joined = Enum.join(bodies)
      # The names are there, the values are not.
      assert joined =~ vault_secret.key
      refute joined =~ "vault-value-do-not-leak"
      refute joined =~ "env-value-do-not-leak"
    end

    test "a refused write is on the audit trail as the sandbox's", ctx do
      call(ctx.raw, :post, "/api/apply", ~s({"resources": []}))

      assert Enum.any?(
               Fountain.Audit.list_recent_for_user(ctx.user.id, 100),
               &(&1.actor == "sprite" and &1.action == "POST /api/apply" and
                   &1.metadata["status"] == 403)
             )
    end
  end

  describe "deny by default" do
    # Every route the router serves through `:api`, with each parameter filled
    # in, and what the plug answers for it. The allowlist is the exact set
    # below: a route added later is refused to a sandbox key unless someone
    # changes both the plug and this list.
    @allowed [
      {"GET", "/api/auth/me"},
      {"GET", "/api/catalog"},
      {"GET", "/api/agents"},
      {"GET", "/api/agents/:id"},
      {"GET", "/api/agents/:id/avatar"},
      {"GET", "/api/agents/:id/versions"},
      {"GET", "/api/agents/:id/versions/:version"},
      {"GET", "/api/environments"},
      {"GET", "/api/environments/:id"},
      {"GET", "/api/environments/:environment_id/secrets"},
      {"GET", "/api/vaults"},
      {"GET", "/api/vaults/:id"},
      {"GET", "/api/vaults/:vault_id/secrets"},
      {"POST", "/api/conversations"},
      {"GET", "/api/conversations/:id"},
      {"DELETE", "/api/conversations/:id"},
      {"GET", "/api/conversations/:conversation_id/turns"},
      {"GET", "/api/conversations/:conversation_id/events"},
      {"GET", "/api/conversations/:conversation_id/stream"},
      {"GET", "/api/conversations/:conversation_id/turns/:turn_id/images/:position"},
      {"POST", "/api/conversations/:conversation_id/prompts"},
      {"POST", "/api/conversations/:conversation_id/interrupt"},
      {"POST", "/api/conversations/:conversation_id/wake"},
      {"POST", "/api/conversations/:conversation_id/terminate"},
      {"PATCH", "/api/conversations/:conversation_id/labels"}
    ]

    test "only the allowlisted routes pass, and every other route is refused" do
      passing =
        for route <- FountainWeb.Router.__routes__(),
            String.starts_with?(route.path, "/api/"),
            verb = route.verb |> Atom.to_string() |> String.upcase(),
            segments = route.path |> String.split("/", trim: true) |> Enum.map(&fill/1),
            SandboxKeyScope.route(verb, segments) != :deny,
            uniq: true,
            do: {verb, route.path}

      assert Enum.sort(passing) == Enum.sort(@allowed)
    end

    test "a route no one has written yet is refused" do
      assert SandboxKeyScope.route("GET", ["api", "brand-new"]) == :deny
      assert SandboxKeyScope.route("GET", ["api", "agents", "a", "brand-new"]) == :deny
      assert SandboxKeyScope.route("GET", ["api", "vaults", "v", "secrets", "K"]) == :deny
      assert SandboxKeyScope.route("GET", ["api", "conversations", "c", "brand-new"]) == :deny
      assert SandboxKeyScope.route("POST", ["api", "conversations", "c", "brand-new"]) == :deny
    end

    defp fill(":" <> _param), do: Ecto.UUID.generate()
    defp fill(segment), do: segment
  end
end
