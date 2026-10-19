defmodule Fountain.Conversations do
  @moduledoc """
  Context for sandboxes (sprite lifespans) and conversations (chat histories).

  Sandboxes own a sprite. Conversations live inside a sandbox and own the
  turn-by-turn chat with a particular agent. v1 keeps these 1:1.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Audit

  alias Fountain.Conversations.{
    Blocks,
    Conversation,
    Labels,
    LogEvent,
    Sandbox,
    Turn,
    TurnImage
  }

  alias Fountain.Conversations.Termination
  alias Fountain.Conversations.InferenceResolution
  alias Fountain.Conversations.TurnLocks
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  # Advisory-lock namespace for machine operations, keyed by the workspace (`sandbox_lock_key/1`). Distinct from
  # Quotas' per-user reservation (4315): this one is taken inside a turn
  # start, and the two must never be mistaken for one another.
  @sandbox_lock_namespace 4316
  @log_event_lock_namespace 4332

  # ── on the _unsafe_ prefix ────────────────────────────────────────────────
  #
  # Every function here that does not scope by `user_id` carries the prefix,
  # including the ones whose callers happen to check ownership first. That is
  # the point of a convention: the reader of a call site should not have to go
  # and find out.
  #
  # Several of these were unprefixed until #182 — `get_sandbox/1`,
  # `list_turns/1`, `list_log_events/3` and friends. No call site was wrong, but
  # nothing marked them either, so the audit that makes `_unsafe_` useful had a
  # hole exactly where it mattered least visibly.
  #
  # A legitimate caller is one of: admin surfaces behind `require_admin`,
  # system-level sweeps like the rehydrator and the reaper, or a GenServer that
  # has already established ownership. Anything user-facing wants the scoped
  # variant.

  # ── sandboxes ──────────────────────────────────────────────────────────────────────────

  @doc "List active sandboxes across all tenants (admin use only)."
  def _unsafe_list_sandboxes_admin do
    alias Fountain.Accounts.User

    Repo.all(
      from s in admin_sandboxes(),
        order_by: [desc: s.inserted_at],
        left_join: u in User,
        on: u.id == s.user_id,
        preload: [user: u, conversations: []]
    )
  end

  @doc """
  How many sandboxes `_unsafe_list_sandboxes_admin/0` would return, without
  loading them or their owners.

  Deliberately built on the same query: the admin overview shows this count
  and links to the list, and a count that came from a second definition of
  "active" would disagree with the page it points at. `Quotas` has its own,
  narrower definition (`pending`/`starting`/`ready`) because the fleet ceiling counts sandboxes being paid for, not sandboxes on screen.
  """
  def _unsafe_count_sandboxes_admin, do: Repo.aggregate(admin_sandboxes(), :count, :id)

  defp admin_sandboxes do
    from s in Lease.machines(), where: s.status not in ["terminated", "failed"]
  end

  # Through `Machines.Lease`, so a machine's lease and transition are its
  # workspace's (ADR 0097, step 3b).
  def _unsafe_get_sandbox(id), do: Lease.get(id)

  def _unsafe_get_sandbox!(id),
    do: Lease.get(id) || raise(Ecto.NoResultsError, queryable: Sandbox)

  @doc """
  Load any tenant's conversation for the admin support view (#446).

  Returns the conversation with owner/agent/sandbox preloaded plus turn and
  log-event **counts** — deliberately not the turns or log events themselves.
  The admin surface renders metadata only (status, timing, exit codes); prompt
  and output content stay tenant-private. `_unsafe_list_turn_summaries_admin/1`
  carries the same rule.
  """
  def _unsafe_get_conversation_admin(id) do
    case Repo.get(Conversation, id) do
      nil ->
        nil

      conv ->
        conv = Repo.preload(conv, [:user, :agent, :sandbox])

        turn_count =
          Repo.aggregate(from(t in Turn, where: t.conversation_id == ^id), :count)

        log_event_count =
          Repo.aggregate(from(le in LogEvent, where: le.conversation_id == ^id), :count)

        %{conversation: conv, turn_count: turn_count, log_event_count: log_event_count}
    end
  end

  @doc """
  Turn metadata for the admin support view: numbers, statuses, exit codes and
  timing — never `prompt`. The select list is the privacy boundary; keep
  content columns out of it.
  """
  def _unsafe_list_turn_summaries_admin(conversation_id, limit \\ 100) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [desc: t.turn_number],
        limit: ^limit,
        select: %{
          id: t.id,
          turn_number: t.turn_number,
          status: t.status,
          exit_code: t.exit_code,
          started_at: t.started_at,
          ended_at: t.ended_at,
          inserted_at: t.inserted_at
        }
    )
  end

  # The two statuses a sandbox stops at.
  @terminal_statuses ~w(terminated failed)

  # What a caller may contribute to a sandbox name — the part after this
  # tenant's prefix. See `mint_machine_name/3`. Deliberately narrow: the value
  # becomes a machine name at a provider, and the old code accepted anything.
  @machine_name_suffix ~r/\A[A-Za-z0-9][A-Za-z0-9_-]{0,39}\z/

  # ── conversations ─────────────────────────────────────────────────────────────────────

  @doc """
  Returns all conversations in the same spawn tree as `conversation_id`,
  scoped to `user_id`.

  Each entry is a map with keys: :id, :source, :status, :parent_id

  Returns `[]` when the conversation does not exist or belongs to someone else.

  Every reference to `conversations` carries the tenant predicate. Without it
  the recursion walks straight across tenant boundaries, which leaked
  conversation ids, sources and statuses in both directions: a conversation
  parented onto another tenant's conversation pulled their whole tree into this
  view, and put this one into theirs.

  The root is the furthest *reachable* ancestor rather than the one with a NULL
  parent. For clean data those are the same node. They differ only where a
  foreign parent link already exists in the data, and picking the boundary node
  degrades to "show the part of the tree you own" instead of returning nothing.
  """
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped above); nothing user-controlled is interpolated.
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters
  # ($1/$2 UUIDs dumped below); nothing user-controlled is interpolated.
  def get_conversation_tree(conversation_id, user_id) when is_binary(user_id) do
    sql = """
    WITH RECURSIVE
    ancestors(id, parent_conversation_id, depth) AS (
      SELECT id, parent_conversation_id, 0
      FROM conversations WHERE id = $1 AND user_id = $2
      UNION ALL
      SELECT c.id, c.parent_conversation_id, a.depth + 1
      FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
      -- depth bound: parent links are client-supplied, and a cycle would
      -- otherwise spin this CTE forever.
      WHERE c.user_id = $2 AND a.depth < 100
    ),
    root_row AS (
      SELECT id FROM ancestors ORDER BY depth DESC LIMIT 1
    ),
    tree(id, source, status, parent_id, depth) AS (
      SELECT c.id, c.source, c.status, c.parent_conversation_id, 0
      FROM conversations c, root_row r
      WHERE c.id = r.id AND c.user_id = $2
      UNION ALL
      SELECT c.id, c.source, c.status, c.parent_conversation_id, t.depth + 1
      FROM conversations c
      INNER JOIN tree t ON c.parent_conversation_id = t.id
      WHERE c.user_id = $2 AND t.depth < 100
    )
    SELECT id, source, status, parent_id FROM tree
    """

    with {:ok, conv_uuid} <- Ecto.UUID.dump(conversation_id),
         {:ok, user_uuid} <- Ecto.UUID.dump(user_id) do
      %{rows: rows} = Repo.query!(sql, [conv_uuid, user_uuid])

      Enum.map(rows, fn [id, source, status, parent_id] ->
        %{
          id: load_uuid!(id),
          source: source,
          status: status,
          parent_id: load_uuid(parent_id)
        }
      end)
    else
      _ -> []
    end
  end

  defp load_uuid!(bin) when is_binary(bin) do
    {:ok, str} = Ecto.UUID.load(bin)
    str
  end

  defp load_uuid(nil), do: nil
  defp load_uuid(bin), do: load_uuid!(bin)

  @doc """
  Conversations whose `ConversationServer` would have been running at the
  time of a clean BEAM stop: status `idle` or `running`, with a fully-
  provisioned (`ready`) sandbox.

  `suspended` is deliberately excluded: a parked conversation has no server
  by design and wakes on the next prompt, not at boot — rehydrating every
  parked conversation would start a server (and re-arm an idle clock) for
  each one on every deploy.
  """
  def _unsafe_list_resumable_conversations do
    Repo.all(
      from c in Conversation,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        where: c.status in ["idle", "running"] and s.status == "ready",
        preload: [:sandbox]
    )
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only —
  user-facing endpoints must use the arity-2 variant that takes user_id.
  """
  def _unsafe_get_conversation(id) do
    Conversation
    |> Repo.get(id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc """
  WARNING: lookup by id without owner check. Admin/internal use only.
  """
  def _unsafe_get_conversation!(id) do
    Conversation
    |> Repo.get!(id)
    |> Repo.preload([:sandbox, :agent, :vault, :agent_version])
  end

  @doc """
  Get conversation scoped to user. A foreign, missing or malformed id reads
  as nil.

  Malformed is part of that promise rather than a caller's problem (#1679):
  the id reaches here from a path segment or a header, and an id that is not
  a uuid raises `Ecto.Query.CastError` out of the query, which leaves the
  request as a 500 with a dropped connection instead of the 404 every caller
  of this function already handles. `dump/1` rather than `cast/1` because
  `cast/1` takes any 16-byte binary, so a sixteen-character name would pass
  the guard and raise at the same place.
  """
  def get_conversation(id, user_id) when is_binary(user_id) do
    with {:ok, _} <- Ecto.UUID.dump(id),
         conv when not is_nil(conv) <- Repo.get_by(Conversation, id: id, user_id: user_id) do
      Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version])
    else
      _ -> nil
    end
  end

  @doc """
  The conversation a sandbox callback key (`callback_api_key_id`) was minted
  for, scoped to `user_id`, unpreloaded. nil when no conversation of the
  account names the key: a rotated-away key, or a key that was never a
  sandbox's.

  A key handed over across a graceful stop (`handover_callback_api_key_id`,
  #2835) still names its conversation while the reattached turn that holds
  it runs, so the turn's sub-agent spawns keep their depth and its
  `"auth": "conversation"` MCP servers keep their binding (ADR 0086).
  """
  @spec get_conversation_for_callback_key(binary(), binary()) :: Conversation.t() | nil
  def get_conversation_for_callback_key(key_id, user_id)
      when is_binary(key_id) and is_binary(user_id) do
    Repo.one(
      from c in Conversation,
        where:
          c.user_id == ^user_id and
            (c.callback_api_key_id == ^key_id or c.handover_callback_api_key_id == ^key_id),
        limit: 1
    )
  end

  @doc """
  Whether `conversation_id` is `root_id` or one of the conversations it
  spawned, at any depth, through `parent_conversation_id`. Scoped to
  `user_id`: a conversation of another account, or one that does not exist,
  is outside every tree.

  A sandbox's own key reaches only its conversation's tree (ADR 0096): the
  conversation, its children and their descendants, never an ancestor or a
  sibling. `FountainWeb.Plugs.SandboxKeyScope` asks this for every
  conversation id such a key names.

  The walk goes up from `conversation_id`, so it touches only that
  conversation's ancestors, and stops at `root_id`. It is bounded like
  `get_conversation_tree/2`, because a cycle in client-supplied parent links
  would otherwise not end.
  """
  # sobelow_skip ["SQL.Query"] — static SQL, values bound as parameters.
  @spec in_spawn_tree?(binary(), binary(), binary()) :: boolean()
  def in_spawn_tree?(root_id, conversation_id, user_id)
      when is_binary(root_id) and is_binary(conversation_id) and is_binary(user_id) do
    sql = """
    WITH RECURSIVE up(id, parent_conversation_id, depth) AS (
      SELECT id, parent_conversation_id, 0
      FROM conversations WHERE id = $1 AND user_id = $3
      UNION ALL
      SELECT c.id, c.parent_conversation_id, u.depth + 1
      FROM conversations c
      INNER JOIN up u ON c.id = u.parent_conversation_id
      WHERE c.user_id = $3 AND u.id <> $2 AND u.depth < 100
    )
    SELECT 1 FROM up WHERE id = $2 LIMIT 1
    """

    with {:ok, conv_uuid} <- Ecto.UUID.dump(conversation_id),
         {:ok, root_uuid} <- Ecto.UUID.dump(root_id),
         {:ok, user_uuid} <- Ecto.UUID.dump(user_id) do
      %{num_rows: rows} = Repo.query!(sql, [conv_uuid, root_uuid, user_uuid])
      rows > 0
    else
      _ -> false
    end
  end

  @typedoc """
  A period's tokens, as the runtimes reported them. `cache_read` and
  `cache_write` are prompt-cache traffic; see `total_input/1`.
  """
  @type token_usage :: %{
          input: non_neg_integer(),
          cache_read: non_neg_integer(),
          cache_write: non_neg_integer(),
          output: non_neg_integer()
        }

  @token_keys [:input, :cache_read, :cache_write, :output]

  # Only a JSON number is cast. `usage` is whatever the runtime reported and
  # nothing validates its shape on the way in, so one row with a string where
  # a number belongs would otherwise take the whole page down with it.
  defmacrop token_sum(usage, key) do
    quote do
      fragment(
        "CASE WHEN jsonb_typeof(?->?) = 'number' THEN (?->>?)::bigint ELSE 0 END",
        unquote(usage),
        unquote(key),
        unquote(usage),
        unquote(key)
      )
    end
  end

  @doc """
  What this tenant's agents spent, in tokens, over a period.

  Summed from `turns.usage` — the figure the runtime reported when the turn
  ended. Reading the turns rather than `conversations.usage_input_tokens` is
  what makes a period possible: those counters are lifetime totals, and a
  conversation started in March is still accruing in April.

  **All four keys, not two.** A coding agent re-reads its context every turn,
  so nearly everything it consumes arrives as `cache_read`: a month of real
  work on this instance was 1.5k `input` against 41M `cache_read`. Reporting
  `input` alone as "what went in" understates it by four orders of magnitude,
  which is worse than not reporting it at all. Callers get the breakdown and
  decide how to present it; `total_input/1` is the sum for the common case.

  Tokens are the tenant's own inference spend — Fountain runs on their key
  (ADR 0008) and never bills for them — so this is reported, not charged.
  Turns from before the usage column existed, and runtimes that report no
  usage, contribute nothing rather than a guess.
  """
  @spec token_usage(binary(), DateTime.t(), DateTime.t()) :: token_usage()
  def token_usage(user_id, %DateTime{} = from, %DateTime{} = to) when is_binary(user_id) do
    # The sum happens in Postgres: a busy month is tens of thousands of turns,
    # and this runs on a page load.
    #
    # `jsonb_typeof` before the cast, because `usage` is whatever the runtime
    # reported and nothing validates its shape on the way in. One row with a
    # string or an object where a number was expected would otherwise take
    # the whole page down with a cast error.
    query =
      from(t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.user_id == ^user_id and t.inserted_at >= ^from and t.inserted_at <= ^to,
        where: not is_nil(t.usage),
        select: %{
          input: sum(token_sum(t.usage, "input")),
          cache_read: sum(token_sum(t.usage, "cache_read")),
          cache_write: sum(token_sum(t.usage, "cache_write")),
          output: sum(token_sum(t.usage, "output"))
        }
      )

    case Repo.one(query) do
      %{} = row -> Map.new(@token_keys, &{&1, to_count(Map.get(row, &1))})
      _ -> empty_token_usage()
    end
  end

  @doc """
  Everything the model read: fresh input plus what it wrote to and read from
  the prompt cache. The cached reads dominate, and leaving them out is what
  made the first version of this metric wrong.
  """
  @spec total_input(token_usage()) :: non_neg_integer()
  def total_input(%{input: input, cache_read: read, cache_write: write}),
    do: input + read + write

  defp empty_token_usage, do: Map.new(@token_keys, &{&1, 0})

  # Postgres sums bigints as `numeric`, which arrives as a Decimal. The
  # callers of this want an integer they can format, and the spec says so.
  defp to_count(nil), do: 0
  defp to_count(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_count(n) when is_integer(n), do: n

  @doc """
  How many conversations this tenant has, and how many are live right now.

  Counted in the database. The console's dashboard wants two numbers, not the
  rows: loading a few hundred conversations with their agents and first turns
  to arrive at "3" is a page load nobody needs.
  """
  @spec conversation_counts(binary()) :: %{total: non_neg_integer(), active: non_neg_integer()}
  def conversation_counts(user_id) when is_binary(user_id) do
    query =
      from(c in Conversation,
        where: c.user_id == ^user_id,
        select: %{
          total: count(c.id),
          active: filter(count(c.id), c.status in ["pending", "running"])
        }
      )

    Repo.one(query) || %{total: 0, active: 0}
  end

  @doc """
  What this tenant's agents did over a half-open period `[from, to)`: the
  turns started in it, and the conversations those turns belong to.

  Counted from the `turns` table (ADR 0079). A deleted conversation takes its
  turns with it, so it drops out of every period it ran in.
  """
  @spec activity_counts(binary(), DateTime.t(), DateTime.t()) ::
          %{conversations: non_neg_integer(), turns: non_neg_integer()}
  def activity_counts(user_id, %DateTime{} = from, %DateTime{} = to) when is_binary(user_id) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}

    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      where: c.user_id == ^user_id and t.inserted_at >= ^from and t.inserted_at < ^to,
      select: %{conversations: count(t.conversation_id, :distinct), turns: count(t.id)}
    )
    |> Repo.one()
  end

  @doc """
  `activity_counts/3` for several accounts in one query, for the admin user
  list: `%{user_id => %{conversations: n, turns: n}}`, accounts with no turns
  in the period absent. `_unsafe_`: crosses tenants; the caller is an admin
  surface.
  """
  @spec _unsafe_activity_counts_admin([binary()], DateTime.t(), DateTime.t()) ::
          %{optional(binary()) => %{conversations: non_neg_integer(), turns: non_neg_integer()}}
  def _unsafe_activity_counts_admin([], _from, _to), do: %{}

  def _unsafe_activity_counts_admin(user_ids, %DateTime{} = from, %DateTime{} = to)
      when is_list(user_ids) do
    {from, to} = {DateTime.truncate(from, :second), DateTime.truncate(to, :second)}

    from(t in Turn,
      join: c in Conversation,
      on: c.id == t.conversation_id,
      where: c.user_id in ^user_ids and t.inserted_at >= ^from and t.inserted_at < ^to,
      group_by: c.user_id,
      select:
        {c.user_id, %{conversations: count(t.conversation_id, :distinct), turns: count(t.id)}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  List conversations for user, ordered by most recently updated.

  Pass `roots_only: true` to exclude child conversations (those with a
  `parent_conversation_id`). Useful for hiding agent-spawned sub-conversations
  from the index when the user only wants to see top-level sessions.

  Further filters (#832), all combinable: `agent_id: id`, `channel_id: id`
  (the bound channel, #774), `status: [..]` (a list of conversation
  statuses), and `sandbox_id: id`. Unpaged, like the list always was, except
  for `limit: n` — which the console's dashboard uses to ask for the five it
  shows instead of every row a busy account has.

  `labels: %{"env" => "prod"}` (#1637) keeps the conversations carrying every
  one of those pairs — jsonb containment, so a row with more labels than the
  filter names still matches, and the GIN index on the column serves it.

  Populates the `last_active_at` virtual field using `kind: "output"` log
  events only — stage events (reconnects, lifecycle) are excluded so
  reconnects don't produce false unread indicators.
  """
  def list_conversations(user_id, opts \\ []) when is_binary(user_id) do
    roots_only = Keyword.get(opts, :roots_only, false)

    base = from(c in annotated_query(user_id), order_by: [desc: c.updated_at, desc: c.id])

    base =
      case Keyword.get(opts, :limit) do
        n when is_integer(n) and n > 0 -> limit(base, ^n)
        _ -> base
      end

    query =
      if roots_only do
        where(base, [conv: c], is_nil(c.parent_conversation_id))
      else
        base
      end

    query =
      Enum.reduce(opts, query, fn
        {:agent_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.agent_id == ^id)

        {:sandbox_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.sandbox_id == ^id)

        {:channel_id, id}, q when is_binary(id) and id != "" ->
          where(q, [conv: c], c.channel_id == ^id)

        {:labels, labels}, q when is_map(labels) and map_size(labels) > 0 ->
          where(q, [conv: c], fragment("? @> ?", c.labels, type(^labels, :map)))

        {:status, [_ | _] = statuses}, q ->
          where(q, [conv: c], c.status in ^statuses)

        _, q ->
          q
      end)

    Repo.all(query)
    |> Repo.preload([:agent, :agent_version, turns: first_turn_query()])
  end

  @doc """
  Scoped fetch that also populates the read-model annotations —
  `turn_count` and `last_active_at` — which `get_conversation/2` leaves at
  their defaults.

  Separate from `get_conversation/2` on purpose: that one is on the hot path
  of every prompt and interrupt, and does not need two extra joins to answer
  "does this conversation exist and is it yours".
  """
  def get_conversation_with_activity(id, user_id) when is_binary(user_id) do
    case Repo.one(from(c in annotated_query(user_id), where: c.id == ^id)) do
      nil ->
        nil

      # The first turn rides along, as it does on the list: `first_prompt` in
      # the JSON is what a client titles an untitled conversation with.
      conv ->
        Repo.preload(conv, [:sandbox, :agent, :vault, :agent_version, turns: first_turn_query()])
    end
  end

  # The conversation list read-model: turn counts and last activity, both as
  # LEFT JOIN LATERAL subqueries so the result stays a plain list of structs
  # and no caller N+1s.
  #
  # Lateral, per conversation, rather than one GROUP BY over the whole table
  # joined back (2026-09-07). The grouped shape aggregated every output log
  # event in the deployment on every call — a full scan of log_events, the
  # largest table, for a list of one tenant's conversations — and a client
  # polling this list 14 times a second turned that into 6.4M sequential
  # scans and a pool exhausted for everyone. Per conversation, the newest
  # output event is one backward probe of the partial index
  # `log_events_output_conversation_id_inserted_at_index`, and the cost
  # scales with the tenant's conversation count instead of the table.
  #
  # Only `kind: "output"` log events count toward `last_active_at` — stage
  # events (reconnects, sandbox lifecycle) would otherwise produce false
  # unread indicators.
  defp annotated_query(user_id) do
    from c in Conversation,
      as: :conv,
      where: c.user_id == ^user_id,
      left_lateral_join: tc in subquery(turn_count_of_conv()),
      on: true,
      left_lateral_join: ll in subquery(last_output_at_of_conv()),
      on: true,
      select: %{
        c
        | turn_count: fragment("COALESCE(?, 0)", tc.count),
          last_active_at:
            fragment(
              "COALESCE(? AT TIME ZONE 'UTC', ? AT TIME ZONE 'UTC')",
              ll.last_at,
              c.inserted_at
            )
      }
  end

  # The lateral halves of the read-model. Each answers for the conversation
  # bound as `:conv` in the outer query, so they compose only under a `from`
  # that names that binding.
  defp turn_count_of_conv do
    from t in Turn,
      where: t.conversation_id == parent_as(:conv).id,
      select: %{count: count(t.id)}
  end

  defp last_output_at_of_conv do
    from le in LogEvent,
      where: le.conversation_id == parent_as(:conv).id and le.kind == "output",
      select: %{last_at: max(le.inserted_at)}
  end

  @doc """
  Whether a conversation has activity the owner has not seen.

  Unread until read at least once; read conversations go unread again when
  output arrives after the last read. Lived in three copies across the nav,
  the index and (implicitly) the API — one definition, so they cannot drift.
  """
  def unread?(%{last_read_at: nil, last_active_at: _}), do: true
  def unread?(%{last_read_at: _, last_active_at: nil}), do: false

  def unread?(%{last_read_at: read_at, last_active_at: active_at}),
    do: DateTime.compare(active_at, read_at) == :gt

  def unread?(_), do: false

  def create_conversation(attrs) do
    insert_conversation_row(attrs)
  end

  # The one place a conversation row is written. Admission writes it inside a
  # transaction with the sandbox, so it cannot
  # share `create_conversation/1` outright; keeping the insert itself in one
  # function is what stops the two shapes drifting.
  # A door for `Fountain.Conversations.Launch` (#2217); not part of the
  # context's public surface.
  @doc false
  def insert_conversation_row(attrs) do
    # An `:id` chosen by the caller, when the row's other attributes are
    # derived from it (a launch's config home, ADR 0097); generated otherwise.
    %Conversation{id: Map.get(attrs, :id)} |> Conversation.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Merge `labels` into `conversation_id`'s. **The door every request-shaped
  caller uses** (#1637).

  Merge, not replace: a key that is not named is left alone and a key whose
  value is `nil` is removed, so a run can stamp one outcome without reading
  the rest first. `Conversations.Labels` owns the limits, and a write that
  breaks one comes back as a changeset naming the offending key.

  **A sandbox may label its own conversation only.** Pass
  `sandbox_key_id: key.id` whenever the caller authenticated with a
  `sprite`-scoped token: the conversation must be the one that token was
  minted for (`callback_api_key_id`), or the write is refused with
  `:sprite_may_not_label_another_conversation`. Without that check a worker
  holding an account-scoped callback key could relabel every other run on the
  account, which is exactly the loop ADR 0045 describes. That is why the
  check lives here and not in each controller: `PATCH .../labels` and a
  `channel_id` resume both write labels, and the rule has to hold on the
  door rather than on whichever of them remembered.

  `labels` that is not a map at all is a validation failure, not a silent
  no-op, so every door refuses `{"labels": "env=prod"}` the same way.

  Tenant-scoped: an id belonging to another account reads as `:not_found`.
  """
  @spec set_conversation_labels(binary(), binary(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, term()}
  def set_conversation_labels(conversation_id, user_id, labels, opts \\ [])
      when is_binary(conversation_id) and is_binary(user_id) do
    case get_conversation(conversation_id, user_id) do
      nil ->
        {:error, :not_found}

      %Conversation{} = conv ->
        if sandbox_owns?(conv, Keyword.get(opts, :sandbox_key_id)) do
          # Ownership: `conv` came from the tenant-scoped fetch above.
          _unsafe_merge_labels(conv, labels, opts)
        else
          {:error, :sprite_may_not_label_another_conversation}
        end
    end
  end

  # No sandbox key on the request is the owner's own credential, which may
  # label any conversation it can already fetch.
  defp sandbox_owns?(_conv, nil), do: true

  defp sandbox_owns?(%Conversation{} = conv, key_id),
    do: key_id in [conv.callback_api_key_id, conv.handover_callback_api_key_id]

  @doc """
  Merge `labels` into a conversation row, with no tenant scoping and no
  credential rule.

  Unscoped, hence the prefix. The legitimate callers are
  `set_conversation_labels/4`, which scopes and applies the sandbox rule
  before delegating here, and `Labels._unsafe_stamp/2`, which runs inside the
  conversation's own server and holds the row that server was started for. A
  request path that calls this directly has skipped the rule that stops one
  sandbox relabelling another, so do not add one.

  A merge that changes nothing writes nothing and records nothing — a
  deterministic run re-stamping the same outcome on every tick is the normal
  case. Audited as `conversation.labels_set` with the keys written and the
  keys removed, never the values (ADR 0013).
  """
  @spec _unsafe_merge_labels(Conversation.t(), term(), keyword()) ::
          {:ok, Conversation.t()} | {:error, Ecto.Changeset.t()}
  def _unsafe_merge_labels(conv, labels, opts \\ []) do
    with {:ok, updated, audit} <- merge_labels(conv, labels) do
      audit_labels(updated, audit, opts)
      {:ok, updated}
    end
  end

  defp merge_labels(%Conversation{} = conv, labels) when is_map(labels) do
    current = conv.labels || %{}
    merged = Labels.merge(current, labels)

    cond do
      merged == current -> {:ok, conv, nil}
      true -> write_labels(conv, current, labels, merged)
    end
  end

  # Anything that is not a map is a validation failure with the same shape a
  # broken limit produces, so a caller reads one answer whichever door it
  # came through.
  defp merge_labels(%Conversation{} = conv, labels) do
    {:error, label_refusal(conv, Labels.check(labels))}
  end

  defp write_labels(conv, current, labels, merged) do
    case Labels.check_merge(current, labels) do
      :ok ->
        {written, removed} = Labels.changed_keys(current, labels)

        conv
        |> Conversation.changeset(%{labels: merged})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated, {written, removed, merged}}
          error -> error
        end

      refusal ->
        {:error, label_refusal(conv, refusal)}
    end
  end

  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def audit_labels(_conv, nil, _opts), do: :ok

  def audit_labels(conv, {written, removed, merged}, opts),
    do: record_labels_set(conv, written, removed, merged, opts)

  defp record_labels_set(conv, written, removed, merged, opts) do
    Audit.record(%{
      user_id: conv.user_id,
      action: "conversation.labels_set",
      resource_type: "conversation",
      resource_id: conv.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "keys" => written,
        "removed_keys" => removed,
        "label_count" => map_size(merged)
      }
    })
  end

  # `Labels.check_merge/2` words the refusal from the write the caller made;
  # this is what turns that sentence into the `errors.labels` a 422 renders,
  # the same key the changeset validator would have used.
  defp label_refusal(%Conversation{} = conv, {:error, message}) do
    conv
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:labels, message)
  end

  def update_conversation(%Conversation{} = conv, attrs) do
    conv
    |> Conversation.changeset(attrs)
    |> Repo.update()
    |> tap(fn
      {:ok, updated} -> broadcast_sidebar_update(updated.user_id)
      _ -> :ok
    end)
  end

  @doc "Apply a harness title without overwriting an explicit name."
  def _unsafe_update_harness_title(conversation_id, title)
      when is_binary(title) or is_nil(title) do
    # A single conditional write arbitrates against concurrent user renames.
    # Updating title_source also lets an owner claim an unchanged harness title.
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id,
        where: is_nil(c.title) or c.title_source == "harness",
        where: fragment("? IS DISTINCT FROM ?", c.title, ^title),
        select: c.user_id
      )

    case Repo.update_all(query,
           set: [title: title, title_source: "harness", updated_at: DateTime.utc_now(:second)]
         ) do
      {1, [user_id]} -> broadcast_sidebar_update(user_id)
      {0, _} -> :ok
    end
  end

  @doc """
  Record the session config options the adapter advertised before a turn's
  prompt (ADR 0062). Written by the conversation's own turn machine, and
  only when the list changed, so a steady conversation writes nothing.
  """
  def _unsafe_put_session_config_options(conversation_id, options) when is_list(options) do
    from(c in Conversation,
      where: c.id == ^conversation_id,
      where:
        fragment("? IS DISTINCT FROM ?", c.session_config_options, type(^options, {:array, :map}))
    )
    |> Repo.update_all(set: [session_config_options: options])

    :ok
  end

  @doc "Idle only the latest ended turn's still-running parent."
  def _unsafe_idle_after_turn(%Turn{} = turn),
    do: write_turn_parent(turn, :idle, %{status: "idle"})

  @doc """
  Apply a runtime session report only for the current, unretired turn.

  `opts` takes `:sandbox_id`, the actor's own binding, to refuse the write when
  the conversation has since moved to another sandbox
  (`TurnLocks._unsafe_write_parent/4`).
  """
  def _unsafe_set_turn_session(%Turn{} = turn, session_id, opts \\ []),
    do: write_turn_parent(turn, :session, %{runtime_session_id: session_id}, opts)

  @doc "Clear an idle legacy peer's session only if its observed identity is still current."
  def _unsafe_clear_idle_session(conv_id, expected) do
    # ownership: this is the already-owned actor's conversation and session.
    TurnLocks._unsafe_clear_idle_session(conv_id, expected, fn current ->
      current |> Conversation.changeset(%{runtime_session_id: nil}) |> Repo.update()
    end)
    |> notify_parent_change()
  end

  defp write_turn_parent(turn, mode, attrs, opts \\ []) do
    # ownership: the calling actor/recovery path already owns this exact turn.
    result =
      TurnLocks._unsafe_write_parent(
        turn,
        mode,
        fn current -> current |> Conversation.changeset(attrs) |> Repo.update() end,
        opts
      )

    notify_parent_change(result)
  end

  defp notify_parent_change(result) do
    case result do
      {:ok, %{applied: true, conversation: conv}} -> broadcast_sidebar_update(conv.user_id)
      _ -> :ok
    end

    result
  end

  # How long a caller waits for advisory lock 4316 before giving up
  # (ADR 0058 stage 6b, carried from 6a's locks review §6).
  #
  # Every transaction this function opens is short and database-only: the
  # longest is `Machines.Lease.claim/2`'s indexed `FOR UPDATE` read and one
  # `update_all`, and `register_server/2`'s marker is the same shape. Nothing
  # holds this lock across provider I/O — the two protocols take the lock to
  # *claim*, then do their checkpoint, suspend or destroy outside it — so five
  # seconds is not a bound anyone should ever reach.
  #
  # It is here because stage 6b makes the lock contended for the first time. A
  # park now takes it on every idle sweep, and a wake takes it through
  # `register_server/2` before it starts a server; with no timeout, a wake
  # blocked behind a claim whose transaction had somehow stalled would wait
  # for as long as that lasted, with nothing to log and nothing to refuse.
  #
  # `55P03` (`lock_not_available`) is raised out of `Repo.query!` below and
  # caught by this function's own `rescue`, which answers
  # `{:error, :sandbox_unavailable}`. It does **not** travel as
  # `Lease.guarded/2`'s `{:database, _}` shape: `guarded/2` wraps the call to
  # this function, and this function no longer lets the exception out.
  #
  # `SET LOCAL`, so it lasts exactly this transaction and no other work on the
  # pooled connection inherits it — and it applies to **every** lock this
  # transaction takes, not only the advisory one: the `FOR UPDATE` reads its
  # callers make are under it too. That is the intent rather than a side
  # effect; a row lock held for five seconds by something else is the same
  # problem from the other end. It does not cover the sites that take 4316
  # with their own `Repo.query!` — the teardown fence, the reset front door,
  # turn admission — and that is deliberate for now: those hold the lock for
  # the same kind of short database work, and giving a fence a new way to fail
  # is a decision for the stage that moves it behind the owner.
  #
  # Overridable so `machines/park_test.exs` can drive the timeout against a
  # genuinely held lock without spending five seconds on it. Nothing in `lib/`
  # sets it.
  @sandbox_lock_timeout_ms 5_000

  defp sandbox_lock_timeout_ms,
    do: Application.get_env(:fountain, :sandbox_lock_timeout_ms, @sandbox_lock_timeout_ms)

  # The lock turn admission takes, so a binding change and a turn start cannot
  # interleave on one machine. `nil` is a conversation whose machine has not
  # been minted yet; there is nothing to serialize against.
  # A door for `Fountain.Conversations.Launch` (#2216) and the machine owner;
  # not part of the context's public surface.
  @doc false
  def with_sandbox_lock(sandbox_id, fun) do
    Repo.transaction(fn ->
      if sandbox_id do
        Repo.query!("SET LOCAL lock_timeout = '#{sandbox_lock_timeout_ms()}ms'")

        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          sandbox_lock_key(sandbox_id)
        ])
      end

      case fun.() do
        {:ok, value} -> value
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  rescue
    # The timeout above arrives as an exception out of `Repo.query!`, and every
    # caller here already has a `{:error, reason}` path, so it becomes one
    # rather than unwinding through a launch or a wake.
    #
    # For a caller that was not already in a transaction, this one has been
    # rolled back by the time the rescue runs and the advisory lock went with
    # it. One caller *is* — `Launch.resume_channel/4`, inside
    # `InferenceCredentials.with_source_lock/2` — and there the enclosing
    # transaction is aborted by the failed statement: Ecto opens no savepoint
    # for a nested `Repo.transaction`, so there is nothing to roll back to and
    # any further query on that connection would fail too. The refusal this
    # returns is therefore one it may carry *outward* and never act on and
    # continue from — and it does not: it hands it to its own `{:error, _}`
    # path and unwinds. Worth saying, because the word looks recoverable and
    # inside that caller the transaction around it is not.
    #
    # The word is `:sandbox_unavailable` and not a new one: "this machine
    # cannot be reached right now" is exactly what it means, it is already 503
    # with a `Retry-After` and `NotReadyError` in the SDK, and stage 6's
    # decision was to reuse it rather than teach five clients a second word
    # (#2304, closed unmerged). Out of `Machines.Lease.claim/2` it can mean
    # nothing else — that function's own refusals are `{:held, _, _}`,
    # `:not_found` and `:lost` — which is what lets the two protocols' busy
    # waits treat it as contention and keep waiting.
    error in Postgrex.Error ->
      if lock_timeout?(error) do
        # Deliberately not "advisory lock 4316 was held": the timeout covers
        # every lock this transaction waits on, so a `FOR UPDATE` row lock held
        # by somebody else lands here too, and naming the wrong one sends an
        # operator looking in the wrong place.
        Logger.warning(
          "a lock on sandbox #{inspect(sandbox_id)} was not available within the " <>
            "#{sandbox_lock_timeout_ms()}ms lock_timeout; refusing"
        )

        {:error, :sandbox_unavailable}
      else
        reraise(error, __STACKTRACE__)
      end
  end

  defp lock_timeout?(%Postgrex.Error{postgres: %{code: :lock_not_available}}), do: true
  defp lock_timeout?(_error), do: false

  @doc """
  The key of a machine's advisory lock in namespace 4316: its **workspace's**
  id (ADR 0097, step 3b), so the lock that serializes a claim, a fence, a turn
  admission and a registration is the one the workspace's owner takes, and
  every sandbox a workspace ever has shares it. A sandbox with no workspace,
  which only a row retired before ADR 0097 is, keeps its own id; so does an
  id with no row.

  One read, without a lock, and safe without one: a live sandbox's
  `workspace_id` does not change while anything can hold its lock (see
  `Fountain.Machines.Lease`). Every taker of 4316 comes through here, so two
  of them never disagree about the key.
  """
  @spec sandbox_lock_key(Ecto.UUID.t()) :: non_neg_integer()
  def sandbox_lock_key(sandbox_id) when is_binary(sandbox_id) do
    workspace_id =
      Repo.one(from s in Sandbox, where: s.id == ^sandbox_id, select: s.workspace_id)

    :erlang.phash2(workspace_id || sandbox_id)
  end

  @doc """
  Start a `ConversationServer` on `sandbox_id`, under the machine's lock
  (ADR 0058 stage 6a, ADR 0072).

  **The only door onto `Fountain.ConversationSupervisor`.** All three starters
  — `Launch.start_conversation/2`'s fresh path, `Wake.start_conversation_server/5`
  and `Rehydrator.spawn_server/1` — come through here, and
  `machines/register_server_test.exs` pins that nothing else names the
  supervisor.

  Under `with_sandbox_lock/2`, in one short transaction: re-read the row
  `FOR UPDATE`, refuse with `{:error, :sandbox_unavailable}` if an owner holds
  a live lease on it (`Machines.Machine.busy?/1`), clear an abandoned
  `transition`, and start the child. The child is registered in
  `Fountain.ConversationRegistry` before `start_child` returns, so by the time
  the lock is released every reader that takes it — a park's claim, the
  reaper's owner calls — finds the server. `ConversationServer.init/1` does no
  database work, which is what makes starting it inside the transaction safe.

  Fountain runs as one node (ADR 0072). Until then the registry was Horde's
  asynchronous CRDT, the child was started *after* the lock, and the row
  carried a `woken_at` marker that the reaper and the park honoured for
  fifteen minutes because "no live server" read on another node was not proof
  of absence. A local registry is proof, so the marker is gone.

  **Why the check is here as well as in the readers** (round 1, locks review).
  `Wake.maybe_reuse_sandbox/1` reads the row with no lock at all, so a
  `Lease.claim/2` landing between that read and this call would otherwise get a
  `ConversationServer` started on a machine somebody is destroying — the
  check-then-act window #2307 constraint 1 names. This door already takes the
  very advisory lock `Lease.claim/2` takes, so asking again inside it closes
  that window for nothing.

  **It clears a stale `transition` in the same transaction** (stage 6b) —
  every one but `destroying`, which it refuses instead (stage 9a; see the
  clause). Reaching that line means the check above found no live lease, which
  makes any *abandonable* stamp on the row an operation whose owner died. The
  next owner to claim that machine would otherwise read the stamp as *its own*
  interrupted operation and pick the work up from the middle, on a machine that
  had since been in use. What clearing it costs `Machines.Park` is a shortcut,
  not correctness: its takeover revalidates everything under its own lease.

  A `destroying` stamp is the only record that this machine was asked to be
  destroyed, and a door that cleared it would delete the request. So this door
  refuses a `destroying` row instead.

  **Refuses an enclosing transaction**, the same guard `Machines.Destroy.run/2`
  carries and for the same reason (#2307 constraint 3): nested, the lock would
  be held until the *outer* commit, with nothing failing.

  **The supervisor's answer is passed back verbatim, including
  `{:error, {:already_started, pid}}`**, because the two callers do not mean
  the same thing by it and normalizing it here would break one of them.
  `Rehydrator.spawn_server/1` reads it as success: the server is running, which
  is what it asked for. `Wake.start_conversation_server/5` reads it as *losing
  a race it has to compensate for*: on the fresh-sandbox path the loser has
  just created a sandbox row of its own, and the winner is serving the
  conversation on a different machine, so the loser retires its row and hands
  the prompt over (#717, #330). Swallowing the tuple here would repoint the
  conversation at the loser's machine — the exact bug #717 closed.

  `sandbox_id` may be `nil` (nothing to lock, as `with_sandbox_lock/2` already
  allows), and a row that is gone by the time the lock is taken is logged and
  stepped over — a vanished sandbox is the child's problem to discover, not a
  reason to refuse to start it here. A *busy* machine is the one case that does
  refuse, and it refuses with the word its readers use.

  `refuse_terminal: true` in `opts` also refuses a terminal row, under the
  same lock, as `:sandbox_unavailable`: for a wake that waited for a busy
  machine to attach to it, and must not register onto one that went while
  it waited (#3001). Every other caller lets a server discover a retired row
  for itself, as above.
  """
  # The child spec is whatever `DynamicSupervisor.start_child/2` takes: every
  # caller here passes `Launch.child_spec/3`'s `{ConversationServer, args}`
  # tuple rather than a map.
  @spec register_server(
          String.t() | nil,
          Supervisor.child_spec() | {module(), term()} | module(),
          keyword()
        ) :: {:ok, pid()} | {:error, term()}
  def register_server(sandbox_id, child_spec, opts \\ []) do
    cond do
      Repo.in_transaction?() ->
        {:error, :transaction_open}

      is_nil(sandbox_id) ->
        start_server(child_spec)

      true ->
        sandbox_id
        |> claim_registration(child_spec, Keyword.get(opts, :refuse_terminal, false))
        |> report_registration(sandbox_id)
    end
  end

  defp start_server(child_spec),
    do: DynamicSupervisor.start_child(Fountain.ConversationSupervisor, child_spec)

  defp claim_registration(sandbox_id, child_spec, refuse_terminal?) do
    with_sandbox_lock(sandbox_id, fn ->
      # The verdict is made on the locked read, never on the struct a caller
      # brought: a pre-lock reading is stale by construction, which is what
      # makes this worth doing twice.
      current = Lease.lock_machine(sandbox_id, :update)

      cond do
        is_nil(current) ->
          {:ok, {:no_row, start_server(child_spec)}}

        Machine.busy?(current) ->
          {:error, :sandbox_unavailable}

        refuse_terminal? and current.status in @terminal_statuses ->
          {:error, :sandbox_unavailable}

        # The one stamp this door does not clear, and so the one it refuses
        # (ADR 0058 stage 9a). A `destroying` stamp on a row that has not
        # retired is an unfinished destroy, not an abandoned operation, and
        # clearing it would take the intent off a machine that is still on its
        # way out — leaving nothing for `SandboxReaper`'s driver to find and a
        # `ConversationServer` started on a disk about to be deleted. Refused
        # with the fence's word rather than the lease's: `:sandbox_unavailable`
        # promises a machine that settles in thirty seconds, and this one is
        # going away for good.
        #
        # A terminal row is not refused. The stamp there is leftovers, as
        # `Destroy.clear_stale_transition/2` says, and a server started on a
        # retired row discovers that for itself — the same reading the
        # `:no_row` clause above takes of a row that has vanished.
        current.transition == "destroying" and current.status not in @terminal_statuses ->
          {:error, :sandbox_reset_pending}

        # An interrupted wake has not proved exec readiness. Only Resume may
        # clear this stamp; boot registration must not publish a ready row.
        current.transition == "resuming" and current.status not in @terminal_statuses ->
          {:error, :sandbox_unavailable}

        # The door's decision; the write is the owner namespace's (stage 9b).
        true ->
          count = Fountain.Machines.Binding.clear_abandoned_transition(sandbox_id)
          {:ok, {count, start_server(child_spec)}}
      end
    end)
  end

  # A row that vanished between the caller's read and this lock is not a reason
  # to refuse to start the server: a server on a machine whose row is gone
  # discovers that for itself, and refusing here would turn a rare race into a
  # failed wake.
  defp report_registration({:ok, {:no_row, started}}, sandbox_id) do
    Logger.warning(
      "register_server: no sandbox #{sandbox_id} under the lock; started the server anyway"
    )

    started
  end

  defp report_registration({:ok, {0, started}}, sandbox_id) do
    Logger.warning(
      "register_server: sandbox #{sandbox_id} vanished under the lock; started the server anyway"
    )

    started
  end

  defp report_registration({:ok, {_count, started}}, _sandbox_id), do: started

  defp report_registration({:error, _reason} = error, _sandbox_id), do: error

  @doc """
  Best-effort terminate the running ConversationServer (destroys the sprite
  if alive), then delete the conversation row. Cascades to turns and log
  events via the FK.
  """
  def delete_conversation(%Conversation{} = conv, opts \\ []) do
    # ownership: conv is the caller's tenant-scoped row. A row already gone
    # answers `:not_found` rather than a stale delete.
    if Repo.exists?(from c in Conversation, where: c.id == ^conv.id),
      do: delete_existing_conversation(conv, opts),
      else: {:error, :not_found}
  end

  defp delete_existing_conversation(%Conversation{id: id, user_id: user_id} = conv, opts) do
    # `audit: false` on the cascade: this terminate is an implementation
    # detail of deleting, not a second thing the user asked for, and the
    # `conversation.deleted` below already accounts for the sandbox going
    # away. Without it every delete would read as terminate-then-delete.
    _ = Termination.terminate_conversation(id, audit: false)
    result = Repo.delete(conv)

    if match?({:ok, _}, result) do
      broadcast_sidebar_update(user_id)

      Audit.record(%{
        user_id: user_id,
        action: "conversation.deleted",
        resource_type: "conversation",
        resource_id: id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{"title" => conv.title}
      })
    end

    result
  end

  @doc """
  Record that `user_id` has read `conversation_id` as of now.

  Scoped to owner — silently no-ops for a wrong user_id. Broadcasts a
  sidebar update so the unread dot clears in the nav without waiting for
  the next natural PubSub event.
  """
  def mark_read(conversation_id, user_id)
      when is_binary(conversation_id) and is_binary(user_id) do
    now = DateTime.utc_now() |> DateTime.truncate(:microsecond)

    case Repo.update_all(
           from(c in Conversation,
             where: c.id == ^conversation_id and c.user_id == ^user_id
           ),
           set: [last_read_at: now]
         ) do
      {0, _} ->
        :ok

      {_, _} ->
        broadcast_sidebar_update(user_id)
        :ok
    end
  end

  # ── turns ─────────────────────────────────────────────────────────────────────────────

  def _unsafe_list_turns(conversation_id) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        order_by: [asc: t.turn_number],
        preload: [images: ^from(i in TurnImage, order_by: [asc: i.position])]
    )
  end

  @doc """
  `turn_id => prompt` for the given turns, for the events feed's `?prompts=true`.

  Deliberately not `_unsafe_list_turns/1` with a filter on top. That helper
  reads the whole conversation and preloads every `TurnImage`, `data` column
  included, and an accepted prompt image is allowed to be 10 MiB. Rendering a
  handful of prompt blocks onto one bounded event page must not read the
  conversation's entire attachment history, so this projects the two columns
  the caller renders and touches no image row at all.

  `turn_ids` comes from the page being rendered, so the work is the page's
  size rather than the conversation's age. The `conversation_id` is still in
  the `where`: it is what keeps a turn id from another tenant's conversation
  from resolving, independent of where the ids were collected.

  An `autonomous` turn (#817) is left out here rather than in the caller, so
  the rows never leave PostgreSQL. Its prompt is a placeholder this server
  wrote for a cycle nobody asked for, and rendering that in the human's voice
  would put words in his mouth. A NULL `origin` is a user turn, as on the
  older rows that predate the column's default.
  """
  def _unsafe_list_turn_prompts(_conversation_id, []), do: %{}

  def _unsafe_list_turn_prompts(conversation_id, turn_ids) when is_list(turn_ids) do
    Repo.all(
      from t in Turn,
        where: t.conversation_id == ^conversation_id,
        where: t.id in ^turn_ids,
        where: is_nil(t.origin) or t.origin == "user",
        where: not is_nil(t.prompt) and t.prompt != "",
        select: {t.id, t.prompt}
    )
    |> Map.new()
  end

  @doc """
  Fetch a turn by conversation, scoped to the owning user.

  Joins through the conversation so a turn belonging to another tenant is
  indistinguishable from one that doesn't exist.
  """
  def get_turn_by_conversation(turn_id, conversation_id, user_id) when is_binary(user_id) do
    Repo.one(
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where:
          t.id == ^turn_id and t.conversation_id == ^conversation_id and
            c.user_id == ^user_id,
        select: t
    )
  end

  def _unsafe_insert_turn_images(_turn_id, []), do: {:ok, 0}

  @doc """
  Store a turn's images.

  Goes through `TurnImage.changeset/2` rather than `Repo.insert_all` against a
  raw table name. The old path skipped the schema entirely, so the media-type
  allowlist, the required fields and the `(turn_id, position)` unique constraint
  never ran — the schema described validation that nothing performed, and a
  client could store an arbitrary media type. Volume here is a handful of rows
  per turn, so there was never a bulk-insert win to protect.

  Returns `{:ok, count}` or `{:error, changeset}`. Both are handled by the
  caller; a rejected image must not take a turn down with it.
  """
  def _unsafe_insert_turn_images(turn_id, images) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    images
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, 0}, fn {%{media_type: mt, data: data}, idx}, {:ok, count} ->
      changeset =
        TurnImage.changeset(%TurnImage{}, %{
          turn_id: turn_id,
          position: idx,
          media_type: mt,
          data: data,
          inserted_at: now
        })

      case Repo.insert(changeset) do
        {:ok, _} -> {:cont, {:ok, count + 1}}
        {:error, cs} -> {:halt, {:error, cs}}
      end
    end)
  end

  @doc """
  A turn's stored images, in the shape `_unsafe_insert_turn_images/2` took
  them, for launching the turn again (`Reattachment`'s unsent-prompt relaunch).
  """
  def _unsafe_list_turn_images(turn_id) do
    Repo.all(
      from i in TurnImage,
        where: i.turn_id == ^turn_id,
        order_by: i.position,
        select: %{media_type: i.media_type, data: i.data}
    )
  end

  def _unsafe_get_turn_image(turn_id, position) do
    Repo.get_by(TurnImage, turn_id: turn_id, position: position)
  end

  def _unsafe_next_turn_number(conversation_id) do
    last =
      Repo.one(
        from t in Turn,
          where: t.conversation_id == ^conversation_id,
          select: max(t.turn_number)
      )

    (last || 0) + 1
  end

  def _unsafe_create_turn(attrs) do
    %Turn{} |> Turn.changeset(attrs) |> Repo.insert()
  end

  @doc """
  Create a turn on the conversation's sandbox, under the machine's lock.

  **The owner's write** (ADR 0058 stage 8a). `Fountain.Machines.Admission` is
  the only caller; everything that used to call this directly goes through
  `Fountain.Machines.Machine.admit_turn/3`.

  `opts[:deadline]`, a `DateTime` on the database clock, is the caller's own
  bound on waiting for this answer, set by the owner door on the in-owner
  path: read against the `statement_timestamp()` this transaction takes the
  machine's row with, a deadline already passed is `{:error, :admission_expired}`
  and no turn is written — a prompt that was told 503 must not gain a turn
  after the fact (round 1 of stage 8a). What is bounded is the row read; the
  commit may land one transaction tail after the deadline, and that tail has
  no lock wait in it.

  All runtimes take the machine's advisory lock and read the machine's row
  under it, and every verdict about the machine is taken from that read (#2307
  constraint 1): the conversation must still be bound to this nonterminal
  sandbox; neither fence may be set, nor the `destroying` stamp that replaces
  them in stage 9b — a teardown fence refuses here since stage
  8a, where before only a reset's did, because all three are durable statements
  that the machine is going away and the other protocols refuse on any; and
  no owner may hold a **live lease** on it (`Fountain.Machines.Machine.busy?/1`),
  which is `{:error, :machine_busy}` and the one refusal the protocol waits
  out before it returns it. A dead lease, or an abandonable transition whose
  holder has died, refuses nothing: that is an owner that died, and the row is
  judged by its status (stage 6a's rule). `destroying` is not abandonable and
  is the fence above rather than a lease reading (stage 9a).

  The conversation row stays locked through the insert: an earlier
  reassignment refuses this sandbox, while a later forced reassignment can
  move a conversation whose turn was already admitted. This ordering does not
  make arbitrary reassignment writers check for running turns.

  There is no capacity count: a machine serves one conversation (#2676).
  Refusal writes no turn.
  """
  def _unsafe_create_turn_on_sandbox(attrs, sandbox_id, opts \\ [])
      when is_binary(sandbox_id) and is_list(opts) do
    conv_id = Map.fetch!(attrs, :conversation_id)
    deadline = Keyword.get(opts, :deadline)

    result =
      Repo.transaction(fn ->
        user_id =
          Repo.one(from c in Conversation, where: c.id == ^conv_id, select: c.user_id) ||
            Repo.rollback(:sandbox_unavailable)

        :ok = InferenceCredentials.lock_source(user_id)

        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          @sandbox_lock_namespace,
          sandbox_lock_key(sandbox_id)
        ])

        # Hold the parent row through the turn insert.
        conv =
          Repo.one(
            from c in Conversation,
              where: c.id == ^conv_id,
              select: %{
                id: c.id,
                user_id: c.user_id,
                sandbox_id: c.sandbox_id,
                runtime: c.runtime,
                inference_source: c.inference_source
              },
              lock: "FOR UPDATE"
          ) || Repo.rollback(:sandbox_unavailable)

        if conv.user_id != user_id, do: Repo.rollback(:sandbox_unavailable)

        # A serving actor must agree with the persisted binding. Hold the source
        # lock through insertion so replacement cannot race turn admission.
        if Map.has_key?(attrs, :inference_source) and
             attrs.inference_source != conv.inference_source do
          Repo.rollback(:inference_source_changed)
        end

        if source = Source.load(conv.inference_source) do
          case InferenceCredentials.validate_source(user_id, source) do
            :ok -> :ok
            {:error, reason} -> Repo.rollback(reason)
          end
        end

        attrs = Map.put(attrs, :inference_source, conv.inference_source)

        # The machine, read under the lock. Row-only retirement writers do not
        # take the admission advisory lock, so its row is held `FOR SHARE`
        # through the insert too: a committed retirement refuses admission,
        # while a later forced retirement follows the turn. The clock rides
        # along with the read, so the caller's deadline is judged at the same
        # instant the row was seen.
        # Its lease and transition are its workspace's, read under the
        # workspace's row lock first (`Lease.lock_machine/2`), in the order
        # every compare-and-set takes them.
        machine =
          case Lease.lock_machine(sandbox_id, :share) do
            nil ->
              nil

            %Sandbox{} = locked ->
              locked
              |> Map.take([:id, :user_id, :status, :transition, :lease_node])
              |> Map.put(:db_now, statement_clock())
          end

        case admissible_machine(machine, conv, sandbox_id) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback(reason)
        end

        # The caller's deadline, judged on the same clock the row was read
        # with. After the machine's own verdicts so a refusal names the machine
        # first; before the write so an expired caller gains nothing.
        if deadline && DateTime.compare(machine.db_now, deadline) == :gt,
          do: Repo.rollback(:admission_expired)

        # A terminated or failed parent takes no more turns. `attached?` above
        # checks the machine; this checks the conversation, which a retired
        # actor can still reach with a queued prompt.
        if Repo.exists?(
             from c in Conversation,
               where: c.id == ^conv_id and c.status in ["terminated", "failed"]
           ),
           do: Repo.rollback(:not_running)

        # No capacity count: one conversation per machine (#2676), and a
        # second turn of this one is refused by its server (`:busy`).
        turn =
          case %Turn{} |> Turn.changeset(attrs) |> Repo.insert() do
            {:ok, turn} -> turn
            {:error, changeset} -> Repo.rollback(changeset)
          end

        # The parent goes `running` here rather than in the launch, so a turn
        # and the conversation status that explains it commit together. A
        # reader used to be able to see a `running` turn under an `idle`
        # parent for the width of the launch, and a launch that failed left
        # the pair disagreeing. `update_all`, not `update_conversation/2`:
        # that one audits, and an audit insert must not run inside a
        # transaction (ADR 0013).
        if Map.get(attrs, :status) == "running" do
          Repo.update_all(
            from(c in Conversation,
              where: c.id == ^conv_id and c.status != "running"
            ),
            set: [status: "running", updated_at: DateTime.utc_now()]
          )
        end

        Fountain.Conversations.PromptReceipt.resolve(conv_id, Map.get(attrs, :prompt_receipt_id))
        turn
      end)

    record_started_turn(result)
  end

  # The machine's side of admission, from the row read under the lock. In the
  # order that makes the answer most useful: is the conversation still bound
  # to this machine at all, is the machine still here, has anyone asked for it
  # to go, is anyone operating on it right now.
  #
  # `:sandbox_unavailable` for the first three is `main`'s word at this site.
  # The lease is the new refusal and gets the protocol's word so that
  # `Fountain.Machines.Admission` can wait it out — the others are final for
  # this prompt, a live lease is not.
  # The database's clock at this statement, for the deadline: read just after
  # the machine's rows, inside the same transaction.
  defp statement_clock do
    %Postgrex.Result{rows: [[%DateTime{} = now]]} = Repo.query!("SELECT statement_timestamp()")
    now
  end

  defp admissible_machine(nil, _conv, _sandbox_id), do: {:error, :sandbox_unavailable}

  defp admissible_machine(machine, conv, sandbox_id) do
    cond do
      conv.sandbox_id != sandbox_id or machine.user_id != conv.user_id ->
        {:error, :sandbox_unavailable}

      machine.status in @terminal_statuses ->
        {:error, :sandbox_unavailable}

      # Parked under this conversation by a co-tenant (ADR 0097: the park is
      # the workspace's, over all of its conversations). Its server is being
      # told `machine_gone` and stops; the prompt's retry wakes the machine
      # for this conversation through the ordinary wake. A turn admitted here
      # would run on a row no sweep looks at (decisions/0017).
      machine.status == "suspended" ->
        {:error, :sandbox_unavailable}

      # Either fence, read off the `destroying` stamp both write (stage 9a;
      # stage 9b stopped reading the two columns 8a read here). The status
      # clause above has already taken the terminal rows where the stamp would
      # be leftovers.
      machine.transition == "destroying" ->
        {:error, :sandbox_unavailable}

      Machine.busy?(machine) ->
        {:error, :machine_busy}

      true ->
        :ok
    end
  end

  defp record_started_turn({:ok, turn}) do
    case Repo.get(Conversation, turn.conversation_id) do
      nil -> :ok
      conv -> broadcast_sidebar_update(conv.user_id)
    end

    {:ok, turn}
  end

  defp record_started_turn(error), do: error

  @doc """
  How many turns are running right now on `sandbox_id` for conversations
  other than `conv_id` — every conversation on the machine when `conv_id` is
  nil — and, given a `runtime`, for conversations on that runtime alone.
  `_unsafe_`: the caller owns `conv_id`.

  The three-argument form was the per-runtime capacity count (ADR 0058 stage
  8a), which went with shared machines (#2676). The two-argument form asks
  whether *anything* is mid-turn on this machine, as a failed launch's binding
  check does.
  """
  def _unsafe_running_turns_elsewhere(sandbox_id, conv_id, runtime \\ :any)

  def _unsafe_running_turns_elsewhere(sandbox_id, conv_id, runtime)
      when is_binary(sandbox_id) and (is_binary(conv_id) or is_nil(conv_id)) and
             (is_binary(runtime) or runtime == :any) do
    query =
      from t in Turn,
        join: c in Conversation,
        on: c.id == t.conversation_id,
        where: c.sandbox_id == ^sandbox_id and t.status == "running",
        select: count(t.id)

    query = if is_nil(conv_id), do: query, else: where(query, [t, c], c.id != ^conv_id)
    query = if runtime == :any, do: query, else: where(query, [t, c], c.runtime == ^runtime)

    Repo.one(query)
  end

  @doc """
  Every conversation still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: for a machine event that belongs on all of their
  transcripts, such as the checkpoint a park records.
  """
  def _unsafe_list_holder_ids(sandbox_id) when is_binary(sandbox_id) do
    Repo.all(
      from c in Conversation,
        where: c.sandbox_id == ^sandbox_id and c.status not in ["terminated", "failed"],
        select: c.id
    )
  end

  @doc """
  The other conversations still holding `sandbox_id` — not `terminated` or
  `failed` — as ids: the machine's co-tenants, for a lifecycle decision one
  of them is about to make for all of them. With `nil` for `conv_id`, every
  one of them: a machine operation nobody bound to it asked for.

  The same reading of the machine as the predicates above and below it
  (`Fountain.Machines.Occupancy`, ADR 0058 stage 4), returned as a list rather
  than a verdict.
  """
  def _unsafe_list_cotenant_ids(sandbox_id, nil) when is_binary(sandbox_id),
    do: Occupancy.bindings(sandbox_id).bound

  def _unsafe_list_cotenant_ids(sandbox_id, conv_id)
      when is_binary(sandbox_id) and is_binary(conv_id) do
    sandbox_id |> Occupancy.bindings() |> Occupancy.cotenant_ids(conv_id)
  end

  @doc """
  Whether any *other* conversation on `sandbox_id` is mid-turn, or was active
  within the last `idle_seconds`.

  A server that finds its own conversation idle asks this before parking the
  machine everyone is on: the idle verdict is the machine's, taken over the
  union of its conversations' activity (ADR 0023 step 5), not one
  conversation's clock. Activity is a co-tenant's newest turn row (start or
  end), falling back to the conversation's own `updated_at` for one that
  never took a turn — the same fold `SandboxReaper.last_activity_at/1` makes
  for a sandbox with no server at all. `nil` idle seconds (the bound is off)
  is never busy.

  The query and the verdict both live in `Fountain.Machines.Occupancy` (ADR
  0058 stage 4), which is the one answer to "is anyone here" that
  `Machines.Binding.held_by_other?/2` and the two liveness scans also
  take. The semantics that separate them stay separate: this one applies the
  idle window, and `held_by_other?/2` deliberately does not.

  Still the same two short-circuiting `EXISTS` probes over the co-tenants that
  it has always run — this sits on the conversation server's lifecycle tick,
  so it takes `Occupancy`'s by-id form rather than loading the whole machine.
  """
  def _unsafe_sandbox_busy_elsewhere?(
        sandbox_id,
        conv_id,
        idle_seconds,
        now \\ DateTime.utc_now()
      )

  def _unsafe_sandbox_busy_elsewhere?(_sandbox_id, _conv_id, nil, _now), do: false

  def _unsafe_sandbox_busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
      when is_integer(idle_seconds) do
    Occupancy.busy_elsewhere?(sandbox_id, conv_id, idle_seconds, now)
  end

  @doc """
  Update a turn's row. When the update ends the turn — its status becomes
  `completed`, `failed` or `interrupted` — the assistant's text for the
  turn is materialised into `reply_text` in the same write (#826). Conditional
  completion and orphan reconciliation also materialize the reply in their
  transactions. A turn that already carries a `reply_text` keeps it.
  """
  def _unsafe_update_turn(%Turn{} = turn, attrs) do
    # ownership: this is the already-owned actor's turn or a system recovery write.
    turn |> Turn.changeset(attrs) |> maybe_put_reply_text(turn) |> Repo.update()
  end

  @doc """
  Complete a running turn only on the actor's current sandbox binding.

  Lock the conversation and turn in that order, and commit the outcome with
  the reply and parent idle status. A moved or
  terminal conversation is a no-op. An already-ended current turn can release
  its parent without announcing another terminal event. Reply materialization
  shares that transaction;
  the sidebar publication runs after it commits. The optional
  `:exit_code` is persisted atomically with the result.

  Only the latest generation can idle a running parent.

  `"interrupted"` is a terminal status this writer accepts. The two-phase
  interrupt the server drives itself is a different write, and it keeps the
  conversation running until the peer has stopped.
  """
  def _unsafe_complete_turn(%Turn{} = turn, sandbox_id, status, opts \\ [])
      when status in ["completed", "failed", "interrupted"] do
    end_running_turn(turn, sandbox_id, status, true, Map.new(Keyword.take(opts, [:exit_code])))
  end

  @doc """
  Withdraw an actor's turn whose prompt never reached an agent (#3005): its
  adapter did not start, and the provider then said the machine was gone.
  Only `Fountain.Machines.Admission.end_turn/3` calls this.

  Under the parent and turn locks, and only for the conversation's newest
  turn while it is still `running` and the conversation is still bound to
  `sandbox_id`: the turn row is deleted, with its images and its stage
  events, and the parent goes back to `idle`. Nothing of the turn reached an
  agent, so there is nothing of it to keep, and the prompt runs again under
  the same turn number on the rebuilt machine, where a client following that
  number finds it. Audited after the commit as `conversation.turn.withdrawn`.

  `{:ok, turn}` for the turn withdrawn, `:noop` when the fence refused or
  the turn had already ended (a destroy of the machine ends its running
  turns), `{:error, reason}` from the transaction.
  """
  @spec _unsafe_withdraw_turn(Turn.t(), Ecto.UUID.t() | nil) ::
          {:ok, Turn.t()} | :noop | {:error, term()}
  def _unsafe_withdraw_turn(%Turn{} = turn, sandbox_id) do
    # ownership: the actor supplied its own turn and sandbox binding.
    result =
      TurnLocks._unsafe_end_actor_turn(turn, sandbox_id, "failed", %{}, fn conv, ending ->
        if ending.running? and TurnLocks.latest_turn?(conv.id, ending.turn.id) do
          Repo.delete!(ending.turn)

          conv =
            if conv.status == "running",
              do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
              else: conv

          {:withdrawn, ending.turn, conv}
        else
          :noop
        end
      end)

    case result do
      {:ok, {:withdrawn, withdrawn, conv}} ->
        broadcast_sidebar_update(conv.user_id)

        # This row also bounds automatic rebuilds (`MachineLoss`), so a write
        # that fails is said loudly.
        with {:error, reason} <-
               Audit.record(%{
                 user_id: conv.user_id,
                 action: "conversation.turn.withdrawn",
                 resource_type: "turn",
                 resource_id: withdrawn.id,
                 actor: "system:conversation_server",
                 metadata: %{
                   "conversation_id" => withdrawn.conversation_id,
                   "turn_number" => withdrawn.turn_number,
                   "reason" => "machine_lost"
                 }
               }) do
          Logger.error("turn #{withdrawn.id}: withdrawal not audited: #{inspect(reason)}")
        end

        {:ok, withdrawn}

      {:ok, :noop} ->
        :noop

      {:error, _} = error ->
        error
    end
  end

  # Door for `Fountain.Conversations.Interruption` (#2213), which shares this
  # helper with `_unsafe_complete_turn/4` above and so cannot move with it.
  @doc false
  def end_running_turn(turn, sandbox_id, status, idle?, attrs \\ %{}) do
    # ownership: the actor supplied its original turn and sandbox binding.
    result =
      TurnLocks._unsafe_end_actor_turn(turn, sandbox_id, status, attrs, fn conv, ending ->
        changeset = Turn.changeset(ending.turn, ending.attrs)

        changeset =
          if ending.running?,
            do: maybe_put_reply_text(changeset, ending.turn),
            else: changeset

        updated = Repo.update!(changeset)

        # Completion releases only its newest ended generation. Interrupt keeps
        # the parent running until the peer stops and its second half idles it.
        updated_conv =
          if idle? and updated.status in ["completed", "failed", "interrupted"] and
               conv.status == "running" and
               TurnLocks.latest_turn?(conv.id, turn.id),
             do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
             else: conv

        {updated, updated_conv, ending.running?}
      end)

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated, conv, announce?}} ->
        if idle?, do: broadcast_sidebar_update(conv.user_id)
        if announce?, do: {:ok, updated}, else: :noop

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Finish an actor's machine-gone notification, and release a stranded parent.

  Lock the parent through the running-turn check and any idle write, as
  admission does. A deleted conversation or a newer running turn makes this a
  no-op. `:ok` says the notification is this actor's to narrate: the binding
  still names the sandbox it closed and the conversation is not terminal. A
  moved or terminal conversation answers `:noop`, so an obsolete actor emits no
  sandbox event. Publication happens after commit, and this function performs
  no provider or actor I/O.

  The idle write is not conditioned on the binding, and that is deliberate.
  Under the parent lock a `running` conversation with no running turn is not a
  legitimate transient: admission inserts the running turn and sets the parent
  `running` in one transaction under this same lock (`_unsafe_create_turn_on_sandbox/3`),
  and the two other writers of `running` (`Reattachment` and `Connection`) both
  have their running turn in hand. So that pair is a stuck row, and the sweeps
  cannot repair it — `SandboxReaper.sweep_stuck_turns/0` and
  `TurnLocks._unsafe_recover_turn/3` both select a running turn, and there
  is none. `_unsafe_idle_interrupted_turn/1` declines to recheck the binding for
  exactly this reason and names this function as its backstop (#2000); a
  refusal here would strand the parent with nothing left to release it.
  Releasing it is a repair, not an act of the stale actor, so it still answers
  `:noop` and publishes nothing.
  """
  def _unsafe_finish_machine_gone(conversation_id, sandbox_id) do
    {:ok, result} =
      Repo.transaction(fn ->
        conversation_query =
          from(c in Conversation, where: c.id == ^conversation_id, lock: "FOR UPDATE")

        running_query =
          from(t in Turn, where: t.conversation_id == ^conversation_id and t.status == "running")

        with %Conversation{} = conv <- Repo.one(conversation_query),
             false <- Repo.exists?(running_query) do
          # A terminal conversation is never `running`, so this decides the
          # answer, never the write.
          current? = conv.sandbox_id == sandbox_id and conv.status not in ["terminated", "failed"]

          cond do
            conv.status == "running" ->
              idled = conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!()
              if current?, do: {:updated, idled}, else: {:released, idled}

            current? ->
              :unchanged

            true ->
              :noop
          end
        else
          _ -> :noop
        end
      end)

    case result do
      {:updated, conv} ->
        broadcast_sidebar_update(conv.user_id)
        :ok

      {:released, conv} ->
        broadcast_sidebar_update(conv.user_id)
        :noop

      :unchanged ->
        :ok

      :noop ->
        :noop
    end
  end

  @doc """
  Reconciles a turn left `running` after its server or runtime disappeared.

  The turn transition and the conversation's `running` to `idle` transition
  are conditional writes. If another process already ended the turn, this is
  a no-op rather than overwriting its result. `orphaned_at` records that the
  true end of work is unknown, which keeps the interval out of billing and
  usage attribution.

  This function is unscoped because it is called by a conversation's own
  server and by the system reaper, both through
  `Fountain.Machines.Machine.end_turn/3` (ADR 0058 stage 8a), its only
  caller. Callers may supply audit attribution.

  An actor recovering its own turn passes `:sandbox_id`, its binding; the
  locked parent having been rebound to another sandbox answers
  `{:error, :ownership_changed}` and writes nothing
  (`Fountain.Machines.Admission.bound?/2`). The reaper omits the key, because
  it recovers on nobody's behalf.
  """
  def _unsafe_orphan_turn(%Turn{} = turn, why, opts \\ []) do
    # ownership: this is the existing actor's turn or a system recovery candidate.
    recover_opts = Keyword.take(opts, [:sandbox_id])

    result =
      TurnLocks._unsafe_recover_turn(
        turn,
        fn current, conv, latest? ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          reply_text = current.reply_text || _unsafe_turn_reply_text(current)

          updates =
            if current.status == "running",
              do: [status: "interrupted", ended_at: now, orphaned_at: now],
              else: [orphaned_at: now]

          updated =
            current
            |> Turn.changeset(Map.new(maybe_set_reply_text(updates, reply_text)))
            |> Repo.update!()

          conversation_changed? = latest? and conv.status == "running"

          conv =
            if conversation_changed?,
              do: conv |> Conversation.changeset(%{status: "idle"}) |> Repo.update!(),
              else: conv

          {updated, conv, conversation_changed?}
        end,
        recover_opts
      )

    case result do
      {:ok, :noop} ->
        :noop

      {:ok, {updated_turn, conv, conversation_changed?}} ->
        if conversation_changed?, do: broadcast_sidebar_update(conv.user_id)

        metadata = %{
          outcome: "turn_orphaned",
          turn_id: turn.id,
          turn_number: turn.turn_number,
          reason: why
        }

        publish_stage(turn.conversation_id, "reattach", "interrupted", metadata)

        # The turn's own end, on the stage a client waits on for it (#2529).
        # The `reattach` event above is the recovery's record; without this a
        # client that keys on `turn` events never learns that the turn it is
        # watching is over. `TurnLocks._unsafe_recover_turn/3` calls the writer
        # only for a turn still `running`, so this write is what ended it.
        publish_stage(turn.conversation_id, "turn", "interrupted", metadata)

        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.turn.orphaned",
          resource_type: "turn",
          resource_id: turn.id,
          actor: Keyword.get(opts, :actor, "system:conversation_server"),
          metadata: %{
            "conversation_id" => turn.conversation_id,
            "turn_number" => turn.turn_number,
            "reason" => why
          }
        })

        {:ok, updated_turn, conv}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_set_reply_text(updates, nil), do: updates

  defp maybe_set_reply_text(updates, reply_text),
    do: Keyword.put(updates, :reply_text, reply_text)

  @doc """
  Record a turn's end-of-turn token usage (#827): stamp `usage` on the turn
  and add its `input` / `output` to the conversation's running sums, in one
  transaction. `usage` is the normalised map `Managoat.ACP.Usage`
  produces (`%{"input" => n, "output" => n, ...}`); nil records nothing.

  Once per turn, by the ConversationServer when the `session/prompt`
  response arrives — never from the live `usage_update`s, whose meaning
  differs per runtime (a per-call delta, a thread total, a per-step figure).
  A second call for the same turn would double-count the conversation, so
  it refuses when the turn already carries a usage.

  The one usage map that is not an end-of-turn record is the turn-start
  inference stamp (#1685), which turns from before ADR 0075 carry: it has no
  token figure, so it has counted towards nothing and there is nothing to
  double. This write merges over it.
  """
  def _unsafe_record_turn_usage(%Turn{}, nil), do: :ok

  def _unsafe_record_turn_usage(%Turn{usage: %{} = recorded} = turn, %{} = usage) do
    if Turn.inference_stamp_only?(recorded),
      do: write_turn_usage(turn, Map.merge(recorded, usage)),
      else: {:error, :already_recorded}
  end

  def _unsafe_record_turn_usage(%Turn{} = turn, %{} = usage), do: write_turn_usage(turn, usage)

  defp write_turn_usage(%Turn{} = turn, %{} = usage) do
    # `usage` is whatever the runtime reported. The map is stored as it came,
    # but the counters it increments are bigints: a string or an object here
    # used to raise inside the transaction and take the turn's usage
    # recording with it. Anything that is not a non-negative integer counts
    # as nothing, which is what an unreported figure already counts as.
    Repo.transaction(fn ->
      # Same parent-before-turn lock order as TurnLocks. Duplicate deliveries
      # cannot count twice.
      Repo.one(from c in Conversation, where: c.id == ^turn.conversation_id, lock: "FOR UPDATE") ||
        Repo.rollback(:not_found)

      current =
        Repo.one(
          from t in Turn,
            where: t.id == ^turn.id and t.conversation_id == ^turn.conversation_id,
            lock: "FOR UPDATE"
        ) || Repo.rollback(:not_found)

      # The row read under the lock is what decides, not the one the caller
      # matched on — that is the whole point of re-reading it. But `usage` is
      # not only a figure: a turn carries an inference stamp from the moment
      # it starts (#1685), which is a map and is not a recorded usage. Refuse
      # a real second figure, and merge over a stamp exactly as
      # `_unsafe_record_turn_usage/2` does on the unlocked read above.
      # Checking `is_map/1` alone refused every stamped turn.
      usage =
        cond do
          is_nil(current.usage) -> usage
          Turn.inference_stamp_only?(current.usage) -> Map.merge(current.usage, usage)
          true -> Repo.rollback(:already_recorded)
        end

      # Read from the merged map because that is what gets stored; the two
      # agree either way, since the only map the merge folds in is a stamp and
      # a stamp carries no counter. Do not read this as defending against a
      # stamp that grows one — if that were possible the merge would debit it
      # here and again when the real figure landed, so the ordering would be
      # the bug rather than the guard.
      #
      # `usage` is whatever the runtime reported. The map is stored as it came,
      # but the counters it increments are bigints: a string or an object here
      # used to raise inside the transaction and take the turn's usage
      # recording with it. Anything that is not a non-negative integer counts
      # as nothing, which is what an unreported figure already counts as.
      input = counter_value(Map.get(usage, "input"))
      output = counter_value(Map.get(usage, "output"))

      {:ok, updated} = current |> Turn.changeset(%{usage: usage}) |> Repo.update()

      {1, _} =
        Repo.update_all(
          from(c in Conversation, where: c.id == ^turn.conversation_id),
          inc: [usage_input_tokens: input, usage_output_tokens: output]
        )

      updated
    end)
  end

  defp counter_value(n) when is_integer(n) and n >= 0, do: n
  defp counter_value(_), do: 0

  @terminal_turn_statuses ~w(completed failed interrupted)

  defp maybe_put_reply_text(%Ecto.Changeset{valid?: false} = changeset, _turn), do: changeset

  # `get_field`, not `get_change`: a terminal turn whose text is still null is
  # re-derived on each later write rather than only on the write that ended
  # it. That is the same work
  # `_unsafe_backfill_reply_texts/0` below does, on the same rows, for the same
  # reason — a turn whose assistant blocks landed after its status did. The
  # guard is `reply_text: nil`, so a turn that has one is never revisited.
  defp maybe_put_reply_text(changeset, %Turn{reply_text: nil} = turn) do
    case Ecto.Changeset.get_field(changeset, :status) do
      status when status in @terminal_turn_statuses ->
        Ecto.Changeset.put_change(changeset, :reply_text, _unsafe_turn_reply_text(turn))

      _ ->
        changeset
    end
  end

  defp maybe_put_reply_text(changeset, _turn), do: changeset

  @doc """
  Materialise `reply_text` on every ended turn that has none — the one-time
  backfill for turns that predate the column (`Fountain.Release.backfill_turn_replies/0`).
  Returns the number of turns written; a turn with no assistant text is
  left null and visited again next run (there are few, and re-parsing them
  is cheap). No tenant scope: a system sweep.
  """
  def _unsafe_backfill_reply_texts do
    from(t in Turn,
      where: t.status in ^@terminal_turn_statuses and is_nil(t.reply_text),
      order_by: [asc: t.inserted_at]
    )
    |> Repo.all()
    |> Enum.reduce(0, fn turn, n ->
      case _unsafe_turn_reply_text(turn) do
        nil ->
          n

        text ->
          {:ok, _} = turn |> Turn.changeset(%{reply_text: text}) |> Repo.update()
          n + 1
      end
    end)
  end

  @doc """
  The assistant's text for `turn`, from its events through the same parse
  the transcript uses (`Blocks.assistant_text/1`); nil when there is none.
  Without tenant scope: the caller holds the turn.
  """
  def _unsafe_turn_reply_text(%Turn{} = turn) do
    case turn.id |> _unsafe_list_turn_log_events() |> Blocks.assistant_text() do
      "" -> nil
      text -> text
    end
  end

  # ── log events ──────────────────────────────────────────────────────────────────────────

  @doc """
  Total persisted bytes of `kind: "output"` log data for a conversation.
  Without tenant scoping — the caller is the conversation's own server,
  seeding the durable-output budget (#331).
  """
  def _unsafe_output_byte_total(conversation_id) do
    Repo.one(
      from(l in LogEvent,
        where: l.conversation_id == ^conversation_id and l.kind == "output",
        select: coalesce(sum(fragment("octet_length(?)", l.data)), 0)
      )
    )
  end

  @doc """
  Insert a log event. Returns the inserted struct (with integer `:id`,
  used as the SSE event id). Stage callers use `publish_stage/4`.
  """
  def log!(attrs) do
    # Microsecond precision so the LiveView can compute stage durations
    # under 1s (provision steps run in tens of ms).
    attrs = Map.put_new(attrs, :inserted_at, DateTime.utc_now())

    # Redact here rather than at the call sites. Sprite output is persisted
    # verbatim and log_events has none of the encryption the secret itself has,
    # so a path that forgets to scrub writes plaintext credentials to a table
    # that outlives the conversation. Doing it at the single writer means a new
    # log path is covered whether or not its author knew to.
    attrs = attrs |> redact_attrs() |> sanitize_raw_output()

    # The ordered insert (#1706), not a bare `Repo.insert!`: events must take
    # the account's SSE cursor lock, or they can commit out from behind the
    # cursor and never be seen.
    %LogEvent{} |> LogEvent.changeset(attrs) |> insert_ordered_log_event!()
  end

  defp insert_ordered_log_event!(%Ecto.Changeset{valid?: true} = changeset) do
    conversation_id = Ecto.Changeset.get_field(changeset, :conversation_id)

    {:ok, event} =
      Repo.transaction(fn ->
        # Account SSE cursors advance by id. Allocate that id only after all
        # earlier writes for this account commit, including other conversations
        # and outer transactions. Otherwise N+1 can commit first and hide N
        # forever behind the cursor (#1706). Other accounts have separate locks.
        Repo.query!(
          "SELECT pg_advisory_xact_lock($1, hashtext(user_id::text)) " <>
            "FROM conversations WHERE id = $2",
          [@log_event_lock_namespace, Ecto.UUID.dump!(conversation_id)]
        )

        Repo.insert!(changeset)
      end)

    event
  end

  defp insert_ordered_log_event!(changeset), do: Repo.insert!(changeset)

  defp redact_attrs(%{conversation_id: conv_id, data: data} = attrs)
       when is_binary(conv_id) and is_binary(data) do
    %{attrs | data: Fountain.Conversations.Redaction.redact(conv_id, data)}
  end

  defp redact_attrs(attrs), do: attrs

  defp sanitize_raw_output(%{kind: "output", stream: stream, data: data} = attrs)
       when stream in ["stdout", "stderr"] and is_binary(data) do
    # Transport chunks can split UTF-8 or contain arbitrary bytes (#2372).
    # PostgreSQL text also rejects NUL. Replace after redaction so registered
    # binary values still match, and use one-byte replacements so sanitizing
    # cannot expand the data beyond Output's byte budget. This is per row:
    # a codepoint split across rows is replaced on each side of the boundary.
    data = data |> String.replace_invalid("?") |> String.replace(<<0>>, "?")
    %{attrs | data: data}
  end

  defp sanitize_raw_output(attrs), do: attrs

  @doc """
  Record a stage transition: persist the log event, broadcast it to the
  conversation's PubSub topic, and emit a `[:fountain, :stage]` telemetry
  event.

  `stage` and `status` are the metric's only tags; both value sets are small
  and fixed. `conv_id` stays in metadata and must never become a tag.
  """
  def publish_stage(conv_id, stage, status, meta \\ %{}) do
    turn_id = Map.get(meta, :turn_id) || Map.get(meta, "turn_id")

    event =
      log!(%{
        conversation_id: conv_id,
        turn_id: turn_id,
        kind: "stage",
        stage: stage,
        state: status,
        data: Jason.encode!(meta)
      })

    notify_stage(event)
    event
  end

  defp notify_stage(event) do
    conv_id = event.conversation_id
    stage = event.stage
    status = event.state

    Fountain.Telemetry.event(
      [:stage],
      %{stage: stage, status: status, conv_id: conv_id},
      %{count: 1}
    )

    Phoenix.PubSub.broadcast(Fountain.PubSub, "conv:#{conv_id}", {:log_event, event})

    event
  end

  @doc """
  One turn's log events, oldest first — the events a single reply is rendered
  from. Ownership rides on the turn: reach it through a tenant-scoped
  conversation first.
  """
  def _unsafe_list_turn_log_events(turn_id) when is_binary(turn_id) do
    Repo.all(from e in LogEvent, where: e.turn_id == ^turn_id, order_by: [asc: e.id])
  end

  @doc """
  List a conversation's log events after `after_id`, oldest first.

  Options:

    * `:streams` — allow-list of `"stdout"` / `"stderr"` / `"stage"`
    * `:before` — only events with an id below this; `nil` for no bound
    * `:limit` — cap the number of rows returned. A log feed is unbounded
      in principle (a chatty agent writes tens of thousands of rows), so
      the JSON read-model paginates rather than materialising all of it.
  """
  def _unsafe_list_log_events(conversation_id, after_id \\ 0, opts \\ []) do
    base =
      from e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^after_id,
        order_by: [asc: e.id]

    base
    |> apply_before(Keyword.get(opts, :before))
    |> apply_streams_filter(Keyword.get(opts, :streams))
    |> apply_limit(Keyword.get(opts, :limit))
    |> Repo.all()
  end

  @doc """
  One page of a conversation's log events, newest first (#2531).

  The backward half of `_unsafe_list_log_events/3`, for a client that opens a
  long conversation at its newest turns instead of draining it from the start.
  Returns `%{events: events, has_more: boolean, turn_split: boolean}`, with
  `events` in descending id order and `has_more` saying whether matching
  events older than the page exist.

  Options:

    * `:limit` (required) — the page size.
    * `:before` — only events with an id below this. `nil` starts at the newest.
    * `:after` — only events with an id above this. Defaults to `0`.
    * `:streams` — the same allow-list as `_unsafe_list_log_events/3`.
    * `:whole_turns` — never end the page inside a turn. When the `limit`th
      event belongs to a turn whose first event is older, the page extends
      down to that first event, taking every matching event in the range,
      including other turns' and turn-less events interleaved with it; a turn
      those bring in extends it again. A page's turns are therefore complete
      below the `:before` cursor, and a follow-up `before: <oldest id>` never
      returns an event of one of them.
    * `:max_events` — the ceiling on a whole-turn page, 5,000 by default. A
      turn too large for it is cut at the ceiling, the page is flagged
      `turn_split: true`, and the rest of the turn is on the next page.

  Cursors are ids read from rows: IDs are global and sparse, so nothing here
  counts back from an id. The `(conversation_id, id)` index is read backwards
  for the page and the range; the `(turn_id, id)` index answers each turn's
  first event.
  """
  def _unsafe_list_log_events_backward(conversation_id, opts) do
    limit = Keyword.fetch!(opts, :limit)

    query =
      from(e in LogEvent,
        where: e.conversation_id == ^conversation_id and e.id > ^Keyword.get(opts, :after, 0),
        order_by: [desc: e.id]
      )
      |> apply_before(Keyword.get(opts, :before))
      |> apply_streams_filter(Keyword.get(opts, :streams))

    # One extra row decides has_more without a count.
    rows = query |> apply_limit(limit + 1) |> Repo.all()

    case Enum.split(rows, limit) do
      {page, []} ->
        %{events: page, has_more: false, turn_split: false}

      {page, _older} ->
        if Keyword.get(opts, :whole_turns, false) do
          max_events = Keyword.get(opts, :max_events, 5000)
          complete_turns(query, conversation_id, page, List.last(page).id, max_events)
        else
          %{events: page, has_more: true, turn_split: false}
        end
    end
  end

  defp apply_before(query, nil), do: query
  defp apply_before(query, before) when is_integer(before), do: where(query, [e], e.id < ^before)

  # `floor` is the lowest id the page covers: every matching event with an id
  # from `floor` up to the page's cursor is already in `page`. Only turns that
  # entered the page since the last pass can start below it.
  defp complete_turns(query, conversation_id, page, floor, max_events),
    do: complete_turns(query, conversation_id, page, floor, max_events, turn_ids(page))

  defp complete_turns(query, conversation_id, page, floor, max_events, new_turn_ids) do
    case first_turn_event_id(conversation_id, new_turn_ids) do
      start when is_integer(start) and start < floor ->
        room = max_events - length(page)

        extra =
          query
          |> where([e], e.id >= ^start and e.id < ^floor)
          |> apply_limit(room + 1)
          |> Repo.all()

        if length(extra) > room do
          # The ceiling: the rows past it are still there, so this is a split.
          %{events: page ++ Enum.take(extra, room), has_more: true, turn_split: true}
        else
          complete_turns(
            query,
            conversation_id,
            page ++ extra,
            start,
            max_events,
            turn_ids(extra)
          )
        end

      _ ->
        %{events: page, has_more: older_events?(query, floor), turn_split: false}
    end
  end

  defp turn_ids(events) do
    for %LogEvent{turn_id: turn_id} <- events, turn_id != nil, uniq: true, do: turn_id
  end

  # The id of the earliest first event among these turns, or nil. One probe of
  # the `(turn_id, id)` index per turn rather than a `min` over the
  # conversation, which the planner may answer by walking the conversation's
  # index from its first row.
  defp first_turn_event_id(_conversation_id, []), do: nil

  defp first_turn_event_id(conversation_id, turn_ids) do
    %{rows: [[first]]} =
      Repo.query!(
        """
        SELECT min(first.id)
        FROM unnest($1::uuid[]) AS t(id)
        CROSS JOIN LATERAL (
          SELECT e.id FROM log_events e
          WHERE e.turn_id = t.id AND e.conversation_id = $2
          ORDER BY e.id
          LIMIT 1
        ) AS first
        """,
        [Enum.map(turn_ids, &Ecto.UUID.dump!/1), Ecto.UUID.dump!(conversation_id)]
      )

    first
  end

  defp older_events?(query, floor) do
    query |> where([e], e.id < ^floor) |> exclude(:order_by) |> Repo.exists?()
  end

  @doc "The newest durable event cursor across this user's conversations, or zero."
  def latest_user_log_event_id(user_id) when is_binary(user_id) do
    user_log_events_query(user_id)
    |> select([e], max(e.id))
    |> Repo.one()
    |> Kernel.||(0)
  end

  @doc """
  Durable events after a user's cursor, including conversations that have finished.
  Returns at most 500 rows in id order.
  """
  def list_user_log_events(user_id, after_id) when is_binary(user_id) do
    user_log_events_query(user_id)
    |> where([e], e.id > ^after_id)
    |> order_by([e], asc: e.id)
    |> limit(500)
    |> select([e], e)
    |> Repo.all()
  end

  defp user_log_events_query(user_id) do
    from e in LogEvent,
      join: c in Conversation,
      on: c.id == e.conversation_id,
      where: c.user_id == ^user_id
  end

  defp apply_limit(query, nil), do: query

  defp apply_limit(query, limit) when is_integer(limit) and limit > 0,
    do: from(e in query, limit: ^limit)

  # `streams` is a list of allowed stream identifiers: any value of the
  # `stream` column, plus `"stage"`, the synthetic name for `kind: "stage"`
  # events (which have no `stream` value of their own). `nil`/empty list =
  # no filter.
  #
  # There is deliberately **no allow-list of stream names**. There used to be
  # one — `["stdout", "stderr"]`, written when those were the only two — and
  # when ACP added a third (`"acp"`, one stored `session/update` per line) the
  # filter silently answered "nothing" for it: an unrecognised name fell to a
  # `where: false`. A name we do not know is now simply a name no row has,
  # which returns nothing on its own without a list to keep in step.
  #
  # `event_in_streams?/2` is the same rule for an event already in hand. The
  # two must agree — see the test that runs one table through both. They did
  # not agree before, and the gap was invisible in exactly the way that hurts:
  # live events matched, replayed ones did not, so a filtered stream returned
  # a conversation's future and none of its past.
  defp apply_streams_filter(query, nil), do: query
  defp apply_streams_filter(query, []), do: query

  defp apply_streams_filter(query, streams) when is_list(streams) do
    real_streams = Enum.reject(streams, &(&1 == "stage"))
    include_stage? = "stage" in streams

    cond do
      include_stage? and real_streams != [] ->
        from e in query,
          where: e.kind == "stage" or e.stream in ^real_streams

      include_stage? ->
        from e in query, where: e.kind == "stage"

      true ->
        from e in query, where: e.stream in ^real_streams
    end
  end

  @doc """
  Whether one already-loaded event belongs to a `?streams=` selection.

  The in-memory half of `apply_streams_filter/2`, used for events arriving
  live over PubSub, where there is no query to add a `where` to. It lives here
  rather than in the controller so the two halves of one rule sit together and
  are tested together.
  """
  @spec event_in_streams?(LogEvent.t(), [String.t()] | nil) :: boolean()
  def event_in_streams?(_ev, nil), do: true
  def event_in_streams?(_ev, []), do: true
  def event_in_streams?(%LogEvent{kind: "stage"}, streams), do: "stage" in streams

  def event_in_streams?(%LogEvent{stream: s}, streams) when is_binary(s),
    do: s in streams

  def event_in_streams?(_ev, _streams), do: false

  @doc """
  The most recent persisted output lines of one stream for a turn, as a set.

  Feeds the ACP reattach path: sprites replays the tail of the session buffer
  (measured at 16 KiB), and the peer re-encodes protocol lines so a byte count
  cannot align the replay with what is already stored — content can. `limit`
  rows is comfortably more than 16 KiB of `session/update` lines.
  """
  def _unsafe_recent_output_lines(conversation_id, turn_id, stream, limit \\ 400) do
    from(e in LogEvent,
      where:
        e.conversation_id == ^conversation_id and e.turn_id == ^turn_id and
          e.kind == "output" and e.stream == ^stream,
      order_by: [desc: e.id],
      limit: ^limit,
      select: e.data
    )
    |> Repo.all()
    |> MapSet.new()
  end

  # ── high-level lifecycle ──────────────────────────────────────────────────────────

  alias Fountain.Agents
  alias Fountain.Conversations.ConversationServer

  # A resume lands on the conversation the binding already has, so labels on
  # the request are merged into it rather than dropped (#1637). A caller that
  # sends none changes nothing, and the resume stays the silent path it was.
  #
  # The same scoped ownership rule as set_conversation_labels/4, applied to
  # the row resume_channel read under admission's source lock. Keep the audit
  # outside that transaction so a failed audit cannot undo a successful resume.
  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def resume_labels(%Conversation{} = conv, nil, _opts), do: {:ok, conv, nil}

  def resume_labels(%Conversation{} = conv, labels, opts) do
    if sandbox_owns?(conv, Keyword.get(opts, :sandbox_key_id)),
      do: merge_labels(conv, labels),
      else: {:error, :sprite_may_not_label_another_conversation}
  end

  # A nested transaction does not commit: workers and provider calls must not
  # escape a caller's transaction that can still roll back the accepted rows.
  # Public (door for `Fountain.Conversations.Wake`, #2211, and
  # `Fountain.Conversations.Launch`, #2217).
  @doc false
  def require_provider_commit_boundary do
    if Repo.in_transaction?(), do: {:error, :provider_transaction_open}, else: :ok
  end

  @doc "One of the caller's sandboxes, or nil. A foreign or malformed id reads as nil."
  def get_sandbox(id, user_id) when is_binary(id) and is_binary(user_id) do
    case Ecto.UUID.dump(id) do
      {:ok, _} ->
        Repo.one(from s in Lease.machines(), where: s.id == ^id and s.user_id == ^user_id)

      :error ->
        nil
    end
  end

  @doc """
  The caller's sandboxes, newest first, each with its conversations (newest
  first). `status: [...]` filters; anything else lists every status, the
  terminated ones included — a machine's history is part of the account.
  """
  def list_sandboxes(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from(s in Lease.machines(),
        where: s.user_id == ^user_id,
        order_by: [desc: s.inserted_at, desc: s.id]
      )

    query =
      case Keyword.get(opts, :status) do
        [_ | _] = statuses -> where(query, [s], s.status in ^statuses)
        _ -> query
      end

    query
    |> Repo.all()
    |> Repo.preload(conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
  end

  @doc "`get_sandbox/2` with the conversations preloaded, newest first."
  def get_sandbox_with_conversations(id, user_id) when is_binary(id) and is_binary(user_id) do
    case get_sandbox(id, user_id) do
      nil ->
        nil

      s ->
        Repo.preload(s, conversations: from(c in Conversation, order_by: [desc: c.inserted_at]))
    end
  end

  # A door for the conversation modules; not part of the context's public
  # surface.
  @doc false
  def broadcast_sidebar_update(user_id) when is_binary(user_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "sidebar:#{user_id}",
      {:sidebar_update, user_id}
    )
  end

  defp first_turn_query, do: from(t in Turn, where: t.turn_number == 1)

  defp short_id, do: Ecto.UUID.generate() |> binary_part(0, 8)

  # The sandbox name is minted here and stamped on the row; the adapter is
  # handed nothing else (ADR 0018).
  #
  # A caller-supplied name is a *suffix*, never the whole name (#1632). The
  # name is the machine's identity at the provider, where names are unique per
  # deployment token rather than per tenant, and the Sprites adapter adopts on
  # 409 because it assumes Fountain minted every name it asks for. A verbatim
  # override broke that assumption: two rows in two accounts could name one
  # machine, and that machine holds a tenant's decrypted environment and vault
  # values on disk. Keeping this tenant's prefix on every name puts a chosen
  # name in the caller's own namespace: not reachable adversarially, because a
  # caller cannot pick their own user id, though two accounts whose ids share
  # their first eight characters would share a namespace — the live
  # `(provider, machine_name)` unique index (#2141) makes that "cannot" rather
  # than "will not". Names are unique per provider organization, which
  # belongs to this instance alone (ADR 0005, 2026-10-15 addendum). A name that
  # already carries the prefix — one an earlier launch handed back — is taken
  # as it stands.
  # Public (door for `Fountain.Conversations.Wake`, #2211, and
  # `Fountain.Conversations.Launch`, #2217):
  # `create_fresh_sandbox_and_start/4` moved there and calls this remotely;
  # `start_conversation/2` below still calls it locally.
  @doc false
  def mint_machine_name(_provider, user_id, nil),
    do: {:ok, machine_name_prefix(user_id) <> short_id()}

  # An empty override is no override, the way an empty sandbox_mode is.
  def mint_machine_name(provider, user_id, ""), do: mint_machine_name(provider, user_id, nil)

  def mint_machine_name(_provider, user_id, name) when is_binary(name) do
    prefix = machine_name_prefix(user_id)
    suffix = String.replace_prefix(name, prefix, "")

    if Regex.match?(@machine_name_suffix, suffix),
      do: {:ok, prefix <> suffix},
      else: {:error, :invalid_sprite_name}
  end

  defp machine_name_prefix(user_id), do: "fountain-#{tenant_prefix(user_id)}-"

  defp tenant_prefix(user_id) when is_binary(user_id), do: binary_part(user_id, 0, 8)

  # A door for `Fountain.Conversations.Launch` (#2216); not part of the
  # context's public surface.
  @doc false
  def resolve_vault_id(nil, _user_id, _agent), do: {:ok, nil}
  def resolve_vault_id("", _user_id, _agent), do: {:ok, nil}

  def resolve_vault_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_vault_allowed(id, agent) do
      case Fountain.Vaults.get_vault(id, user_id) do
        nil -> {:error, :vault_not_found}
        vault -> {:ok, vault.id}
      end
    end
  end

  # Vault values override the reviewed environment. Use the persisted policy;
  # resolve_vault_id also enforces tenant ownership before attaching a vault.
  defp check_vault_allowed(vault_id, %Agents.Agent{} = agent) do
    if Agents.Agent.vault_allowed?(agent, vault_id), do: :ok, else: {:error, :vault_not_allowed}
  end

  # A per-launch environment override (#783): the conversation is provisioned
  # from this environment instead of the agent's own, and stays pinned to it
  # across wakes. Resolved exactly like the vault — a scoped fetch (a foreign
  # id reads as not found, so it cannot be probed) behind the agent's allowlist.
  # A door for `Fountain.Conversations.Launch` (#2216); not part of the
  # context's public surface.
  @doc false
  def resolve_environment_id(nil, _user_id, _agent), do: {:ok, nil}
  def resolve_environment_id("", _user_id, _agent), do: {:ok, nil}

  def resolve_environment_id(id, user_id, agent) when is_binary(id) and is_binary(user_id) do
    with :ok <- check_environment_allowed(id, agent) do
      case Fountain.Environments.get_environment(id, user_id) do
        nil -> {:error, :environment_not_found}
        env -> {:ok, env.id}
      end
    end
  end

  # An override replaces the reviewed environment wholesale, so it is scoped
  # the same way as a vault: use the persisted policy, which also passes the
  # agent's own environment because naming it is not an override. An
  # unrestricted default is deliberate — a caller who can attach a vault can
  # already override every key, so a stricter default here would guard
  # nothing (#783). resolve_environment_id enforces tenant ownership after.
  defp check_environment_allowed(id, %Agents.Agent{} = agent) do
    if Agents.Agent.environment_allowed?(agent, id),
      do: :ok,
      else: {:error, :environment_not_allowed}
  end

  # Public for `Fountain.Conversations.Launch` (stage 7a of #2175), which
  # owns the channel door; not a request-facing entry point.
  def resolve_saved_inference(conv, agent) do
    with {:ok, source, _credentials} <-
           InferenceResolution.revalidate(conv, agent,
             environment_id: conv.environment_id || agent.environment_id,
             vault_id: conv.vault_id
           ) do
      {:ok, source}
    end
  end

  @doc """
  Answer a permission request a running agent is blocked on (#940).

  Tenant-scoped: the conversation is fetched for `user_id` first, so a request
  id from another tenant reads as not found rather than as a permission error.

  **A sprite may not answer its own prompt.** It holds a `MANAGOAT_TOKEN` and
  could otherwise approve the very tool it just asked for, which would make the
  policy decorative. The loop is closed by name here rather than left to the
  actor vocabulary to imply.

  Audited as a decision about tenant-owned state, per 0013: the tool and the
  verdict, never the tool's input.

  Only a request the running turn is holding can be answered. A request does
  not outlive its turn: the turn's end denies it (ADR 0014).
  """
  @spec answer_permission_request(binary(), binary(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def answer_permission_request(conv_id, user_id, request_id, option_id, opts \\ [])
      when is_binary(conv_id) and is_binary(user_id) do
    actor = Keyword.get(opts, :actor, "self")

    cond do
      actor == "sprite" ->
        {:error, :sprite_may_not_answer}

      is_nil(get_conversation(conv_id, user_id)) ->
        {:error, :not_found}

      true ->
        do_answer_permission(conv_id, user_id, request_id, option_id, opts)
    end
  end

  defp do_answer_permission(conv_id, user_id, request_id, option_id, opts) do
    case ConversationServer.answer_permission(conv_id, request_id, option_id) do
      :ok ->
        Audit.record(%{
          user_id: user_id,
          action: "conversation.permission_answered",
          resource_type: "conversation",
          resource_id: conv_id,
          actor: Keyword.get(opts, :actor, "self"),
          request_ip: Keyword.get(opts, :request_ip),
          metadata: %{"request_id" => request_id, "option_id" => option_id}
        })

        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Answer a form a running agent is blocked on (an ACP `elicitation/create`,
  #2492): Claude's `AskUserQuestion`, an MCP server's form, or the CLI's
  refusal-fallback prompt.

  `action` is `"accept"` (with `content`, checked against the form's schema),
  `"decline"` or `"cancel"`. The same ownership, sprite and "too late" rules
  as `answer_permission_request/5`.

  Audited as `conversation.question_answered` with the action only, never
  the content: what a person typed into a form an MCP server sent may be a
  secret.
  """
  @spec answer_elicitation_request(
          binary(),
          binary(),
          String.t(),
          String.t(),
          map() | nil,
          keyword()
        ) :: :ok | {:error, term()}
  def answer_elicitation_request(conv_id, user_id, request_id, action, content, opts \\ [])
      when is_binary(conv_id) and is_binary(user_id) do
    actor = Keyword.get(opts, :actor, "self")

    cond do
      actor == "sprite" ->
        {:error, :sprite_may_not_answer}

      is_nil(get_conversation(conv_id, user_id)) ->
        {:error, :not_found}

      true ->
        with :ok <- ConversationServer.answer_elicitation(conv_id, request_id, action, content) do
          Audit.record(%{
            user_id: user_id,
            action: "conversation.question_answered",
            resource_type: "conversation",
            resource_id: conv_id,
            actor: actor,
            request_ip: Keyword.get(opts, :request_ip),
            metadata: %{"request_id" => request_id, "action" => action}
          })

          :ok
        end
    end
  end

  @doc """
  Record that the permission policy withheld a tool from a running agent.

  Called by the `ConversationServer` when its peer reports a refusal (#939).
  The actor defaults to `sprite`: the agent asked, the policy answered, and no
  human was involved — attributing it to the person who happened to write the
  policy would be a lie about who was at the keyboard.

  Only refusals are recorded. A turn makes dozens of tool calls and a row per
  allow would make the trail a second copy of the transcript, which 0013
  forbids for exactly this reason. The tool's *input* is never recorded, only
  its name and the verdict.
  """
  @spec record_permission_denied(binary(), String.t() | nil, String.t(), keyword()) :: :ok
  def record_permission_denied(conversation_id, tool, verdict, opts \\ [])
      when is_binary(conversation_id) do
    case _unsafe_get_conversation(conversation_id) do
      nil ->
        :ok

      conv ->
        Audit.record(%{
          user_id: conv.user_id,
          action: "conversation.permission_denied",
          resource_type: "conversation",
          resource_id: conv.id,
          actor: Keyword.get(opts, :actor, "sprite"),
          metadata: %{"tool" => tool, "verdict" => verdict}
        })

        :ok
    end
  end

  # A per-launch permission override (#939). Unlike the vault and environment
  # overrides, this one needs no allowlist on the agent: `check_narrows/2`
  # refuses anything looser than the agent's own policy, so a launch cannot
  # reach a permission the agent did not already grant. There is nothing to
  # allow-list because there is nothing to escalate to.
  #
  # Rejected loudly rather than clamped. `Permissions.effective/2` clamps
  # anyway — that is the invariant the peer relies on — but a caller who asked
  # to loosen a policy and silently got a tighter one would have no way to
  # tell, and the difference matters when the ask was a mistake.
  # A per-conversation model override (ADR 0061), checked exactly as the
  # agent's own model is (`Agent.check_model/2`) against the runtime the
  # conversation runs. No allowlist on the agent: the agent's owner is the
  # conversation's owner, so there is nobody for one to guard against yet.
  #
  # The `acp` runtime resolves no model, so an override there would be stored
  # and never read. Refused, like a `runtime_command` on any other runtime.
  # A door for `Fountain.Conversations.Launch`; not part of the context's
  # public surface.
  @doc false
  def resolve_model(nil, _agent), do: {:ok, nil}
  def resolve_model("", _agent), do: {:ok, nil}

  def resolve_model(model, %Agents.Agent{runtime: runtime}) when is_binary(model) do
    with true <-
           Fountain.RuntimeDispatch.model_required?(runtime) ||
             {:error, "the #{runtime} runtime resolves no model"},
         :ok <- Agents.Agent.check_model(runtime, model) do
      {:ok, model}
    else
      {:error, message} -> {:error, {:model_invalid, message}}
    end
  end

  def resolve_model(_model, _agent), do: {:error, {:model_invalid, "must be a string"}}

  # A door for `Fountain.Conversations.Launch`; not part of the context's
  # public surface.
  @doc false
  def resolve_permission_policy(nil, _agent), do: {:ok, nil}
  def resolve_permission_policy(policy, _agent) when policy == %{}, do: {:ok, nil}

  def resolve_permission_policy(policy, agent) when is_map(policy) do
    with :ok <- validate_policy_shape(policy),
         :ok <- Managoat.ACP.Permissions.check_narrows(agent.permission_policy, policy) do
      {:ok, policy}
    end
  end

  def resolve_permission_policy(_policy, _agent), do: {:error, :permission_policy_invalid}

  defp validate_policy_shape(policy) do
    Enum.find_value(policy, :ok, fn {tool, verdict} ->
      cond do
        not is_binary(tool) or tool == "" ->
          {:error, :permission_policy_invalid}

        verdict not in Managoat.ACP.Permissions.verdicts() ->
          {:error, :permission_policy_invalid}

        not Managoat.ACP.Permissions.buildable?(verdict) ->
          {:error, {:permission_policy_unbuilt, verdict}}

        true ->
          nil
      end
    end)
  end

  # A provider this release no longer knows (`daytona`, removed in 2026-10, on
  # terminal rows kept as history) reads as `:removed`: no adapter serves it and
  # `SandboxProviders.enabled?/1` says no, so the sweeps that walk terminal
  # rows skip it rather than raise on an atom nothing loaded.
  def sandbox_provider_atom(%{provider: provider}) when is_binary(provider) do
    if provider in Fountain.SandboxProviders.known_providers(),
      do: String.to_existing_atom(provider),
      else: :removed
  end

  def sandbox_provider_atom(_sandbox), do: :sprites

  # Placement for a NEW sandbox: the agent's override, else the instance
  # default. Only an override is gated on enabledness — the default keeps its
  # lazy credential check (a credential-less boot fails at provision time
  # with the missing variable named, exactly as before), while an agent
  # pinned to a provider whose credentials were since removed fails here
  # with an error the API/UI can explain.
  # A door for `Fountain.Conversations.Launch` and `Wake`; not part of the
  # context's public surface.
  @doc false
  def resolve_sandbox_provider(%Agents.Agent{sandbox_provider: nil}),
    do: {:ok, Fountain.SandboxProviders.default_provider()}

  def resolve_sandbox_provider(%Agents.Agent{sandbox_provider: value}) do
    provider = String.to_existing_atom(value)

    if Fountain.SandboxProviders.enabled?(provider) do
      {:ok, provider}
    else
      {:error, {:sandbox_provider_disabled, provider}}
    end
  end
end
