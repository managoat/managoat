defmodule Fountain.Conversations.SpriteEnv do
  @moduledoc """
  The sandbox's environment: rows and decrypted secrets in, an ordered
  `{name, value}` list out.

  One precedence rule, stated here and nowhere else: **a vault wins over an
  environment on key collision** (`merge_secrets/3`). In the assembled list
  (`build/4`) the runtime's own defaults come first and the broker's proxy
  variables last, and the secrets in it — the credentials, not the
  identifiers around them — are registered with
  `Fountain.Conversations.Redaction` before it is returned, so every secret
  the agent is given is scrubbed from its output (`secret_values/6`, #2366).

  Functions over rows and values, not over server state (#1369). Nothing
  here talks to a sandbox; the writes that carry the list into one are
  `Fountain.Conversations.Provisioning`'s.
  """

  alias Fountain.{Broker, Crypto, Environments, InferenceCredentials, Vaults}
  alias Fountain.Conversations.{CallbackKey, InferenceResolution}
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  @doc """
  The source and credentials a provision runs on: the stored source
  re-validated against the rows loaded now, under
  `Fountain.Conversations.InferenceBinding.with_current/2`, then reserved.
  A conversation admitted before sources were stored (no `inference_source`)
  is a new selection, which is what
  `InferenceResolution.revalidate/3` does with nothing to compare against.
  """
  def resolve_inference(conv, agent, env, vault) do
    Fountain.Conversations.InferenceBinding.with_current(conv, fn conv ->
      with {:ok, dek} <- Crypto.load_tenant_key(conv.user_id),
           {:ok, source, creds} <-
             InferenceResolution.revalidate(conv, agent,
               environment_id: env && env.id,
               vault_id: vault && vault.id
             ),
           :ok <- Fountain.Conversations.InferenceBinding.reserve(conv, source) do
        {:ok, dek, source, creds}
      end
    end)
  end

  # Env secrets first, vault overrides last — vault wins on key collision.
  # Same merged map feeds repositories[].secret_key resolution.
  @spec merge_secrets(Environment.t() | nil, Vault.t() | nil, binary()) :: %{
          String.t() => String.t()
        }
  def merge_secrets(env, vault, dek) do
    env_secrets = if env, do: Environments.decrypted_env(env, dek), else: %{}
    vault_secrets = if vault, do: Vaults.decrypted_env(vault, dek), else: %{}
    Map.merge(env_secrets, vault_secrets)
  end

  @doc """
  The sandbox's environment, assembled in the order the pieces have always
  come in: the runtime's own defaults, the callback pair, the conversation
  and sandbox ids, the sandbox URL, the trace context, the git author, the
  broker's CA defaults, the environment's plain variables, the decrypted
  secrets and, last, the broker's proxy variables.

  The broker's pairs sit on either side of the tenant's own values on
  purpose. Its CA variables are hints — "here is a trust store holding the
  MITM root" — so an `env_vars` entry naming a different bundle wins, and
  costs that tenant its own egress and nobody else's. Its proxy variables
  are the chokepoint (ADR 0019), so nothing overrides them. Before #1674 the
  whole list came last, so an `env_vars` entry for one of those names was
  written and then overwritten one line later. `docs/concepts/secrets.md`
  publishes both halves of the rule.

  `opts` carries what `ConversationServer` holds: `:runtime_module`,
  `:env_credentials`, `:callback_token`, `:conversation_id` and
  `:sandbox_id`, plus `:sandbox_url` (nil before the sandbox has one),
  `:brokered` (the pairs from the broker session, `[]` when the conversation
  is not brokered; the broker half is #1373's).
  """
  @spec build(map() | nil, Environment.t() | nil, map(), keyword()) ::
          [{String.t(), String.t()}]
  def build(agent, env, secrets, opts) do
    runtime_module = Keyword.fetch!(opts, :runtime_module)
    conversation_id = Keyword.fetch!(opts, :conversation_id)
    {ca_defaults, proxy} = split_brokered(Keyword.get(opts, :brokered, []))

    env_credentials = Keyword.fetch!(opts, :env_credentials)

    # Only the resolved kind reaches the selected provider's auth inputs.
    # Its value has already passed through Egress, including broker custody.
    auth_names = inference_input_names(agent && agent.model)

    plain = if env, do: Map.drop(env.env_vars || %{}, auth_names), else: %{}
    secrets = Map.drop(secrets, auth_names)

    sprite_env =
      with_legacy_names(runtime_module.default_env(agent, env_credentials) || []) ++
        config_env(runtime_module, Keyword.get(opts, :config_home)) ++
        Fountain.Conversations.CodexChatGPT.env(runtime_module, env_credentials) ++
        with_legacy_names(
          CallbackKey.env(Keyword.fetch!(opts, :callback_token)) ++
            conversation_env(conversation_id) ++
            sandbox_id_env(Keyword.fetch!(opts, :sandbox_id))
        ) ++
        sandbox_url_env(Keyword.get(opts, :sandbox_url)) ++
        otel_propagation_env() ++
        git_author_env() ++
        ca_defaults ++
        Enum.map(plain, fn {k, v} -> {to_string(k), to_string(v)} end) ++
        Enum.map(secrets, fn {k, v} -> {k, v} end) ++
        proxy

    # Register before anything can log. Provisioning writes output from its
    # very first step, and the secrets are already in the sprite by then.
    #
    # `:broker_credentials` are the values `Broker.split/2` took *out* of the
    # secrets above, swapping each for a placeholder so the sandbox never holds
    # one (ADR 0019). They are therefore absent from `sprite_env`, and building
    # the registry from the env alone left them unscrubbed — which matters
    # because keeping a credential out of the sandbox does not keep it out of
    # the sandbox's *output*. The broker injects it into an outbound request,
    # and an upstream that echoes a header back returns it as ordinary tool
    # output, which `log_events` stores verbatim and the stream serves. The one
    # value brokering exists to withhold from the agent was the one value never
    # redacted from what the agent reads.
    broker_credentials = Keyword.get(opts, :broker_credentials, %{})

    # `add/2`: a wake or reattach rebuilds this env, and a value registered
    # earlier in the conversation can still be in output on its way.
    Fountain.Conversations.Redaction.add(
      conversation_id,
      secret_values(sprite_env, secrets, plain, proxy, broker_credentials, opts)
    )

    sprite_env
  end

  # What the registry holds: the values that are secret, and not the rest of
  # the env (#2366).
  #
  # Registering `sprite_env` whole was one line and needed no judgement, and
  # the judgement is now unavoidable, because the registry is no longer only
  # a scrubber. `RedactionCarry` holds back any chunk whose end could begin a
  # registered value, so every non-secret in the registry buys latency on the
  # live stream and a `[REDACTED]` over ordinary text. With the conversation
  # and sandbox ids registered — UUIDs — every hex character was the start of
  # a value, so a large share of the model's own reply arrived a chunk late,
  # and a conversation that printed its own id read `[REDACTED]`.
  #
  # So each piece is classified at its source rather than filtered back out of
  # the assembled list: an env pair is secret when the value came from a
  # credential, and not when the value came from Fountain's own identifiers
  # and configuration (`MANAGOAT_CONVERSATION_ID`, `MANAGOAT_SANDBOX_ID`,
  # `SANDBOX_URL`, `MANAGOAT_BASE_URL`, the trace context, the git author, the
  # CA paths, a runtime's `HOME`) or from the broker's placeholder rule. Add a
  # piece to `build/4` that carries a credential, and add it here too; the
  # `SpriteEnvTest` coverage over this function is where that is checked.
  #
  # The tenant's plain `env_vars` stay registered. They are config by
  # intention, but nothing stops someone from pasting a token into one, and
  # they are few and tenant-sized — unlike the identifiers, which are on every
  # conversation. Environments would need a secret/non-secret distinction of
  # their own before this could drop them (#2366).
  defp secret_values(sprite_env, secrets, plain, proxy, broker_credentials, opts) do
    credentials =
      exported_credentials(
        sprite_env,
        Keyword.fetch!(opts, :env_credentials),
        broker_credentials
      )

    # A brokered key's value here is the placeholder `Broker.split/2` left in
    # its place, and the credential it stands for arrives in
    # `broker_credentials` below.
    #
    # Provenance decides, not shape. `broker_credentials` is the map the split
    # produced, so a key in it is a key the broker took custody of, and only
    # such a key's value can be a stand-in. A tenant is free to store
    # `PASSWORD=__password__`; unbrokered, that is a secret like any other and
    # stays registered, which testing the value's shape alone would get wrong.
    tenant_secrets =
      for {key, value} <- secrets,
          not (Map.has_key?(broker_credentials, key) and Broker.placeholder?(key, value)),
          do: value

    # The proxy variables carry the broker session token inside a URL. The
    # token is the secret; the URL around it is public, and registering it
    # whole would hold back every chunk of output that ends in `h`.
    proxy_token = Broker.proxy_secrets(proxy)

    credentials ++
      [Keyword.fetch!(opts, :callback_token)] ++
      tenant_secrets ++
      Enum.map(plain, fn {_k, v} -> to_string(v) end) ++
      Map.values(broker_credentials) ++
      proxy_token
  end

  @doc """
  The credential values a sprite env exports.

  A conversation resolves every credential its provider could want and the
  runtime exports the one it picked — Claude takes the OAuth token or the API
  key, never both. The kind it passed over is not in the sandbox, so it is not
  in the sandbox's output either, and registering it for redaction would buy
  nothing and hold back output that begins with its first byte (#2366).
  `ConversationServer` registers through here too, for the API key it injects
  when a provider refuses a subscription.

  A brokered credential is not one of these either: `split_inference/2` put
  the value itself in `brokered`, which `build/4` registers, and left the
  runtime a string generated from the broker's own key name. Pass that map as
  `brokered` and each credential in it is matched against the placeholder for
  **its** key, not for the name it is exported under: a Google key stored as
  `GOOGLE_GENERATIVE_AI_API_KEY` is held by the broker as `GEMINI_API_KEY`, so
  comparing against the exported name left `AIza__gemini_api_key__` in the
  registry.

  Every credential reaches a sprite through this list. One that ever reaches
  it another way — as a brokered value does, which `build/4` registers
  explicitly — has to be registered where that happens.
  """
  @spec exported_credentials([{String.t(), String.t()}], map(), map()) :: [String.t()]
  def exported_credentials(sprite_env, env_credentials, brokered \\ %{}) do
    exported = MapSet.new(sprite_env, fn {_key, value} -> value end)
    stand_ins = credential_placeholders(brokered)

    for {credential, value} <- env_credentials,
        is_binary(value),
        value != Map.get(stand_ins, credential),
        MapSet.member?(exported, value),
        do: value
  end

  @doc """
  Register what a sprite env rebuilt outside `build/4` exports, for a
  conversation already running: the credentials it exports
  (`exported_credentials/3`) and the brokered values.

  `ConversationServer`'s answer to a refused Claude OAuth token (#655)
  injects the API key, which was never in the sprite env before, so
  `build/4` never registered it; without this the very value the fix
  injects prints in plaintext into `log_events`. The credentials the env
  exports, not the env whole (#2366); the refused OAuth token is still in
  the sprite's `/home/sprite/.env`, and `Redaction.add/2` never forgets it.
  """
  @spec register_exported(String.t(), [{String.t(), String.t()}], map(), map()) :: :ok
  def register_exported(conversation_id, sprite_env, env_credentials, brokered) do
    creds = exported_credentials(sprite_env, env_credentials, brokered)
    Fountain.Conversations.Redaction.add(conversation_id, creds ++ Map.values(brokered))
  end

  # What each brokered inference credential carries in the sandbox, by
  # credential rather than by env name. `Broker.inference_keys/0` maps the
  # broker's key names to the credentials they hold, and `placeholder/1` is
  # generated from the key, so this is the broker's own account of what it
  # replaced — never a guess from the value's shape.
  defp credential_placeholders(brokered) do
    inference = Broker.inference_keys()

    for {key, _value} <- brokered,
        key = to_string(key),
        credential = Map.get(inference, key),
        into: %{},
        do: {credential, Broker.placeholder(key)}
  end

  def without_inference_inputs(model, inputs),
    do: Map.drop(inputs, inference_input_names(model))

  # The env names that would carry a credential for the provider the run
  # reaches, which the model's prefix says.
  defp inference_input_names(model) do
    model
    |> Managoat.Runtimes.Model.provider()
    |> InferenceCredentials.credentials_for_provider()
    |> Enum.flat_map(&Map.fetch!(InferenceCredentials.env_aliases(), &1))
  end

  @doc """
  `pairs` with every `MANAGOAT_*` variable also exported under its
  `FOUNTAIN_*` name, right after it.

  The variables Managoat gives a sandbox were `FOUNTAIN_*` until ADR 0082.
  Agents, skills, setup scripts and CLIs written before it read the old
  names, so both are set for a deprecation window; a later release stops
  exporting the old ones (#2776). Only Managoat's own variables pass through
  here, never a tenant's `env_vars` or secrets.
  """
  @spec with_legacy_names([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def with_legacy_names(pairs) do
    Enum.flat_map(pairs, fn
      {"MANAGOAT_" <> name, value} = pair -> [pair, {"FOUNTAIN_" <> name, value}]
      pair -> [pair]
    end)
  end

  # The variable that points the runtime at the conversation's config home
  # (ADR 0097): `CLAUDE_CONFIG_DIR`, `CODEX_HOME`, `GEMINI_CLI_HOME`, or the
  # `acp` runtime's `MANAGOAT_SKILLS_DIR`. A path, not a credential, so it is
  # not registered for redaction. Before the tenant's own variables, so an
  # `env_vars` entry naming the same variable wins, as it always could for
  # `HOME`; that moves the runtime off the files Managoat writes, which is the
  # tenant's choice.
  defp config_env(_runtime_module, nil), do: []

  defp config_env(runtime_module, home),
    do: with_legacy_names(Managoat.Runtimes.config_env(runtime_module, home))

  # The overridable half of the broker's pairs, and the half that is not.
  # Split by key rather than by position: `:brokered` is whatever
  # `Egress.sandbox_env/1` handed over, and a pair belonging to neither half
  # keeps the old behaviour of coming last.
  defp split_brokered(brokered) do
    ca_keys = Fountain.Broker.ca_keys()
    Enum.split_with(brokered, fn {k, _v} -> to_string(k) in ca_keys end)
  end

  # The sandbox's own HTTP endpoint, so an agent asked "what's the URL?" can
  # answer. Without it the agent has no way to know: the platform assigns the
  # URL outside the sandbox, and inside it the hostname is just "sprite".
  #
  # `SANDBOX_URL` rather than `SPRITE_URL` because the value is provider-
  # neutral; a provider that has no such endpoint simply sets nothing, and an
  # unset variable is the honest answer to "no URL".
  @spec sandbox_url_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_url_env(nil), do: []
  def sandbox_url_env(url) when is_binary(url), do: [{"SANDBOX_URL", url}]

  # Inject the current conversation ID so the bundled managoat skill can
  # propagate it as X-Managoat-Parent-Conversation-Id when spawning children.
  @spec conversation_env(String.t() | nil) :: [{String.t(), String.t()}]
  def conversation_env(nil), do: []

  def conversation_env(conv_id) when is_binary(conv_id),
    do: [{"MANAGOAT_CONVERSATION_ID", conv_id}]

  # The machine's own id, so the bundled managoat skill can put a child
  # conversation onto this same sandbox (`sandbox_id` on the create, ADR 0023).
  # Machine-scoped, not conversation-scoped: every conversation on the sandbox
  # sees the same value, so unlike the conversation id it may live on the disk.
  @spec sandbox_id_env(String.t() | nil) :: [{String.t(), String.t()}]
  def sandbox_id_env(nil), do: []

  def sandbox_id_env(sandbox_id) when is_binary(sandbox_id),
    do: [{"MANAGOAT_SANDBOX_ID", sandbox_id}]

  @doc false
  def git_author_env do
    [
      {"GIT_AUTHOR_NAME", "AoD"},
      {"GIT_AUTHOR_EMAIL", "aod@local"},
      {"GIT_COMMITTER_NAME", "AoD"},
      {"GIT_COMMITTER_EMAIL", "aod@local"}
    ]
  end

  # Inject the W3C trace context as TRACEPARENT into the sprite env when
  # we're inside an active OTel span. claude / codex / gemini
  # all read TRACEPARENT and tag their API calls into the trace, so a
  # turn span has every model API request as a child.
  @spec otel_propagation_env() :: [{String.t(), String.t()}]
  def otel_propagation_env do
    case Fountain.Telemetry.current_traceparent() do
      nil -> []
      tp -> [{"TRACEPARENT", tp}]
    end
  end
end
