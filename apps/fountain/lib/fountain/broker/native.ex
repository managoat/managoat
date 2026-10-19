defmodule Fountain.Broker.Native do
  @moduledoc """
  The native backend of `Fountain.Broker`: the `Managoat.Broker` proxy run
  inside this application (#1340, ADR 0019 §8 as amended). Selected by
  `BROKER_LISTEN_PORT`.

  `prepare/4` maps the conversation's brokered keys and bindings to
  `Managoat.Broker.Rule`s and stores them, encrypted under the tenant's DEK,
  as a `Fountain.Broker.Native.Sessions` row keyed by the hash of a fresh
  token. The proxy resolves the token back to the rules through the
  `Managoat.Broker.Store` behaviour that module implements, on whichever
  replica the ingress chose. `release/1` deletes the conversation's rows;
  `Fountain.Workers.BrokerReaper` sweeps the expired ones.

  The listener is started by `Fountain.Application` from `listener_spec/0`.
  Its root CA is derived from `ca_seed/0`: `BROKER_CA_SEED` when set, else
  thirty-two bytes HKDF-derived from the master key with a fixed info string.
  Nothing is stored; `ca_pem/0` is that root.

  The request log is the `[:managoat, :broker, :request]` telemetry event
  the proxy emits. `attach_telemetry/0` writes one log line per request
  naming the conversation, method, host and outcome, with a redacted path,
  and buffers a `broker_requests` row through
  `Fountain.Broker.Native.RequestLog` for `GET /api/conversations/:id/egress`
  to read back (gate 4, #1486). Since `managoat_broker` 0.3.0 the event is
  **terminal** — it fires when the response body completes or fails, not
  when the request is sent — so the row also carries the upstream status,
  the total duration and the reason where forwarding did not finish (#1501
  row 2). A long-lived stream is therefore recorded when it ends.

  `emit_telemetry/0` is the poller tick behind the `fountain_broker_*`
  gauges (#1170): the listener, the live session count and the CA's
  remaining life. The alerts that read them are in home-cloud.
  """

  alias Fountain.Broker
  alias Fountain.Broker.Native.RequestLog
  alias Fountain.Broker.Native.Sessions
  alias Fountain.Conversations.Conversation
  alias Fountain.Repo
  alias Managoat.Broker.Rule

  import Ecto.Query, only: [from: 2]

  require Logger

  @ca_info "managoat-broker-ca"
  @telemetry_handler "fountain-broker-native-request"

  # ---------------------------------------------------------------------------
  # The listener

  @doc """
  The child spec `Fountain.Application` starts when this backend is
  selected: the `Managoat.Broker` listener on `BROKER_LISTEN_PORT`, with
  `Fountain.Broker.Native.Sessions` as its store and `ca_seed/0` as its CA.
  """
  @spec listener_spec() :: {module(), keyword()}
  def listener_spec do
    {Managoat.Broker,
     port: Application.fetch_env!(:fountain, :broker_listen_port),
     store: Sessions,
     ca_seed: ca_seed(),
     diagnostics_interval: Fountain.Broker.Native.Diagnostics.stall_ms(),
     allow_private_upstreams:
       Application.get_env(:fountain, :broker_allow_private_upstreams, false)}
  end

  @doc """
  The seed the broker CA is derived from. `BROKER_CA_SEED` (32 random bytes,
  generated where Managoat runs and never shared) wins when set, so the CA
  can rotate without the master key (ADR 0093). Otherwise it is HKDF-SHA256
  over the master key with the info string `"#{@ca_info}"`: the CA key is
  never the storage key, and rotating the master key rotates the CA.
  """
  @spec ca_seed() :: <<_::256>>
  def ca_seed do
    Application.get_env(:fountain, :broker_ca_seed) || derived_ca_seed()
  end

  defp derived_ca_seed do
    prk = :crypto.mac(:hmac, :sha256, <<0::256>>, master_key())
    :crypto.mac(:hmac, :sha256, prk, @ca_info <> <<1>>)
  end

  defp master_key do
    case Application.fetch_env!(:fountain, :master_secrets_key) do
      <<_::binary-32>> = key -> key
      other -> raise "MASTER_SECRETS_KEY must be 32 bytes, got #{byte_size(other)}"
    end
  end

  @doc """
  Record every proxied request: one log line, and one buffered
  `broker_requests` row. Idempotent.
  """
  @spec attach_telemetry() :: :ok
  def attach_telemetry do
    :ok = Fountain.Broker.Native.Diagnostics.attach()

    case :telemetry.attach(
           @telemetry_handler,
           [:managoat, :broker, :request],
           &__MODULE__.handle_request/4,
           nil
         ) do
      :ok -> :ok
      {:error, :already_exists} -> :ok
    end
  end

  # `:telemetry` detaches a handler that raises, for the life of the node
  # (#1427), so this one cannot be allowed to. The whole body is guarded and
  # the row goes through a cast, never a synchronous insert on the proxy's
  # own connection process.
  @doc false
  def handle_request(_event, measurements, meta, _config) do
    # Credentials can occupy any URL segment, including the first (Telegram).
    # Redact before either sink, regardless of which secrets the broker knows.
    meta = Map.put(meta, :path, RequestLog.redacted_path())
    session = Map.get(meta, :meta) || %{}
    conv = session["conversation_id"]

    owner =
      if session["workspace_id"],
        do: "workspace #{session["workspace_id"]}",
        else: "conv #{conv || "?"}"

    Logger.info(
      "broker: #{owner} #{meta.method} #{meta.host}#{meta.path} " <>
        describe(meta.outcome, Map.get(meta, :scheme), meta.rule) <>
        ending(meta, measurements) <> correlation(meta)
    )

    if is_binary(conv) and is_binary(session["user_id"]) do
      RequestLog.record(row(meta, measurements, session, conv))
    end

    :ok
  rescue
    error ->
      Logger.warning("broker: request log handler skipped a row: #{Exception.message(error)}")
      :ok
  catch
    kind, reason ->
      Logger.warning("broker: request log handler skipped a row: #{inspect({kind, reason})}")
      :ok
  end

  # `credential_keys` names the environment variables whose values the proxy
  # attached, never the values: the same thing an audit row records for a
  # secret. The rule-to-keys map rides on the session's `meta`, put there by
  # `prepare/4`, because the proxy knows only the rule that matched.
  defp row(meta, measurements, session, conv) do
    {outcome, credentialed?} = verdict(meta.outcome, Map.get(meta, :scheme))
    rule = if credentialed?, do: meta.rule && to_string(meta.rule)

    %{
      conversation_id: conv,
      user_id: session["user_id"],
      method: clip(meta.method, 16),
      host: clip(meta.host, 255),
      path: clip(meta.path, 2048),
      outcome: outcome,
      service: rule && clip(rule, 255),
      credential_keys: (rule && get_in(session, ["credential_keys", rule])) || [],
      status: Map.get(meta, :status),
      latency_ms: latency_ms(measurements),
      error: meta |> Map.get(:error) |> error_string(),
      inserted_at: DateTime.utc_now()
    }
  end

  # What the row says happened, and whether `service` may name a binding.
  #
  # `outcome` answers "did a rule apply". A matched `:passthrough` rule —
  # which is how a host is allowed under `limited` — applies without
  # attaching anything, so it arrives as `:injected`, identical to a
  # `:bearer` rule. Deriving the verdict from `outcome` alone would make an
  # allowed host's row read as though a credential had been sent to it, and
  # `service` would name the `ALLOW` rule where the schema promises "the
  # binding that matched, and so which credential was attached".
  #
  # `scheme` (managoat_broker 0.11.0) is the field that tells the two apart.
  # Found building managoat/airlock's egress record
  # (managoat/managoat_broker#27); Fountain had the same exposure.
  defp verdict(:injected, :passthrough), do: {"passthrough", false}
  defp verdict(:injected, _scheme), do: {"injected", true}
  defp verdict(outcome, _scheme), do: {to_string(outcome), false}

  # The proxy measures monotonically in native units, from the request head
  # arriving to the response body completing or failing (managoat_broker
  # 0.3.0). It is total duration rather than time to first byte, so a
  # streamed reply is recorded when the stream ends and its row carries how
  # long the whole thing took.
  defp latency_ms(%{duration: duration}) when is_integer(duration),
    do: System.convert_time_unit(duration, :native, :millisecond)

  defp latency_ms(_measurements), do: nil

  defp error_string(nil), do: nil
  defp error_string(error), do: clip(error, 255)

  # Postgres counts `varchar(n)` in characters, so does `String.slice/3`, and
  # slicing on graphemes cannot produce the invalid UTF-8 that would make the
  # whole batch fail to insert.
  defp clip(nil, _max), do: ""
  defp clip(value, max), do: value |> to_string() |> String.slice(0, max)

  defp describe(:injected, :passthrough, rule), do: "allowed #{rule}"
  defp describe(:injected, _scheme, rule), do: "injected #{rule}"
  defp describe(:passthrough, _scheme, _rule), do: "passthrough"
  defp describe(:denied, _scheme, _rule), do: "denied"
  defp describe(outcome, _scheme, _rule), do: to_string(outcome)

  # How it ended, appended to the request line: the status the sandbox saw,
  # how long it took, and the reason where forwarding did not complete.
  defp ending(meta, measurements) do
    ms = latency_ms(measurements)

    [Map.get(meta, :status), ms && "#{ms}ms", Map.get(meta, :error)]
    |> Enum.reject(&is_nil/1)
    |> Enum.map_join(&" #{&1}")
  end

  defp correlation(%{connection_id: connection, request_id: request}),
    do: " connection #{connection} request #{request}"

  defp correlation(_meta), do: ""

  # ---------------------------------------------------------------------------
  # The backend

  @doc "Is the listener up on this node?"
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    if Managoat.Broker.running?(),
      do: :ok,
      else: {:error, {:broker, :unreachable, :listener_down}}
  end

  @doc "The derived root, as PEM."
  @spec ca_pem() :: {:ok, binary()}
  def ca_pem, do: {:ok, Managoat.Broker.ca_pem_for_seed(ca_seed())}

  @doc """
  Mint the conversation's session: the rules the proxy may apply (one or
  two per binding, the catalog rules for an unbound GitHub key, a passthrough
  per allowed host under `limited`), stored under the tenant's key with a
  fresh token. `opts[:user_id]` names the tenant; without it the
  conversation row does.
  """
  @spec prepare(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, Broker.session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts)
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    network = Keyword.get(opts, :network, :unrestricted)

    with {:ok, user_id} <- user_id(conversation_id, opts) do
      Sessions.create(%{
        conversation_id: conversation_id,
        user_id: user_id,
        rules: rules_for(brokered, bindings, network),
        unmatched_host_policy: policy_for(network),
        meta: meta_for(conversation_id, user_id, brokered, bindings),
        ttl_seconds: Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600)
      })
    end
  end

  @doc """
  Rewrite the rules of the conversation's live sessions in place
  (`Sessions.update_rules/4`), so a token a running process already holds
  resolves to the new credentials (#1736). Same inputs as `prepare/4`; a
  secret edit leaves the network shape alone, so only the rules and the
  `credential_keys` in `meta` move. `{:ok, 0}` means no live session was
  there to update.
  """
  @spec refresh(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh(conversation_id, brokered, bindings, opts)
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    network = Keyword.get(opts, :network, :unrestricted)

    with {:ok, user_id} <- user_id(conversation_id, opts) do
      Sessions.update_rules(
        conversation_id,
        user_id,
        rules_for(brokered, bindings, network),
        meta_for(conversation_id, user_id, brokered, bindings)
      )
    end
  end

  @doc """
  Mint a workspace's session (ADR 0097, step 5): `prepare/4`'s rules for the
  workspace's own environment and vault, owned by the workspace rather than
  a conversation, for the provision on create that runs before any
  conversation exists. `opts[:user_id]` is required: the workspace's owner.
  Its egress is logged, and not written to any conversation's egress trail.
  """
  @spec prepare_workspace(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, Broker.session()} | {:error, term()}
  def prepare_workspace(workspace_id, brokered, bindings, opts)
      when is_binary(workspace_id) and is_map(brokered) and is_map(bindings) do
    network = Keyword.get(opts, :network, :unrestricted)
    user_id = Keyword.fetch!(opts, :user_id)

    Sessions.create_workspace(%{
      workspace_id: workspace_id,
      user_id: user_id,
      rules: rules_for(brokered, bindings, network),
      unmatched_host_policy: policy_for(network),
      meta: workspace_meta(workspace_id, user_id, brokered, bindings),
      ttl_seconds: Application.get_env(:fountain, :broker_session_ttl_seconds, 21_600)
    })
  end

  @doc "`refresh/4` for a workspace's live sessions. `opts[:user_id]` is required."
  @spec refresh_workspace(String.t(), %{String.t() => String.t()}, Broker.bindings(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_workspace(workspace_id, brokered, bindings, opts)
      when is_binary(workspace_id) and is_map(brokered) and is_map(bindings) do
    network = Keyword.get(opts, :network, :unrestricted)
    user_id = Keyword.fetch!(opts, :user_id)

    Sessions.update_workspace_rules(
      workspace_id,
      user_id,
      rules_for(brokered, bindings, network),
      workspace_meta(workspace_id, user_id, brokered, bindings)
    )
  end

  @doc "Delete a workspace's sessions. Their tokens stop working at once."
  @spec release_workspace(String.t()) :: :ok
  def release_workspace(workspace_id) when is_binary(workspace_id),
    do: Sessions.release_workspace(workspace_id)

  defp workspace_meta(workspace_id, user_id, brokered, bindings) do
    %{
      "workspace_id" => workspace_id,
      "user_id" => user_id,
      "credential_keys" => credential_keys(brokered, bindings)
    }
  end

  defp meta_for(conversation_id, user_id, brokered, bindings) do
    keys = credential_keys(brokered, bindings)

    %{"conversation_id" => conversation_id, "user_id" => user_id, "credential_keys" => keys}
  end

  defp user_id(conversation_id, opts) do
    case Keyword.get(opts, :user_id) do
      id when is_binary(id) ->
        {:ok, id}

      nil ->
        case Repo.one(from(c in Conversation, where: c.id == ^conversation_id, select: c.user_id)) do
          nil -> {:error, {:broker, :session, :unknown_conversation}}
          id -> {:ok, id}
        end
    end
  end

  defp policy_for(:unrestricted), do: :passthrough
  defp policy_for({:limited, _hosts}), do: :deny

  @doc """
  The rules a set of brokered keys turns into: one per binding (plus a
  substitution twin for every header-setting shape, so the placeholder is
  replaced wherever a client puts it -- a header value, the path or the
  query), the catalog rules for a GitHub key with no bindings of its own,
  then under `limited` a passthrough per allowed host that no credentialed
  rule already covers.

  Order is not the tie-breaker it once was. Since `managoat_broker` 0.7.0
  the **most specific** matched rule sets the header, and declaration order
  only breaks a tie between equally specific rules. Nothing here writes a
  generic default and then an override, so this list resolves as it always
  did; the change matters to anyone who adds one.
  """
  @spec rules_for(%{String.t() => String.t()}, Broker.bindings(), Broker.network()) :: [Rule.t()]
  def rules_for(brokered, bindings, network) do
    bound =
      brokered
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.flat_map(fn {key, value} ->
        bindings |> Map.get(key, []) |> Enum.flat_map(&binding_rules(key, value, &1, brokered))
      end)

    credentialed = bound ++ catalog_rules(brokered, bindings)
    credentialed ++ allow_rules(network, credentialed)
  end

  defp binding_rules(key, value, binding, brokered) do
    name = Broker.service_name(key, binding.host)
    base = %Rule{name: name, pattern: pattern_for(binding.host), scheme: :passthrough}
    twin = %{base | scheme: :substitute, placeholder: Broker.placeholder(key), credential: value}

    case binding.auth_type do
      "substitute" ->
        [twin]

      "bearer" ->
        [%{base | scheme: :bearer, credential: value}, twin]

      "basic" ->
        [%{base | scheme: :basic, credential: {binding.username || "", value}}, twin]

      "api_key" ->
        [
          %{
            base
            | scheme: :api_key,
              header: binding.header,
              prefix: binding.prefix || "",
              credential: value
          },
          twin
        ]

      "custom" ->
        [%{base | scheme: :custom, template: binding.headers || %{}, credential: brokered}, twin]
    end
  end

  # Gate 1a's default: an unbound GitHub key goes to api.github.com as a
  # bearer, to api.githubcopilot.com for MCP, and to github.com as git's basic `x-access-token`.
  defp catalog_rules(brokered, bindings) do
    case Broker.catalog_github_key(brokered, bindings) do
      nil ->
        []

      key ->
        value = Map.fetch!(brokered, key)
        placeholder = Broker.placeholder(key)

        [
          %Rule{
            name: "github-api",
            pattern: "api.github.com",
            scheme: :bearer,
            credential: value
          },
          %Rule{
            name: "github-api",
            pattern: "api.github.com",
            scheme: :substitute,
            placeholder: placeholder,
            credential: value
          },
          %Rule{
            name: "github-mcp",
            pattern: "api.githubcopilot.com",
            scheme: :bearer,
            credential: value
          },
          %Rule{
            name: "github-mcp",
            pattern: "api.githubcopilot.com",
            scheme: :substitute,
            placeholder: placeholder,
            credential: value
          },
          %Rule{
            name: "github-git",
            pattern: "github.com",
            scheme: :basic,
            credential: {Broker.github_basic_user(), value}
          }
        ]
    end
  end

  # `limited`: one passthrough rule per allowed host, so the deny policy has
  # something to match. A host that already carries a credentialed rule is
  # skipped — that rule is the one that must win there.
  defp allow_rules(:unrestricted, _credentialed), do: []

  defp allow_rules({:limited, hosts}, credentialed) do
    taken = MapSet.new(credentialed, & &1.pattern)

    hosts
    |> Enum.map(&(&1 |> to_string() |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&{&1, pattern_for(&1)})
    |> Enum.reject(fn {_host, pattern} -> MapSet.member?(taken, pattern) end)
    |> Enum.uniq_by(&elem(&1, 1))
    |> Enum.map(fn {host, pattern} ->
      %Rule{name: Broker.service_name("ALLOW", host), pattern: pattern, scheme: :passthrough}
    end)
  end

  @doc """
  A host as a `Managoat.Broker.Rule` pattern.

  Everything a tenant types is already one, with a single exception: an IPv6
  literal has to be **bracketed** (`[::1]`, `[::1]:8443`), because in a bare
  one there is no telling which colon separates the port. The library matches
  a bare literal against nothing rather than guessing, so
  `allowed_hosts: ["::1"]` would silently allow no host at all under
  `limited`, which is the worst way for a rule to be wrong
  (`managoat_broker` 0.4.0, #1501 row 3).

  Only an unambiguous case is rewritten: the whole string parses as an IPv6
  address. A tenant who wants a port on one writes the brackets, because
  `::1:8443` genuinely cannot be told apart from an address.
  """
  @spec pattern_for(String.t()) :: String.t()
  def pattern_for(host) when is_binary(host) do
    case :inet.parse_ipv6strict_address(String.to_charlist(host)) do
      {:ok, _address} -> "[" <> host <> "]"
      {:error, _} -> host
    end
  end

  @doc "Delete the conversation's sessions. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id),
    do: Sessions.release(conversation_id)

  @doc "Revoke one session matching tenant, conversation and token."
  @spec release_session(String.t(), String.t(), String.t()) :: :ok
  def release_session(user_id, conversation_id, token),
    do: Sessions.release_session(user_id, conversation_id, token)

  @doc """
  The conversation's egress rows, newest first (gate 4, #1486). The same
  shape the Agent Vault backend answered with, `status`, `latency_ms` and
  `error` included since the proxy started framing responses (#1501 row 2).
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [Broker.egress_event()], next: integer() | nil}}
  def request_log(conversation_id, opts), do: RequestLog.page(conversation_id, opts)

  # ---------------------------------------------------------------------------
  # Gauges (#1170)

  @doc """
  The poller tick behind the `fountain_broker_*` series: is the listener up
  on this node, how many sessions are live, and how long the derived CA has
  left.
  """
  @spec emit_telemetry() :: :ok
  def emit_telemetry do
    Fountain.TelemetryTick.run("broker gauges", fn ->
      up = if preflight() == :ok, do: 1, else: 0
      :telemetry.execute([:fountain, :broker, :listener], %{up: up}, %{})

      :telemetry.execute(
        [:fountain, :broker, :sessions],
        %{count: Repo.aggregate(Fountain.Broker.Native.Session, :count, :id)},
        %{}
      )

      :telemetry.execute(
        [:fountain, :broker, :ca],
        %{expires_in_seconds: ca_expires_in_seconds()},
        %{}
      )
    end)

    :ok
  end

  @doc """
  When the derived root every brokered sandbox trusts stops being valid, or
  `nil` where this deployment holds no CA to read.

  Public because two readers need the same answer: `emit_telemetry/0` turns
  it into `fountain_broker_ca_expires_in_seconds`, which is what
  `FountainBrokerCaExpiring` alerts on, and `/admin/broker` prints the date.
  A second copy of the PEM-to-`DateTime` chain would let the page and the
  alert disagree about the one date whose passing stops every sandbox
  trusting the proxy.
  """
  @spec ca_expires_at() :: DateTime.t() | nil
  def ca_expires_at do
    {:ok, pem} = ca_pem()

    pem
    |> X509.Certificate.from_pem!()
    |> X509.Certificate.validity()
    |> elem(2)
    |> X509.DateTime.to_datetime()
  rescue
    _ -> nil
  end

  # The root the library derives has a fixed twenty-year window today, so
  # this reads as a constant. It is exported anyway: the number is the one
  # thing that turns "the CA is fine" from an assumption into a series, and
  # a library that ever shortens the window becomes visible here rather than
  # on the day every sandbox stops trusting the proxy.
  defp ca_expires_in_seconds do
    case ca_expires_at() do
      %DateTime{} = not_after ->
        DateTime.diff(not_after, DateTime.utc_now())

      # Skip the datapoint rather than publish a nil the alert would read as
      # zero seconds left. `TelemetryTick` logs it and the next tick retries.
      nil ->
        raise "broker CA is unreadable, so its expiry gauge has no value"
    end
  end

  # Which environment variables each rule's credential came from, by rule
  # name, mirroring how `rules_for/3` names them. Stored on the session so
  # the request log can say which credential was attached without the proxy
  # ever knowing an environment variable's name.
  @spec credential_keys(%{String.t() => String.t()}, Broker.bindings()) :: %{
          String.t() => [String.t()]
        }
  def credential_keys(brokered, bindings) do
    bound =
      brokered
      |> Enum.flat_map(fn {key, _value} ->
        bindings |> Map.get(key, []) |> Enum.map(&{Broker.service_name(key, &1.host), key})
      end)

    catalog =
      case Broker.catalog_github_key(brokered, bindings) do
        nil -> []
        key -> [{"github-api", key}, {"github-mcp", key}, {"github-git", key}]
      end

    (bound ++ catalog)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Map.new(fn {name, keys} -> {name, keys |> Enum.uniq() |> Enum.sort()} end)
  end
end
