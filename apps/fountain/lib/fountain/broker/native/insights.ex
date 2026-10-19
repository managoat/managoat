defmodule Fountain.Broker.Native.Insights do
  @moduledoc """
  What the egress broker is doing, for `/admin/broker` (ADR 0019).

  Everything the broker knows is already on disk — `broker_sessions` says
  which conversations hold a proxy token, and `broker_requests` says what
  each brokered sandbox reached and whether a credential went with it — but
  until this module the only readers were a per-conversation API page and
  the Prometheus series. An operator asking "is the broker healthy, who is
  it brokering, and what is it denying" had to run SQL. This answers those
  three from one call.

  Every function here is `_unsafe_`: the queries span every tenant by
  design, and the one caller is the admin page behind `require_admin`.

  The numbers are bounded by a window (default the last 24 hours, selected
  from 1, 24 or 168 hours) and filter on `inserted_at`. A wide window can
  still read the full retained log, so traffic aggregates refresh only on
  operator action.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Accounts.User
  alias Fountain.Broker
  alias Fountain.Broker.Native.{Request, Session}
  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo

  @default_window_hours 24
  @windows [1, 24, 168]
  @live_sessions_limit 50

  # Sandboxes cutting streams (#2503). Some Sprites machines develop a fault
  # that silently drops any outbound TCP connection idle for about a second,
  # so every streamed reply that pauses dies mid-stream and the broker logs
  # it `client_closed` after 1-20 s. Measured in prod: on healthy traffic
  # (Anthropic streams) `client_closed` is under 1% of forwarded requests; on
  # faulted Codex sandboxes it was about 65%, and 100% for hours. A share of
  # half sits far from both, and ten streams keeps one cancelled turn on a
  # quiet sandbox (a few cut rows out of a handful) from flagging it.
  # `latency_ms` is the whole stream (see `Request`), so a second or more is
  # a stream rather than a quick call a cancelled turn might also cut.
  @forwarded_outcomes ["injected", "passthrough"]
  @stream_min_latency_ms 1_000
  @cut_min_streams 10
  @cut_min_share 0.5
  @cut_sandboxes_limit 20

  @doc "The windows the page offers, in hours."
  @spec windows() :: [pos_integer()]
  def windows, do: @windows

  @doc """
  The whole picture, in one map:

    * `:backend` / `:listener_up` / `:tenants` / `:ca_expires_at` /
      `:retention_hours` — the switch and its health, from configuration and
      the listener, not the database. A deployment that does not broker
      returns these with the rest empty, and the page says so.
    * `:sessions` — live rows, expired rows the reaper has not swept, and
      how many conversations hold one.
    * `:window` — request counts over the window by outcome, plus how many
      conversations and tenants produced them.
    * `:hosts` — the busiest hosts in the window with their outcome split.
    * `:services` — the bindings whose credential the proxy attached, and the
      variable names it attached (never a value).
    * `:denied` — the most recent refusals, each linked to its conversation.
    * `:errors` — how forwarding failed, by reason, in the window. A refusal
      the broker made is not in here; it is counted under `:window.denied`
      and its `:no_credential` subset.
    * `:cut_sandboxes` — sandboxes whose streamed requests the sandbox side
      keeps hanging up on (#2503): at least #{@cut_min_streams} forwarded
      requests of #{@stream_min_latency_ms} ms or more in the window, of
      which at least #{round(@cut_min_share * 100)}% ended `client_closed`.
      That is the signature of a machine dropping quiet connections, which
      only replacing the sandbox clears. Most cut first, at most
      #{@cut_sandboxes_limit}.
    * `:live_sessions` — the sessions themselves, most recently minted first.
      A conversation can hold more than one (`Sessions.create/1` mints on
      every provision and reattach and releases only on expiry), so this is
      capped at #{@live_sessions_limit}; `:live_sessions_total` is the true
      count at the same read, and the page says when the list is short of it.

  `window_hours` is clamped to `windows/0`.
  """
  @spec _unsafe_overview_admin(pos_integer()) :: map()
  def _unsafe_overview_admin(window_hours \\ @default_window_hours) do
    hours = if window_hours in @windows, do: window_hours, else: @default_window_hours
    since = DateTime.add(DateTime.utc_now(), -hours, :hour)
    health = _unsafe_health_admin()

    Map.merge(health, %{
      window_hours: hours,
      window: window_counts(since),
      hosts: top_hosts(since, 10),
      services: top_services(since, 10),
      denied: recent(since, :denied, 20),
      errors: error_counts(since),
      failed: recent(since, :failed, 10),
      cut_sandboxes: cut_sandboxes(since, @cut_sandboxes_limit),
      live_sessions: live_sessions(@live_sessions_limit),
      # Taken with the list, not from `:sessions`: the health tick refreshes
      # that count every 30s and leaves the list alone, so comparing the two
      # would call the list truncated as soon as one new session was minted.
      live_sessions_total: health.sessions.live
    })
  end

  @doc "Health information without request-log aggregates, for the automatic refresh."
  def _unsafe_health_admin do
    %{
      listener_up: listener_up?(),
      retention_hours: Broker.log_retention_hours(),
      ca_expires_at: ca_expires_at(),
      sessions: session_counts()
    }
  end

  defp listener_up? do
    case Broker.preflight() do
      :ok -> true
      _ -> false
    end
  end

  # The derived CA's end. This calls the one function `emit_telemetry/0`
  # derives `fountain_broker_ca_expires_in_seconds` from, so the page and
  # `FountainBrokerCaExpiring` cannot disagree about the date.
  defp ca_expires_at, do: Fountain.Broker.Native.ca_expires_at()

  defp session_counts do
    now = DateTime.utc_now()

    Repo.one(
      from s in Session,
        select: %{
          live: count(fragment("CASE WHEN ? > ? THEN 1 END", s.expires_at, ^now)),
          expired: count(fragment("CASE WHEN ? <= ? THEN 1 END", s.expires_at, ^now)),
          conversations:
            count(
              fragment(
                "DISTINCT CASE WHEN ? > ? THEN ? END",
                s.expires_at,
                ^now,
                s.conversation_id
              )
            )
        }
    )
  end

  defp window_counts(since) do
    Repo.one(
      from r in Request,
        where: r.inserted_at >= ^since,
        select: %{
          requests: count(r.id),
          conversations: count(r.conversation_id, :distinct),
          tenants: count(r.user_id, :distinct),
          injected: count(fragment("CASE WHEN ? = 'injected' THEN 1 END", r.outcome)),
          passthrough: count(fragment("CASE WHEN ? = 'passthrough' THEN 1 END", r.outcome)),
          denied: count(fragment("CASE WHEN ? = 'denied' THEN 1 END", r.outcome)),
          no_credential:
            count(
              fragment(
                "CASE WHEN ? = 'denied' AND ? = 'credential_missing' THEN 1 END",
                r.outcome,
                r.error
              )
            ),
          failed:
            count(
              fragment(
                "CASE WHEN ? IS NOT NULL AND ? <> 'denied' THEN 1 END",
                r.error,
                r.outcome
              )
            )
        }
    )
  end

  defp top_hosts(since, limit) do
    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since,
        group_by: r.host,
        order_by: [desc: count(r.id)],
        limit: ^limit,
        select: %{
          host: r.host,
          requests: count(r.id),
          injected: count(fragment("CASE WHEN ? = 'injected' THEN 1 END", r.outcome)),
          denied: count(fragment("CASE WHEN ? = 'denied' THEN 1 END", r.outcome)),
          failed:
            count(
              fragment(
                "CASE WHEN ? IS NOT NULL AND ? <> 'denied' THEN 1 END",
                r.error,
                r.outcome
              )
            )
        }
    )
  end

  # `credential_keys` is already the variable *names*, the same thing an
  # audit row records for a secret write; the values never reach this table.
  # Two reads rather than an aggregate over an array column: `array_agg` of
  # arrays needs every row the same length, which they are not.
  defp top_services(since, limit) do
    services =
      Repo.all(
        from r in Request,
          where: r.inserted_at >= ^since and r.outcome == "injected" and not is_nil(r.service),
          group_by: r.service,
          order_by: [desc: count(r.id)],
          limit: ^limit,
          select: %{
            service: r.service,
            requests: count(r.id),
            conversations: count(r.conversation_id, :distinct)
          }
      )

    keys = keys_by_service(since, Enum.map(services, & &1.service))

    Enum.map(services, &Map.put(&1, :credential_keys, Map.get(keys, &1.service, [])))
  end

  # Named services only, never the whole window: the unrestricted form read
  # every injected row to build a map whose entries beyond these ten were
  # thrown away on the next line.
  defp keys_by_service(_since, []), do: %{}

  defp keys_by_service(since, services) do
    Repo.all(
      from r in Request,
        where:
          r.inserted_at >= ^since and r.outcome == "injected" and
            r.service in ^services,
        distinct: true,
        select: {r.service, fragment("unnest(?)", r.credential_keys)}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {service, names} -> {service, Enum.sort(names)} end)
  end

  # The rows an operator acts on: what was refused, and what broke. The
  # same columns either way, each linking to the conversation it came from.
  defp recent(since, :denied, limit),
    do: since |> recent_query(limit) |> where_outcome("denied") |> Repo.all()

  defp recent(since, :failed, limit),
    do: since |> recent_query(limit) |> where_failed() |> Repo.all()

  # `desc: r.inserted_at` rather than `desc: r.id`, which reads identically
  # and plans very differently: with a filter on `outcome` or `error` (neither
  # indexed) a backward primary-key walk has no reason to stop at the window's
  # edge, so a window holding no refusal walked the whole retained log to
  # prove it. Ordering on the indexed column bounds the scan to the window.
  # `r.id` stays as the tiebreak so rows sharing a timestamp keep an order.
  defp recent_query(since, limit) do
    from r in Request,
      left_join: u in User,
      on: u.id == r.user_id,
      where: r.inserted_at >= ^since,
      order_by: [desc: r.inserted_at, desc: r.id],
      limit: ^limit,
      select: %{
        id: r.id,
        inserted_at: r.inserted_at,
        method: r.method,
        host: r.host,
        path: r.path,
        conversation_id: r.conversation_id,
        user_id: r.user_id,
        email: u.email,
        status: r.status,
        error: r.error
      }
  end

  defp where_outcome(query, outcome), do: from(r in query, where: r.outcome == ^outcome)

  defp where_failed(query),
    do: from(r in query, where: not is_nil(r.error) and r.outcome != "denied")

  defp error_counts(since) do
    Repo.all(
      from r in Request,
        where: r.inserted_at >= ^since and not is_nil(r.error) and r.outcome != "denied",
        group_by: r.error,
        order_by: [desc: count(r.id)],
        select: %{error: r.error, requests: count(r.id)}
    )
  end

  # Per sandbox rather than per conversation: the fault is the machine's, and
  # a persistent sandbox carries several conversations that all see it. The
  # owner is the sandbox's, which a deleted account nilifies (the row stays
  # for billing) — the page shows that as deleted.
  defp cut_sandboxes(since, limit) do
    Repo.all(
      from r in Request,
        join: c in Conversation,
        on: c.id == r.conversation_id,
        join: s in Sandbox,
        on: s.id == c.sandbox_id,
        left_join: u in User,
        on: u.id == s.user_id,
        where:
          r.inserted_at >= ^since and r.outcome in ^@forwarded_outcomes and
            r.latency_ms >= ^@stream_min_latency_ms,
        group_by: [s.id, u.id],
        having:
          count(r.id) >= ^@cut_min_streams and
            count(fragment("CASE WHEN ? = 'client_closed' THEN 1 END", r.error)) >=
              fragment("? * ?::float", count(r.id), ^@cut_min_share),
        order_by: [
          desc: count(fragment("CASE WHEN ? = 'client_closed' THEN 1 END", r.error)),
          asc: s.id
        ],
        limit: ^limit,
        select: %{
          sandbox_id: s.id,
          machine_name: s.machine_name,
          provider: s.provider,
          status: s.status,
          user_id: s.user_id,
          email: u.email,
          streams: count(r.id),
          cut: count(fragment("CASE WHEN ? = 'client_closed' THEN 1 END", r.error)),
          conversations: count(r.conversation_id, :distinct),
          last_seen_at: max(r.inserted_at)
        }
    )
    |> Enum.map(&Map.put(&1, :share, &1.cut / &1.streams))
  end

  # Nothing decrypted: the rules stay ciphertext under the tenant's DEK and
  # this page never loads one. `meta` carries the rule-to-variable-names
  # map `prepare/4` stored, which is how many bindings the session brokers.
  defp live_sessions(limit) do
    now = DateTime.utc_now()

    Repo.all(
      from s in Session,
        left_join: u in User,
        on: u.id == s.user_id,
        where: s.expires_at > ^now,
        order_by: [desc: s.inserted_at],
        limit: ^limit,
        select: %{
          id: s.id,
          conversation_id: s.conversation_id,
          # A workspace's setup session has no conversation (ADR 0097).
          workspace_id: s.workspace_id,
          user_id: s.user_id,
          email: u.email,
          policy: s.unmatched_host_policy,
          meta: s.meta,
          inserted_at: s.inserted_at,
          expires_at: s.expires_at
        }
    )
    |> Enum.map(fn s ->
      keys = s.meta |> Map.get("credential_keys", %{}) |> Map.values() |> List.flatten()
      %{s | meta: nil} |> Map.put(:credential_keys, keys |> Enum.uniq() |> Enum.sort())
    end)
  end
end
