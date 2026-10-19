defmodule Fountain.Conversations.Egress do
  @moduledoc """
  Everything ADR 0019 wired into a conversation: which secrets are brokered,
  the proxy session's life, and the network floor.

  Talks to `Fountain.Broker` (the facade over its backends since #1357,
  never a backend). Functions over rows and values, not over server state
  (#1369): `ConversationServer` keeps the fields the session, its
  placeholders and its bindings live in, unpacks them for each call and
  applies what comes back. The mint, which changes
  more than one field at once, is the server's short wrapper over
  `prepare/4`. The refresh before a turn reads seven fields and writes four
  since #1736, so `refresh_before_turn/1` takes the state and names them;
  `refresh_live/1` (#2548) and the OAuth switch, `switch_to_api_key/1`, do
  the same.

  The split rules, in order, as the server applies them at provision:
  `bindings/1`, `split_brokered/2`, `split_inference/3`. Every conversation
  is brokered (ADR 0019, amendment of 2026-10-15): there is no unbrokered
  deployment for them to step aside on.
  """

  alias Fountain.Broker
  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.SpriteEnv
  alias Fountain.Environments
  alias Fountain.Vaults

  require Logger

  @typedoc "A proxy session as `Fountain.Broker.prepare/4` returns it, or nil when the conversation has none."
  @type session :: map() | nil

  # On a brokered conversation the catalog keys leave the secrets map here,
  # before the MCP substitution and the env are built from it, so both see
  # the placeholder and neither sees the value.
  @spec split_brokered(map(), Broker.bindings()) :: {map(), map()}
  def split_brokered(secrets, bindings), do: Broker.split(secrets, bindings)

  # Re-read the tenant's own brokered secrets before a turn (#1736).
  # `merged` is the environment + vault merge as `SpriteEnv.merge_secrets/3`
  # returns it now, `tenant_keys` the keys the previous read brokered. An
  # edited value replaces the broker's; a deleted key is dropped, and what
  # it was masking takes the name back, as at provisioning: `underlay` is
  # the map of those values, the runtime's inference credentials under their
  # env var names. Returns the brokered map, the tenant's brokered keys now,
  # and whether anything moved.
  @spec refresh_tenant_secrets([String.t()], map(), map(), Broker.bindings(), map()) ::
          {map(), [String.t()], boolean()}
  def refresh_tenant_secrets(tenant_keys, merged, brokered, bindings, underlay) do
    {_sandbox, fresh} = Broker.split(merged, bindings)
    fresh_keys = fresh |> Map.keys() |> Enum.sort()
    removed = tenant_keys -- fresh_keys

    next =
      brokered
      |> Map.drop(removed)
      |> Map.merge(Map.take(underlay, removed))
      |> Map.merge(fresh)

    {next, fresh_keys, next != brokered}
  end

  @spec bindings(String.t()) :: Broker.bindings()
  def bindings(user_id), do: Fountain.SecretBindings.enabled_by_key(user_id)

  # Gate 3: the runtime is handed placeholders for its inference credentials
  # and the broker gets the values, with an implicit binding to the provider's
  # host. A tenant's own secret of the same name (already split above) wins
  # over the inference credential, as it wins in the environment.
  @spec split_inference(map(), map(), Broker.bindings()) ::
          {map(), map(), Broker.bindings()}
  def split_inference(inference_creds, brokered, bindings) do
    {env_creds, inference_brokered, implicit} =
      Broker.split_inference(inference_creds, bindings)

    {env_creds, Map.merge(inference_brokered, brokered), Map.merge(implicit, bindings)}
  end

  @doc "The proxy variables a session puts in the sandbox's env; none without a session."
  @spec sandbox_env(session(), Broker.ca_files()) :: [{String.t(), String.t()}]
  def sandbox_env(session, ca_files \\ Broker.system_ca_files())
  def sandbox_env(nil, _ca_files), do: []
  def sandbox_env(session, ca_files), do: Broker.sandbox_env(session, ca_files)

  @doc """
  The CA files the sandbox's env should name, resolved before it is built.
  Only a brokered conversation asks the sandbox: an unbrokered one names no
  CA files, and must not fail a launch over a lookup it has no use for.
  """
  @spec ca_files(session(), Managoat.Sandbox.Handle.t()) ::
          {:ok, Broker.ca_files()} | {:error, term()}
  def ca_files(nil, _handle), do: {:ok, Broker.system_ca_files()}
  def ca_files(_session, handle), do: Provisioning.broker_ca_files(handle)

  @doc """
  Mint the conversation's proxy session and start the `broker` stage.
  The stage completes only after `install_ca/3` establishes trust in the
  sandbox. The caller holds the session that comes back.
  """
  @spec prepare(String.t(), map(), Broker.bindings(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings, opts) do
    publish_stage(conversation_id, "broker", "started", %{
      keys: brokered |> Map.keys() |> Enum.sort()
    })

    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        {:ok, session}

      {:error, reason} ->
        publish_stage(conversation_id, "broker", "failed", %{reason: inspect(reason)})
        {:error, reason}
    end
  end

  @doc """
  The OAuth token was refused: forget it on both sides, so the API key is
  what the substitution carries. Returns the runtime's credentials, the
  brokered map and the bindings without it; the caller then `reprepare/5`s.
  """
  @spec drop_oauth_token(map(), map(), Broker.bindings()) :: {map(), map(), Broker.bindings()}
  def drop_oauth_token(inference_credentials, brokered, bindings) do
    creds = Map.delete(inference_credentials, :claude_code_oauth_token)

    {env_creds, inference_brokered, implicit} =
      Broker.split_inference(creds, bindings)

    brokered =
      brokered
      |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN")
      |> Map.merge(inference_brokered)

    bindings =
      bindings |> Map.delete("CLAUDE_CODE_OAUTH_TOKEN") |> Map.merge(implicit)

    {env_creds, brokered, bindings}
  end

  @doc """
  `drop_oauth_token/3` then `reprepare/1`, over the server's state: the
  OAuth token was refused, so the vault is re-prepared with the API key as
  what the substitution carries. Writes `brokered`, `broker_bindings`,
  `env_credentials`, `broker` and `sprite_env`. Best effort — a broker
  error leaves the turn to fail at the proxy, which names the cause, rather
  than silently injecting a plaintext key. An unbrokered state comes back
  unchanged.
  """
  @spec switch_to_api_key(map()) :: map()
  def switch_to_api_key(%{broker: nil} = state), do: state

  def switch_to_api_key(state) do
    {env_creds, brokered, bindings} =
      drop_oauth_token(state.inference_credentials, state.brokered, state.broker_bindings)

    state = %{state | brokered: brokered, broker_bindings: bindings, env_credentials: env_creds}

    case reprepare(state) do
      {:ok, session, sprite_env} ->
        %{state | broker: session, sprite_env: sprite_env}

      {:error, reason} ->
        Logger.warning(
          "conv #{state.conversation_id}: broker re-prepare after OAuth refusal failed: #{inspect(reason)}"
        )

        state
    end
  end

  @doc """
  Replace the session and rebuild the env with the new token; everything
  else in the env is unchanged. No stage is published: this is the refresh
  before a turn and the re-prepare after an OAuth refusal, not provisioning.

  Only the proxy variables are replaced. The CA defaults are constants, they
  are already in the list `SpriteEnv.build/4` produced, and stripping them by
  key would take an `env_vars` override of `SSL_CERT_FILE` with them —
  re-adding the broker's value on top, which is the bug #1674 reported, an
  hour into the conversation rather than at provisioning.

  There is no arm here for a list that carries no CA defaults:
  `prepare_state/1` runs before `build_sprite_env/5` on both entry paths
  (`ConversationServer` lines 863 and 1114), so a brokered conversation's env
  has always been assembled with them.
  """
  @spec reprepare(String.t(), map(), Broker.bindings(), [{String.t(), String.t()}], keyword()) ::
          {:ok, map(), [{String.t(), String.t()}]} | {:error, term()}
  def reprepare(conversation_id, brokered, bindings, sprite_env, opts) do
    case Broker.prepare(conversation_id, brokered, bindings, opts) do
      {:ok, session} ->
        proxy_keys = Broker.proxy_keys()
        kept = Enum.reject(sprite_env, fn {k, _} -> to_string(k) in proxy_keys end)
        {:ok, session, kept ++ Broker.proxy_env(session)}

      {:error, _} = error ->
        error
    end
  end

  @doc "`reprepare/5` over the server's state, with `session_opts/1`."
  @spec reprepare(map()) :: {:ok, map(), [{String.t(), String.t()}]} | {:error, term()}
  def reprepare(state) do
    reprepare(
      state.conversation_id,
      state.brokered,
      state.broker_bindings,
      state.sprite_env,
      session_opts(state)
    )
  end

  @doc """
  Rewrite the rules of the conversation's live sessions in place
  (`Fountain.Broker.refresh/4`), keeping the token the sandbox and the idle
  ACP peer already hold (#1736). The refresh before a turn calls this when
  a secret has moved; `reprepare/5` is for a session that is expiring, and
  the new token it mints reaches only the next spawn. `{:ok, 0}` (no live
  session to rewrite) is an error to the caller: the rules went nowhere,
  and a fresh session is the way to carry them.
  """
  @spec refresh_rules(String.t(), map(), Broker.bindings(), keyword()) :: :ok | {:error, term()}
  def refresh_rules(conversation_id, brokered, bindings, opts) do
    case Broker.refresh(conversation_id, brokered, bindings, opts) do
      {:ok, n} when n > 0 -> :ok
      {:ok, 0} -> {:error, :no_live_session}
      {:error, _} = error -> error
    end
  end

  @doc """
  The refresh before a turn, over the server's state (#1736): the secrets
  the broker holds are read again, a change is written into the live
  session's rules with the token kept, and a session near its end is
  replaced before the turn that would outlive it, the env rebuilt with the
  new token for the next spawn. Reads `broker`, `brokered`, `tenant_keys`,
  `secret_sources`, `broker_bindings` and `inference_credentials` (plus the
  ids and the DEK); writes `brokered`, `tenant_keys`, `broker`,
  `sprite_env` and, on a ChatGPT subscription, `inference_credentials`. Returns the state and whether
  the session token was replaced. The state of an unbrokered conversation
  comes back unchanged.

  The token is in the env of every process the sandbox already runs — the
  idle ACP peer that carries the next turn included — so a new session
  would reach none of them; only the rules can move. A rewrite that fails
  falls through to a fresh session, and the caller closes the idle peer on
  the `true` that comes back, so the next spawn carries the new token. A
  re-mint that fails leaves the turn on the old token, to fail at the
  proxy, which names the cause, rather than silently here.
  """
  @spec refresh_before_turn(map()) :: {map(), boolean()}
  def refresh_before_turn(%{broker: nil} = state), do: {state, false}

  def refresh_before_turn(%{broker: session} = state) do
    {state, outcome} = reread_and_rewrite(state)

    if outcome == :failed or Broker.expiring?(session) do
      case reprepare(state) do
        {:ok, fresh, sprite_env} ->
          {%{state | broker: fresh, sprite_env: sprite_env}, fresh.token != session.token}

        {:error, reason} ->
          Logger.warning(
            "conv #{state.conversation_id}: broker session refresh failed: #{inspect(reason)}"
          )

          {state, false}
      end
    else
      {state, false}
    end
  end

  @doc """
  The refresh a secret write asks for, during a turn or between turns
  (#2548): the rereading, registration and rewrite `refresh_before_turn/1`
  starts with, and nothing after it. No session is minted and no connection
  is touched, so a running turn carries on, and its next tunnel through the
  broker reads the new rules. Reads and writes the fields
  `refresh_before_turn/1` does, less `broker` and `sprite_env`.

  The state comes back unchanged unless the rules were rewritten. A rewrite
  that fails leaves the old copy in place, so the refresh before the next
  turn still sees the change and falls through to a fresh session as it
  always has. An unbrokered conversation is a no-op: its secrets are in the
  sandbox's env, and only a new process reads them again.
  """
  @spec refresh_live(map()) :: map()
  def refresh_live(%{broker: nil} = state), do: state

  def refresh_live(state) do
    case reread_and_rewrite(state) do
      {refreshed, :rewritten} ->
        Logger.info("conv #{state.conversation_id}: a secret write reached the live broker rules")
        refreshed

      {_refreshed, _unchanged_or_failed} ->
        state
    end
  end

  # What both refreshes share: the secrets read again, registered, and a
  # change written into the live session's rules with the token kept.
  # `:unchanged`, `:rewritten` or `:failed`, with the state that was read.
  defp reread_and_rewrite(state) do
    {state, changed?} = reread_secrets(state)

    # Before the broker can inject any of it. An edited vault secret becomes
    # live through the rewrite or a fresh session, and `SpriteEnv.build/4` —
    # the only other registration — does not run on these paths. Registered without it, the new credential
    # would be echoed into `log_events` in plaintext by the first upstream
    # that returns a header. `add/2`, not `put/2`: the old value can still be
    # in output already on its way.
    Redaction.add(state.conversation_id, Map.to_list(state.brokered))

    cond do
      not changed? -> {state, :unchanged}
      rewrite_rules(state) == :ok -> {state, :rewritten}
      true -> {state, :failed}
    end
  end

  # The tenant's own secrets, as init merged them. Two decrypts of two rows
  # per turn; a turn is a sandbox spawn or an ACP prompt, so the read is not
  # what a turn waits on.
  defp reread_secrets(state) do
    {state, token_moved?} = reread_chatgpt_token(state)
    # The bound credential rotated in place (#2602): the new value goes to
    # the broker, the sandbox keeps its placeholder.
    {state, rotated?} = Fountain.Conversations.InferenceRotation.reread_brokered(state)

    # What a deleted tenant secret hands its name back to: the inference
    # credential of that name.
    {_creds, underlay, _implicit} =
      Broker.split_inference(state.inference_credentials, state.broker_bindings)

    {brokered, tenant_keys, edited?} =
      refresh_tenant_secrets(
        state.tenant_keys,
        Fountain.Conversations.SpriteEnv.without_inference_inputs(
          Map.get(state, :inference_model),
          tenant_secrets(state)
        ),
        state.brokered,
        state.broker_bindings,
        underlay
      )

    state = %{state | brokered: brokered, tenant_keys: tenant_keys}

    # Last, so a connection's token is what its reserved key carries
    # (ADR 0085): refreshed first if it expires within ten minutes.
    {state, connection_moved?} = Fountain.Conversations.McpConnections.reread(state)

    {state, edited? or token_moved? or rotated? or connection_moved?}
  end

  # A conversation on a ChatGPT subscription (ADR 0070): the access token as
  # it is stored now, so a refresh by the daily keepalive (or by another
  # replica) reaches the broker's rule before the next turn. A database read,
  # not an exchange with the auth server, unless the stored token has
  # expired or is about to (`Fountain.ChatGPT.token_for/2`). A subscription
  # that no longer serves changes nothing here: the turn's gate refuses it
  # with `chatgpt_reconnect_required`.
  defp reread_chatgpt_token(state) do
    with {user_id, account_id} <-
           Fountain.InferenceCredentials.Source.chatgpt_owner(Map.get(state, :inference_source)),
         {:ok, token} <- Fountain.ChatGPT.token_for(user_id, account_id),
         creds when is_map(creds) <- state.inference_credentials,
         old when is_binary(old) and old != token <- creds[:codex_chatgpt_access_token] do
      key = Fountain.Conversations.CodexChatGPT.env_key()

      brokered =
        if Map.has_key?(state.brokered, key),
          do: Map.put(state.brokered, key, token),
          else: state.brokered

      {%{
         state
         | inference_credentials: Map.put(creds, :codex_chatgpt_access_token, token),
           brokered: brokered
       }, true}
    else
      _ -> {state, false}
    end
  end

  # The environment + vault merge as it stands now. Both fetches are
  # tenant-scoped on the user the server established at init; a row that is
  # gone contributes nothing, so its secrets leave the broker too.
  defp tenant_secrets(%{secret_sources: nil}), do: %{}

  defp tenant_secrets(%{secret_sources: sources} = state) do
    env =
      sources.environment_id &&
        Environments.get_environment(sources.environment_id, state.user_id)

    vault = sources.vault_id && Vaults.get_vault(sources.vault_id, state.user_id)
    SpriteEnv.merge_secrets(env, vault, state.tenant_key)
  end

  defp rewrite_rules(state) do
    case refresh_rules(
           state.conversation_id,
           state.brokered,
           state.broker_bindings,
           session_opts(state)
         ) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning(
          "conv #{state.conversation_id}: broker rules rewrite failed: #{inspect(reason)}"
        )

        :error
    end
  end

  @doc """
  What every mint and every rewrite of this conversation's broker session is
  given: the network shape and the tenant.
  """
  @spec session_opts(map()) :: keyword()
  def session_opts(state), do: [network: state.broker_network, user_id: state.user_id]

  @doc "Keep the minted proxy session in server state."
  def prepare_state(state) do
    case prepare(
           state.conversation_id,
           state.brokered,
           state.broker_bindings,
           session_opts(state)
         ) do
      {:ok, session} -> {:ok, %{state | broker: session}}
      {:error, _} = error -> error
    end
  end

  @doc "Revoke only the session this preparation returned; a failed mint owns no token."
  def release_prepared({:ok, %{broker: %{token: token}} = state}),
    do: Broker.release_session(state.user_id, state.conversation_id, token)

  def release_prepared(_result), do: :ok

  @doc """
  Install broker trust and establish transport readiness; nothing without a
  session.

  `relay_owner` names whom the machine's transport relay belongs to
  (`Fountain.Broker.TransportRelay`, which refuses a second owner): the
  conversation on an implicit workspace's machine, as it always was, and the
  workspace on an explicit one, whose conversations share the relay as they
  share the trust store (ADR 0097, step 5; `Fountain.Workspaces.relay_owner/2`).
  The relay holds no token, so sharing it shares nothing a conversation's
  own proxy credential does not already carry.
  """
  @spec install_ca(session(), Managoat.Sandbox.Handle.t(), String.t(), String.t() | nil) ::
          :ok | {:error, term()}
  def install_ca(session, handle, conversation_id, relay_owner \\ nil)
  def install_ca(nil, _handle, _conversation_id, _relay_owner), do: :ok

  def install_ca(session, handle, conversation_id, relay_owner) do
    # The relay verifies the broker endpoint's own certificate, which the
    # operator's ingress serves from a public or operator CA already in the
    # system bundle, never the broker CA installed here. So it starts beside
    # the CA install rather than after it: the two were 0.47 s and 0.6-0.7 s
    # one after the other on a fresh sprite (2026-10-17). Failures still
    # answer in the old order, the CA's first.
    relay = start_transport(handle, relay_owner || conversation_id)
    result = Provisioning.install_broker_ca(handle, conversation_id)

    # Only a conversation's trust setup reaches this path. Broker health
    # probes and session refreshes do not contribute to the failure ratio.
    Fountain.Telemetry.event(
      [:broker, :ca_install],
      %{provider: handle.provider, outcome: ca_install_outcome(result)},
      %{count: 1}
    )

    transport = await_transport(relay)

    with :ok <- result,
         :ok <- transport_ready(transport, conversation_id) do
      publish_stage(conversation_id, "broker", "done", %{
        vault: session.vault,
        expires_at: session.expires_at
      })

      :ok
    end
  end

  # An exception in the relay task would reach the caller as a link exit, past
  # the rescue that fails a provision cleanly, so it is caught and re-raised
  # here with its own stacktrace.
  defp start_transport(handle, owner) do
    context = :otel_ctx.get_current()

    Task.async(fn ->
      token = :otel_ctx.attach(context)

      try do
        {:ok, Fountain.Broker.TransportRelay.ensure(handle, owner)}
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      after
        :otel_ctx.detach(token)
      end
    end)
  end

  defp await_transport(task) do
    case Task.await(task, :infinity) do
      {:ok, result} -> result
      {:raised, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  defp transport_ready(:ok, _conversation_id), do: :ok

  defp transport_ready({:error, _} = error, conversation_id) do
    publish_stage(conversation_id, "broker", "failed", %{reason: "relay_unavailable"})
    error
  end

  defp ca_install_outcome(:ok), do: "ok"
  defp ca_install_outcome({:error, {:broker, :ca_install_exit, _, _}}), do: "exit"
  defp ca_install_outcome({:error, {:broker, :ca_install, _}}), do: "unreachable"
  defp ca_install_outcome({:error, _}), do: "unavailable"

  # Every session of the conversation goes when its sandbox does. Still off
  # the caller's path: deleting rows is local and cannot fail the way a call
  # to a vendor proxy could, but teardown is not a place to start waiting on
  # the database either, and a broker session that outlives its sandbox is
  # swept by `Fountain.Workers.BrokerReaper` regardless.
  @spec release(String.t()) :: :ok
  def release(conversation_id) do
    Task.Supervisor.start_child(Fountain.TaskSupervisor, fn -> Broker.release(conversation_id) end)

    :ok
  end

  @doc """
  The network floor: the broker's host is the one the sandbox may reach. The
  environment's `networking_type` is enforced at the broker, not here.
  """
  @spec apply_policy(Managoat.Sandbox.Handle.t(), String.t()) :: :ok | {:error, term()}
  def apply_policy(handle, conv_id), do: Provisioning.apply_broker_floor(handle, conv_id)

  @doc """
  Ensure the floor before an existing machine receives credentials or resumes.

  A machine may predate the deployment's broker, from before brokerage was
  unconditional, so the floor is asserted on every attach. On a machine the
  provider reports running (`running?: true`) it is written only when the
  provider does not already report it: a Sprites write resets the machine's
  open flows, and in a workspace those include other conversations' model
  streams (fountain#2964). A parked or waking machine has no flows to lose,
  so its floor is written, as before, rather than trusted across the wake.
  Policy failures are retryable and never establish that its disk is gone.
  """
  @spec reattach_policy(Managoat.Sandbox.Handle.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def reattach_policy(handle, conv_id, opts \\ []) do
    with :ok <- Provisioning.check_broker_support(handle.provider, conv_id) do
      Provisioning.apply_broker_floor(handle, conv_id,
        if_changed: Keyword.get(opts, :running?, false)
      )
    end
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Fountain.Conversations.publish_stage(conv_id, stage, status, meta)
  end
end
