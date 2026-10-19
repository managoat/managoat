defmodule FountainWeb.ConversationKeyScopeTest do
  @moduledoc """
  The key an `"auth": "conversation"` MCP server receives reads its own
  conversation and nothing else (#2934, ADR 0086).

  Until #2934 that server received the sandbox's own `sprite` key, which
  reads every transcript on the account through `/api/search` and
  `/api/events/stream`, and prompts, ends and starts its conversations.
  """

  use FountainWeb.ConnCase, async: true

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Accounts, Repo}
  alias Fountain.Accounts.ApiKey
  alias Fountain.Audit.Event
  alias FountainWeb.Plugs.ConversationKeyScope

  setup do
    user = insert_verified_user()
    {parent, _sprite_raw} = insert_sprite_api_key(user)
    agent = insert_agent(user_id: user.id)
    conv = insert_conversation(user_id: user.id, agent: agent)
    other = insert_conversation(user_id: user.id, agent: agent)
    {:ok, _} = Fountain.Conversations.update_conversation(conv, %{callback_api_key_id: parent.id})

    {:ok, {key, raw}} =
      Accounts.create_conversation_api_key(user.id, parent.id, conv.id,
        actor: "system:conversation_server"
      )

    {:ok, user: user, parent: parent, conv: conv, other: other, key: key, raw: raw, agent: agent}
  end

  describe "what the key reaches" do
    test "/api/auth/me names its conversation", %{conn: conn, raw: raw, conv: conv} do
      body = conn |> authed_with_key(raw) |> get("/api/auth/me") |> json_response(200)
      assert body["conversation_id"] == conv.id
    end

    test "its own conversation, its turns and its events", %{conn: conn, raw: raw, conv: conv} do
      for path <- ["", "/turns", "/events"] do
        conn = build_conn() |> authed_with_key(raw) |> get("/api/conversations/#{conv.id}#{path}")
        assert conn.status == 200, "GET #{path}: #{conn.status} #{conn.resp_body}"
      end

      _ = conn
    end

    test "nothing else on the account", %{conn: conn, raw: raw, conv: conv, other: other} = ctx do
      refused = [
        {:get, "/api/conversations/#{other.id}"},
        {:get, "/api/conversations/#{other.id}/events"},
        {:get, "/api/conversations"},
        {:get, "/api/conversations/#{conv.id}/tree"},
        {:get, "/api/search?q=secret"},
        {:get, "/api/events/stream"},
        {:get, "/api/agents"},
        {:get, "/api/agents/#{ctx.agent.id}"},
        {:get, "/api/environments"},
        {:get, "/api/vaults"},
        {:get, "/api/audit"},
        {:get, "/api/sandboxes"},
        {:get, "/api/auth/api-keys"},
        {:post, "/api/conversations"},
        {:post, "/api/conversations/#{conv.id}/prompts"},
        {:post, "/api/conversations/#{conv.id}/interrupt"},
        {:post, "/api/conversations/#{conv.id}/terminate"},
        {:patch, "/api/conversations/#{conv.id}/labels"},
        {:delete, "/api/conversations/#{conv.id}"},
        {:post, "/api/auth/api-keys"},
        {:get, "/api/no-such-route"}
      ]

      for {method, path} <- refused do
        resp =
          build_conn()
          |> authed_with_key(raw)
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, path, "{}")

        assert resp.status == 403, "#{method} #{path}: #{resp.status} #{resp.resp_body}"

        assert %{
                 "error" => "insufficient_scope",
                 "reason" => "insufficient_scope",
                 "required_scope" => "full",
                 "message" => "A conversation key reads only its own conversation"
               } = Jason.decode!(resp.resp_body)
      end

      _ = conn
    end

    test "the account's own keys are untouched by the plug", %{conn: conn, user: user} do
      {_rec, full} = insert_api_key(user)
      assert conn |> authed_with_key(full) |> get("/api/search?q=x") |> json_response(200)
    end

    test "a turn image of its own conversation passes the allowlist; another's does not",
         %{conv: conv, other: other} do
      assert ConversationKeyScope.allowed?(
               "GET",
               ["api", "conversations", conv.id, "turns", "t", "images", "0"],
               conv.id
             )

      refute ConversationKeyScope.allowed?(
               "GET",
               ["api", "conversations", other.id, "turns", "t", "images", "0"],
               conv.id
             )

      # A key with no conversation reads nothing but /api/auth/me.
      refute ConversationKeyScope.allowed?("GET", ["api", "conversations", conv.id], nil)
      assert ConversationKeyScope.allowed?("GET", ["api", "auth", "me"], nil)
    end
  end

  describe "its lifetime is its parent's" do
    test "it takes the parent's expiry", %{parent: parent, key: key} do
      assert key.expires_at == parent.expires_at
      assert key.parent_key_id == parent.id
      assert key.scopes == ["conversation"]
    end

    test "revoking the parent revokes it, audited",
         %{conn: conn, user: user, parent: parent} = ctx do
      {:ok, _} = Accounts.revoke_api_key(user.id, parent.id, actor: "system:conversation_server")

      assert Repo.get!(ApiKey, ctx.key.id).revoked_at
      body = conn |> authed_with_key(ctx.raw) |> get("/api/auth/me") |> json_response(401)
      assert body["reason"] == "api_key_revoked"

      assert [%Event{actor: "system:conversation_server"}] =
               Repo.all(
                 from e in Event,
                   where: e.action == "api_key.revoked" and e.resource_id == ^ctx.key.id
               )
    end

    test "an expiry set on the parent reaches it", %{user: user, parent: parent, key: key} do
      at = DateTime.utc_now() |> DateTime.add(600) |> DateTime.truncate(:second)

      :ok =
        Accounts.set_api_key_expiry(user.id, parent.id, at, actor: "system:conversation_server")

      assert Repo.get!(ApiKey, parent.id).expires_at == at
      assert Repo.get!(ApiKey, key.id).expires_at == at

      assert Repo.aggregate(
               from(e in Event,
                 where:
                   e.action == "api_key.expiry_changed" and e.resource_id in ^[parent.id, key.id]
               ),
               :count
             ) == 2
    end

    test "deleting its conversation deletes it", %{conv: conv, key: key} do
      Repo.delete!(Fountain.Conversations._unsafe_get_conversation!(conv.id))
      assert Repo.get(ApiKey, key.id) == nil
    end
  end

  describe "minting" do
    test "only from the account's own live sprite key", %{user: user, parent: parent, conv: conv} do
      {full, _raw} = insert_api_key(user)

      assert {:error, :parent_not_live} =
               Accounts.create_conversation_api_key(user.id, full.id, conv.id)

      stranger = insert_verified_user()

      assert {:error, :parent_not_live} =
               Accounts.create_conversation_api_key(stranger.id, parent.id, conv.id)

      {:ok, _} = Accounts.revoke_api_key(user.id, parent.id)

      assert {:error, :parent_not_live} =
               Accounts.create_conversation_api_key(user.id, parent.id, conv.id)
    end

    test "never through the general paths", %{user: user} do
      assert_raise ArgumentError, fn ->
        Accounts.create_api_key(user.id, "x", scopes: ["conversation"])
      end
    end

    test "the scope stands alone and names its binding", %{user: user, parent: parent, conv: conv} do
      base = %{user_id: user.id, name: "x", key_hash: "h", key_prefix: "p"}

      refute ApiKey.changeset(%ApiKey{}, Map.put(base, :scopes, ["conversation"])).valid?

      refute ApiKey.changeset(
               %ApiKey{},
               Map.merge(base, %{
                 scopes: ["conversation", "sprite"],
                 conversation_id: conv.id,
                 parent_key_id: parent.id
               })
             ).valid?

      refute ApiKey.changeset(
               %ApiKey{},
               Map.merge(base, %{scopes: ["sprite"], conversation_id: conv.id})
             ).valid?
    end
  end
end
