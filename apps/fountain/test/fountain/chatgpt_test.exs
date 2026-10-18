defmodule Fountain.ChatGPTTest do
  @moduledoc """
  ChatGPT subscriptions (ADR 0070): linking, the refresh and its keepalive,
  resolution for codex, the pre-turn token read and the sandbox's auth.json.
  Every call to auth.openai.com is a `Req.Test` stub (`config/test.exs`).

  `async: false`: Mimic stubs here run global.
  """
  use Fountain.DataCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Fountain.{Audit, ChatGPT, InferenceCredentials, Repo}
  alias Fountain.ChatGPT.Subscription
  alias Fountain.Conversations.{CodexChatGPT, Egress}
  alias Fountain.InferenceCredentials.Source

  @auth_claim "https://api.openai.com/auth"

  setup do
    # Every test may end a sign-in at OpenAI; none may exchange tokens
    # unless it says so.
    stub_auth(fn _conn, _body -> flunk("unexpected token exchange") end)
    {:ok, user: insert_verified_user()}
  end

  describe "connect and disconnect" do
    test "a user's link stores encrypted tokens and the claims, and is audited", %{user: user} do
      assert {:ok, sub} =
               ChatGPT.connect(user.id, tokens(), method: "device_code", actor: "ui")

      assert sub.user_id == user.id
      assert sub.account_id == "acct_1"
      assert sub.plan_type == "plus"
      assert sub.status == "active"
      assert %DateTime{} = sub.expires_at

      assert [event] = chatgpt_events(user)
      assert event.action == "chatgpt_subscription.connected"
      assert event.actor == "ui"
      assert event.metadata == %{"method" => "device_code", "plan_type" => "plus"}
    end

    test "a relink replaces the tokens on the same row", %{user: user} do
      {:ok, first} = ChatGPT.connect(user.id, tokens())
      {:ok, second} = ChatGPT.connect(user.id, tokens(account_id: "acct_2"))

      assert second.id == first.id
      assert second.account_id == "acct_2"
      assert Repo.aggregate(Subscription, :count) == 1
    end

    test "each owner reaches only its own row", %{user: user} do
      other = insert_verified_user()
      {:ok, _} = ChatGPT.connect(user.id, tokens())

      assert ChatGPT.get(other.id) == nil
      :ok = ChatGPT.disconnect(other.id)
      assert ChatGPT.active?(user.id)
    end

    test "a pasted auth.json must be a ChatGPT sign-in with a refresh token", %{user: user} do
      owner = user.id
      assert {:ok, _} = ChatGPT.connect_auth_json(owner, auth_json())

      assert {:error, :not_a_chatgpt_login} =
               ChatGPT.connect_auth_json(owner, auth_json(auth_mode: "apikey"))

      assert {:error, :no_refresh_token} =
               ChatGPT.connect_auth_json(owner, auth_json(refresh_token: ""))

      assert {:error, :invalid_auth_json} = ChatGPT.connect_auth_json(owner, "{")

      assert {:error, :invalid_id_token} =
               ChatGPT.connect(owner, %{tokens() | id_token: "not-a-jwt"})
    end

    test "disconnect deletes the row and audits only a removal", %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      :ok = ChatGPT.disconnect(user.id, actor: "ui")
      :ok = ChatGPT.disconnect(user.id, actor: "ui")

      assert ChatGPT.get(user.id) == nil

      assert [
               "chatgpt_subscription.connected",
               "chatgpt_subscription.disconnected",
               "chatgpt_subscription.revoked_at_openai"
             ] == user |> chatgpt_events() |> Enum.map(& &1.action) |> Enum.sort()
    end

    test "deleting the account deletes its subscription", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      Repo.delete!(user)
      refute Repo.get(Subscription, sub.id)
    end
  end

  describe "ending the sign-in at OpenAI" do
    test "disconnect revokes the refresh token after the delete commits", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      :ok = ChatGPT.disconnect(user.id, actor: "ui", request_ip: "203.0.113.9")

      assert_received {:revoke, body, in_transaction?}
      refute in_transaction?, "auth.openai.com was called inside a transaction"

      assert body == %{
               "token" => "rt_1",
               "token_type_hint" => "refresh_token",
               "client_id" => "app_EMoamEEZ73f0CkXaXp7hrann"
             }

      assert %{actor: "ui", request_ip: "203.0.113.9", resource_id: id, metadata: metadata} =
               event(user, "chatgpt_subscription.revoked_at_openai")

      assert id == sub.id
      assert metadata["trigger"] == "disconnected"
    end

    test "a refused revocation keeps the disconnect, and is logged without the token and audited",
         %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      stub_auth(fn _conn, _body -> flunk("unexpected token exchange") end, 401)

      log = capture_log(fn -> assert :ok = ChatGPT.disconnect(user.id) end)

      assert ChatGPT.get(user.id) == nil
      assert log =~ "ending the sign-in at OpenAI failed (401 invalid_refresh_token)"
      refute log =~ "rt_1"

      assert %{metadata: %{"trigger" => "disconnected", "error" => "401 invalid_refresh_token"}} =
               event(user, "chatgpt_subscription.not_revoked_at_openai")

      assert event(user, "chatgpt_subscription.disconnected")
    end

    test "a revocation that cannot reach OpenAI keeps the disconnect", %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      Req.Test.stub(Fountain.ChatGPT.OAuth, &Req.Test.transport_error(&1, :econnrefused))

      capture_log(fn -> assert :ok = ChatGPT.disconnect(user.id) end)

      assert ChatGPT.get(user.id) == nil
      assert event(user, "chatgpt_subscription.not_revoked_at_openai")
    end

    test "a relink revokes the refresh token it replaced, and only a different one",
         %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      refute_received {:revoke, _, _}

      {:ok, _} = ChatGPT.connect(user.id, tokens(refresh_token: "rt_new"))
      assert_received {:revoke, %{"token" => "rt_1"}, false}

      assert %{metadata: %{"trigger" => "replaced"}} =
               event(user, "chatgpt_subscription.revoked_at_openai")

      assert {:ok, _} = ChatGPT.token_for(user.id, "acct_1")
    end

    test "a device-code sign-in that cannot be stored is revoked; a pasted one is not",
         %{user: user} do
      bad = %{tokens(refresh_token: "rt_device") | id_token: "not-a-jwt"}

      assert {:error, :invalid_id_token} = ChatGPT.connect(user.id, bad, method: "device_code")
      assert_received {:revoke, %{"token" => "rt_device"}, false}

      assert %{resource_id: nil, metadata: %{"trigger" => "discarded"}} =
               event(user, "chatgpt_subscription.revoked_at_openai")

      assert {:error, :invalid_id_token} =
               ChatGPT.connect(user.id, %{bad | refresh_token: "rt_pasted"}, method: "auth_json")

      refute_received {:revoke, _, _}
    end

    test "a subscription OpenAI already refused is not revoked again", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      sub |> Ecto.Changeset.change(status: "revoked") |> Repo.update!()

      :ok = ChatGPT.disconnect(user.id)

      refute_received {:revoke, _, _}
      assert event(user, "chatgpt_subscription.disconnected")
    end

    test "account deletion revokes the sign-in after the account is gone", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      {:ok, _} = Fountain.Accounts.Deletion.delete_user(user, actor: "admin:1")

      refute Repo.get(Subscription, sub.id)
      assert_received {:revoke, %{"token" => "rt_1"}, false}

      assert [%{user_id: nil, actor: "admin:1", metadata: metadata}] =
               Repo.all(
                 from e in Fountain.Audit.Event,
                   where: e.action == "chatgpt_subscription.revoked_at_openai"
               )

      assert metadata["user_id"] == user.id
      assert metadata["trigger"] == "account_deleted"
    end
  end

  describe "refresh/1" do
    test "rotates both tokens and stamps the row", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      sub = age(sub, days: 7)

      stub_auth(fn conn, body ->
        assert body["grant_type"] == "refresh_token"
        assert body["refresh_token"] == "rt_1"
        token_response(conn, access_token("at_2"), "rt_2")
      end)

      assert {:ok, fresh} = ChatGPT.refresh(sub)
      assert DateTime.compare(fresh.last_refreshed_at, sub.last_refreshed_at) == :gt
      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_2"

      # The rotated refresh token is the one the next refresh spends.
      stub_auth(fn conn, body ->
        assert body["refresh_token"] == "rt_2"
        token_response(conn, access_token("at_3"), "rt_3")
      end)

      assert {:ok, _} = ChatGPT.refresh(age(fresh, days: 7))
    end

    test "a terminal refusal revokes the subscription and is audited", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())

      stub_auth(fn conn, _body ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(401, ~s({"error":{"code":"refresh_token_reused"}}))
      end)

      assert {:error, :revoked} = ChatGPT.refresh(sub)

      assert %{status: "revoked", revoked_reason: "refresh_token_reused"} =
               Repo.get(Subscription, sub.id)

      refute ChatGPT.active?(user.id)

      assert "chatgpt_subscription.revoked" in Enum.map(chatgpt_events(user), & &1.action)
    end

    test "a transient failure keeps the row as it was", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      stub_auth(fn conn, _body -> Plug.Conn.send_resp(conn, 503, "upstream down") end)

      assert {:error, :refresh_failed} = ChatGPT.refresh(sub)
      assert Repo.get(Subscription, sub.id).access_token_ciphertext == sub.access_token_ciphertext
    end

    test "a row someone refreshed since it was read is not refreshed again", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      stale = %{sub | last_refreshed_at: DateTime.add(sub.last_refreshed_at, -60)}
      stub_auth(fn _conn, _body -> flunk("refreshed twice") end)

      assert {:ok, _} = ChatGPT.refresh(stale)
    end

    # #2661: OpenAI has rotated the refresh token by the time the write runs,
    # so a failed write must not lose the new one.
    test "a write that fails after a successful refresh is retried and keeps the rotated token",
         %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      fail_token_writes(1)
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)

      log = capture_log(fn -> assert {:ok, _} = ChatGPT.refresh(age(sub, days: 7)) end)
      assert log =~ "storing the refreshed tokens failed"

      stored = Repo.get(Subscription, sub.id)
      assert stored.refresh_lease_until == nil
      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_2"

      stub_auth(fn conn, body ->
        assert body["refresh_token"] == "rt_2"
        token_response(conn, access_token("at_3"), "rt_3")
      end)

      assert {:ok, _} = ChatGPT.refresh(age(stored, days: 7))
    end

    test "a write that keeps failing is logged as an error, and no HTTP call ran in a transaction",
         %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      fail_token_writes(100)

      stub_auth(fn conn, _body ->
        refute Repo.in_transaction?(), "auth.openai.com was called inside a transaction"
        token_response(conn, access_token("at_2"), "rt_2")
      end)

      log =
        capture_log(fn -> assert {:error, :store_failed} = ChatGPT.refresh(age(sub, days: 7)) end)

      assert log =~ "rotated refresh token could not be stored"
      refute log =~ "rt_2"
    end

    test "two concurrent refreshes spend the refresh token once", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      sub = age(sub, days: 7)
      test = self()

      stub_auth(fn conn, body ->
        send(test, {:exchanging, self(), body["refresh_token"]})
        assert_receive :answer, 5_000
        token_response(conn, access_token("at_2"), "rt_2")
      end)

      first = Task.async(fn -> ChatGPT.refresh(sub) end)
      assert_receive {:exchanging, exchanger, "rt_1"}, 5_000

      # While the first is waiting on auth.openai.com, the second finds the
      # row leased and does not call out.
      second = Task.async(fn -> ChatGPT.refresh(sub) end)
      assert {:error, :locked} = Task.await(second)

      send(exchanger, :answer)
      assert {:ok, fresh} = Task.await(first)
      refute_received {:exchanging, _, _}

      assert fresh.refresh_lease_until == nil
      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_2"

      # And the second, retried with what it read before, sees the refresh.
      stub_auth(fn _conn, _body -> flunk("refreshed twice") end)
      assert {:ok, _} = ChatGPT.refresh(sub)
    end

    test "a relink during a refresh wins, and the old chain's tokens are dropped", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      sub = age(sub, days: 7)
      test = self()

      stub_auth(fn conn, _body ->
        send(test, {:exchanging, self()})
        assert_receive :answer, 5_000
        token_response(conn, access_token("at_old_chain"), "rt_old_chain")
      end)

      refresh = Task.async(fn -> ChatGPT.refresh(sub) end)
      assert_receive {:exchanging, exchanger}, 5_000

      # Linking does not wait on the exchange.
      assert {:ok, _} =
               ChatGPT.connect(
                 user.id,
                 tokens(access_token: access_token("at_relinked"))
               )

      send(exchanger, :answer)
      capture_log(fn -> assert {:error, :superseded} = Task.await(refresh) end)

      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_relinked"

      # The old chain's rotated refresh token, which nothing holds, is ended.
      assert_received {:revoke, %{"token" => "rt_old_chain"}, false}

      assert %{actor: "system:chatgpt_refresh", metadata: %{"trigger" => "discarded"}} =
               event(user, "chatgpt_subscription.revoked_at_openai")
    end

    test "a lease left by a process that died lapses", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      sub = age(sub, days: 7)
      lease(sub, DateTime.add(DateTime.utc_now(), 30))
      stub_auth(fn _conn, _body -> flunk("the row is leased") end)

      assert {:error, :locked} = ChatGPT.refresh(sub)

      lease(sub, DateTime.add(DateTime.utc_now(), -1))
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)

      assert {:ok, _} = ChatGPT.refresh(sub)
    end

    test "a transient failure frees the lease at once", %{user: user} do
      {:ok, sub} = ChatGPT.connect(user.id, tokens())
      stub_auth(fn conn, _body -> Plug.Conn.send_resp(conn, 503, "upstream down") end)

      capture_log(fn -> assert {:error, :refresh_failed} = ChatGPT.refresh(age(sub, days: 7)) end)
      assert Repo.get(Subscription, sub.id).refresh_lease_until == nil
    end
  end

  describe "the keepalive" do
    test "refreshes only active subscriptions idle for more than six days", %{user: user} do
      other = insert_verified_user()
      {:ok, due} = ChatGPT.connect(user.id, tokens())
      {:ok, recent} = ChatGPT.connect(other.id, tokens(account_id: "acct_2"))
      age(due, days: 7)
      age(recent, days: 5)

      stub_auth(fn conn, _body -> token_response(conn, access_token("at_new"), "rt_new") end)

      assert :ok = perform_job(Fountain.Workers.ChatGPTKeepalive, %{})

      assert DateTime.diff(DateTime.utc_now(), Repo.get(Subscription, due.id).last_refreshed_at) <
               60

      assert DateTime.diff(
               DateTime.utc_now(),
               Repo.get(Subscription, recent.id).last_refreshed_at
             ) > 86_400
    end
  end

  describe "token_for/2, before a turn" do
    test "reads the stored token without calling OpenAI", %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)

      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_1"
    end

    test "refreshes first when the stored token is about to expire", %{user: user} do
      {:ok, _} =
        ChatGPT.connect(user.id, tokens(access_token: access_token("at_1", 120)))

      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)

      assert {:ok, token} = ChatGPT.token_for(user.id, "acct_1")
      assert jti(token) == "at_2"
    end

    test "a subscription that is gone or on another account needs reconnecting", %{user: user} do
      {:ok, _} = ChatGPT.connect(user.id, tokens())

      assert {:error, :chatgpt_reconnect_required} =
               ChatGPT.token_for(user.id, "acct_other")

      ChatGPT.disconnect(user.id)

      assert {:error, :chatgpt_reconnect_required} =
               ChatGPT.token_for(user.id, "acct_1")
    end
  end

  describe "resolution for codex" do
    test "the user's own subscription wins over the user's API key", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(user.id, tokens())

      assert {:ok, source, creds} = resolve(user)
      assert %Source{scope: :grant, kind: :codex_chatgpt_access_token} = source
      assert source.identity == "chatgpt:" <> user.id
      assert source.revision == "acct_1"
      assert jti(creds.codex_chatgpt_access_token) == "at_1"
      refute Map.has_key?(creds, :openai_api_key)
    end

    # ADR 0075: the deployment pays for no inference.
    test "with no subscription or key of its own, nothing serves", %{user: user} do
      assert {:ok, %Source{scope: :missing}, creds} = resolve(user)
      refute Map.has_key?(creds, :codex_chatgpt_access_token)
    end

    test "the table holds no subscription without a user" do
      assert_raise Postgrex.Error, ~r/not_null_violation|null value/, fn ->
        insert_deployment_row()
      end
    end

    # A conversation bound to the deployment's subscription before ADR 0075
    # is refused at its next turn, as for any source that stops serving.
    test "a conversation bound to the deployment's subscription is refused", %{user: user} do
      put_openai_key(user)
      {:ok, own, _} = resolve(user)

      stored =
        own
        |> Source.dump()
        |> Map.merge(%{
          "scope" => "platform",
          "origin" => "platform",
          "kind" => "codex_chatgpt_access_token",
          "identity" => "platform:chatgpt",
          "revision" => "acct_platform"
        })

      assert Source.summary(stored) == nil
      assert Source.chatgpt_owner(stored) == nil

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, Source.load(stored))
    end

    test "another runtime skips subscriptions", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(user.id, tokens())

      assert {:ok, %Source{scope: :credential}, _} =
               InferenceCredentials.resolve(user.id, "openai/gpt-5", "acp")
    end

    test "a conversation whose subscription is gone is told to reconnect", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      {:ok, source, _} = resolve(user)

      assert :ok = InferenceCredentials.validate_source(user.id, source)

      # A refresh keeps the source.
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_2"), "rt_2") end)
      {:ok, _} = ChatGPT.refresh(age(ChatGPT.get(user.id), days: 7))
      assert :ok = InferenceCredentials.validate_source(user.id, source)

      ChatGPT.disconnect(user.id)

      assert {:error, :chatgpt_reconnect_required} =
               InferenceCredentials.validate_source(user.id, source)

      # Linked again to the same account, it serves again; another account is
      # a different source.
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      assert :ok = InferenceCredentials.validate_source(user.id, source)

      {:ok, _} = ChatGPT.connect(user.id, tokens(account_id: "acct_2"))

      assert {:error, :inference_source_changed} =
               InferenceCredentials.validate_source(user.id, source)
    end

    test "a source the retired implementation wrote still renders but never validates", %{
      user: user
    } do
      stored = %{
        "scope" => "grant",
        "kind" => "codex_chatgpt_access_token",
        "identity" => "chatgpt_grant:" <> Ecto.UUID.generate(),
        "grant_id" => Ecto.UUID.generate(),
        "origin" => "own"
      }

      assert Source.summary(stored) == %{scope: "grant"}
      assert Source.chatgpt_owner(stored) == nil
      _ = user
    end
  end

  describe "the broker and the sandbox" do
    test "the token is brokered on chatgpt.com and the sandbox gets a placeholder" do
      {env_creds, brokered, implicit} =
        Fountain.Broker.split_inference(%{codex_chatgpt_access_token: "at_secret"})

      assert env_creds.codex_chatgpt_access_token == "__codex_chatgpt_access_token__"
      assert brokered == %{"CODEX_CHATGPT_ACCESS_TOKEN" => "at_secret"}

      assert [%{host: "chatgpt.com", auth_type: "substitute"}] =
               implicit["CODEX_CHATGPT_ACCESS_TOKEN"]

      assert CodexChatGPT.env(Managoat.Runtimes.Codex, env_creds) ==
               [{"CODEX_CHATGPT_ACCESS_TOKEN", "__codex_chatgpt_access_token__"}]

      assert CodexChatGPT.env(Managoat.Runtimes.Claude, env_creds) == []
      assert CodexChatGPT.peer_auth(Managoat.Runtimes.Codex, env_creds) == :none
      assert CodexChatGPT.peer_auth(Managoat.Runtimes.Codex, %{openai_api_key: "k"}) == :api_key
    end

    test "prepare_sandbox writes a chatgptAuthTokens auth.json with no secret in it", %{
      user: user
    } do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      {:ok, source, creds} = resolve(user)
      handle = %Managoat.Sandbox.Handle{provider: :sprites, name: "s"}
      test_pid = self()

      stub(Managoat.Sandbox, :write_file, fn ^handle, path, body, opts ->
        send(test_pid, {:wrote, path, body, opts})
        :ok
      end)

      home = "/home/sprite/.managoat/c/#{Ecto.UUID.generate()}"
      assert :ok = CodexChatGPT.prepare_sandbox(handle, "codex", source, user.id, home)
      assert_received {:wrote, path, body, [mode: 0o600]}
      assert path == "#{home}/auth.json"

      auth = Jason.decode!(body)
      assert auth["auth_mode"] == "chatgptAuthTokens"
      assert auth["tokens"]["access_token"] == "__codex_chatgpt_access_token__"
      assert auth["tokens"]["account_id"] == "acct_1"
      assert auth["tokens"]["refresh_token"] == ""
      refute body =~ creds.codex_chatgpt_access_token
      refute body =~ "rt_1"
      refute body =~ "someone@example.com"

      {:ok, claims} = Fountain.ChatGPT.Tokens.decode_payload(auth["tokens"]["id_token"])
      assert claims[@auth_claim]["chatgpt_plan_type"] == "plus"

      # Another runtime or an API-key source is the library's; another user's
      # subscription is refused.
      assert :skip = CodexChatGPT.prepare_sandbox(handle, "claude", source, user.id, home)

      assert :skip =
               CodexChatGPT.prepare_sandbox(handle, "codex", Source.credential(), user.id, home)

      assert {:error, :chatgpt_reconnect_required} =
               CodexChatGPT.prepare_sandbox(handle, "codex", source, Ecto.UUID.generate(), home)
    end

    test "the refresh before a turn puts the stored token into the broker's rule", %{user: user} do
      put_openai_key(user)
      {:ok, _} = ChatGPT.connect(user.id, tokens())
      {:ok, source, creds} = resolve(user)
      {_env, brokered, bindings} = Fountain.Broker.split_inference(creds)

      state = %{
        conversation_id: Ecto.UUID.generate(),
        user_id: user.id,
        broker: %{
          vault: "c-test",
          token: "av_sess",
          expires_at: DateTime.add(DateTime.utc_now(), 3_600)
        },
        broker_network: :unrestricted,
        brokered: brokered,
        broker_bindings: bindings,
        tenant_keys: [],
        secret_sources: nil,
        tenant_key: nil,
        inference_model: "openai/gpt-5",
        inference_source: source,
        inference_credentials: creds,
        sprite_env: []
      }

      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)
      stub(Fountain.Broker, :refresh, fn _, _, _, _ -> flunk("nothing moved") end)
      stub(Fountain.Broker, :prepare, fn _, _, _, _ -> flunk("the session is not expiring") end)
      assert {_same, false} = Egress.refresh_before_turn(state)

      # The keepalive refreshed it; the next turn carries the new token.
      stub_auth(fn conn, _body -> token_response(conn, access_token("at_kept"), "rt_2") end)
      {:ok, _} = ChatGPT.refresh(age(ChatGPT.get(user.id), days: 7))
      test_pid = self()

      stub(Fountain.Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
        send(test_pid, {:rules, brokered["CODEX_CHATGPT_ACCESS_TOKEN"]})
        {:ok, 1}
      end)

      stub_auth(fn _conn, _body -> flunk("a turn must not exchange tokens") end)
      assert {next, false} = Egress.refresh_before_turn(state)
      assert_received {:rules, sent}
      assert jti(sent) == "at_kept"
      assert jti(next.inference_credentials.codex_chatgpt_access_token) == "at_kept"
    end
  end

  # ── fixtures ───────────────────────────────────────────────────────────

  defp chatgpt_events(user) do
    user.id
    |> Audit.list_recent_for_user()
    |> Enum.filter(&String.starts_with?(&1.action, "chatgpt_subscription."))
  end

  defp jwt(claims) do
    header = Base.url_encode64(~s({"alg":"none"}), padding: false)
    header <> "." <> (claims |> Jason.encode!() |> Base.url_encode64(padding: false)) <> ".sig"
  end

  # A token is told apart by its `jti`; its `exp` is what `Tokens.expires_at/1` reads.
  defp access_token(jti, seconds \\ 10 * 86_400),
    do: jwt(%{"jti" => jti, "exp" => System.os_time(:second) + seconds})

  defp jti(token) do
    {:ok, claims} = Fountain.ChatGPT.Tokens.decode_payload(token)
    claims["jti"]
  end

  defp id_token(account_id) do
    jwt(%{
      "email" => "someone@example.com",
      @auth_claim => %{
        "chatgpt_account_id" => account_id,
        "chatgpt_user_id" => "user-x",
        "chatgpt_plan_type" => "plus"
      }
    })
  end

  defp tokens(opts \\ []) do
    %{
      access_token: Keyword.get(opts, :access_token, access_token("at_1")),
      refresh_token: Keyword.get(opts, :refresh_token, "rt_1"),
      id_token: id_token(Keyword.get(opts, :account_id, "acct_1"))
    }
  end

  defp auth_json(opts \\ []) do
    Jason.encode!(%{
      "auth_mode" => Keyword.get(opts, :auth_mode, "chatgpt"),
      "tokens" => %{
        "id_token" => id_token("acct_1"),
        "access_token" => access_token("at_1"),
        "refresh_token" => Keyword.get(opts, :refresh_token, "rt_1")
      }
    })
  end

  defp token_response(conn, access, refresh) do
    Req.Test.json(conn, %{
      "access_token" => access,
      "refresh_token" => refresh,
      "id_token" => id_token("acct_1")
    })
  end

  # `fun` answers the token endpoint. A revocation is answered with
  # `revoke_status` and reported to the test as `{:revoke, body,
  # in_transaction?}`.
  defp stub_auth(fun, revoke_status \\ 200) do
    test = self()

    Req.Test.stub(Fountain.ChatGPT.OAuth, fn conn ->
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      body = Jason.decode!(raw)

      case conn.request_path do
        "/oauth/revoke" ->
          send(test, {:revoke, body, Repo.in_transaction?()})

          if revoke_status == 200 do
            Req.Test.json(conn, %{})
          else
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(
              revoke_status,
              ~s({"error":{"code":"invalid_refresh_token","type":"invalid_request_error"}})
            )
          end

        _ ->
          fun.(conn, body)
      end
    end)
  end

  defp event(user, action) do
    Enum.find(chatgpt_events(user), &(&1.action == action))
  end

  defp age(sub, days: days) do
    at = DateTime.utc_now() |> DateTime.add(-days * 86_400) |> DateTime.truncate(:second)
    sub |> Ecto.Changeset.change(last_refreshed_at: at) |> Repo.update!()
  end

  defp lease(sub, until) do
    sub |> Ecto.Changeset.change(refresh_lease_until: until) |> Repo.update!()
  end

  # The next `times` writes of a new access token to the table fail in the
  # database, as a commit lost to a blip would. A sequence counts them
  # because it is not rolled back with the failed statement. All of it is
  # DDL inside the test's sandbox transaction, so it goes when the test does.
  defp fail_token_writes(times) do
    Repo.query!("CREATE SEQUENCE chatgpt_test_failed_writes")

    Repo.query!("""
    CREATE FUNCTION chatgpt_test_fail_write() RETURNS trigger AS $$
    BEGIN
      IF nextval('chatgpt_test_failed_writes') <= #{times} THEN
        RAISE EXCEPTION 'injected write failure' USING ERRCODE = '08006';
      END IF;
      RETURN NEW;
    END $$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER chatgpt_test_fail_write BEFORE UPDATE ON chatgpt_subscriptions
    FOR EACH ROW WHEN (NEW.access_token_ciphertext IS DISTINCT FROM OLD.access_token_ciphertext)
    EXECUTE FUNCTION chatgpt_test_fail_write()
    """)
  end

  defp put_openai_key(user) do
    {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
    {:ok, set} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-own")
    set
  end

  defp resolve(user, opts \\ []),
    do: InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex", opts)

  # The deployment's row as releases before ADR 0075 wrote it: no user.
  defp insert_deployment_row do
    Repo.insert!(%Subscription{
      id: Ecto.UUID.generate(),
      user_id: nil,
      account_id: "acct_platform",
      access_token_ciphertext: "sealed",
      refresh_token_ciphertext: "sealed",
      last_refreshed_at:
        DateTime.utc_now() |> DateTime.add(-8 * 86_400) |> DateTime.truncate(:second)
    })
  end
end
