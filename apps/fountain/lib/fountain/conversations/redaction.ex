defmodule Fountain.Conversations.Redaction do
  @moduledoc """
  Redacts tenant secrets out of sprite output before it is persisted.

  Decrypted secrets are placed in the sprite's environment and written to
  `/home/sprite/.env`, and every byte a sprite writes to stdout or stderr is
  persisted verbatim into `log_events` and streamed over SSE. So an `env`, a
  `set -x`, a `cat .env` in someone's `setup_script`, or an agent that simply
  prints its environment, wrote plaintext credentials into Postgres — a table
  with none of the envelope encryption the secret itself has, and one that
  outlives the conversation.

  ## Why a registry rather than an argument

  A scrubber already existed for git's HTTPS token, and it was applied on the
  HTTPS clone path and *not* on the SSH one. That is the failure mode worth
  designing against: redaction that a caller has to remember will eventually be
  forgotten by a new caller.

  So the values live in an ETS table keyed by conversation, and
  `Conversations.log!/1` — the single writer for every log event — consults it.
  A new log path is redacted whether or not its author knew this module existed.

  ## What is registered

  The conversation's secrets, and nothing else: the decrypted environment and
  vault values, the inference credential, the callback
  token, the brokered credentials and the broker session token.
  `Fountain.Conversations.SpriteEnv.build/4` classifies them, and a value
  registered once is never forgotten (`add/2`).

  Fountain's own identifiers and configuration are left out — the
  conversation and sandbox ids, the base and sandbox URLs, the trace context,
  the CA paths. They are not secret, and the registry is no longer only a
  scrubber: `RedactionCarry` holds back output that could begin a registered
  value, so a registered UUID cost the live stream a chunk of latency for
  every hex character output ends in, and printed a conversation's own id as
  `[REDACTED]` (#2366).

  ## The length floor

  Only values of at least #{8} bytes are redacted. Sprite environments hold
  plenty of short non-secrets (`true`, `1`, a port, a region), and redacting
  those would turn logs into noise while protecting nothing. Real credentials —
  tokens, keys, connection strings — are comfortably longer. A deliberately
  short password is the case this misses, and is worth knowing about.

  ## Two forms of every value

  `redact/2` matches a value's own bytes, and an `acp` row is not the bytes
  the agent wrote: it is a `session/update` line the peer encoded as JSON. A
  value holding a `"`, a `\\` or a control character — a PEM key's newlines,
  a service-account document's quotes — is stored escaped, and its raw bytes
  match nothing (#2359). So `put/2` also registers the JSON-escaped form of
  such a value, and `patterns/1` is both. `lookup/1` stays the values
  themselves, for callers that match decoded text or raw file bytes.

  ## The boundary guarantee

  A match needs the whole value inside one `data`, and sandbox output arrives
  in chunks whose boundaries nobody chooses: a model's reply as many
  `agent_message_chunk` lines, stdout and stderr as whatever bytes the
  transport delivered. Redacting each row on its own left a value cut by a
  boundary as two plaintext fragments — in `log_events`, on the live stream,
  and whole again in `turns.reply_text`, which joins a turn's text (#2359).

  `Fountain.Conversations.RedactionCarry` closes that before rows reach the
  writer. Only a chunk whose end could be the start of a registered value is
  held, per stream and per ACP chunk kind: whole when small, so row boundaries
  survive, and joined to that stream's next text only when a value really
  crosses. Tool lines between two text chunks do not release it. Nothing else
  waits, and everything held is bounded (`RedactionCarry.max_unit/0`,
  `RedactionCarry.max_hold/0`). The cost is latency: such a chunk appears when
  the next one arrives or the turn ends. So for every sandbox stream `Output.log/4`
  writes, a registered value that arrives whole across any number of chunks,
  with anything in between, reaches `log!/1` whole, and is redacted there.

  Some cases fall outside that guarantee:

    * A value the process never finishes is not a value. Its prefix is
      written as it is when the turn ends.
    * A value long enough to overflow the hold is replaced by the placeholder
      as it streams, and the rest of it is dropped as it arrives. That errs
      toward redacting text that only looked like the value's start.
    * A server that stops mid-turn loses what it holds. Nothing leaks. A
      reattach's replay does not deduplicate a line the carry rewrote (only
      when a value crossed a boundary, or a chunk was too large to hold
      whole), so that text can appear twice.
    * Output written outside `Output` (provisioning steps) is written whole
      and needs no carry.
  """

  use GenServer

  @table :fountain_redaction
  @min_length 8
  @placeholder "[REDACTED]"

  def start_link(opts),
    do: GenServer.start_link(__MODULE__, :ok, Keyword.put_new(opts, :name, __MODULE__))

  @impl true
  def init(:ok) do
    :ets.new(@table, [
      :named_table,
      :public,
      :set,
      read_concurrency: true,
      write_concurrency: true
    ])

    {:ok, %{}}
  end

  @doc """
  Register the values to redact for a conversation.

  Accepts the sprite env as a keyword-ish list of `{name, value}` tuples, or a
  plain list of values.
  """
  def put(conversation_id, values) when is_binary(conversation_id) and is_list(values) do
    redactable =
      values
      |> Enum.map(fn
        {_name, value} -> value
        value -> value
      end)
      |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= @min_length))
      # Longest first: a secret that contains another as a substring must be
      # replaced whole, or the shorter match would leave a fragment behind.
      |> Enum.sort_by(&byte_size/1, :desc)
      |> Enum.uniq()

    if redactable == [] do
      delete(conversation_id)
    else
      ensure_table()
      :ets.insert(@table, {conversation_id, redactable, with_escaped(redactable)})
    end

    :ok
  end

  def put(_conversation_id, _values), do: :ok

  @doc """
  Register more values for a conversation without forgetting any.

  `put/2` replaces, which is right for the first registration and wrong for
  every one after it. A credential rotates mid-conversation — an edited vault
  or environment secret — while output produced under the old
  one can still be on its way to `log_events`. So once a value has been a
  secret in this conversation, it stays redacted until the conversation ends
  and `delete/1` clears it. Over-redacting a retired credential costs nothing;
  un-redacting one that is still in flight is the disclosure.

  Reads then writes, which is safe because a conversation's registry is written
  only from its own server process.
  """
  def add(conversation_id, values) when is_binary(conversation_id) and is_list(values),
    do: put(conversation_id, lookup(conversation_id) ++ values)

  def add(_conversation_id, _values), do: :ok

  @doc "Forget a conversation's values. Called when its server stops."
  def delete(conversation_id) when is_binary(conversation_id) do
    ensure_table()
    :ets.delete(@table, conversation_id)
    :ok
  end

  def delete(_), do: :ok

  @doc """
  Replace any registered secret value appearing in `text`.

  Returns `text` unchanged when the conversation has no registered values, which
  is the common case for conversations with no secrets at all.
  """
  def redact(conversation_id, text) when is_binary(conversation_id) and is_binary(text) do
    case patterns(conversation_id) do
      [] -> text
      patterns -> :binary.replace(text, patterns, @placeholder, [:global])
    end
  end

  def redact(_conversation_id, text), do: text

  @doc "Values registered for a conversation. Empty when none or unavailable."
  def lookup(conversation_id), do: entry(conversation_id, 2)

  @doc """
  What `redact/2` matches: every value, plus the JSON-escaped form of each
  value that has one. Longest first. Empty when none or unavailable.
  """
  def patterns(conversation_id), do: entry(conversation_id, 3)

  defp entry(conversation_id, position) when is_binary(conversation_id) do
    ensure_table()

    case :ets.lookup(@table, conversation_id) do
      [{^conversation_id, _values, _patterns} = entry] -> elem(entry, position - 1)
      _ -> []
    end
  catch
    :error, :badarg -> []
  end

  defp entry(_, _), do: []

  # The form a value takes inside a line the ACP peer encoded with Jason. Only
  # a value that escapes adds one, and a value that is not UTF-8 cannot be in
  # a JSON string at all.
  @doc """
  `values` with each one's JSON-escaped form beside it, where that differs
  (a value holding a quote, a backslash or a control character), longest
  first: what output that prints a value inside JSON has to be matched with.
  `patterns/1` is a conversation's; a workspace's setup log uses this for its
  own values (`Fountain.Workspaces.SetupOutput`).
  """
  @spec with_escaped([String.t()]) :: [String.t()]
  def with_escaped(values) do
    escaped =
      for value <- values,
          String.valid?(value),
          json = Jason.encode!(value),
          escaped = binary_part(json, 1, byte_size(json) - 2),
          escaped != value,
          do: escaped

    (values ++ escaped) |> Enum.uniq() |> Enum.sort_by(&byte_size/1, :desc)
  end

  def min_length, do: @min_length
  def placeholder, do: @placeholder

  # The table is owned by this GenServer. Tests and any caller that runs before
  # the supervision tree is up should degrade to "no redaction registered"
  # rather than crash the operation being logged.
  defp ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  @doc """
  A `ConversationServer` state with every secret in it replaced, for
  `format_status/1` (#315).

  An unhandled raise in any callback logs `State:` through `inspect`. Without
  this that meant plaintext env secrets, the raw tenant DEK, decrypted BYO
  inference credentials, the callback API key and the platform Sprites token
  (inside `sprite.client`) on stdout and, with `SENTRY_DSN` set, in a Sentry
  event body. Sentry's PlugContext scrubbing never sees process crash reports,
  so the redaction has to happen at the server.

  Key names are kept and only values are replaced, so crash reports stay
  debuggable.

  The list is the whole point, and it has fallen behind the state twice
  (#1690): `brokered` and `broker` arrived with the egress broker
  (#1136/#1150), `resolved_mcp_servers` with the one-substitution-pass fix
  (#1511), and none of them were scrubbed. Reviewing that fix found more:
  the sandbox command's adapter-owned client and the turn's prompt and reply
  text. `ConversationServerRedactionTest`'s field
  guard now fails for a new state field until it is either redacted here or
  classified as plaintext there, so the next one cannot arrive quietly.
  """
  def server_state(state) do
    %{
      state
      | handle: state.handle && %{state.handle | private: nil},
        sprite_env: Enum.map(state.sprite_env, fn {k, _v} -> {k, @placeholder} end),
        # ADR 0019: `Broker.split/2` leaves placeholders in the sandbox env and
        # puts the real values here, so this map — not `sprite_env` — is where
        # a brokered GITHUB_TOKEN or inference key lives.
        brokered: secrets(state.brokered),
        # The minted proxy session: `%{vault, token, expires_at}`. Every value
        # goes rather than the token alone, so a field added to the session
        # shape is redacted the day it appears; the vault and the expiry are
        # already published on the `broker` stage event.
        broker: secrets(state.broker),
        env_credentials: secrets(state.env_credentials),
        resolved_mcp_servers: deep_redact(state.resolved_mcp_servers),
        # The same adapter-owned `private` that `handle` carries — for Sprites,
        # the client struct holding the platform bearer token. Both structs
        # `@derive` a narrow `Inspect`, but that is the dependency's choice to
        # change, not a property this server can rely on.
        current_command: state.current_command && %{state.current_command | private: nil},
        current_turn: turn(state.current_turn),
        # Output held back until the value it may begin arrives (#2359): by
        # construction, the start of a secret.
        output_carry: secret(state.output_carry),
        tenant_key: secret(state.tenant_key),
        inference_credentials: secrets(state.inference_credentials),
        callback_token: secret(state.callback_token),
        # `{parent_key_id, plaintext}` (#2934): the row id stays, the key goes.
        conversation_key: conversation_key(state.conversation_key),
        turn_session_retry: secret(state.turn_session_retry),
        # The provider's error text (#2545), which may quote the request.
        turn_provider_failure: secret(state.turn_provider_failure),
        # What `TurnLaunch` keeps to relaunch a crashed adapter (#2402): the
        # prompt, its images, the agent and the conversation. The timing and
        # the flags beside it are the debugging signal.
        turn_metrics: launch(state.turn_metrics)
    }
  end

  defp launch(%{launch: %{} = launch} = metrics),
    do: %{metrics | launch: %{relaunched?: launch.relaunched?}}

  defp launch(metrics), do: metrics

  @doc """
  `server_state/1` applied to the `:state` entry of a `format_status/1` map.
  """
  def server_status(status) do
    Map.new(status, fn
      {:state, %{conversation_id: _} = state} -> {:state, server_state(state)}
      other -> other
    end)
  end

  # A struct is not enumerable, so it cannot be walked key by key. Replacing it
  # whole is the safe reading: `format_status/1` raising is itself a leak, since
  # OTP then reports the unredacted state.
  defp secrets(%_{}), do: @placeholder
  defp secrets(%{} = map), do: Map.new(map, fn {k, _v} -> {k, @placeholder} end)
  defp secrets(other), do: secret(other)

  defp secret(nil), do: nil
  defp secret(_present), do: @placeholder

  defp conversation_key({parent_key_id, _plaintext}), do: {parent_key_id, @placeholder}
  defp conversation_key(other), do: secret(other)

  # `resolved_mcp_servers` is the agent's MCP document with `${VAR}` already
  # substituted (#1404/#1511): a header written `Bearer ${GITHUB_TOKEN}` holds
  # the token itself, and so does a server's `env`. Which servers were resolved
  # is exactly the debugging signal worth keeping, so every key and the shape of
  # the document survive and only the leaves go.
  #
  # Tuples and charlists cannot appear in an Ecto `:map` decoded from JSON, so
  # the last two clauses are for the day the field's shape changes: a keyword
  # list is a list of tuples, and a charlist is a list of integers that a
  # crash report prints as text.
  defp deep_redact(nil), do: nil
  defp deep_redact(%_{}), do: @placeholder
  defp deep_redact(%{} = map), do: Map.new(map, fn {k, v} -> {k, deep_redact(v)} end)

  defp deep_redact([_ | _] = list),
    do: if(charlist?(list), do: @placeholder, else: redact_each(list))

  defp deep_redact(list) when is_list(list), do: list
  defp deep_redact(value) when is_binary(value), do: @placeholder

  defp deep_redact(tuple) when is_tuple(tuple),
    do: tuple |> Tuple.to_list() |> redact_each() |> List.to_tuple()

  defp deep_redact(other), do: other

  defp redact_each(list), do: Enum.map(list, &deep_redact/1)

  defp charlist?(list), do: List.ascii_printable?(list)

  # Everything a `%Turn{}` holds that is not on this list — the prompt, the
  # reply text, the pending permission request, the usage map — is tenant
  # content, and a crash report goes to a third-party processor when
  # `SENTRY_DSN` is set. Keeping the list of identity fields rather than
  # naming the content fields means a text field added to the schema is
  # redacted the day it appears.
  @turn_identity_fields [
    :id,
    :conversation_id,
    :turn_number,
    :status,
    :origin,
    :exit_code,
    :acp_prompt_id,
    :started_at,
    :ended_at,
    :orphaned_at,
    :inserted_at
  ]

  defp turn(nil), do: nil

  defp turn(%_{} = turn) do
    turn
    |> Map.from_struct()
    |> Enum.reduce(turn, fn
      # Nothing to redact, and both read better left alone in a report.
      {_key, nil}, acc -> acc
      {_key, %Ecto.Association.NotLoaded{}}, acc -> acc
      {:__meta__, _value}, acc -> acc
      {key, _value}, acc when key in @turn_identity_fields -> acc
      {key, _value}, acc -> Map.put(acc, key, @placeholder)
    end)
  end

  defp turn(other), do: secrets(other)
end
