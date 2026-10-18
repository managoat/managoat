defmodule FountainWeb.ConversationControllerTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  alias Fountain.Conversations.ConversationServer
  alias FountainWeb.ConversationController
  alias Fountain.Conversations.Interruption
  alias Fountain.Conversations.Termination
  alias Fountain.Conversations.Wake

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes. Stubbed at `Managoat.Sandbox.Sprites` rather than at the
  # `Managoat.Sandbox` facade so a test that drives either layer itself still
  # overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    {:ok, user: user, raw_key: raw_key}
  end

  describe "GET /api/conversations" do
    test "returns 200 and lists user's conversations", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert conv.id in ids
    end

    test "does not include conversations belonging to other users", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_active_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")

      body = json_response(conn, 200)
      ids = Enum.map(body["data"], & &1["id"])
      refute other_conv.id in ids
    end

    test "filters by agent_id, channel_id and status (#832)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      ada = insert_agent(user_id: user.id)
      linus = insert_agent(user_id: user.id)

      bound_idle =
        insert_conversation(
          user_id: user.id,
          agent: ada,
          channel_id: "slack:C042",
          status: "idle"
        )

      bound_dead =
        insert_conversation(
          user_id: user.id,
          agent: ada,
          channel_id: "slack:C042",
          status: "terminated"
        )

      plain = insert_conversation(user_id: user.id, agent: linus, status: "idle")

      ids = fn query ->
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations", query)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert ids.(agent_id: ada.id) == Enum.sort([bound_idle.id, bound_dead.id])
      assert ids.(channel_id: "slack:C042") == Enum.sort([bound_idle.id, bound_dead.id])
      assert ids.(agent_id: ada.id, status: "terminated") == [bound_dead.id]

      assert ids.(status: "idle,terminated") ==
               Enum.sort([bound_idle.id, bound_dead.id, plain.id])

      assert ids.(agent_id: linus.id, channel_id: "slack:C042") == []

      assert %{"error" => "invalid_status"} =
               conn
               |> authed_with_key(raw_key)
               |> get("/api/conversations", status: "terminted")
               |> json_response(400)
    end

    test "sandbox filter combines with status and never crosses tenant scope", %{
      conn: conn,
      user: user,
      raw_key: key
    } do
      sandbox = insert_sandbox(user_id: user.id)
      other = insert_sandbox(user_id: user.id)
      live = insert_conversation(user_id: user.id, sandbox_id: sandbox.id, status: "idle")
      done = insert_conversation(user_id: user.id, sandbox_id: sandbox.id, status: "terminated")
      insert_conversation(user_id: user.id, sandbox_id: other.id)
      insert_conversation(user_id: user.id)
      foreign_user = insert_verified_user()
      foreign_sandbox = insert_sandbox(user_id: foreign_user.id)
      insert_conversation(user_id: foreign_user.id, sandbox_id: foreign_sandbox.id)

      ids = fn query ->
        conn
        |> authed_with_key(key)
        |> get("/api/conversations", query)
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])
        |> Enum.sort()
      end

      assert ids.(sandbox_id: sandbox.id) == Enum.sort([live.id, done.id])
      assert ids.(sandbox_id: sandbox.id, status: "terminated") == [done.id]
      assert ids.(sandbox_id: foreign_sandbox.id) == []
      assert ids.(sandbox_id: Ecto.UUID.generate()) == []

      assert conn
             |> authed_with_key(key)
             |> get("/api/conversations", sandbox_id: "invalid")
             |> json_response(422)
    end

    test "returns 401 without authentication", %{conn: conn} do
      conn = get(conn, "/api/conversations")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:id" do
    test "returns 200 with the conversation for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      body = json_response(conn, 200)
      assert body["data"]["id"] == conv.id
    end

    # Provenance (ADR 0029, #1051): the stamp is on the row, the number is
    # resolved on show and index so a client can read it without a second
    # request; a conversation that predates versioning reports null for both.
    test "reports the agent version it launched under", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      {:ok, _} = Fountain.Agents.update_agent(agent, %{"description" => "edited"})
      version_id = Fountain.Agents._unsafe_current_version_id(agent.id)

      stamped =
        insert_conversation(user_id: user.id, agent_id: agent.id, agent_version_id: version_id)

      unstamped = insert_conversation(user_id: user.id, agent_id: agent.id)

      shown = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{stamped.id}")

      assert %{"agent_version_id" => ^version_id, "agent_version" => 2} =
               json_response(shown, 200)["data"]

      shown = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{unstamped.id}")

      assert %{"agent_version_id" => nil, "agent_version" => nil} =
               json_response(shown, 200)["data"]

      listed = conn |> authed_with_key(raw_key) |> get("/api/conversations")
      by_id = Map.new(json_response(listed, 200)["data"], &{&1["id"], &1})
      assert by_id[stamped.id]["agent_version"] == 2
      assert by_id[unstamped.id]["agent_version"] == nil
    end

    # Retired with the agent's (#2430): every conversation an ACP client can
    # reopen is on the `acp` stream, and one that is not stays web-only.
    test "does not report the retired acp field", %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id, runtime: "claude")
      conv = insert_conversation(user_id: user.id, agent_id: agent.id, runtime: "claude")
      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}")

      refute Map.has_key?(json_response(conn, 200)["data"], "acp")
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_active_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = get(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "GET /api/conversations/:conversation_id/turns" do
    test "returns 200 with turns list for the authenticated user", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      turn = insert_turn(conv, [])

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert is_list(body["data"])
      ids = Enum.map(body["data"], & &1["id"])
      assert turn.id in ids
    end

    test "each turn carries the client_request_id of its prompt, or null (#1406)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_turn(conv, [])
      insert_turn(conv, client_request_id: "salon-execution-42")

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      ids =
        conn
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.sort_by(& &1["turn_number"])
        |> Enum.map(& &1["client_request_id"])

      assert ids == [nil, "salon-execution-42"]
    end

    test "each turn says who opened it (#817)", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      insert_turn(conv, [])
      insert_turn(conv, origin: "autonomous", prompt: "(background task follow-up)")

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      origins = conn |> json_response(200) |> Map.fetch!("data") |> Enum.map(& &1["origin"])
      assert Enum.sort(origins) == ["autonomous", "user"]
    end

    test "carries each turn's usage and the conversation's usage_total (#827)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      t1 = insert_turn(conv, status: "completed")
      insert_turn(conv, status: "completed")

      {:ok, _} =
        Fountain.Conversations._unsafe_record_turn_usage(t1, %{
          "input" => 120,
          "output" => 30,
          "cache_read" => 100
        })

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/turns")
        |> json_response(200)

      assert [
               %{"usage" => %{"input" => 120, "output" => 30, "cache_read" => 100}},
               %{"usage" => nil}
             ] = body["data"]

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}")
        |> json_response(200)

      assert body["data"]["usage_total"] == %{"input" => 120, "output" => 30}
    end

    test "exposes partial accounting, metadata-only reports and unqualified history", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      accounting = %{
        "version" => 1,
        "source" => "codex/thread-token-usage-delta",
        "scope" => "root_thread_prompt",
        "completeness" => "partial"
      }

      partial =
        Managoat.ACP.Usage.from_prompt_result(%{
          "usage" => %{"inputTokens" => 12, "outputTokens" => 3, "cachedReadTokens" => 40},
          "_meta" => %{"usageAccounting" => accounting}
        })

      unknown =
        Managoat.ACP.Usage.from_prompt_result(%{
          "usage" => nil,
          "_meta" => %{"usageAccounting" => accounting}
        })

      legacy = %{"input" => 2, "output" => 1}

      for usage <- [partial, unknown, legacy] do
        turn = insert_turn(conv, status: "completed")
        assert {:ok, _} = Fountain.Conversations._unsafe_record_turn_usage(turn, usage)
      end

      body =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/turns")
        |> json_response(200)

      assert Enum.map(body["data"], & &1["usage"]) == [partial, unknown, legacy]
      assert unknown == %{"accounting" => accounting}
      refute Map.has_key?(List.last(body["data"])["usage"], "accounting")

      total =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}")
        |> json_response(200)

      assert total["data"]["usage_total"] == %{"input" => 14, "output" => 4}

      {_key, other_key} = insert_api_key(insert_verified_user())
      # This endpoint still authorizes the parent conversation before reading usage.
      assert conn
             |> authed_with_key(other_key)
             |> get("/api/conversations/#{conv.id}/turns")
             |> response(404)
    end

    test "returns 200 with an empty list when there are no turns", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{conv.id}/turns")

      body = json_response(conn, 200)
      assert body["data"] == []
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_active_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations/#{other_conv.id}/turns")

      assert json_response(conn, 404)
    end
  end

  describe "the fleet ceiling" do
    test "POST /api/conversations returns 503 fleet_full at the ceiling", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      fill_fleet()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 503)["error"] == "fleet_full"
      assert get_resp_header(conn, "retry-after") == ["60"]
    end

    test "POST /api/conversations succeeds below the ceiling", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      fill_fleet(1)

      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 201)
    end
  end

  describe "DELETE /api/conversations/:id" do
    test "deletes the conversation and returns 204", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{conv.id}")

      assert conn.status == 204
    end

    test "returns 404 when the conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_active_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn = conn |> authed_with_key(raw_key) |> delete("/api/conversations/#{other_conv.id}")

      assert json_response(conn, 404)
    end

    test "returns 401 without authentication", %{conn: conn, user: user} do
      conv = insert_conversation(user_id: user.id)
      conn = delete(conn, "/api/conversations/#{conv.id}")
      assert json_response(conn, 401)
    end
  end

  describe "infer_provenance/1" do
    test "returns {\"api\", nil} when header is nil" do
      assert ConversationController.infer_provenance(nil) == {"api", nil}
    end

    test "returns {\"api\", nil} when header is an empty string" do
      assert ConversationController.infer_provenance("") == {"api", nil}
    end

    test "returns {\"agent\", id} when header contains a conversation id" do
      assert ConversationController.infer_provenance("some-conv-uuid") ==
               {"agent", "some-conv-uuid"}
    end
  end

  describe "POST /api/conversations" do
    test "an empty or oversized client_request_id is refused before anything launches (#1406)",
         %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)
      reject(&Fountain.Conversations.Launch.start_or_resume_conversation/2)
      too_long = String.duplicate("x", Fountain.Conversations.Turn.client_request_id_max() + 1)

      for bad <- ["", too_long, 42] do
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "prompt" => "hello",
          "client_request_id" => bad
        })
        |> json_response(422)
      end
    end

    # The `message` is the assertion that matters: without the fallback clause
    # the terminal safety net still answers 422 with the bare atom, so a test
    # that only checked the status and `error` would pass with no clause at
    # all (#1632).
    test "returns 422 invalid_sprite_name, with a message, for a malformed suffix", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => agent.id, "machine_name" => "not a valid name"})
        )

      body = json_response(conn, 422)
      assert body["error"] == "invalid_sprite_name"
      assert body["message"] =~ "suffix of an account-scoped sandbox name"
    end

    test "returns 422 machine_name_conflict when machine_name and sprite_name differ", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => agent.id, "machine_name" => "a", "sprite_name" => "b"})
        )

      body = json_response(conn, 422)
      assert body["error"] == "machine_name_conflict"
      assert body["message"] =~ "send machine_name alone"
    end

    test "returns 404 when agent_id does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_agent_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => unknown_agent_id, "prompt" => "hello"})
        )

      assert json_response(conn, 404)
    end

    test "returns 404 when agent belongs to a different user", %{conn: conn, raw_key: raw_key} do
      other_user = insert_active_user()
      other_agent = insert_agent(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("content-type", "application/json")
        |> post(
          "/api/conversations",
          Jason.encode!(%{"agent_id" => other_agent.id, "prompt" => "hello"})
        )

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/prompts" do
    test "returns 200 with status queued on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 200)["status"] == "queued"
    end

    test "echoes client_request_id and sends it on with the prompt (#1406)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      test = self()

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, opts ->
        send(test, {:prompt_opts, opts})
        :ok
      end)

      body =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{
          "prompt" => "hello",
          "client_request_id" => "salon-execution-42"
        })
        |> json_response(200)

      assert body == %{"status" => "queued", "client_request_id" => "salon-execution-42"}
      assert_received {:prompt_opts, opts}
      assert opts[:client_request_id] == "salon-execution-42"
      # Still the audit attribution it always was.
      assert opts[:actor]
    end

    test "a prompt that names no request is answered with a null id (#1406)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts -> :ok end)

      body =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})
        |> json_response(200)

      assert body == %{"status" => "queued", "client_request_id" => nil}

      # An explicit null is the same as leaving it out, as it is for `images`.
      body =
        build_conn()
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{
          "prompt" => "hello",
          "client_request_id" => nil
        })
        |> json_response(200)

      assert body == %{"status" => "queued", "client_request_id" => nil}
    end

    test "an empty or oversized client_request_id is refused before the prompt is sent", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      reject(&ConversationServer.send_prompt/4)
      too_long = String.duplicate("x", Fountain.Conversations.Turn.client_request_id_max() + 1)

      for bad <- ["", too_long, 42] do
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{
          "prompt" => "hello",
          "client_request_id" => bad
        })
        |> json_response(422)
      end
    end

    # PostgreSQL cannot hold U+0000 in a text column: the insert raises 22021
    # from a place nothing rescues, so an ordinary prompt would end its
    # conversation server over the label it carried — and on a wake, after the
    # caller had already been told `queued`. The prompt is fine; the id is not.
    test "a NUL in the id is refused before the prompt is sent", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      reject(&ConversationServer.send_prompt/4)

      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/conversations/#{conv.id}/prompts", %{
        "prompt" => "hello",
        "client_request_id" => "plan-7" <> <<0>> <> "step-3"
      })
      |> json_response(422)
    end

    # `replace_params: false` leaves path, query and body merged in `params`,
    # and the schema validates only the body. A query-only value was therefore
    # never checked: it was echoed to the caller and then dropped by
    # `PromptDelivery.travelling/1`, naming a correlation no turn could carry.
    test "an id supplied only in the query string is not read", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      test = self()

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, opts ->
        send(test, {:prompt_opts, opts})
        :ok
      end)

      too_long = String.duplicate("x", Fountain.Conversations.Turn.client_request_id_max() + 1)

      # The second is the array form, which used to render a list where
      # `PromptResponse` declares a nullable string.
      for query <- ["client_request_id=#{too_long}", "client_request_id[]=x"] do
        body =
          build_conn()
          |> authed_with_key(raw_key)
          |> post_json("/api/conversations/#{conv.id}/prompts?#{query}", %{"prompt" => "hello"})
          |> json_response(200)

        assert body == %{"status" => "queued", "client_request_id" => nil}
        assert_received {:prompt_opts, opts}
        assert is_nil(opts[:client_request_id])
      end
    end

    # The door takes these, so the response echoes them and the turn has to
    # carry the same bytes back (`PromptCorrelationTest`). An id of spaces is
    # one character to every length check here and an empty string to Ecto's
    # default casting, which is where it used to disappear.
    test "an id the door accepts travels as it was sent, spaces and all", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      test = self()

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, opts ->
        send(test, {:prompt_opts, opts})
        :ok
      end)

      combining = String.duplicate("e\u0301", Fountain.Conversations.Turn.client_request_id_max())

      for id <- [" ", "\t\n", combining] do
        body =
          build_conn()
          |> authed_with_key(raw_key)
          |> post_json("/api/conversations/#{conv.id}/prompts", %{
            "prompt" => "hello",
            "client_request_id" => id
          })
          |> json_response(200)

        assert body == %{"status" => "queued", "client_request_id" => id}
        assert_received {:prompt_opts, opts}
        assert opts[:client_request_id] == id
      end
    end

    test "a machine whose teardown has been asked for answers 409, not a bare atom", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      # ADR 0058 stage 7a, round 1 of the surfaces review. `Machines.Resume`
      # refuses a fenced machine with its own word, `:fenced`, and that word has
      # no meaning outside `Fountain.Machines` — untranslated it reached here
      # and rendered as `422 {"error": "fenced"}` through the terminal safety
      # net, with a "fallback: unmapped error atom" warning in the log.
      # `Machine.ensure_up/2` translates it to the word the front door has
      # always used for a machine on its way out.
      #
      # **What this test reaches since stage 9b: the wake door, not the
      # resume.** The row is stamped before the prompt, and
      # `Wake.maybe_reuse_sandbox/1` refuses a `destroying` row first, with the
      # same word, so the resume's translation is never reached here and
      # removing it leaves this test green. The translation itself is pinned in
      # `machines/resume_test.exs`. What reaches the resume's arm in
      # production is a fence that lands between the wake's check and the
      # lease: a race, not a row shape this test can build. This test pins the
      # word the prompt gets.
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")

      conv =
        insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      sandbox
      |> put_lease(transition: "destroying", transition_reason: "teardown")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
      reject(&Managoat.Sandbox.Sprites.resume/1)

      body =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})
        |> json_response(409)

      assert body["error"] == "sandbox_reset_pending"
      assert body["message"] =~ "Managoat finishes the delete automatically"
    end

    test "returns 404 when ConversationServer is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :not_running}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end

    test "returns 400 when conversation is busy", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :busy}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 400)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{unknown_id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end

    # The #332 trio: each of these used to blow the hand-maintained case
    # clause and 500. All three run the real wake path, no stubs.

    test "returns 410 when the conversation is terminated", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "terminated")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 410)["error"] == "conversation_terminated"
    end

    test "returns 422 when the conversation's agent was deleted", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "idle")
      assert conv.agent_id == nil

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 422)["error"] == "no_agent"
    end

    test "returns 422 when the wake path surfaces a changeset error", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, Fountain.Conversations.Sandbox.changeset(%Fountain.Conversations.Sandbox{}, %{})}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert %{"errors" => _} = json_response(conn, 422)
    end

    test "an unknown refusal atom is a 422, not a CaseClauseError 500", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(ConversationServer, :send_prompt, fn _id, _prompt, _images, _opts ->
        {:error, :some_future_refusal}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 422)["error"] == "some_future_refusal"
    end

    test "returns 404 when conversation belongs to a different user", %{
      conn: conn,
      raw_key: raw_key
    } do
      other_user = insert_active_user()
      other_conv = insert_conversation(user_id: other_user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations/#{other_conv.id}/prompts", %{"prompt" => "hello"})

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/requests/:request_id" do
    # The request is held by the running turn's server; the door relays the
    # answer there and audits it. What the server says is stubbed here and
    # driven for real in `conversation_server_acp_test.exs`.
    defp answer(conn, raw_key, conv, request_id, option_id) do
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/conversations/#{conv.id}/requests/#{request_id}", %{"option_id" => option_id})
    end

    test "answers a request the running turn holds, and audits it", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "running")

      stub(ConversationServer, :answer_permission, fn id, "7.abc", "yes" ->
        assert id == conv.id
        :ok
      end)

      assert answer(conn, raw_key, conv, "7.abc", "yes") |> json_response(200) == %{"ok" => true}

      assert Enum.any?(
               Fountain.Audit.list_recent_for_user(user.id, 20),
               &(&1.action == "conversation.permission_answered")
             )
    end

    test "refuses an option the agent never offered", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "running")
      stub(ConversationServer, :answer_permission, fn _, _, _ -> {:error, :unknown_option} end)

      body = answer(conn, raw_key, conv, "7.abc", "made-up") |> json_response(422)
      assert body["error"] == "unknown_option"
    end

    test "refuses the sandbox's own token", %{conn: conn, user: user} do
      # The sprite holds a MANAGOAT_TOKEN and could otherwise approve the tool
      # it just asked about. The route is not on the sandbox key's allowlist
      # (ADR 0096), so it is refused before the context's own rule.
      {record, sprite_key} = insert_sprite_api_key(user)

      conv =
        insert_conversation(user_id: user.id, status: "running", callback_api_key_id: record.id)

      reject(ConversationServer, :answer_permission, 3)

      body = answer(conn, sprite_key, conv, "7.abc", "yes") |> json_response(403)
      assert body["reason"] == "insufficient_scope"
    end

    test "a request nobody is holding is a 409", %{conn: conn, user: user, raw_key: raw_key} do
      # A request does not outlive its turn (#2676): once the turn has ended,
      # or no server runs it, there is nothing to answer.
      conv = insert_conversation(user_id: user.id, status: "idle")

      body = answer(conn, raw_key, conv, "7.abc", "yes") |> json_response(409)
      assert body["error"] == "permission_request_resolved"
    end

    defp answer_form(conn, raw_key, conv, request_id, body) do
      conn
      |> authed_with_key(raw_key)
      |> put_req_header("content-type", "application/json")
      |> post("/api/conversations/#{conv.id}/requests/#{request_id}", body)
    end

    test "answers a form with an action and its content, and audits the action only (#2492)",
         %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id, status: "running")

      stub(ConversationServer, :answer_elicitation, fn id, "8.abc", "accept", content ->
        assert id == conv.id
        assert content == %{"question_0" => "Postgres", "question_0_custom" => "hunter2"}
        :ok
      end)

      body = %{
        "action" => "accept",
        "content" => %{"question_0" => "Postgres", "question_0_custom" => "hunter2"}
      }

      assert answer_form(conn, raw_key, conv, "8.abc", body) |> json_response(200) == %{
               "ok" => true
             }

      audits = Fountain.Audit.list_recent_for_user(user.id, 20)
      assert audit = Enum.find(audits, &(&1.action == "conversation.question_answered"))
      assert audit.metadata == %{"request_id" => "8.abc", "action" => "accept"}
      refute inspect(audits) =~ "hunter2"
    end

    test "a form answer that does not fit is a 422 that says why", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "running")

      stub(ConversationServer, :answer_elicitation, fn _, _, _, _ ->
        {:error, {:invalid_content, "question_0: not one of the offered choices"}}
      end)

      body =
        answer_form(conn, raw_key, conv, "8.abc", %{
          "action" => "accept",
          "content" => %{"question_0" => "MySQL"}
        })
        |> json_response(422)

      assert body["error"] == "invalid_content"
      assert body["message"] =~ "question_0"
    end

    test "answering a form with an option id says which answer it wants", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "running")

      stub(ConversationServer, :answer_permission, fn _, _, _ ->
        {:error, :not_a_permission_request}
      end)

      body = answer(conn, raw_key, conv, "8.abc", "yes") |> json_response(422)
      assert body["error"] == "wrong_answer_kind"
    end

    test "a body with neither option_id nor action is a 422", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id, status: "running")
      reject(ConversationServer, :answer_elicitation, 4)

      body = answer_form(conn, raw_key, conv, "8.abc", %{}) |> json_response(422)
      assert body["error"] == "option_id_required"
    end

    test "the sandbox's own token may not answer a form either", %{conn: conn, user: user} do
      {record, sprite_key} = insert_sprite_api_key(user)

      conv =
        insert_conversation(user_id: user.id, status: "running", callback_api_key_id: record.id)

      reject(ConversationServer, :answer_elicitation, 4)

      body =
        answer_form(conn, sprite_key, conv, "8.abc", %{"action" => "decline"})
        |> json_response(403)

      assert body["reason"] == "insufficient_scope"
    end
  end

  describe "POST /api/conversations/:conversation_id/terminate" do
    test "returns a retryable 503 when the actor's sandbox binding is unavailable", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      expect(Termination, :terminate_conversation, fn id, _opts ->
        assert id == conv.id
        {:error, :sandbox_unavailable}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert %{"error" => "sandbox_unavailable", "message" => message} =
               json_response(conn, 503)

      assert message =~ "send it again shortly"
      assert get_resp_header(conn, "retry-after") == ["30"]
    end

    test "returns 204 on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(Termination, :terminate_conversation, fn _id, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert conn.status == 204
    end

    test "returns 404 when ConversationServer is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      stub(Termination, :terminate_conversation, fn _id, _opts ->
        {:error, :not_running}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/terminate")

      assert json_response(conn, 404)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{unknown_id}/terminate")

      assert json_response(conn, 404)
    end
  end

  describe "POST /api/conversations/:conversation_id/interrupt" do
    test "returns 204 on success", %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)
      stub(Interruption, :interrupt, fn _id, _opts -> :ok end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert conn.status == 204
    end

    # The acp runtime carries no special case at this door, and that is the
    # claim (#1634). The other half of the path, `:interrupt` becoming a
    # `session/cancel` on the command and an `interrupted` turn, is pinned in
    # conversation_server_acp_runtime_test.exs against a live server.
    test "an acp conversation interrupts through the same door", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id, runtime: "acp", runtime_command: "chant acp")
      conv = insert_conversation(user_id: user.id, agent: agent)
      assert conv.runtime == "acp"

      test = self()

      stub(Interruption, :interrupt, fn id, _opts ->
        send(test, {:interrupted, id}) && :ok
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert conn.status == 204
      assert_receive {:interrupted, id}
      assert id == conv.id
    end

    # Ownership is established before the server is asked, so "not running" is
    # a state conflict on a conversation the caller can see, not a missing one
    # (#1179 — the owner of a stuck conversation got a 404 saying it was the
    # wrong id or someone else's, while `GET` on it worked with the same key).
    test "returns 409 when the conversation is not running", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(Interruption, :interrupt, fn _id, _opts -> {:error, :not_running} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert %{"error" => "not_running"} = json_response(conn, 409)
    end

    # Still reachable: the row can be deleted between the ownership fetch and
    # the interrupt.
    test "returns 404 when the conversation vanished mid-request", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(Interruption, :interrupt, fn _id, _opts -> {:error, :not_found} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert json_response(conn, 404)
    end

    test "returns 409 conflict when conversation is idle", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      stub(Interruption, :interrupt, fn _id, _opts -> {:error, :idle} end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{conv.id}/interrupt")

      assert json_response(conn, 409)
    end

    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post("/api/conversations/#{unknown_id}/interrupt")

      assert json_response(conn, 404)
    end
  end

  describe "GET /api/conversations/:conversation_id/stream" do
    test "returns 404 when conversation does not exist", %{conn: conn, raw_key: raw_key} do
      unknown_id = Ecto.UUID.generate()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{unknown_id}/stream")

      assert json_response(conn, 404)
    end

    test "returns 200 with text/event-stream content-type when wait=false", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    # parse_bool_param("true") returns true, but wait=true blocks in sse_loop
    # (60 s timeout), so we pass wait=false here and verify the endpoint
    # still returns 200 — the "true" branch is covered by the unit path
    # exercised whenever the default (true) is used in production.
    # Instead we verify that explicitly passing wait=false (parse_bool_param
    # "false" → false) closes the stream immediately with 200.
    test "returns 200 when wait=false is explicit (parse_bool_param \"false\" branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams param is provided (parse_streams_param branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is non-integer (parse_last_event_id :error branch defaults to 0)",
         %{conn: conn, user: user, raw_key: raw_key} do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "abc")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when wait=0 (parse_bool_param \"0\" → false, non-blocking)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=0")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when streams= is empty string (parse_streams_param \"\" → nil)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "returns 200 when Last-Event-ID is empty string (parse_last_event_id \"\" → 0)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end
  end

  # Every test above passed while the endpoint 406'd for every real client,
  # because Phoenix.ConnTest sends no Accept header and `plug :accepts` then
  # falls through to the default format. A real SSE client — the Go CLI, the
  # browser's EventSource, curl -H — sends `Accept: text/event-stream`, which
  # `plug :accepts, ["json"]` refuses before the action runs. So these tests
  # send the header on purpose.
  describe "GET /api/conversations/:conversation_id/stream — content negotiation" do
    test "accepts the Accept header a real SSE client sends", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
    end

    test "still replays buffered events with that header set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "hello"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert conn.resp_body =~ "event: output"
      assert conn.resp_body =~ "hello"
    end

    test "an unknown conversation still renders a JSON 404", %{conn: conn, raw_key: raw_key} do
      # The route negotiates no format at all now, so the fallback path has to
      # keep working without one.
      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{Ecto.UUID.generate()}/stream")

      assert json_response(conn, 404)
    end

    test "authentication is still enforced on the stream route", %{conn: conn, user: user} do
      # The stream lives in its own scope now. It shares the `:api` pipeline
      # rather than a copy of it, and this is what holds that true.
      conv = insert_conversation(user_id: user.id)

      conn =
        conn
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert json_response(conn, 401)
    end

    test "another tenant's conversation is still a 404", %{conn: conn, raw_key: raw_key} do
      other = insert_conversation(user_id: insert_active_user().id)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations/#{other.id}/stream?wait=false")

      assert json_response(conn, 404)
    end

    test "JSON endpoints still refuse text/event-stream", %{conn: conn, raw_key: raw_key} do
      # The fix is scoped to the stream route: negotiation was not loosened
      # across /api, so asking a JSON endpoint for an event stream is still a
      # 406 rather than a 500 from a missing template.
      assert_raise Phoenix.NotAcceptableError, fn ->
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("accept", "text/event-stream")
        |> get("/api/conversations")
      end
    end
  end

  describe "GET /api/conversations/:conversation_id/stream with log events (replay path)" do
    test "replays existing log events when wait=false and conversation has events", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "hello"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      assert get_resp_header(conn, "content-type") == ["text/event-stream"]
      body = conn.resp_body
      assert body =~ "event: output"
      assert body =~ "hello"

      # #2297: the frame this stream actually sends matches the schema the
      # operation now declares, not just the bare string it used to.
      [payload] = Regex.run(~r/data: (\{[^\n]*hello[^\n]*\})/, body, capture: :all_but_first)
      decoded = Jason.decode!(payload)

      assert FountainWeb.SchemaGuard.validate_value(FountainWeb.Schemas.StreamLogEvent, decoded) ==
               :ok
    end

    test "replays only matching stream events when streams filter is set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "stdout-data"})
      insert_log_event(conv, %{kind: "output", stream: "stderr", data: "stderr-data"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> get("/api/conversations/#{conv.id}/stream?wait=false&streams=stdout")

      assert conn.status == 200
      body = conn.resp_body
      assert body =~ "stdout-data"
      refute body =~ "stderr-data"
    end

    test "replays events after last_event_id when Last-Event-ID header is set", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      conv = insert_conversation(user_id: user.id)
      ev1 = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "first"})
      insert_log_event(conv, %{kind: "output", stream: "stdout", data: "second"})

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("last-event-id", "#{ev1.id}")
        |> get("/api/conversations/#{conv.id}/stream?wait=false")

      assert conn.status == 200
      body = conn.resp_body
      refute body =~ "first"
      assert body =~ "second"
    end
  end

  describe "POST /api/conversations — parent conversation header" do
    test "records agent provenance from the parent header", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", parent_conv.id)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      data = json_response(conn, 201)["data"]
      assert data["source"] == "agent"
      assert data["parent_conversation_id"] == parent_conv.id
    end

    test "still reads the X-Fountain parent header (ADR 0082 window)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      data =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-fountain-parent-conversation-id", parent_conv.id)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["source"] == "agent"
      assert data["parent_conversation_id"] == parent_conv.id
    end

    test "ignores the legacy parent header", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      parent_conv = insert_conversation(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      data =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-aod-parent-conversation-id", parent_conv.id)
        |> post_json("/api/conversations", %{"agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["source"] == "api"
      assert is_nil(data["parent_conversation_id"])
    end

    test "returns 404 when the header is not a conversation id (#1679)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", "my-other-conversation")
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 404) == %{"error" => "parent_conversation_not_found"}
    end

    test "returns 404 when the header is a sixteen-character name (#1679)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      # Sixteen bytes is the length `Ecto.UUID.cast/1` reads as a raw uuid, so
      # this is the value a cast-based guard would have let through.
      conn =
        conn
        |> authed_with_key(raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", "warehouse worker")
        |> post_json("/api/conversations", %{"agent_id" => agent.id})

      assert json_response(conn, 404) == %{"error" => "parent_conversation_not_found"}
    end
  end

  describe "POST /api/conversations — spawn depth (#1269)" do
    setup %{user: user} do
      stub_server_start(fn _supervisor, _child_spec -> {:ok, spawn(fn -> :ok end)} end)
      {:ok, agent: insert_agent(user_id: user.id), max: Fountain.Conversations.Launch.max_depth()}
    end

    test "a start from outside any sandbox is depth 0", %{conn: conn, raw_key: raw_key} = ctx do
      data =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["depth"] == 0
    end

    test "a child is one deeper than the parent the header names", ctx do
      parent = insert_conversation(user_id: ctx.user.id, depth: 2)

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", parent.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["depth"] == 3
      assert Fountain.Repo.get!(Fountain.Conversations.Conversation, data["id"]).depth == 3
    end

    test "a start past the ceiling is refused, naming the depth", ctx do
      parent = insert_conversation(user_id: ctx.user.id, depth: ctx.max)
      before = Fountain.Repo.aggregate(Fountain.Conversations.Conversation, :count)

      body =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", parent.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(422)

      assert %{
               "error" => "conversation_depth_exceeded",
               "depth" => depth,
               "max_depth" => max,
               "message" => message
             } = body

      assert depth == ctx.max + 1
      assert max == ctx.max
      assert message =~ "depth #{ctx.max + 1}"
      assert Fountain.Repo.aggregate(Fountain.Conversations.Conversation, :count) == before
    end

    test "the ceiling itself is still allowed", ctx do
      parent = insert_conversation(user_id: ctx.user.id, depth: ctx.max - 1)

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> put_req_header("x-managoat-parent-conversation-id", parent.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["depth"] == ctx.max
    end

    test "a sandbox token counts from its own conversation without the header", ctx do
      {key, sprite_raw} = insert_sprite_api_key(ctx.user)
      own = insert_conversation(user_id: ctx.user.id, depth: 1, callback_api_key_id: key.id)

      data =
        ctx.conn
        |> authed_with_key(sprite_raw)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["depth"] == 2
      # A sandbox's start is always its own conversation's child (ADR 0096),
      # header or not, so the tree its key is confined to stays closed.
      assert data["parent_conversation_id"] == own.id
      assert data["source"] == "agent"
    end

    test "leaving the header out does not reset a deep sandbox's chain", ctx do
      {key, sprite_raw} = insert_sprite_api_key(ctx.user)
      insert_conversation(user_id: ctx.user.id, depth: ctx.max, callback_api_key_id: key.id)

      body =
        ctx.conn
        |> authed_with_key(sprite_raw)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(422)

      assert body["error"] == "conversation_depth_exceeded"
      assert body["depth"] == ctx.max + 1
    end

    test "a sandbox token naming its own conversation in the header counts from it", ctx do
      {key, sprite_raw} = insert_sprite_api_key(ctx.user)
      own = insert_conversation(user_id: ctx.user.id, depth: 3, callback_api_key_id: key.id)

      data =
        ctx.conn
        |> authed_with_key(sprite_raw)
        |> put_req_header("x-managoat-parent-conversation-id", own.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["depth"] == 4
      assert data["parent_conversation_id"] == own.id
    end

    test "a sandbox token may not name another conversation as the parent", ctx do
      # Grafting a child onto a shallower or unrelated conversation would put
      # it outside the key's tree (ADR 0096), so it is refused as an unknown
      # parent and nothing is started.
      {key, sprite_raw} = insert_sprite_api_key(ctx.user)
      insert_conversation(user_id: ctx.user.id, depth: 3, callback_api_key_id: key.id)
      shallow = insert_conversation(user_id: ctx.user.id, depth: 0)
      before = Fountain.Repo.aggregate(Fountain.Conversations.Conversation, :count)

      body =
        ctx.conn
        |> authed_with_key(sprite_raw)
        |> put_req_header("x-managoat-parent-conversation-id", shallow.id)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(404)

      assert body["error"] == "parent_conversation_not_found"
      assert Fountain.Repo.aggregate(Fountain.Conversations.Conversation, :count) == before
    end

    test "a sandbox token no conversation of the account names starts nothing", ctx do
      {key, sprite_raw} = insert_sprite_api_key(ctx.user)
      other = insert_active_user()
      insert_conversation(user_id: other.id, depth: ctx.max, callback_api_key_id: key.id)

      body =
        ctx.conn
        |> authed_with_key(sprite_raw)
        |> post_json("/api/conversations", %{"agent_id" => ctx.agent.id})
        |> json_response(404)

      assert body["error"] == "parent_conversation_not_found"
    end
  end

  describe "POST /api/conversations with environment_id (#783)" do
    setup %{user: user} do
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      agent_env = insert_env(user_id: user.id)
      other_env = insert_env(user_id: user.id)
      agent = insert_agent(user_id: user.id, environment_id: agent_env.id)
      %{agent: agent, other_env: other_env}
    end

    test "provisions from the named environment and reports it", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent,
      other_env: other_env
    } do
      body = %{"agent_id" => agent.id, "environment_id" => other_env.id}

      data =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", body)
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["environment_id"] == other_env.id
    end

    test "a foreign environment is a 404 — indistinguishable from an unknown one", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      foreign = insert_env(user_id: insert_active_user().id)

      for id <- [foreign.id, Ecto.UUID.generate()] do
        assert conn
               |> authed_with_key(raw_key)
               |> post_json("/api/conversations", %{
                 "agent_id" => agent.id,
                 "environment_id" => id
               })
               |> json_response(404)
               |> Map.fetch!("error") == "environment_not_found"
      end
    end

    test "an environment outside the agent's allowlist is a 422 environment_not_allowed", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent,
      other_env: other_env
    } do
      {:ok, agent} = Fountain.Agents.update_agent(agent, %{allowed_environment_ids: []})

      resp =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "environment_id" => other_env.id
        })
        |> json_response(422)

      assert resp["error"] == "environment_not_allowed"
    end
  end

  # ADR 0061. A model is checked, not looked up: there is no allowlist and
  # nothing to 404, so the shapes are the stored value and the two refusals.
  describe "POST /api/conversations with model (ADR 0061)" do
    setup %{user: user} do
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      %{agent: insert_agent(user_id: user.id, runtime: "claude")}
    end

    defp create_on_model(conn, raw_key, body) do
      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/conversations", body)
    end

    test "runs and reports the named model", %{conn: conn, raw_key: raw_key, agent: agent} do
      data =
        conn
        |> create_on_model(raw_key, %{
          "agent_id" => agent.id,
          "model" => "anthropic/claude-sonnet-5"
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["model"] == "anthropic/claude-sonnet-5"

      data =
        conn
        |> create_on_model(raw_key, %{"agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["model"] == nil
    end

    test "a model the runtime cannot run is a 422 model_invalid", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      resp =
        conn
        |> create_on_model(raw_key, %{"agent_id" => agent.id, "model" => "openai/gpt-5"})
        |> json_response(422)

      assert resp["error"] == "model_invalid"
      assert resp["message"] =~ "anthropic/"
    end

    test "a channel resume on a different model is a 409 conversation_model_differs", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-0061"}

      conn
      |> create_on_model(raw_key, Map.put(body, "model", "anthropic/claude-sonnet-5"))
      |> json_response(201)

      resp =
        conn
        |> create_on_model(raw_key, Map.put(body, "model", "anthropic/claude-fable-5-1"))
        |> json_response(409)

      assert resp["error"] == "conversation_model_differs"
      assert resp["model"] == "anthropic/claude-sonnet-5"
    end
  end

  describe "POST /api/conversations with channel_id (#774)" do
    # A client that forgets its sessions — a restarted buzz-acp — must land back
    # on the same conversation, and so the same sandbox, rather than opening a
    # fresh one per restart. The key is opaque; Fountain only matches it.
    setup %{user: user} do
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      %{agent: insert_agent(user_id: user.id)}
    end

    defp create(conn, raw_key, body) do
      conn |> authed_with_key(raw_key) |> post_json("/api/conversations", body)
    end

    test "first call creates (201), second resumes the same conversation (200, meta.resumed)",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-abc"}

      first = create(conn, raw_key, body) |> json_response(201)
      assert first["data"]["channel_id"] == "chan-abc"
      assert first["meta"]["resumed"] == false

      second = create(conn, raw_key, body) |> json_response(200)
      assert second["data"]["id"] == first["data"]["id"]
      assert second["meta"]["resumed"] == true

      # Only one conversation exists for it.
      assert [_] = Fountain.Conversations.list_conversations(agent.user_id)
    end

    test "different channels, and different vaults on one channel, are different conversations",
         %{conn: conn, raw_key: raw_key, agent: agent, user: user} do
      vault = insert_vault(user_id: user.id)

      a =
        create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-a"})
        |> json_response(201)

      b =
        create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-b"})
        |> json_response(201)

      a_vault =
        create(conn, raw_key, %{
          "agent_id" => agent.id,
          "channel_id" => "chan-a",
          "vault_id" => vault.id
        })
        |> json_response(201)

      ids = [a, b, a_vault] |> Enum.map(& &1["data"]["id"])
      assert length(Enum.uniq(ids)) == 3

      # And each binding resumes its own.
      assert create(conn, raw_key, %{"agent_id" => agent.id, "channel_id" => "chan-a"})
             |> json_response(200)
             |> get_in(["data", "id"]) == a["data"]["id"]
    end

    test "a terminated conversation is not resumed — a new one takes over the binding",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-t"}
      first = create(conn, raw_key, body) |> json_response(201)

      conv = Fountain.Conversations._unsafe_get_conversation!(first["data"]["id"])
      {:ok, _} = Fountain.Conversations.update_conversation(conv, %{status: "terminated"})

      second = create(conn, raw_key, body) |> json_response(201)
      refute second["data"]["id"] == first["data"]["id"]

      # From now on the new one is what resumes.
      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               second["data"]["id"]
    end

    test "fresh: true opens a new conversation despite the binding, and it takes over",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-r"}
      first = create(conn, raw_key, body) |> json_response(201)

      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               first["data"]["id"]

      # The harness's owner rotated the channel (ACP _meta.freshSession).
      rotated = create(conn, raw_key, Map.put(body, "fresh", true)) |> json_response(201)
      refute rotated["data"]["id"] == first["data"]["id"]
      assert rotated["data"]["channel_id"] == "chan-r"
      assert rotated["meta"]["resumed"] == false

      # From now on the new one is what an ordinary session/new resumes, and
      # the old one is unbound (not terminated — it may be mid-turn).
      assert create(conn, raw_key, body) |> json_response(200) |> get_in(["data", "id"]) ==
               rotated["data"]["id"]

      old = Fountain.Conversations._unsafe_get_conversation!(first["data"]["id"])
      assert old.channel_id == nil
      refute old.status in ["terminated", "failed"]

      # fresh: false / absent / a non-boolean does not rotate.
      assert create(conn, raw_key, Map.put(body, "fresh", false))
             |> json_response(200)
             |> get_in(["data", "id"]) == rotated["data"]["id"]

      # Without a channel key fresh is meaningless — creates like any other.
      assert %{"data" => %{"channel_id" => nil}} =
               create(conn, raw_key, %{"agent_id" => agent.id, "fresh" => true})
               |> json_response(201)
    end

    test "another user's binding is invisible", %{conn: conn, agent: agent} do
      other = insert_active_user()
      {_k, other_key} = insert_api_key(other)
      other_agent = insert_agent(user_id: other.id)

      mine = create(conn, other_key, %{"agent_id" => other_agent.id, "channel_id" => "shared"})
      assert json_response(mine, 201)

      # Same channel key, different tenant and agent: a fresh conversation.
      {_k, my_key} = insert_api_key(Fountain.Repo.get!(Fountain.Accounts.User, agent.user_id))

      assert create(conn, my_key, %{"agent_id" => agent.id, "channel_id" => "shared"})
             |> json_response(201)
    end

    test "without channel_id nothing changes: every call creates", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      a = create(conn, raw_key, %{"agent_id" => agent.id}) |> json_response(201)
      b = create(conn, raw_key, %{"agent_id" => agent.id}) |> json_response(201)
      refute a["data"]["id"] == b["data"]["id"]
      assert a["data"]["channel_id"] == nil
    end
  end

  describe "POST /api/conversations with images" do
    test "delivers opening text and image bytes when returning 201",
         %{conn: conn, user: user, raw_key: raw_key} do
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, self()}
      end)

      image_data = Base.encode64("fake-image-bytes")

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "prompt" => "Review",
          "images" => [%{"media_type" => "image/png", "data" => image_data}]
        })

      assert json_response(conn, 201)

      assert_received {:"$gen_cast",
                       {:initial_prompt, "Review", [image],
                        [
                          prompt_receipt_id: _receipt_id,
                          response_timing: %{path: "cold", started_mono: _started}
                        ]}}

      assert image == %{media_type: "image/png", data: "fake-image-bytes"}
    end

    test "images without opening text are refused before reserving a sandbox", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)
      reject_server_start()

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "images" => [%{"media_type" => "image/png", "data" => Base.encode64("bytes")}]
        })

      assert json_response(conn, 422)["error"] == "invalid_prompt"
      assert Fountain.Repo.aggregate(Fountain.Conversations.Conversation, :count) == 0
      assert Fountain.Repo.aggregate(Fountain.Conversations.Sandbox, :count) == 0
    end

    test "returns 201 with conversation when no images provided (decode_images [] branch)", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      agent = insert_agent(user_id: user.id)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      conn =
        conn
        |> authed_with_key(raw_key)
        |> post_json("/api/conversations", %{
          "agent_id" => agent.id,
          "images" => []
        })

      assert json_response(conn, 201)
    end
  end

  describe "GET /api/conversations?limit=" do
    test "caps the page at the most recently updated conversations", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      older = insert_conversation(user_id: user.id)
      newer = insert_conversation(user_id: user.id)

      # updated_at is the sort key; make the order unambiguous.
      later =
        DateTime.utc_now()
        |> DateTime.add(60, :second)
        |> DateTime.truncate(:second)

      newer |> Ecto.Changeset.change(updated_at: later) |> Fountain.Repo.update!()

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations?limit=1")

      body = json_response(conn, 200)
      assert [%{"id" => id}] = body["data"]
      assert id == newer.id
      refute id == older.id
    end

    test "without a limit the whole list comes back, as before", %{
      conn: conn,
      user: user,
      raw_key: raw_key
    } do
      for _ <- 1..3, do: insert_conversation(user_id: user.id)

      conn = conn |> authed_with_key(raw_key) |> get("/api/conversations")
      assert length(json_response(conn, 200)["data"]) == 3
    end

    test "a limit outside 1..500 is refused, not clamped", %{conn: conn, raw_key: raw_key} do
      for bad <- ["0", "501", "ten"] do
        conn = conn |> authed_with_key(raw_key) |> get("/api/conversations?limit=#{bad}")
        assert conn.status in [400, 422], "limit=#{bad} answered #{conn.status}"
      end
    end
  end

  # ADR 0097 step 1: a launch may name the working directory its agent runs
  # in, and every conversation launched now gets a config home of its own.
  describe "POST /api/conversations with cwd (ADR 0097)" do
    setup %{user: user} do
      stub_server_start(fn _s, _spec -> {:ok, spawn(fn -> :ok end)} end)
      %{agent: insert_agent(user_id: user.id, runtime: "claude")}
    end

    defp create_with(conn, raw_key, body) do
      conn
      |> authed_with_key(raw_key)
      |> post_json("/api/conversations", body)
    end

    test "is stored normalised, fixed with a config home of the conversation's own, and served",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      data =
        conn
        |> create_with(raw_key, %{"agent_id" => agent.id, "cwd" => "/home/sprite/work/app/"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["cwd"] == "/home/sprite/work/app"

      conv = Fountain.Conversations._unsafe_get_conversation!(data["id"])
      assert conv.cwd == "/home/sprite/work/app"
      assert conv.config_home == "/home/sprite/.managoat/c/#{conv.id}"
    end

    test "omitted, the runtime's default is served and nil stored", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      data =
        conn
        |> create_with(raw_key, %{"agent_id" => agent.id})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["cwd"] == "/home/sprite"
      conv = Fountain.Conversations._unsafe_get_conversation!(data["id"])
      assert conv.cwd == nil
      assert conv.config_home == "/home/sprite/.managoat/c/#{conv.id}"
    end

    test "a path outside the sandbox home is a 422 naming the field, before anything launches",
         %{conn: conn, raw_key: raw_key, agent: agent} do
      reject(&Fountain.Machines.Provision.reserve/1)

      for cwd <- ["/etc", "relative", "/home/sprite/.managoat/c/x", "/tmp/x"] do
        resp =
          conn
          |> create_with(raw_key, %{"agent_id" => agent.id, "cwd" => cwd})
          |> json_response(422)

        assert resp["error"] == "validation_failed", cwd
        assert [message] = resp["errors"]["cwd"], cwd
        assert is_binary(message)
      end
    end

    test "a cwd that is not a string is refused at the cast, naming the field", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      resp =
        conn
        |> create_with(raw_key, %{"agent_id" => agent.id, "cwd" => 42})
        |> json_response(422)

      assert resp["error"] == "validation_failed"
      assert Map.has_key?(resp["errors"], "cwd")
    end

    test "a gemini agent may also run under /tmp", %{conn: conn, raw_key: raw_key, user: user} do
      agent = insert_agent(user_id: user.id, runtime: "gemini", model: "google/gemini-2.5-pro")

      data =
        conn
        |> create_with(raw_key, %{"agent_id" => agent.id, "cwd" => "/tmp/project"})
        |> json_response(201)
        |> Map.fetch!("data")

      assert data["cwd"] == "/tmp/project"
    end

    test "a channel resume must name the same cwd, or none", %{
      conn: conn,
      raw_key: raw_key,
      agent: agent
    } do
      body = %{"agent_id" => agent.id, "channel_id" => "chan-0097", "cwd" => "/home/sprite/a"}
      first = conn |> create_with(raw_key, body) |> json_response(201) |> Map.fetch!("data")

      again = conn |> create_with(raw_key, body) |> json_response(200) |> Map.fetch!("data")
      assert again["id"] == first["id"]

      bare = conn |> create_with(raw_key, Map.delete(body, "cwd")) |> json_response(200)
      assert bare["data"]["id"] == first["id"]

      resp =
        conn
        |> create_with(raw_key, Map.put(body, "cwd", "/home/sprite/b"))
        |> json_response(422)

      assert resp["error"] == "validation_failed"
      assert [message] = resp["errors"]["cwd"]
      assert message =~ "/home/sprite/a"
    end
  end
end
