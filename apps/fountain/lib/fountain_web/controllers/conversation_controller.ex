defmodule FountainWeb.ConversationController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{ConversationServer, Interruption, Launch, LogEvent}
  alias Fountain.Conversations.{Termination, Wake}
  alias FountainWeb.Audited
  alias FountainWeb.LabelFilter
  alias FountainWeb.SandboxKey
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  # Before the cast, and only where the parameter exists: `label` is a
  # repeated key, and the cast reads query parameters out of Plug, which
  # keeps only the last of them. See the plug's moduledoc.
  plug FountainWeb.Plugs.RepeatedQueryParam, "label" when action in [:index]

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Conversations"])

  operation(:index,
    summary: "List conversations",
    parameters: [
      roots_only: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Exclude sub-conversations (those with a `parent_conversation_id`), " <>
            "leaving only top-level sessions. Defaults to false."
      ],
      agent_id: [
        in: :query,
        type: :string,
        required: false,
        description: "Only this agent's conversations (#832)."
      ],
      sandbox_id: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, format: :uuid},
        required: false,
        description: "Only conversations on this sandbox. Combined with the other filters."
      ],
      channel_id: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Only conversations bound to this channel (the `channel_id` a create " <>
            "named)."
      ],
      status: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated statuses to keep (`idle,terminated`); 400 on a value outside the vocabulary."
      ],
      limit: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :integer, minimum: 1, maximum: 500},
        required: false,
        description:
          "Return at most this many conversations, most recently updated first (1 to 500; " <>
            "400 outside that range). Without it the whole list is returned, which on a " <>
            "busy account is hundreds of rows per call — a client that needs one " <>
            "conversation should filter (`agent_id`, `sandbox_id`, `channel_id`) and cap."
      ],
      label: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :array, items: %OpenApiSpex.Schema{type: :string}},
        style: :form,
        explode: true,
        required: false,
        description:
          "Only conversations carrying these `key:value` labels (#1637). Repeat the " <>
            "parameter to combine them with AND: `?label=env:prod&label=drift:true` keeps " <>
            "the conversations that carry both. `label[]=` is accepted as well. Each value " <>
            "splits on its first colon only, so `label=path:a:b` matches the label `path` " <>
            "with the value `a:b`. 400 `invalid_label_filter` on a value with no colon or " <>
            "an empty key."
      ]
    ],
    responses: [
      ok: {"Conversations", "application/json", Schemas.ConversationListResponse},
      bad_request: {"Unknown status or limit out of range", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid filter", "application/json", Schemas.Error}
    ]
  )

  def index(conn, params) do
    user = conn.assigns.current_user
    roots_only = parse_bool_param(params["roots_only"], false)

    with {:ok, statuses} <- parse_statuses(params["status"]),
         {:ok, limit} <- parse_list_limit(params["limit"]),
         {:ok, labels} <- LabelFilter.from(conn) do
      render(conn, :index,
        conversations:
          Conversations.list_conversations(user.id,
            roots_only: roots_only,
            agent_id: params["agent_id"],
            channel_id: params["channel_id"],
            sandbox_id: params["sandbox_id"],
            status: statuses,
            limit: limit,
            labels: labels
          )
      )
    end
  end

  @max_list_limit 500

  # Absent means the whole list, as it always has; a value outside 1..500 is
  # a 400 rather than a silent clamp, for the same reason as a bad status —
  # a client that asked for 0 or 10,000 should find out.
  defp parse_list_limit(nil), do: {:ok, nil}
  defp parse_list_limit(""), do: {:ok, nil}

  defp parse_list_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n in 1..@max_list_limit -> {:ok, n}
      _ -> {:error, "invalid_limit"}
    end
  end

  # A status the vocabulary does not have is a 400, not a silent "match
  # nothing" (or worse, "match everything"): a client that typos `terminted`
  # should find out.
  defp parse_statuses(nil), do: {:ok, []}
  defp parse_statuses(""), do: {:ok, []}

  defp parse_statuses(s) when is_binary(s) do
    statuses = s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)

    if Enum.all?(statuses, &(&1 in Fountain.Conversations.Conversation.statuses())),
      do: {:ok, statuses},
      else: {:error, "invalid_status"}
  end

  operation(:read,
    summary: "Mark a conversation read",
    description:
      "Sets the conversation's `last_read_at` to now, which is what clears its " <>
        "unread state. Idempotent.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Marked read",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def read(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        :ok = Conversations.mark_read(id, user.id)
        send_resp(conn, :no_content, "")
    end
  end

  operation(:labels,
    summary: "Set a conversation's labels",
    description:
      "Merges `labels` into the conversation's own (#1637). A key the body does not name " <>
        "is left alone, and a key whose value is `null` is removed, so a run can stamp one " <>
        "outcome without reading the rest first.\n\n" <>
        "At most 32 labels survive the merge; a key is at most 64 bytes and a value at most " <>
        "256 bytes. A 422 names the offending key.\n\n" <>
        "The account's own key may label any of its conversations. A sandbox callback token " <>
        "may label **only the conversation it was minted for**; another id is refused with " <>
        "403 `sprite_may_not_label_another_conversation`. An agent inside a turn does not " <>
        "need this route at all: it sends the `_fountain/labels` ACP extension update " <>
        "instead.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body: {"Labels", "application/json", Schemas.ConversationLabelsRequest},
    responses: [
      ok: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden:
        {"A sandbox token labelling another conversation", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid labels", "application/json", Schemas.Error}
    ]
  )

  def labels(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user
    opts = SandboxKey.opts(conn) ++ Audited.attribution(conn)

    with {:ok, conv} <-
           Conversations.set_conversation_labels(id, user.id, params["labels"], opts) do
      # Re-read annotated, so this renders the same conversation object every
      # other conversation route does rather than one with a null turn_count.
      render(conn, :show,
        conversation: Conversations.get_conversation_with_activity(conv.id, user.id)
      )
    end
  end

  operation(:tree,
    summary: "Get the conversation's spawn tree",
    description:
      "Every conversation in the same spawn tree — ancestors and descendants of " <>
        "this one — as flat `{id, source, status, parent_id}` entries. The API is " <>
        "how sub-conversations get created (`X-Managoat-Parent-Conversation-Id`), " <>
        "so this is how an agent that fanned out enumerates what it started " <>
        "without client-side bookkeeping.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation tree", "application/json", Schemas.ConversationTreeResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def tree(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil -> {:error, :not_found}
      _conv -> render(conn, :tree, nodes: Conversations.get_conversation_tree(id, user.id))
    end
  end

  operation(:show,
    summary: "Get a conversation",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Conversation", "application/json", Schemas.ConversationResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    # The annotated variant: a `show` that reported turn_count 0 and a null
    # last_active_at, as the plain fetch would, is worse than not serving
    # the fields at all.
    case Conversations.get_conversation_with_activity(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        render(conn, :show, conversation: conv)
    end
  end

  operation(:turns,
    summary: "List turns in a conversation",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Turns", "application/json", Schemas.TurnListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  operation(:egress,
    summary: "List what the conversation sent out through the egress broker",
    description:
      "The broker's request log for this conversation, newest first: each " <>
        "outbound HTTP request the sandbox made, the host, the service that " <>
        "matched (and so which credential was attached), the status and " <>
        "latency (ADR 0019 gate 4). The log outlives the conversation " <>
        "for `BROKER_LOG_RETENTION_HOURS`.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      limit: [in: :query, type: :integer, description: "1 to 500, default 100"],
      before: [
        in: :query,
        type: :integer,
        description: "Page: the `next` value of the previous page"
      ]
    ],
    responses: [
      ok: {"Egress", "application/json", Schemas.EgressListResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      forbidden: {"The key lacks full scope", "application/json", Schemas.Error}
    ]
  )

  def egress(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        opts = [limit: egress_limit(params["limit"])] ++ egress_before(params["before"])

        {:ok, %{events: events, next: next}} = Fountain.Broker.request_log(conv.id, opts)
        render(conn, :egress, events: events, next: next, brokered: true)
    end
  end

  defp egress_limit(nil), do: 100

  defp egress_limit(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n in 1..500 -> n
      _ -> 100
    end
  end

  defp egress_before(nil), do: []

  defp egress_before(raw) do
    case Integer.parse(to_string(raw)) do
      {n, ""} when n > 0 -> [before: n]
      _ -> []
    end
  end

  def turns(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # Ownership: established by the scoped get_conversation above.
        render(conn, :turns, turns: Conversations._unsafe_list_turns(id))
    end
  end

  @default_event_limit 100
  @max_event_limit 1000
  # The most events one `whole_turns=true` page can hold, whatever `limit` is.
  @max_whole_turn_events 5000

  operation(:events,
    summary: "List a conversation's log events",
    description:
      "The read-model behind the SSE stream. Same rows, same fields, as JSON — " <>
        "fetching or archiving a conversation's output no longer requires an SSE " <>
        "parser. Oldest first, cursor-paginated: pass the previous page's " <>
        "`meta.next_cursor` as `after`. SSE remains the tail/follow mechanism. " <>
        "With `order=desc` the page is the newest events instead, newest first, " <>
        "and `meta.next_cursor` is the page's oldest id, to pass as `before` for " <>
        "the page older than it; add `whole_turns=true` so no page ends inside a " <>
        "turn. `page.newest_cursor` of the first such page is where an SSE follow " <>
        "resumes (`Last-Event-ID`).",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated allow-list of `stdout`, `stderr`, `stage`. " <>
            "Same semantics as the SSE route; omitted means everything."
      ],
      after: [
        in: :query,
        type: :integer,
        required: false,
        description: "Return events with an id greater than this. Defaults to 0."
      ],
      before: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "Return events with an id less than this: the previous `order=desc` page's " <>
            "`meta.next_cursor`. Applies in either order; omitted means no upper bound."
      ],
      order: [
        in: :query,
        schema: %OpenApiSpex.Schema{type: :string, enum: ["asc", "desc"]},
        required: false,
        description:
          "`asc` (the default) pages forward from `after`, oldest first. `desc` pages " <>
            "backward from `before` (or from the newest event), and `data` is newest first."
      ],
      whole_turns: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "With `order=desc`, never end a page inside a turn: when the `limit`th event " <>
            "belongs to a turn that began earlier, the page extends past `limit` to that " <>
            "turn's first event, keeping any events interleaved with it, so a client " <>
            "renders complete turns and `before=<meta.next_cursor>` returns only earlier " <>
            "ones. At most #{@max_whole_turn_events} events: a turn larger than that " <>
            "is cut there, with `page.turn_split: true`, and continues on the next page. " <>
            "Turn-less events (the setup before turn 1) page by `limit` alone. Refused " <>
            "with 422 without `order=desc`. Defaults to false."
      ],
      limit: [
        in: :query,
        type: :integer,
        required: false,
        description:
          "Page size, 1..#{@max_event_limit}. Defaults to #{@default_event_limit}. " <>
            "`whole_turns=true` can return more."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Add `blocks` to each event: its `data` parsed server-side into the " <>
            "structured blocks a transcript renders (text, thinking, tool_use, " <>
            "tool_result, init, result, error, raw) — the same parse the web UI uses, " <>
            "so no client re-implements a runtime's dialect. Defaults to false."
      ],
      prompts: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "With `blocks=true`, fill each turn's `turn`/`started` stage event — whose " <>
            "`blocks` is otherwise always `[]` — with one `prompt` block carrying the " <>
            "prompt that opened that turn. Without it the feed holds only what the " <>
            "runtime wrote, so a client replaying a conversation renders it as a " <>
            "monologue in the agent's voice. No event is added, removed or reordered, " <>
            "so `meta.next_cursor`, `has_more` and the page size are unchanged. A turn " <>
            "whose `origin` is `autonomous` gets no block: nobody typed it. Note that " <>
            "`streams=acp` excludes stage events, and so excludes these prompts with " <>
            "them. Ignored without `blocks=true`. Defaults to false."
      ]
    ],
    responses: [
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      ok: {"Log events", "application/json", Schemas.LogEventListResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def events(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        limit = parse_limit(params["limit"])
        blocks? = parse_bool_param(params["blocks"], false)
        prompts? = parse_bool_param(params["prompts"], false)

        opts = [
          limit: limit,
          after: parse_after(params["after"]),
          before: parse_before(params["before"]),
          streams: parse_streams_param(params["streams"]),
          whole_turns: parse_bool_param(params["whole_turns"], false)
        ]

        # Ownership: established by the scoped get_conversation above.
        case event_page(id, params["order"] || "asc", opts) do
          {:ok, page, order} ->
            render(conn, :events,
              events: page.events,
              has_more: page.has_more,
              turn_split: page.turn_split,
              order: order,
              limit: limit,
              blocks?: blocks?,
              prompts: turn_prompts(id, page.events, blocks? and prompts?)
            )

          {:error, message} ->
            conn
            |> put_status(:unprocessable_entity)
            |> json(%{error: "invalid_parameters", message: message})
        end
    end
  end

  # ownership: only called from events/2, after its scoped get_conversation.
  defp event_page(conversation_id, "desc", opts) do
    page =
      Conversations._unsafe_list_log_events_backward(
        conversation_id,
        Keyword.put(opts, :max_events, @max_whole_turn_events)
      )

    {:ok, page, :desc}
  end

  defp event_page(conversation_id, "asc", opts) do
    if opts[:whole_turns] do
      {:error, "whole_turns requires order=desc."}
    else
      # Forward paging exactly as it has always been. One extra row decides
      # has_more without a second count query.
      # ownership: only called from events/2, after its scoped get_conversation.
      events =
        Conversations._unsafe_list_log_events(conversation_id, opts[:after],
          streams: opts[:streams],
          before: opts[:before],
          limit: opts[:limit] + 1
        )

      {page, has_more?} = split_page(events, opts[:limit])
      {:ok, %{events: page, has_more: has_more?, turn_split: false}, :asc}
    end
  end

  # `turn_id => prompt` for `?prompts=true`, the human's half of the transcript
  # the log feed has no room for.
  #
  # Only the page's own turns are read, and only when a prompt block can
  # actually be rendered. `prompts=true` without `blocks=true` is documented as
  # ignored, `streams=acp` filters the anchors out, and a drained cursor has no
  # events left, so all three collect nothing and never reach PostgreSQL.
  # Hydrating the whole conversation for those would make a client draining a
  # long transcript re-read every turn, and every prompt image, once per page.
  defp turn_prompts(_conversation_id, _page, false), do: %{}

  # ownership: established by the scoped get_conversation/2 above, which is what
  # lets the `turns` action read the same rows the same way. The page's anchors
  # only choose which ids are asked for; the conversation id inside the query is
  # what keeps another tenant's turn id from resolving.
  defp turn_prompts(conversation_id, page, true) do
    Conversations._unsafe_list_turn_prompts(conversation_id, anchor_turn_ids(page))
  end

  # The events that can carry a prompt block: `put_blocks/4` renders one onto a
  # turn's start anchor and nowhere else, so asking for any other turn's prompt
  # would fetch a row no renderer would read.
  defp anchor_turn_ids(page) do
    for %LogEvent{kind: "stage", stage: "turn", state: "started", turn_id: turn_id} <- page,
        turn_id != nil,
        uniq: true,
        do: turn_id
  end

  defp split_page(events, limit) do
    case Enum.split(events, limit) do
      {page, []} -> {page, false}
      {page, _extra} -> {page, true}
    end
  end

  defp parse_limit(nil), do: @default_event_limit
  defp parse_limit(n) when is_integer(n), do: n |> max(1) |> min(@max_event_limit)

  defp parse_limit(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> parse_limit(n)
      :error -> @default_event_limit
    end
  end

  defp parse_after(nil), do: 0
  defp parse_after(n) when is_integer(n) and n > 0, do: n
  defp parse_after(n) when is_integer(n), do: 0
  defp parse_after(s) when is_binary(s), do: s |> parse_last_event_id() |> max(0)

  # nil is no upper bound; an id at or below zero bounds everything out.
  defp parse_before(nil), do: nil
  defp parse_before(""), do: nil
  defp parse_before(n) when is_integer(n), do: n
  defp parse_before(s) when is_binary(s), do: parse_last_event_id(s)

  operation(:create,
    summary: "Start a conversation",
    description:
      "Creates a sandbox + conversation pair, starts the runtime in a fresh sprite, " <>
        "and (if `prompt` is supplied) sends it as turn 1. " <>
        "With `channel_id`, resumes the latest live conversation already bound to that " <>
        "channel for the same agent and vault (200, `meta.resumed: true`) instead of " <>
        "opening a new one (201). " <>
        "`labels` (#1637) are stamped on the new conversation; with `channel_id`, a resume " <>
        "merges them into the conversation it hands back, and a sandbox callback token " <>
        "resuming a conversation it was not minted for is refused with 403, or with 404 " <>
        "when that conversation is outside the token's conversation tree. " <>
        "Pass `X-Managoat-Parent-Conversation-Id` header to record which conversation spawned this one. " <>
        "A start made with a sandbox's own key is always a child of that key's conversation: " <>
        "the header may be left out or name it, and any other value is refused with 404 " <>
        "`parent_conversation_not_found`. " <>
        "A start from inside a sandbox (that header, or the sandbox's own callback token) is one " <>
        "deeper than the conversation it came from, and a start deeper than " <>
        "`CONVERSATION_MAX_DEPTH` is refused with 422 `conversation_depth_exceeded`, naming " <>
        "`depth` and `max_depth`. " <>
        "With `workspace_id`, the conversation runs on that workspace's machine beside its " <>
        "other conversations, with the workspace's environment and vault; see the field.",
    request_body: {"Conversation attrs", "application/json", Schemas.ConversationCreateRequest},
    responses: [
      bad_request: {"Invalid request", "application/json", Schemas.Error},
      conflict:
        {"Conflicting state, changed inference source, or incompatible Codex sandbox credential",
         "application/json", Schemas.Error},
      service_unavailable:
        {"Sandbox unavailable, or every sandbox slot in use (fleet_full)", "application/json",
         Schemas.Error},
      created: {"Conversation", "application/json", Schemas.ConversationResponse},
      ok:
        {"Conversation (resumed by channel_id)", "application/json", Schemas.ConversationResponse},
      forbidden:
        {"A sandbox token labelling the conversation a resume landed on, or naming a " <>
           "workspace (insufficient_scope)", "application/json", Schemas.Error},
      not_found:
        {"Agent or workspace not found, or a parent the caller may not start under " <>
           "(parent_conversation_not_found)", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Validation error, or the spawn chain is too deep (conversation_depth_exceeded)",
         "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]) do
      create_with_images(conn, params, user, images)
    end
  end

  defp create_with_images(conn, params, user, images) do
    # X-Fountain-Parent-Conversation-Id is the name before ADR 0082, which
    # skills and clients in running sandboxes still send; read for a
    # deprecation window (#2776).
    parent_header =
      List.first(
        get_req_header(conn, "x-managoat-parent-conversation-id") ++
          get_req_header(conn, "x-fountain-parent-conversation-id")
      )

    {source, parent_id} = infer_provenance(parent_header)

    params =
      params
      |> Map.put("images", images)
      |> Map.put("source", source)
      |> Map.put("parent_conversation_id", parent_id)
      |> Map.put("user_id", user.id)
      # From the body the cast approved, never from the query string, which
      # this door's `params` also carries and the request schema never sees.
      # The prompts route reads it the same way; see `client_request_id/1`.
      |> Map.put("client_request_id", client_request_id(conn))

    # `SandboxKey.opts/1` rides along because a `channel_id` resume lands on an
    # *existing* conversation and merges this request's labels into it (#1637);
    # without it a sandbox token could relabel any conversation of the tenant
    # by resuming its channel.
    opts = SandboxKey.opts(conn) ++ Audited.attribution(conn)

    with :ok <- workspace_scope(conn, params),
         {:ok, conv, outcome} <- Launch.start_or_resume_conversation(params, opts) do
      # 201 when a conversation was opened; 200 when `channel_id` resumed an
      # existing one (#774). Same body either way, so a client that ignores
      # the status still gets the id it needs.
      conn
      |> put_status(if(outcome == :created, do: :created, else: :ok))
      |> render(:show, conversation: conv, resumed: outcome == :resumed)
    end
  end

  # Naming a workspace takes a full-scope key (ADR 0097): the same refusal
  # the workspace routes give a sandbox's own key, made before the launch,
  # which refuses it again for a sandbox key.
  defp workspace_scope(conn, %{"workspace_id" => id}) when is_binary(id) and id != "" do
    case conn.assigns[:current_api_key] do
      %Fountain.Accounts.ApiKey{} = key ->
        if Fountain.Accounts.ApiKey.may_manage_keys?(key),
          do: :ok,
          else: {:error, :insufficient_scope}

      _no_key ->
        {:error, :insufficient_scope}
    end
  end

  defp workspace_scope(_conn, _params), do: :ok

  operation(:wake,
    summary: "Wake a conversation without a prompt",
    description:
      "Brings the conversation's sandbox and server up without opening a turn, so the " <>
        "next prompt does not wait for them. A suspended sandbox is resumed; one that is " <>
        "gone is replaced with a fresh one, as a prompt would do. Answers `waking` once the " <>
        "checks that need no sandbox pass, and wakes behind the response: the reattach or " <>
        "provision reports on the event stream, and a wake that fails is a `wake` `failed` " <>
        "stage there. A woken conversation is parked again after the usual idle period.\n\n" <>
        "`awake` means the server was already running and nothing was done. Refused as a " <>
        "prompt's wake is: 410 once the conversation has ended, 409 " <>
        "`sandbox_reset_pending` while its machine is being deleted (Managoat finishes " <>
        "the delete itself, and the next prompt builds a new machine), and 503 while the " <>
        "fleet is full. Anything the sandbox itself refuses arrives on the event stream.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Awake or waking", "application/json", Schemas.ConversationWakeResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"Sandbox is being deleted", "application/json", Schemas.Error},
      gone: {"Conversation is terminal", "application/json", Schemas.Error},
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error}
    ]
  )

  def wake(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # Ownership was established by the scoped fetch above.
        with {:ok, status} <- Wake.wake_without_prompt(id, Audited.attribution(conn)) do
          json(conn, %{status: Atom.to_string(status)})
        end
    end
  end

  operation(:answer_request,
    summary: "Answer a permission request or a question",
    description:
      "Answers a request the agent is blocked on.\n\n" <>
        "A `permission_request` block (#940) is answered with `option_id`, which must be " <>
        "one of the `optionId` values that block carried. Never send an option the agent " <>
        "did not offer.\n\n" <>
        "An `elicitation_request` block (#2492) is a form: Claude's `AskUserQuestion`, an " <>
        "MCP server's form, or a prompt to retry a refused request on another model. It is " <>
        "answered with `action`: `accept` with `content` (an object keyed by the block's " <>
        "`schema` properties; a choice must be one the schema offers), `decline`, or " <>
        "`cancel`. An answer that does not fit the form is refused with 422 " <>
        "`invalid_content`.\n\n" <>
        "First answer wins: another attached client, the timeout, or the turn ending " <>
        "may already have resolved it, and all of those return 409. A permission request " <>
        "nobody answers is refused; a form nobody answers is declined. The resolution " <>
        "appears on the stream as a `request` stage event with state `done`. A request " <>
        "never outlives the turn that raised it.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      request_id: [in: :path, type: :string, required: true]
    ],
    request_body: {"Answer", "application/json", Schemas.PermissionAnswerRequest},
    responses: [
      ok: {"Answered", "application/json", Schemas.PermissionAnswerResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"Already resolved", "application/json", Schemas.Error},
      unprocessable_entity:
        {"Unknown option, or an answer that does not fit", "application/json", Schemas.Error},
      forbidden: {"The sandbox may not answer", "application/json", Schemas.Error}
    ]
  )

  def answer_request(conn, %{"conversation_id" => id, "request_id" => request_id} = params) do
    user = conn.assigns.current_user

    case params do
      %{"option_id" => option_id} when is_binary(option_id) and option_id != "" ->
        conn
        |> Audited.attribution()
        |> then(&Conversations.answer_permission_request(id, user.id, request_id, option_id, &1))
        |> answer_response(conn)

      %{"action" => action} when is_binary(action) and action != "" ->
        content = params["content"]

        conn
        |> Audited.attribution()
        |> then(
          &Conversations.answer_elicitation_request(id, user.id, request_id, action, content, &1)
        )
        |> answer_response(conn)

      _ ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "option_id_required",
          message: "send option_id for a permission_request, or action for an elicitation_request"
        })
    end
  end

  defp answer_response(:ok, conn), do: json(conn, %{ok: true})

  # Every "too late" is one status. A client that lost the race to another
  # client and a client answering after the timeout are in the same position:
  # the request is gone and the stream says how it ended.
  defp answer_response({:error, reason}, conn)
       when reason in [:no_pending_permission, :not_running] do
    conn
    |> put_status(:conflict)
    |> json(%{error: "permission_request_resolved"})
  end

  defp answer_response({:error, :unknown_option}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unknown_option", message: "option_id was not offered for this request"})
  end

  # Answering a request with the other kind's body.
  defp answer_response({:error, reason}, conn)
       when reason in [:not_a_permission_request, :not_an_elicitation] do
    message =
      if reason == :not_an_elicitation,
        do: "this request is a permission_request: answer it with option_id",
        else: "this request is an elicitation_request: answer it with action"

    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "wrong_answer_kind", message: message})
  end

  defp answer_response({:error, :unknown_action}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "unknown_action", message: "action must be accept, decline or cancel"})
  end

  defp answer_response({:error, {:invalid_content, why}}, conn) do
    conn
    |> put_status(:unprocessable_entity)
    |> json(%{error: "invalid_content", message: why})
  end

  defp answer_response({:error, :sprite_may_not_answer}, conn) do
    conn
    |> put_status(:forbidden)
    |> json(%{error: "sprite_may_not_answer"})
  end

  defp answer_response({:error, :not_found}, conn) do
    conn |> put_status(:not_found) |> json(%{error: "not_found"})
  end

  # Everything else renders through the FallbackController, for the reason
  # `do_prompt/5` gives: an error shape this function has not learned used to
  # be a FunctionClauseError 500.
  defp answer_response({:error, _} = err, _conn), do: err

  @doc """
  Infer the conversation's `source` and `parent_conversation_id` from
  the `X-Managoat-Parent-Conversation-Id` header value (or `nil` if absent).

  Pure function so the inference logic can be unit-tested without
  going through the full `Conversations.start_conversation/1` pipeline
  (which provisions a real Sprite).
  """
  @spec infer_provenance(String.t() | nil) :: {String.t(), String.t() | nil}
  def infer_provenance(parent_header) do
    case parent_header do
      id when is_binary(id) and byte_size(id) > 0 -> {"agent", id}
      _ -> {"api", nil}
    end
  end

  operation(:prompt,
    summary: "Send another prompt",
    description:
      "Queues a new turn. A conversation whose sandbox is parked or gone is woken " <>
        "behind the response: it answers `queued` once the account and agent checks " <>
        "and the fleet ceiling (`fleet_full`) pass, and a wake that then fails is reported on the event " <>
        "stream as a `wake` `failed` stage, with its `reason` and whether a retry can " <>
        "succeed. A sandbox that is gone is replaced, and the runtime resumes via its " <>
        "session id where its disk survives.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    request_body: {"Prompt", "application/json", Schemas.PromptRequest},
    responses: [
      gone: {"Conversation is terminal", "application/json", Schemas.Error},
      unprocessable_entity: {"Invalid request parameters", "application/json", Schemas.Error},
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      # `sandbox_reset_pending`: the conversation's machine is being deleted
      # (a `destroying` stamp on its row), so there is nothing to wake.
      # Fountain finishes the delete itself, and the next prompt after it
      # builds a new machine. The word predates ADR 0073's removal of reset
      # and stays because clients match on it.
      #
      # `Wake.maybe_reuse_sandbox/1` refuses a destroy-fenced machine with this
      # word, and `Machines.Resume` gives it a second path here (a fence landing
      # between the reuse check and the machine's lease).
      conflict: {"Sandbox is being deleted", "application/json", Schemas.Error},
      ok: {"Queued", "application/json", Schemas.PromptResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      bad_request: {"Busy", "application/json", Schemas.Error}
    ]
  )

  def prompt(conn, %{"conversation_id" => id, "prompt" => prompt} = params) do
    user = conn.assigns.current_user

    with {:ok, images} <- decode_images(params["images"]),
         :ok <- refuse_prompt_session_config(conn) do
      do_prompt(conn, id, prompt, user, images, client_request_id(conn))
    end
  end

  # A prompt's own session config options were removed (ADR 0062, addendum of
  # 2026-10-15, agent only): every turn requests the agent's, as the
  # conversation launched with them. A non-empty map is refused rather than
  # ignored, so a caller that asked for an option learns it would not get it.
  # Read from the cast body for the reason `client_request_id/1` gives.
  defp refuse_prompt_session_config(%{private: %{open_api_spex: %{body_params: body}}}) do
    config =
      case body do
        %{session_config: config} -> config
        %{"session_config" => config} -> config
        _ -> nil
      end

    if Fountain.Agents.SessionConfig.requested?(config),
      do: {:error, :session_config_agent_only},
      else: :ok
  end

  defp refuse_prompt_session_config(_conn), do: :ok

  # `replace_params: false` leaves `params` as Plug built it: the path, the
  # query string and the body in one map. The request schema validates the
  # *body*, so a value that only ever appeared in the query string was never
  # checked against it. Read the field the cast approved (#1406).
  #
  # `?client_request_id=<201 characters>` and `?client_request_id[]=x` both
  # reach `params` untouched: the first was echoed to the caller and then
  # dropped by `PromptDelivery.travelling/1`, naming a correlation no turn
  # could ever carry, and the second rendered a list where `PromptResponse`
  # declares a nullable string.
  defp client_request_id(%{private: %{open_api_spex: %{body_params: body}}}),
    do: from_body(body)

  defp client_request_id(_conn), do: nil

  defp from_body(%{client_request_id: id}), do: id
  defp from_body(%{"client_request_id" => id}), do: id
  defp from_body(_body), do: nil

  defp do_prompt(conn, id, prompt, user, images, client_request_id) do
    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # The id rides in the opts to the turn the prompt opens (#1406),
        # whichever road delivers it; see
        # `Conversations.PromptDelivery`.
        #
        # A parked conversation is woken behind the response (#2561): the
        # wake's refusals that need no provider still answer here, and the
        # rest arrive on the event stream as a `wake` `failed` stage.
        opts =
          Audited.attribution(conn,
            client_request_id: client_request_id,
            wake: :background
          )

        case ConversationServer.send_prompt(id, prompt, images, opts) do
          :ok ->
            json(conn, %{status: "queued", client_request_id: client_request_id})

          {:error, :not_running} ->
            {:error, :not_found}

          {:error, :busy} ->
            {:error, "conversation_busy"}

          # Everything else renders via the FallbackController. This case has
          # had error shapes threaded through it by hand four times (#212,
          # then :gone / :no_agent / changeset in #332), and each one it
          # was missing was a CaseClauseError 500. The fallback owns the
          # error → status mapping; new shapes land there, not here.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:terminate,
    summary: "Terminate a conversation",
    description:
      "Marks the conversation `terminated` and answers. Its sandbox is then destroyed " <>
        "at the provider; it accepts no new work from the moment the request is " <>
        "answered. Idempotent for already-dead conversations.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      no_content: "Terminated",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def terminate(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        # The machine is destroyed behind the response (#2561); the fence
        # that decides it commits first.
        case Termination.terminate_conversation(
               id,
               Audited.attribution(conn, destroy: :background)
             ) do
          :ok -> send_resp(conn, :no_content, "")
          {:error, :not_running} -> {:error, :not_found}
          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err -> err
        end
    end
  end

  operation(:interrupt,
    summary: "Interrupt the running turn",
    description:
      "Ends the turn in flight. Wakes a conversation whose server has died " <>
        "so a turn left `running` behind it can still be closed.\n\n" <>
        "`404` means no such conversation. `409` means the conversation " <>
        "exists but has nothing to interrupt: `no_turn_running` when it is " <>
        "idle between turns, `not_running` when it is terminated or could " <>
        "not be woken.",
    parameters: [conversation_id: [in: :path, type: :string, required: true]],
    responses: [
      service_unavailable: {"Sandbox or fleet unavailable", "application/json", Schemas.Error},
      no_content: "Interrupted",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"Nothing to interrupt", "application/json", Schemas.Error}
    ]
  )

  def interrupt(conn, %{"conversation_id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _ ->
        case Interruption.interrupt(id, Audited.attribution(conn)) do
          :ok ->
            send_resp(conn, :no_content, "")

          # Ownership was established by the fetch above, so a state problem
          # here is a conflict, not a missing row (#1179). `:not_found` is
          # still reachable — the conversation can be deleted between the two
          # calls — and falls through to the FallbackController's 404.
          {:error, :not_running} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "not_running",
              message: "the conversation is not running, so there is no turn to interrupt"
            })

          {:error, :idle} ->
            conn |> put_status(:conflict) |> json(%{error: "no_turn_running"})

          # :provisioning and future shapes render via the FallbackController.
          {:error, _} = err ->
            err
        end
    end
  end

  operation(:delete,
    summary: "Delete a conversation",
    description:
      "Tears down the sprite if alive, then deletes the conversation row " <>
        "(cascades to turns and log events).",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      conv ->
        {:ok, _} = Conversations.delete_conversation(conv, Audited.attribution(conn))
        send_resp(conn, :no_content, "")
    end
  end

  operation(:stream,
    summary: "Stream log events (SSE)",
    description:
      "Server-Sent Events stream of the conversation's log events. The `Last-Event-ID` " <>
        "request header resumes from a known event id; missed events are replayed before " <>
        "the live tail begins. Keep-alive heartbeats every 15s as `: heartbeat` comments.\n\n" <>
        "Each message carries the event id in `id:`, the event's `kind` in `event:` " <>
        "(`output` or `stage`), and a JSON object in `data:` with `kind`, `stream`, " <>
        "`data`, `stage`, `state`, `turn_id` and `ts`. The `data` field is a string: raw " <>
        "output for an `output` event, JSON-encoded metadata for a `stage` one.\n\n" <>
        "**This shape is an interface, not an implementation detail.** Two clients render " <>
        "from it — the web UI and `managoat acp`, the Agent Client Protocol adapter an " <>
        "editor spawns — so changing an event's shape or a stream's meaning breaks a " <>
        "surface outside this repo. See decisions/0015.",
    parameters: [
      conversation_id: [in: :path, type: :string, required: true],
      "Last-Event-ID": [
        in: :header,
        type: :string,
        required: false,
        description:
          "Resume after this event id (integer as string). " <>
            "Missing or unparseable values are treated as 0."
      ],
      # Both load-bearing in the bundled SKILL.md files and undocumented here
      # until now. The values are enumerated from LogEvent.streams/0 by a guard
      # test, because this list has already gone stale once: `acp` shipped in
      # #647 and the description still said "stdout, stderr, stage" while the
      # query filter silently dropped it (#716).
      streams: [
        in: :query,
        type: :string,
        required: false,
        description:
          "Comma-separated subset of `stdout`, `stderr`, `acp` and `stage`. " <>
            "Omitted or empty means everything.\n\n" <>
            "- `stdout` / `stderr` — the runtime process's own output, byte for byte.\n" <>
            "- `acp` — one Agent Client Protocol `session/update` notification per line, " <>
            "stored exactly as the runtime's adapter emitted it. This is what a protocol " <>
            "client forwards to an editor, so it is a compatibility surface (decisions/0015). " <>
            "Only conversations whose runtime speaks ACP have it — see the conversation's " <>
            "`acp` field.\n" <>
            "- `stage` — lifecycle events (`provision`, `setup`, `turn`, `reattach`, " <>
            "`sandbox`, `terminate`) with a `state` and JSON metadata. The terminal " <>
            "`turn`/`done` carries the turn's `stop_reason`.\n\n" <>
            "A name no event carries selects nothing; it is not an error."
      ],
      wait: [
        in: :query,
        type: :string,
        required: false,
        description:
          "`false`/`0` drains the buffered events and closes immediately, " <>
            "rather than holding the connection open for the live tail. " <>
            "Defaults to true."
      ],
      blocks: [
        in: :query,
        type: :boolean,
        required: false,
        description:
          "Add `blocks` to each event payload — its `data` parsed server-side into " <>
            "the structured blocks a transcript renders, as on `/events?blocks=true`. " <>
            "Defaults to false."
      ]
    ],
    responses: [
      ok: {"SSE stream", "text/event-stream", Schemas.StreamLogEvent},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  # Both read from application env so the loop can be driven at test speed.
  # Waiting 15s for a heartbeat and 60s for the idle exit is why none of this
  # had tests: the timings are the behaviour, and the behaviour was unreachable.
  @default_heartbeat_ms 15_000
  @default_idle_timeout_ms 60_000

  defp heartbeat_ms,
    do: Application.get_env(:fountain, :sse_heartbeat_ms, @default_heartbeat_ms)

  defp idle_timeout_ms,
    do: Application.get_env(:fountain, :sse_idle_timeout_ms, @default_idle_timeout_ms)

  def stream(conn, %{"conversation_id" => id} = params) do
    user = conn.assigns.current_user

    case Conversations.get_conversation(id, user.id) do
      nil ->
        {:error, :not_found}

      _conv ->
        last_event_id =
          conn
          |> get_req_header("last-event-id")
          |> List.first()
          |> parse_last_event_id()

        streams = parse_streams_param(params["streams"])
        wait? = parse_bool_param(params["wait"], true)
        blocks? = parse_bool_param(params["blocks"], false)

        if wait? do
          FountainWeb.StreamDrain.subscribe()
          Phoenix.PubSub.subscribe(Fountain.PubSub, "conv:#{id}")
        end

        # A ConversationServer that dies without publishing a terminal
        # stage (a crash, a deploy) would otherwise
        # leave this stream heartbeating forever with no data and no
        # reason to reconnect. Monitoring is best-effort: no server just
        # means an idle/finished conversation being drained from history.
        # The ref is matched exactly in sse_loop — this process holds other
        # monitors (DB ownership among them) whose :DOWN messages must not
        # end the stream.
        monitor_ref =
          if wait? do
            case ConversationServer.whereis(id) do
              pid when is_pid(pid) -> Process.monitor(pid)
              _ -> nil
            end
          end

        conn =
          conn
          |> put_resp_header("content-type", "text/event-stream")
          |> put_resp_header("cache-control", "no-cache")
          |> put_resp_header("connection", "keep-alive")
          |> send_chunked(200)

        # Replay buffered events the client missed.
        {status, conn, last_id} = replay(conn, id, last_event_id, streams, blocks?)

        if wait? and status == :ok do
          Process.send_after(self(), :heartbeat, heartbeat_ms())
          sse_loop(conn, last_id, streams, monitor_ref, blocks?)
        else
          # `?wait=false` → close immediately after replay. Useful when
          # the caller already knows the conversation is finished and
          # just wants to drain the history quickly (no 60s heartbeat
          # window before curl `--max-time` fires).
          conn
        end
    end
  end

  defp parse_bool_param("false", _default), do: false
  defp parse_bool_param("0", _default), do: false
  defp parse_bool_param("true", _default), do: true
  defp parse_bool_param("1", _default), do: true
  defp parse_bool_param(_, default), do: default

  # `?streams=stdout,stderr,stage` — comma-separated allow-list. Empty /
  # missing param = no filter (everything goes through).
  defp parse_streams_param(nil), do: nil
  defp parse_streams_param(""), do: nil

  defp parse_streams_param(s) when is_binary(s) do
    s |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
  end

  # Validation, decode and size cap live in FountainWeb.PromptImages so the
  # LiveView prompt path applies exactly the same checks.
  defp decode_images(images), do: FountainWeb.PromptImages.decode(images)

  defp parse_last_event_id(nil), do: 0
  defp parse_last_event_id(""), do: 0

  defp parse_last_event_id(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> 0
    end
  end

  # Returns `{:ok, conn, last_id}`, or `{:closed, conn, last_id}` when the
  # client went away mid-replay — a routine disconnect (Ctrl-C on a curl, a
  # closed tab, an EventSource reconnect against a long backlog), not an
  # error. This used to `throw` the chunk error with no catch anywhere in
  # the module, producing a crash report and a Sentry event per disconnect.
  defp replay(conn, conv_id, after_id, streams, blocks?) do
    # Ownership: only called from stream/2, after its scoped get_conversation.
    conv_id
    |> Conversations._unsafe_list_log_events(after_id, streams: streams)
    |> Enum.reduce_while({:ok, conn, after_id}, fn ev, {:ok, acc_conn, last_id} ->
      case write_event(acc_conn, ev, blocks?) do
        {:ok, c} -> {:cont, {:ok, c, ev.id}}
        {:error, _} -> {:halt, {:closed, acc_conn, last_id}}
      end
    end)
  end

  # Match a freshly-broadcast event against the same rule the historical
  # replay uses — literally the same function now. This used to be a second
  # copy that had drifted from the query filter, so `?streams=acp` matched
  # live events and no replayed ones.
  defp event_in_streams?(ev, streams), do: Conversations.event_in_streams?(ev, streams)

  defp sse_loop(conn, last_id, streams, monitor_ref, blocks?) do
    receive do
      :fountain_shutdown ->
        conn

      {:log_event, %LogEvent{id: ev_id} = ev} when ev_id > last_id ->
        cond do
          not event_in_streams?(ev, streams) ->
            sse_loop(conn, ev_id, streams, monitor_ref, blocks?)

          true ->
            case write_event(conn, ev, blocks?) do
              {:ok, conn} -> sse_loop(conn, ev_id, streams, monitor_ref, blocks?)
              {:error, _} -> conn
            end
        end

      {:log_event, _stale} ->
        sse_loop(conn, last_id, streams, monitor_ref, blocks?)

      :heartbeat ->
        case Plug.Conn.chunk(conn, ": heartbeat\n\n") do
          {:ok, conn} ->
            Process.send_after(self(), :heartbeat, heartbeat_ms())
            sse_loop(conn, last_id, streams, monitor_ref, blocks?)

          {:error, _} ->
            conn
        end

      {:DOWN, ^monitor_ref, :process, _pid, reason} when is_reference(monitor_ref) ->
        # The conversation server died without publishing a terminal stage.
        # Say so and close, so the client reconnects (and, if the server was
        # rehydrated elsewhere, resumes) instead of receiving heartbeats
        # forever on a topic nothing will publish to again.
        write_server_down_event(conn, reason)
    after
      idle_timeout_ms() ->
        # Long quiet — exit cleanly so the client reconnects.
        conn
    end
  end

  # Synthetic (not persisted, so no SSE id — it must not disturb
  # Last-Event-ID resume) stage event telling the client why the stream is
  # closing. Same payload shape as write_event/2. A clean shutdown is the
  # stage reaching its end ("done"); anything else is a crash
  # ("failed") — the stage vocabulary clients already switch on.
  defp write_server_down_event(conn, reason) do
    state =
      case reason do
        :normal -> "done"
        :shutdown -> "done"
        {:shutdown, _} -> "done"
        _ -> "failed"
      end

    payload =
      Jason.encode!(%{
        kind: "stage",
        stream: "",
        data:
          Jason.encode!(%{
            reason: inspect(reason),
            message: "conversation server exited — reconnect to resume streaming"
          }),
        stage: "server",
        state: state,
        turn_id: nil,
        ts: DateTime.utc_now()
      })

    case Plug.Conn.chunk(conn, "event: stage\ndata: #{payload}\n\n") do
      {:ok, conn} -> conn
      {:error, _} -> conn
    end
  end

  # Add server-parsed ACP blocks when requested.
  defp write_event(conn, %LogEvent{} = ev, blocks?) do
    payload =
      %{
        kind: ev.kind,
        stream: ev.stream,
        data: ev.data,
        stage: LogEvent.rendered_stage(ev),
        state: LogEvent.rendered_state(ev),
        turn_id: ev.turn_id,
        ts: ev.inserted_at
      }
      |> FountainWeb.ConversationJSON.put_blocks(ev, blocks?)
      |> Jason.encode!()

    chunk = "id: #{ev.id}\nevent: #{ev.kind}\ndata: #{payload}\n\n"
    Plug.Conn.chunk(conn, chunk)
  end
end
