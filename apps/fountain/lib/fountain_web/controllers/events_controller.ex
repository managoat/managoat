defmodule FountainWeb.EventsController do
  @moduledoc """
  `GET /api/events/stream`: every conversation of the caller on one SSE
  connection (#813) — what a client that shows a conversation list with live
  status and unread dots needs, instead of one socket per conversation.

  Subscribes to each followed conversation's `conv:<id>` topic and to the
  user's `sidebar:<id>` topic; the latter is pinged on every change to the list (a conversation created,
  titled, read, deleted — and once per output chunk from ConversationServer),
  so it is debounced here into one `conversations` event and one re-follow
  pass per quiet second at most.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.LogEvent
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Conversations"])

  operation(:stream,
    summary: "Stream every conversation's events (SSE)",
    description:
      "One `text/event-stream` carrying the log events of every conversation the " <>
        "caller owns, including conversations that finish before discovery, each payload the shape of " <>
        "`GET /api/conversations/:id/stream` plus `conversation_id`. A `conversations` " <>
        "event (data `{reason: changed}`) is sent, debounced, when the list changes — " <>
        "created, titled, read, deleted, finished — and the stream follows a new " <>
        "conversation on its own; the client re-lists. `Last-Event-ID` replays what was " <>
        "missed across all owned conversations, including finished ones. Without a cursor, " <>
        "only events recorded after connection are sent. `?streams=` filters log events as elsewhere (not `workspace.status`); " <>
        "`?blocks=true` adds server-parsed blocks. A `workspace.status` event (data " <>
        "`{workspace_id, name, status, error}`) is sent when one of the caller's workspaces " <>
        "changes status; it carries no id and is not replayed, so a client that reconnects " <>
        "re-reads its workspaces. Heartbeats every 15 s; closes after " <>
        "60 s idle so the client reconnects. The first byte is a `: connected` comment.",
    parameters: [
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description: "Comma-separated stream allow-list (`stdout,stderr,acp,stage`)."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Add `blocks` to each event payload. Defaults to false."
      ]
    ],
    responses: [
      ok:
        {"SSE stream", "text/event-stream",
         %OpenApiSpex.Schema{
           oneOf: [Schemas.StreamLogEvent, Schemas.StreamSignal, Schemas.StreamWorkspaceStatus]
         }}
    ]
  )

  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000
  @refollow_debounce_ms 1_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, params) do
    user_id = conn.assigns.current_user.id
    last_event_id = conn |> get_req_header("last-event-id") |> List.first() |> parse_id()
    streams = parse_streams(params["streams"])
    blocks? = params["blocks"] in [true, "true", "1"]

    FountainWeb.StreamDrain.subscribe()
    Phoenix.PubSub.subscribe(Fountain.PubSub, "sidebar:#{user_id}")
    # The caller's workspaces' status changes (ADR 0097), live only.
    :ok = Fountain.Workspaces.subscribe(user_id)
    # Take the baseline before listing/subscribing so a rapid new conversation
    # cannot disappear in the discovery window. An explicit cursor includes
    # finished conversations during replay as well.
    last_event_id =
      if last_event_id > 0,
        do: last_event_id,
        else: Conversations.latest_user_log_event_id(user_id)

    followed = follow(user_id, MapSet.new())

    conn =
      conn
      |> put_resp_header("content-type", "text/event-stream")
      |> put_resp_header("cache-control", "no-cache")
      |> put_resp_header("connection", "keep-alive")
      |> send_chunked(200)

    # A first byte straight away — a buffering proxy (Cloudflare) would
    # otherwise hold the headers until the first heartbeat.
    conn =
      case Plug.Conn.chunk(conn, ": connected\n\n") do
        {:ok, conn} -> conn
        {:error, _} -> conn
      end

    state = %{
      user_id: user_id,
      followed: followed,
      last_id: last_event_id,
      streams: streams,
      blocks?: blocks?,
      refollow_pending?: false
    }

    case replay(conn, state) do
      {:ok, conn, last_id} ->
        Process.send_after(self(), :heartbeat, heartbeat_ms())
        sse_loop(conn, %{state | last_id: last_id})

      {:closed, conn, _} ->
        conn
    end
  end

  # Conversation IDs still worth following.
  # Finished ones publish nothing; a conversation that finishes while
  # followed simply goes quiet. Never unsubscribed — the process ends with
  # the request.
  defp follow(user_id, followed) do
    user_id
    |> Conversations.list_conversations()
    |> Enum.reject(&(&1.status in ["terminated", "failed"]))
    |> Enum.reduce(followed, fn conv, acc ->
      unless MapSet.member?(acc, conv.id) do
        Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{conv.id}")
      end

      MapSet.put(acc, conv.id)
    end)
  end

  # Drain the tenant's durable feed in bounded pages. A live notification can
  # have a higher id than an event from a not-yet-followed conversation, so it
  # must trigger the same drain rather than advancing the cursor past that row.
  defp replay(conn, state) do
    events = Conversations.list_user_log_events(state.user_id, state.last_id)

    result =
      Enum.reduce_while(events, {:ok, conn, state.last_id}, fn ev, {:ok, acc, last_id} ->
        # Advance over filtered rows too: otherwise a busy excluded stream is
        # scanned again on every notification until a matching row arrives.
        result =
          if Conversations.event_in_streams?(ev, state.streams),
            do: write_event(acc, ev, state),
            else: {:ok, acc}

        case result do
          {:ok, c} -> {:cont, {:ok, c, ev.id}}
          {:error, _} -> {:halt, {:closed, acc, last_id}}
        end
      end)

    case result do
      {:ok, conn, last_id} when events != [] -> replay(conn, %{state | last_id: last_id})
      result -> result
    end
  end

  defp sse_loop(conn, state) do
    receive do
      :fountain_shutdown ->
        conn

      {:log_event, %LogEvent{id: ev_id}} when ev_id > state.last_id ->
        case replay(conn, state) do
          {:ok, conn, last_id} -> sse_loop(conn, %{state | last_id: last_id})
          {:closed, conn, _} -> conn
        end

      {:log_event, _stale} ->
        sse_loop(conn, state)

      # No id: a workspace's status is not in the durable feed, so it is not
      # replayed; a client that reconnects reads the workspace.
      {:workspace_status, payload} ->
        case Plug.Conn.chunk(conn, "event: workspace.status\ndata: #{Jason.encode!(payload)}\n\n") do
          {:ok, conn} -> sse_loop(conn, state)
          {:error, _} -> conn
        end

      {:sidebar_update, _} ->
        # Coalesce the burst: one refollow + one `conversations` event per
        # quiet second, however many pings arrived.
        if state.refollow_pending? do
          sse_loop(conn, state)
        else
          Process.send_after(self(), :refollow, @refollow_debounce_ms)
          sse_loop(conn, %{state | refollow_pending?: true})
        end

      :refollow ->
        followed = follow(state.user_id, state.followed)
        chunk = "event: conversations\ndata: #{Jason.encode!(%{reason: "changed"})}\n\n"

        with {:ok, conn, last_id} <- replay(conn, state),
             {:ok, conn} <- Plug.Conn.chunk(conn, chunk) do
          sse_loop(conn, %{state | followed: followed, last_id: last_id, refollow_pending?: false})
        else
          {:closed, conn, _} -> conn
          {:error, _} -> conn
        end

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, state)

          {:error, _} ->
            conn
        end
    after
      idle_timeout_ms() -> conn
    end
  end

  defp write_event(conn, %LogEvent{} = ev, state) do
    payload =
      %{
        conversation_id: ev.conversation_id,
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: LogEvent.rendered_stage(ev),
        state: LogEvent.rendered_state(ev),
        duration_ms: ev.duration_ms,
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> FountainWeb.ConversationJSON.put_blocks(ev, state.blocks?)
      |> Jason.encode!()

    Plug.Conn.chunk(conn, "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n")
  end

  defp parse_id(nil), do: 0
  defp parse_id(""), do: 0

  defp parse_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp parse_streams(nil), do: nil
  defp parse_streams(""), do: nil

  defp parse_streams(s) when is_binary(s),
    do: s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
end
