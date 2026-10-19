defmodule FountainWeb.EventsStreamTest do
  @moduledoc """
  `GET /api/events/stream` — every conversation on one connection — and the
  `?blocks=true` read-model on `/events` and the per-conversation stream.
  Same fast-loop technique as `SseStreamTest`.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Phoenix.ConnTest, only: [build_conn: 0, get: 2, json_response: 2]

  @endpoint FountainWeb.Endpoint

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)

    previous = {
      Application.get_env(:fountain, :sse_heartbeat_ms),
      Application.get_env(:fountain, :sse_idle_timeout_ms)
    }

    on_exit(fn ->
      {hb, idle} = previous

      if hb,
        do: Application.put_env(:fountain, :sse_heartbeat_ms, hb),
        else: Application.delete_env(:fountain, :sse_heartbeat_ms)

      if idle,
        do: Application.put_env(:fountain, :sse_idle_timeout_ms, idle),
        else: Application.delete_env(:fountain, :sse_idle_timeout_ms)
    end)

    Application.put_env(:fountain, :sse_heartbeat_ms, 60_000)
    Application.put_env(:fountain, :sse_idle_timeout_ms, 1_500)

    Ecto.Adapters.SQL.Sandbox.mode(Fountain.Repo, {:shared, self()})

    {:ok, user: user, raw_key: raw_key}
  end

  test "shutdown closes the account stream without waiting for its heartbeat", %{raw_key: key} do
    Application.put_env(:fountain, :sse_idle_timeout_ms, 60_000)
    send(self(), :fountain_shutdown)
    conn = authed_with_key(build_conn(), key) |> get("/api/events/stream")
    assert conn.status == 200
    assert conn.resp_body =~ ": connected"
  end

  defp acp_text(text) do
    Jason.encode!(%{
      "jsonrpc" => "2.0",
      "method" => "session/update",
      "params" => %{
        "sessionId" => "s",
        "update" => %{
          "sessionUpdate" => "agent_message_chunk",
          "content" => %{"type" => "text", "text" => text}
        }
      }
    })
  end

  defp publish(conv, attrs) do
    ev = insert_log_event(conv, attrs)
    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv.id}", {:log_event, ev})
    ev
  end

  defp stream_async(raw_key, path, headers \\ []) do
    parent = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Fountain.Repo, parent, self())

      conn =
        Enum.reduce(headers, authed_with_key(build_conn(), raw_key), fn {k, v}, c ->
          Plug.Conn.put_req_header(c, k, v)
        end)

      Phoenix.ConnTest.dispatch(conn, @endpoint, :get, path)
    end)
  end

  defp await_stream_start(user_id) do
    parent = self()

    stub(Fountain.Conversations, :list_conversations, fn id ->
      Mimic.call_original(Fountain.Conversations, :list_conversations, [id])
    end)

    expect(Fountain.Conversations, :list_conversations, fn ^user_id ->
      conversations = Mimic.call_original(Fountain.Conversations, :list_conversations, [user_id])
      send(parent, {:stream_discovery, self()})

      receive do
        :continue_discovery -> conversations
      end
    end)
  end

  defp release_stream(task) do
    allow(Fountain.Conversations, self(), task.pid)
    assert_receive {:stream_discovery, pid}, 2_000
    send(pid, :continue_discovery)
    pid
  end

  describe "GET /api/events/stream" do
    test "events from owned conversations, including durable terminal history; foreign ones excluded",
         %{
           user: user,
           raw_key: key
         } do
      a = insert_conversation(user_id: user.id, status: "idle")
      b = insert_conversation(user_id: user.id, status: "running")
      dead = insert_conversation(user_id: user.id, status: "terminated")
      foreign = insert_conversation(user_id: insert_verified_user().id, status: "idle")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      publish(dead, %{kind: "output", stream: "acp", data: "from-dead"})
      publish(a, %{kind: "output", stream: "acp", data: "from-a"})
      publish(b, %{kind: "output", stream: "acp", data: "from-b"})
      publish(foreign, %{kind: "output", stream: "acp", data: "from-foreign"})

      conn = Task.await(task, 5_000)
      assert conn.status == 200
      assert String.starts_with?(conn.resp_body, ": connected\n\n")
      assert conn.resp_body =~ "from-a"
      assert conn.resp_body =~ "from-b"
      assert conn.resp_body =~ "from-dead"
      refute conn.resp_body =~ "from-foreign"

      [payload] =
        Regex.run(~r/data: (\{[^\n]*from-a[^\n]*\})/, conn.resp_body, capture: :all_but_first)

      decoded = Jason.decode!(payload)
      assert decoded["conversation_id"] == a.id

      # #2297: the frame this stream actually sends matches the schema the
      # operation now declares, not just the bare string it used to.
      assert FountainWeb.SchemaGuard.validate_value(FountainWeb.Schemas.StreamLogEvent, decoded) ==
               :ok
    end

    test "Last-Event-ID replays what was missed across conversations", %{user: user, raw_key: key} do
      a = insert_conversation(user_id: user.id, status: "idle")
      b = insert_conversation(user_id: user.id, status: "idle")
      seen = insert_log_event(a, %{kind: "output", stream: "acp", data: "seen"})
      insert_log_event(b, %{kind: "output", stream: "acp", data: "missed-b"})
      insert_log_event(a, %{kind: "output", stream: "acp", data: "missed-a"})

      conn =
        stream_async(key, "/api/events/stream", [{"last-event-id", to_string(seen.id)}])
        |> Task.await(5_000)

      refute conn.resp_body =~ "\"seen\""
      assert conn.resp_body =~ "missed-b"
      assert conn.resp_body =~ "missed-a"
    end

    test "a sidebar ping becomes one debounced `conversations` event and follows new ones", %{
      user: user,
      raw_key: key
    } do
      insert_conversation(user_id: user.id, status: "idle")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      new = insert_conversation(user_id: user.id, status: "idle")

      for _ <- 1..5,
          do:
            Phoenix.PubSub.broadcast(
              Fountain.PubSub,
              "sidebar:#{user.id}",
              {:sidebar_update, user.id}
            )

      # Past the 1 s debounce: the refollow ran, the new conversation is subscribed.
      Process.sleep(1_300)
      publish(new, %{kind: "output", stream: "acp", data: "from-new"})

      conn = Task.await(task, 6_000)
      assert length(Regex.scan(~r/event: conversations\n/, conn.resp_body)) == 1
      assert conn.resp_body =~ "from-new"

      # #2297: the `conversations` frame is a StreamSignal, not a StreamLogEvent
      # — it carries no `kind`/`ts`, which the operation's declared response
      # union now has to account for.
      [payload] =
        Regex.run(~r/event: conversations\ndata: (\{[^\n]*\})/, conn.resp_body,
          capture: :all_but_first
        )

      decoded = Jason.decode!(payload)

      assert FountainWeb.SchemaGuard.validate_value(FountainWeb.Schemas.StreamSignal, decoded) ==
               :ok

      assert {:error, _} =
               FountainWeb.SchemaGuard.validate_value(FountainWeb.Schemas.StreamLogEvent, decoded)
    end

    @tag :filtered_cursor_regression
    test "filtered rows advance the durable cursor and stale notifications do not rescan them", %{
      user: user,
      raw_key: key
    } do
      conv = insert_conversation(user_id: user.id, status: "idle")
      old = insert_log_event(conv, %{kind: "output", stream: "stdout", data: "old"})
      await_stream_start(user.id)
      task = stream_async(key, "/api/events/stream?streams=stage")
      allow(Fountain.Conversations, self(), task.pid)
      assert_receive {:stream_discovery, pid}, 2_000
      hidden = insert_log_event(conv, %{kind: "output", stream: "stderr", data: "filtered-out"})
      parent = self()

      expect(Fountain.Conversations, :list_user_log_events, fn user_id, after_id ->
        assert user_id == user.id
        assert after_id == old.id
        Mimic.call_original(Fountain.Conversations, :list_user_log_events, [user_id, after_id])
      end)

      expect(Fountain.Conversations, :list_user_log_events, fn user_id, after_id ->
        assert user_id == user.id
        assert after_id == hidden.id
        send(parent, :advanced_filtered_cursor)
        Mimic.call_original(Fountain.Conversations, :list_user_log_events, [user_id, after_id])
      end)

      send(pid, :continue_discovery)
      assert_receive :advanced_filtered_cursor, 2_000
      send(pid, {:log_event, hidden})
      conn = Task.await(task, 5_000)
      refute conn.resp_body =~ "filtered-out"
      refute conn.resp_body =~ "event: log"
    end

    @tag :discovery_regression
    test "a fast failure before discovery is replayed before a newer followed event", %{
      user: user,
      raw_key: key
    } do
      active = insert_conversation(user_id: user.id, status: "idle")
      old = insert_log_event(active, %{kind: "output", stream: "stdout", data: "old-history"})
      await_stream_start(user.id)
      task = stream_async(key, "/api/events/stream?blocks=true&streams=stage,acp")
      pid = release_stream(task)

      fast = insert_conversation(user_id: user.id, status: "failed")
      started = insert_log_event(fast, %{kind: "stage", stage: "provision", state: "started"})
      hidden = insert_log_event(fast, %{kind: "output", stream: "stderr", data: "filtered-out"})

      failed =
        insert_log_event(fast, %{
          kind: "stage",
          stage: "provision",
          state: "failed",
          data: "fast-failure"
        })

      newer =
        insert_log_event(active, %{kind: "output", stream: "acp", data: acp_text("newer-output")})

      foreign = insert_conversation(user_id: insert_verified_user().id)
      insert_log_event(foreign, %{kind: "output", stream: "acp", data: "foreign-output"})

      # Deliver a higher-id notification before discovery. A global cursor
      # advanced directly from that notification loses the fast failure.
      send(pid, {:log_event, newer})
      send(pid, :refollow)
      send(pid, {:log_event, failed})
      send(pid, {:log_event, newer})
      conn = Task.await(task, 5_000)

      ids =
        Regex.scan(~r/^id: (\d+)$/m, conn.resp_body)
        |> Enum.map(fn [_, id] -> String.to_integer(id) end)

      assert ids == [started.id, failed.id, newer.id]
      refute old.id in ids
      refute hidden.id in ids
      assert conn.resp_body =~ "fast-failure"
      assert conn.resp_body =~ ~s("body":"newer-output")
      refute conn.resp_body =~ "foreign-output"
    end

    @tag :discovery_regression
    test "discovery replays a new finished conversation even with no live notifications", %{
      user: user,
      raw_key: key
    } do
      await_stream_start(user.id)
      task = stream_async(key, "/api/events/stream")
      pid = release_stream(task)
      fast = insert_conversation(user_id: user.id, status: "failed")

      event =
        insert_log_event(fast, %{
          kind: "stage",
          stage: "provision",
          state: "failed",
          data: "missed-at-subscribe"
        })

      send(pid, :refollow)
      conn = Task.await(task, 5_000)
      assert conn.resp_body =~ "id: #{event.id}"
      assert conn.resp_body =~ "missed-at-subscribe"
    end

    @tag :discovery_regression
    test "reconnect replays finished conversations in order across more than one page", %{
      user: user,
      raw_key: key
    } do
      finished = insert_conversation(user_id: user.id, status: "terminated")
      marker = insert_log_event(finished, %{kind: "output", stream: "stdout", data: "seen"})

      events =
        for n <- 1..501,
            do:
              insert_log_event(finished, %{kind: "output", stream: "stdout", data: "replay-#{n}"})

      conn =
        stream_async(key, "/api/events/stream", [{"last-event-id", to_string(marker.id)}])
        |> Task.await(5_000)

      ids =
        Regex.scan(~r/^id: (\d+)$/m, conn.resp_body)
        |> Enum.map(fn [_, id] -> String.to_integer(id) end)

      assert ids == Enum.map(events, & &1.id)
    end

    test "?blocks=true adds the server-parsed blocks per event", %{user: user, raw_key: key} do
      a = insert_conversation(user_id: user.id, status: "idle")
      marker = insert_log_event(a, %{kind: "output", stream: "stdout", data: "m"})
      insert_log_event(a, %{kind: "output", stream: "acp", data: acp_text("hello")})

      conn =
        stream_async(key, "/api/events/stream?blocks=true&streams=acp", [
          {"last-event-id", to_string(marker.id)}
        ])
        |> Task.await(5_000)

      [payload] =
        Regex.run(~r/data: (\{[^\n]*hello[^\n]*\})/, conn.resp_body, capture: :all_but_first)

      assert %{"blocks" => [%{"kind" => "text", "body" => "hello"}]} = Jason.decode!(payload)
    end
  end

  describe "workspace.status" do
    test "carries the caller's workspaces' status changes and no other account's", %{
      user: user,
      raw_key: key
    } do
      mine = insert_workspace(user_id: user.id, implicit: false, name: "mine", status: "ready")
      theirs = insert_workspace(user_id: insert_verified_user().id, implicit: false, name: "x")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      Fountain.Workspaces.publish_status(mine)
      Fountain.Workspaces.publish_status(theirs)

      conn = Task.await(task, 5_000)

      assert [payload] =
               Regex.run(~r/event: workspace.status\ndata: (\{[^\n]*\})/, conn.resp_body,
                 capture: :all_but_first
               )

      assert %{"workspace_id" => id, "status" => "ready", "name" => "mine"} =
               Jason.decode!(payload)

      assert id == mine.id
      refute conn.resp_body =~ theirs.id
    end
  end

  describe "workspace.setup (#3009)" do
    test "carries the caller's workspaces' setup output and no other account's", %{
      user: user,
      raw_key: key
    } do
      mine = insert_workspace(user_id: user.id, implicit: false, name: "mine")
      other = insert_verified_user()
      theirs = insert_workspace(user_id: other.id, implicit: false, name: "x")

      task = stream_async(key, "/api/events/stream")
      Process.sleep(300)

      frame = fn workspace, line ->
        %{
          workspace_id: workspace.id,
          sandbox_id: Ecto.UUID.generate(),
          step: "packages",
          status: "running",
          lines: [line],
          omitted_lines: 0,
          at: DateTime.utc_now()
        }
      end

      Fountain.Workspaces.publish_setup(user.id, frame.(mine, "Setting up jq"))
      Fountain.Workspaces.publish_setup(other.id, frame.(theirs, "not yours"))

      conn = Task.await(task, 5_000)

      assert [payload] =
               Regex.run(~r/event: workspace.setup\ndata: (\{[^\n]*\})/, conn.resp_body,
                 capture: :all_but_first
               )

      assert %{
               "workspace_id" => id,
               "step" => "packages",
               "status" => "running",
               "lines" => ["Setting up jq"],
               "omitted_lines" => 0
             } = Jason.decode!(payload)

      assert id == mine.id
      refute conn.resp_body =~ "not yours"
    end
  end

  describe "?blocks=true on the per-conversation surfaces" do
    test "GET /events adds blocks for output events and [] for stage events", %{
      user: user,
      raw_key: key
    } do
      conv =
        insert_conversation(
          user_id: user.id,
          agent: insert_agent(user_id: user.id, runtime: "claude")
        )

      insert_log_event(conv, %{kind: "output", stream: "acp", data: acp_text("hi")})

      legacy =
        Jason.encode!(%{
          "type" => "assistant",
          "message" => %{"content" => [%{"type" => "text", "text" => "old style"}]}
        })

      insert_log_event(conv, %{kind: "output", stream: "stdout", data: legacy})
      insert_log_event(conv, %{kind: "stage", stream: "", stage: "turn", state: "done"})

      body =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}/events?blocks=true")
        |> json_response(200)

      assert [
               %{"blocks" => [%{"kind" => "text", "body" => "hi"}]},
               %{"blocks" => [], "data" => ^legacy, "stream" => "stdout"},
               %{"blocks" => []}
             ] =
               body["data"]

      # Without the flag the field is absent, so existing clients see the same rows.
      plain =
        build_conn()
        |> authed_with_key(key)
        |> get("/api/conversations/#{conv.id}/events")
        |> json_response(200)

      refute Map.has_key?(hd(plain["data"]), "blocks")
    end

    test "the per-conversation stream adds blocks with ?blocks=true", %{user: user, raw_key: key} do
      conv =
        insert_conversation(
          user_id: user.id,
          agent: insert_agent(user_id: user.id, runtime: "claude")
        )

      insert_log_event(conv, %{kind: "output", stream: "acp", data: acp_text("streamed")})

      conn =
        stream_async(key, "/api/conversations/#{conv.id}/stream?wait=false&blocks=true")
        |> Task.await(5_000)

      assert conn.resp_body =~ ~s("blocks":[{"body":"streamed","kind":"text"}])
    end
  end
end
