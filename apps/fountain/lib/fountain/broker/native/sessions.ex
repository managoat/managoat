defmodule Fountain.Broker.Native.Sessions do
  @moduledoc """
  The native broker's session store: Fountain's `Managoat.Broker.Store`.

  `Fountain.Broker.Native.prepare/4` mints a session here for one
  conversation: a random token, stored hashed; the `Managoat.Broker.Rule`s
  the proxy may apply, with the credentials inside them, as one ciphertext
  under the tenant's DEK (exactly as the environment and vault rows hold
  the same values); the unmatched-host policy; a TTL; and a `meta` map with
  the conversation and user ids for the request log. `lookup/1` is what the
  proxy calls to resolve a token, on whichever replica the ingress chose: the
  raw token from the header in, the decrypted session out, or `:error` for a
  token that is unknown, expired or undecryptable.

  It is called **once per tunnel, and once per request on the plain path**.
  Since `managoat_broker` 0.10.0 an absolute-form connection stays alive and
  carries several requests, each with its own `Proxy-Authorization`, and
  trusting the first would serve a token the proxy never checked (#1501 row
  4). Each request reads the session and wrapped tenant key in one join.
  Materialized rules are cached locally for 30 seconds (1024 entries, 64 KiB
  each), keyed by tenant, ciphertext and both key identities. Cache hits avoid
  both decryptions. Revocation, expiry and metadata/policy updates are checked
  from the fresh row on every request, without relying on broadcasts. The
  traffic is `apt` and its kin, and a tunnel -- which is every inference
  call, every clone and every `npm install` -- is unchanged at one.

  A session is not tenant-editable state and is not audited: it is
  provisioning machinery, created and deleted with the sandbox it serves,
  and the audit trail records the conversation's lifecycle instead.

  **A workspace's session** (ADR 0097, step 5) is the same row with a
  `workspace_id` and no conversation: the credentials an explicit
  workspace's provision on create runs its packages, clones and setup script
  with, before any conversation exists (`Fountain.Workspaces.Network`).
  `create_workspace/1`, `update_workspace_rules/4` and `release_workspace/1`
  are its three verbs; it is released when the setup ends and cascades with
  the workspace.
  """

  @behaviour Managoat.Broker.Store

  import Ecto.Query

  alias Fountain.Accounts.UserDataKey
  alias Fountain.Broker
  alias Fountain.Broker.Native.MaterializedRules
  alias Fountain.Broker.Native.Session
  alias Fountain.Crypto
  alias Fountain.Repo
  alias Managoat.Broker.Rule

  require Logger

  @aad "fountain.broker.rules"
  @schemes %{
    "bearer" => :bearer,
    "basic" => :basic,
    "api_key" => :api_key,
    "custom" => :custom,
    "substitute" => :substitute,
    "passthrough" => :passthrough
  }

  @doc """
  Mint a session. Returns the plaintext token exactly once; only its hash
  is stored. Expired sessions are swept on the way.
  """
  @spec create(%{
          required(:conversation_id) => String.t(),
          required(:user_id) => String.t(),
          required(:rules) => [Rule.t()],
          required(:ttl_seconds) => pos_integer(),
          optional(:unmatched_host_policy) => :passthrough | :deny,
          optional(:meta) => map()
        }) :: {:ok, Broker.session()} | {:error, term()}
  def create(%{conversation_id: _, user_id: user_id} = attrs) do
    sweep_expired()

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      insert(attrs, dek)
    end
  end

  @doc """
  Mint a workspace's session (ADR 0097, step 5): `create/1` with the
  workspace as the owner in place of a conversation. Returns the plaintext
  token exactly once.
  """
  @spec create_workspace(%{
          required(:workspace_id) => String.t(),
          required(:user_id) => String.t(),
          required(:rules) => [Rule.t()],
          required(:ttl_seconds) => pos_integer(),
          optional(:unmatched_host_policy) => :passthrough | :deny,
          optional(:meta) => map()
        }) :: {:ok, Broker.session()} | {:error, term()}
  def create_workspace(%{workspace_id: workspace_id, user_id: user_id} = attrs)
      when is_binary(workspace_id) and is_binary(user_id) do
    sweep_expired()

    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      attrs |> Map.put(:conversation_id, nil) |> insert(dek)
    end
  end

  defp insert(%{conversation_id: conv_id, user_id: user_id} = attrs, dek) do
    token = "fb_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), attrs.ttl_seconds, :second)
    workspace_id = Map.get(attrs, :workspace_id)

    changeset =
      Session.changeset(%Session{}, %{
        token_hash: hash(token),
        conversation_id: conv_id,
        workspace_id: workspace_id,
        user_id: user_id,
        rules_ciphertext: Crypto.encrypt(encode_rules(attrs.rules), dek, @aad),
        unmatched_host_policy:
          Atom.to_string(Map.get(attrs, :unmatched_host_policy, :passthrough)),
        meta: Map.get(attrs, :meta, %{}),
        expires_at: expires_at
      })

    case Repo.insert(changeset) do
      {:ok, _} ->
        {:ok,
         %{
           token: token,
           vault: Broker.vault_name(conv_id || workspace_id),
           expires_at: expires_at
         }}

      {:error, changeset} ->
        {:error, {:broker, :session, changeset}}
    end
  end

  @impl Managoat.Broker.Store
  def lookup(token) when is_binary(token) do
    token_hash = hash(token)

    query =
      from s in Session,
        join: key in UserDataKey,
        on: key.user_id == s.user_id,
        where: s.token_hash == ^token_hash,
        select: {s, key.wrapped_key}

    case Repo.one(query, timeout: 2_000) do
      nil ->
        report(:unknown)
        :error

      {%Session{} = session, wrapped_key} ->
        if DateTime.compare(session.expires_at, DateTime.utc_now()) != :gt do
          report(:expired)
          :error
        else
          case materialize(session, wrapped_key) do
            {:ok, _} = ok -> report(:ok, ok)
            :error -> report(:unreadable)
          end
        end
    end
  rescue
    _ -> {:error, :unavailable}
  catch
    :exit, _ -> {:error, :unavailable}
  end

  # The fresh join above is the authority: revoked rows and removed/rotated
  # tenant keys cannot be served from a previous cache entry on another node.
  # Cache only rules; policy, metadata and expiry always come from this read.
  defp materialize(session, wrapped_key) do
    master_key = Application.fetch_env!(:fountain, :master_secrets_key)

    key =
      hash(
        :erlang.term_to_binary(
          {session.user_id, session.rules_ciphertext, wrapped_key, master_key}
        )
      )

    result =
      MaterializedRules.fetch(key, fn ->
        with {:ok, dek} <- Crypto.decrypt(wrapped_key, master_key, "fountain.key_wrap"),
             {:ok, json} <- Crypto.decrypt(session.rules_ciphertext, dek, @aad) do
          decode_rules(json)
        end
      end)

    case result do
      {:ok, rules} ->
        {:ok,
         %Managoat.Broker.Session{
           rules: rules,
           unmatched_host_policy: String.to_existing_atom(session.unmatched_host_policy),
           expires_at: session.expires_at,
           meta: session.meta
         }}

      _ ->
        Logger.warning("broker: session #{session.id} for #{owner(session)} is unreadable")

        :error
    end
  end

  # Every lookup counted by result (#1170). A sandbox whose token does not
  # resolve gets a 407, which inside the sandbox looks like the network
  # itself being broken, so a storm of these has to be visible without
  # reading logs.
  defp report(result, reply \\ :error) do
    :telemetry.execute([:fountain, :broker, :session_lookup], %{count: 1}, %{result: result})
    reply
  end

  @doc """
  Rewrite the rules of every live session of a conversation, keeping each
  token (#1736). A sandbox process holds its token in its environment for as
  long as it runs, and an idle ACP peer runs across turns, so a new session
  (a new token) reaches nothing already running. An edited or rotated secret
  reaches the proxy this way instead: the next `lookup/1` on any of the
  conversation's tokens decrypts the new rules. Returns how many rows
  changed; zero means every session had expired, and the caller mints one.
  """
  @spec update_rules(String.t(), String.t(), [Rule.t()], map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_rules(conversation_id, user_id, rules, meta)
      when is_binary(conversation_id) and is_binary(user_id) and is_list(rules) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      now = DateTime.utc_now()
      ciphertext = Crypto.encrypt(encode_rules(rules), dek, @aad)

      {n, _} =
        Repo.update_all(
          from(s in Session,
            where: s.conversation_id == ^conversation_id and s.expires_at >= ^now
          ),
          set: [rules_ciphertext: ciphertext, meta: meta, updated_at: now]
        )

      {:ok, n}
    end
  end

  @doc """
  `update_rules/4` for a workspace's live sessions (ADR 0097, step 5): a
  secret written during the workspace's provision on create reaches the
  setup's next tunnel through the broker. Scoped by the workspace's owner.
  """
  @spec update_workspace_rules(String.t(), String.t(), [Rule.t()], map()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def update_workspace_rules(workspace_id, user_id, rules, meta)
      when is_binary(workspace_id) and is_binary(user_id) and is_list(rules) do
    with {:ok, dek} <- Crypto.load_tenant_key(user_id) do
      now = DateTime.utc_now()
      ciphertext = Crypto.encrypt(encode_rules(rules), dek, @aad)

      {n, _} =
        Repo.update_all(
          from(s in Session,
            where:
              s.workspace_id == ^workspace_id and s.user_id == ^user_id and
                s.expires_at >= ^now
          ),
          set: [rules_ciphertext: ciphertext, meta: meta, updated_at: now]
        )

      {:ok, n}
    end
  end

  @doc """
  The workspaces among `workspace_ids` that have a live session, for the
  refresh a secret write asks for.
  """
  @spec live_workspace_ids([String.t()]) :: [String.t()]
  def live_workspace_ids([]), do: []

  def live_workspace_ids(workspace_ids) when is_list(workspace_ids) do
    now = DateTime.utc_now()

    Repo.all(
      from(s in Session,
        where: s.workspace_id in ^workspace_ids and s.expires_at >= ^now,
        distinct: true,
        select: s.workspace_id
      )
    )
  end

  @doc "Delete every session of a workspace. Its tokens stop working at once."
  @spec release_workspace(String.t()) :: :ok
  def release_workspace(workspace_id) when is_binary(workspace_id) do
    Repo.delete_all(from(s in Session, where: s.workspace_id == ^workspace_id))
    :ok
  end

  @doc "Revoke one worker's token without touching a replacement's sessions."
  @spec release_session(String.t(), String.t(), String.t()) :: :ok
  def release_session(user_id, conversation_id, token)
      when is_binary(user_id) and is_binary(conversation_id) and is_binary(token) do
    token_hash = hash(token)

    Repo.delete_all(
      from s in Session,
        where:
          s.user_id == ^user_id and s.conversation_id == ^conversation_id and
            s.token_hash == ^token_hash
    )

    :ok
  end

  @doc "Delete every session of a conversation. Its tokens stop working at once."
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id) do
    Repo.delete_all(from(s in Session, where: s.conversation_id == ^conversation_id))
    :ok
  end

  @doc "Delete sessions past their end. Returns how many."
  @spec sweep_expired() :: non_neg_integer()
  def sweep_expired do
    now = DateTime.utc_now()
    {n, _} = Repo.delete_all(from(s in Session, where: s.expires_at < ^now))
    n
  end

  defp owner(%Session{workspace_id: ws}) when is_binary(ws), do: "workspace #{ws}"
  defp owner(%Session{conversation_id: conv}), do: "conv #{conv}"

  defp hash(token), do: :crypto.hash(:sha256, token)

  # The rules as JSON. Schemes are strings and a basic credential's
  # `{user, pass}` pair is a tagged object, so the round trip is exact.
  defp encode_rules(rules) do
    rules
    |> Enum.map(fn %Rule{} = r ->
      %{
        "name" => r.name,
        "pattern" => r.pattern,
        "scheme" => Atom.to_string(r.scheme),
        "credential" => encode_credential(r.credential),
        "header" => r.header,
        "prefix" => r.prefix,
        "template" => r.template,
        "placeholder" => r.placeholder
      }
    end)
    |> Jason.encode!()
  end

  defp encode_credential({user, pass}) when is_binary(user) and is_binary(pass),
    do: %{"basic" => [user, pass]}

  defp encode_credential(other), do: other

  defp decode_rules(json) do
    with {:ok, list} when is_list(list) <- Jason.decode(json) do
      {:ok, Enum.map(list, &decode_rule/1)}
    else
      _ -> {:error, :bad_rules}
    end
  end

  defp decode_rule(map) do
    %Rule{
      name: map["name"],
      pattern: map["pattern"],
      scheme: Map.fetch!(@schemes, map["scheme"]),
      credential: decode_credential(map["credential"]),
      header: map["header"],
      prefix: map["prefix"] || "",
      template: map["template"] || %{},
      placeholder: map["placeholder"]
    }
  end

  defp decode_credential(%{"basic" => [user, pass]}), do: {user, pass}
  defp decode_credential(other), do: other
end
