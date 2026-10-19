defmodule Fountain.Broker do
  @moduledoc """
  The egress credential broker (ADR 0019).

  A brokered conversation's sandbox holds a **placeholder** where a
  credential used to be, plus a proxy address. The real value stays in the
  DEK-encrypted rows it always lived in and is attached to the outbound
  request at a forward proxy. The sandbox's only permitted egress is the
  proxy, so a placeholder is worthless off the box.

  This module is the seam the rest of the app talks to: the catalog of
  secrets the broker knows how to carry, the placeholder rule, the split of
  a secrets map into what the sandbox gets and what the broker gets, the
  sandbox's environment, and the session lifecycle. It is the **policy**;
  the proxy that does the attaching is `Fountain.Broker.Native`, the
  `Managoat.Broker` listener this application runs itself, selected by
  `BROKER_LISTEN_PORT`.

  Gate 1a shipped against a vendor proxy, Agent Vault, and this module was a
  facade over both while production moved across. Production flipped on
  2026-09-03 (#1485) and the vendor client is gone; what is left of that
  history is in ADR 0019. Functions that do not reach a proxy at all
  (`split/2`, `placeholder/1`, `sandbox_env/1`, `network_for/1`, ...) never
  cared which one ran.

  ## What is brokered

  * A secret with an enabled **binding** (`Fountain.SecretBindings`, gate 1b):
    the tenant said which host it goes to and how. One service per binding.
  * `GITHUB_TOKEN` and `GH_TOKEN` with no binding of their own, bound by the
    built-in catalog to `api.github.com` and `api.githubcopilot.com` (bearer),
    and `github.com` (git over
    HTTPS, basic `x-access-token`) — gate 1a's default, kept so a tenant who
    never opens the bindings page keeps working.
  * The runtime's **inference credential** (gate 3): `CLAUDE_CODE_OAUTH_TOKEN`
    or `ANTHROPIC_API_KEY`, `OPENAI_API_KEY`, `GEMINI_API_KEY`. The runtime
    gets a vendor-shaped placeholder and the broker substitutes the value on
    requests to the provider's host. A tenant secret of the same name with a
    binding of its own wins, as it wins in the environment.
  * Every other secret reaches the sandbox exactly as before.
  * Every tenant, on every deployment. Brokerage was a per-tenant ratchet
    (`BROKER_TENANTS`, ADR 0019 §9) and then a deployment switch
    (`BROKER_LISTEN_PORT` blank meant off); both are gone, and since the
    amendment of 2026-10-15 a deployment without a broker does not boot.

  ## How a value is attached

  Every service carries a **substitution** for its key: the broker replaces
  the placeholder wherever it appears in a request to that host, so the agent
  sends the shape the API wants and nothing has to be told how. A binding's
  explicit shape (bearer, api-key, custom) additionally sets a header the
  agent did not send; `basic` is the one case substitution cannot reach,
  because the client base64-encodes the value before it leaves.

  Substitution reaches **header values and the request target** — the path
  and the query — since `managoat_broker` 0.2.0 (#1501 row 1). So a
  credential a client puts in a URL is brokered: the bot-API shape
  `/bot<token>/sendMessage`, or a `?key=` parameter. A tenant declares that
  a key has a placeholder and nothing more; there is deliberately no
  `auth_type` for *where* the placeholder sits, because the proxy finds it.
  A request body is still not rewritten, and that is a recorded deviation
  from Agent Vault rather than an oversight (ADR 0019's parity amendment).

  Two consequences of substituting into a URL are worth knowing before
  writing a binding. The credential replaces the placeholder **byte for
  byte** — nothing is percent-encoded on the way in — so a credential that
  needs encoding is declared already encoded. And a credential the proxy
  cannot write where its placeholder sits is refused with a 403 rather than
  mangled: a space or a control character in a target, a CR or LF in a
  header value.

  ## The network policy (gate 2)

  The sandbox's own policy is always the floor, `allow: [broker]`. What the
  environment's `networking_type` says is enforced **at the broker**:
  `unrestricted` sets the session's unmatched-host policy to `passthrough`,
  so the agent may reach any host but only ever with the credentials it was
  granted; `limited` sets it to `deny` and turns `allowed_hosts` into
  passthrough services, so an unlisted host is refused with a 403.

  ## Custody

  One broker session per **conversation**, deleted when the conversation
  ends (ADR 0019 §11 as amended). The binding is on the token: a token
  resolves to its own conversation's credentials and to nothing else. The
  one other owner is an explicit workspace's provision on create, which runs
  before any conversation exists under a session of the workspace's own,
  from its environment and vault, released when the setup ends
  (`prepare_workspace/4`; ADR 0097, step 5).

  The session token lives six hours (`:broker_session_ttl_seconds`) and travels to the
  sandbox inside `HTTPS_PROXY`, which is why that variable is process-only
  in `Fountain.Conversations.Identity` and never reaches the shared `.env`.
  """

  alias Fountain.Broker.Native

  # Named for the vendor proxy this replaced, and deliberately not renamed:
  # `install_broker_ca/2` overwrites this exact path, so every sandbox already
  # provisioned swaps its root in place. A new filename would leave the old
  # file behind in the trust store, trusted, with nothing to remove it.
  @ca_path "/usr/local/share/ca-certificates/agent-vault.crt"

  # The OS trust bundle update-ca-certificates rebuilds — real roots plus the
  # broker CA install_broker_ca added. Point replacement-style CA vars here,
  # never at @ca_path alone: that is one cert, and a tool told to trust only it
  # rejects every non-brokered host (pypi, crates.io) it also has to reach.
  @system_ca_bundle "/etc/ssl/certs/ca-certificates.crt"

  @doc """
  The OS trust bundle the CA variables point at, and the artifact
  `install_broker_ca/2` is protecting: `update-ca-certificates` derives it
  from `ca_path/0` and the real roots.
  """
  @spec system_ca_bundle() :: String.t()
  def system_ca_bundle, do: @system_ca_bundle

  @typedoc "A minted proxy session for one conversation."
  @type session :: %{
          vault: String.t(),
          token: String.t(),
          expires_at: DateTime.t() | nil
        }

  # ---------------------------------------------------------------------------
  # Configuration

  @doc "The address the sandbox dials, without a credential."
  @spec proxy_url() :: String.t()
  def proxy_url, do: Application.fetch_env!(:fountain, :broker_proxy_url)

  @doc "The one host a brokered sandbox may reach."
  @spec proxy_host() :: String.t()
  def proxy_host, do: URI.parse(proxy_url()).host

  @doc "How long the egress request log keeps a row before `Fountain.Workers.BrokerReaper` deletes it."
  @spec log_retention_hours() :: pos_integer()
  def log_retention_hours, do: Application.get_env(:fountain, :broker_log_retention_hours, 168)

  @doc "Where the broker CA lands in the sandbox. Node reads it through `NODE_EXTRA_CA_CERTS`."
  @spec ca_path() :: String.t()
  def ca_path, do: @ca_path

  @doc "Where the PEM is written first, as the sandbox user, before sudo moves it into the trust store."
  @spec ca_staging_path() :: String.t()
  def ca_staging_path, do: "/tmp/agent-vault-ca.crt"

  # ---------------------------------------------------------------------------
  # The catalog and the placeholder rule

  # Key name → the services the broker attaches it to. A binding needs a host
  # and an auth shape; today a secret is `{key, value}` and nothing else, so
  # the catalog is what supplies both, by key name. The tail of secrets that
  # need an explicit host is gate 1b (#1090).
  @catalog %{
    "GITHUB_TOKEN" => :github,
    "GH_TOKEN" => :github
  }

  @doc "The secret keys gate 1a knows how to broker."
  @spec catalog_keys() :: [String.t()]
  def catalog_keys, do: Map.keys(@catalog)

  @doc false
  # The unbound GitHub key the catalog rules is attached to, or nil when no
  # catalog key is present without bindings of its own. Both names may be
  # present after the merge; the git URL is written with whichever one
  # `repositories[].secret_key` names, and the broker needs a single
  # credential per service. Prefer the canonical name.
  @spec catalog_github_key(map(), map()) :: String.t() | nil
  def catalog_github_key(brokered, bindings) do
    unbound = fn key -> Map.has_key?(brokered, key) and not Map.has_key?(bindings, key) end

    cond do
      unbound.("GITHUB_TOKEN") -> "GITHUB_TOKEN"
      unbound.("GH_TOKEN") -> "GH_TOKEN"
      true -> nil
    end
  end

  @doc false
  # The username git over HTTPS sends beside a GitHub token.
  @spec github_basic_user() :: String.t()
  def github_basic_user, do: "x-access-token"

  @inference_prefix %{
    "CLAUDE_CODE_OAUTH_TOKEN" => "sk-ant-oat01-",
    "ANTHROPIC_API_KEY" => "sk-ant-api03-",
    "OPENAI_API_KEY" => "sk-",
    "GEMINI_API_KEY" => "AIza"
  }

  @doc """
  The placeholder a brokered key carries in the sandbox.

  Lowercase, wrapped in double underscores: visibly not a token, and exactly
  the string the broker's substitution looks for. An inference credential
  keeps its vendor prefix in front (`sk-ant-oat01-__claude_code_oauth_token__`)
  for a CLI that checks the shape of its own token before sending it; the
  substitution then replaces the whole prefixed string.
  """
  @spec placeholder(String.t()) :: String.t()
  def placeholder(key) do
    Map.get(@inference_prefix, key, "") <> "__" <> String.downcase(key) <> "__"
  end

  @doc """
  True when `value` is what the sandbox holds for `key` in place of a secret.

  The sandbox's copy of a brokered key is `placeholder/1`, which is generated
  from the key and is not a secret: the value it stands for never entered the
  sandbox, and the broker puts it back on the way out. So a placeholder is
  left out of the redaction registry, where it would hold back every chunk of
  output ending in `_` and print the agent's own `__github_token__` back as
  `[REDACTED]` (#2366).

  This answers "is this the placeholder for that key", and nothing more. It is
  not evidence that the broker replaced anything: an unbrokered secret is free
  to hold `__password__`, and it is still a secret. A caller asks this only of
  a key the broker's own map says it took custody of.
  """
  @spec placeholder?(String.t(), term()) :: boolean()
  def placeholder?(key, value) when is_binary(key) and is_binary(value),
    do: value == placeholder(key)

  def placeholder?(_key, _value), do: false

  # Inference credentials (gate 3): the env var each runtime reads, the host
  # it talks to, and the prefix its vendor's tokens carry. Substitution
  # rewrites the placeholder wherever it appears in a header value or in the
  # request target, which covers every shape these runtimes send — Anthropic's
  # `x-api-key`, the OAuth bearer, OpenAI's bearer, Gemini's `x-goog-api-key`,
  # and now a `?key=` query parameter as well.
  #
  # The query half arrived with `managoat_broker` 0.2.0 (#1501 row 1). It is
  # not what makes Gemini work, and the measurement that established that is
  # worth keeping, because the obvious way to repeat it is wrong. Measured
  # 2026-09-03 against gemini-cli 0.58.0 — the sandbox images pin no version,
  # so this is what a sandbox runs — by hooking `fetch` under the sandbox's own
  # env (`GEMINI_API_KEY` set, no base-URL override, so `getAuthTypeFromEnv`
  # resolves `gemini-api-key`): every call to generativelanguage.googleapis.com
  # carries the key in `x-goog-api-key` and nothing in the query string. The
  # `?key=` form is real but belongs to the Live API's audio and music
  # WebSockets, which an ACP turn never opens.
  #
  # Note `GOOGLE_GEMINI_BASE_URL` outranks `GEMINI_API_KEY` in that
  # resolution, so pointing the CLI at a local capture changes the auth type
  # out from under the measurement. Hook the client, do not redirect it.
  @inference %{
    "CLAUDE_CODE_OAUTH_TOKEN" => %{cred: :claude_code_oauth_token, hosts: ["api.anthropic.com"]},
    "ANTHROPIC_API_KEY" => %{cred: :anthropic_api_key, hosts: ["api.anthropic.com"]},
    "OPENAI_API_KEY" => %{cred: :openai_api_key, hosts: ["api.openai.com"]},
    "GEMINI_API_KEY" => %{cred: :gemini_api_key, hosts: ["generativelanguage.googleapis.com"]},
    # A ChatGPT subscription's access token (ADR 0070). Codex sends it as the
    # bearer to the Codex backend on chatgpt.com; the sandbox's `auth.json`
    # holds this key's placeholder (`Fountain.Conversations.CodexChatGPT`).
    # The rule is the whole host, as for every other credential here.
    "CODEX_CHATGPT_ACCESS_TOKEN" => %{cred: :codex_chatgpt_access_token, hosts: ["chatgpt.com"]}
  }

  @doc "The env var names that carry inference credentials, and the credential each comes from."
  @spec inference_keys() :: %{String.t() => atom()}
  def inference_keys, do: Map.new(@inference, fn {k, v} -> {k, v.cred} end)

  @doc """
  Split the runtime's inference credentials (gate 3): the map handed to
  `default_env/2` gets placeholders, the broker gets the values under the
  env var names, and each gets an implicit `substitute` binding to its
  provider's host. A tenant's own binding for the same name wins.
  """
  @spec split_inference(map(), bindings()) :: {map(), %{String.t() => String.t()}, bindings()}
  def split_inference(credentials, bindings \\ %{}) when is_map(credentials) do
    Enum.reduce(@inference, {credentials, %{}, %{}}, fn {key, %{cred: cred, hosts: hosts}},
                                                        {creds, brokered, implicit} ->
      case Map.get(creds, cred) do
        value when is_binary(value) and value != "" ->
          implicit =
            if Map.has_key?(bindings, key),
              do: implicit,
              else: Map.put(implicit, key, Enum.map(hosts, &implicit_binding(key, &1)))

          {Map.put(creds, cred, placeholder(key)), Map.put(brokered, key, value), implicit}

        _ ->
          {creds, brokered, implicit}
      end
    end)
  end

  defp implicit_binding(key, host) do
    %Fountain.SecretBindings.Binding{
      key: key,
      host: host,
      auth_type: "substitute",
      headers: %{},
      enabled: true
    }
  end

  @typedoc "Enabled bindings grouped by secret key, as `Fountain.SecretBindings.enabled_by_key/1` returns them."
  @type bindings :: %{String.t() => [Fountain.SecretBindings.Binding.t()]}

  @doc """
  Split a merged secrets map into what the sandbox gets and what the broker
  gets. Runs on the merged map, so the vault-wins rule has already applied
  (ADR 0019 §9: brokering happens after the merge).

  A key is brokered when it has an enabled binding, or when it is a catalog
  key (`GITHUB_TOKEN`, `GH_TOKEN`) with none. Returns `{sandbox_secrets,
  brokered}`: a placeholder in the first map, the value in the second. Keys
  with an empty value are left alone: there is nothing to broker.
  """
  @spec split(%{String.t() => String.t()}, bindings()) ::
          {%{String.t() => String.t()}, %{String.t() => String.t()}}
  def split(secrets, bindings \\ %{}) when is_map(secrets) and is_map(bindings) do
    Enum.reduce(secrets, {%{}, %{}}, fn {k, v}, {sandbox, brokered} ->
      if brokered?(k, bindings) and is_binary(v) and v != "" do
        {Map.put(sandbox, k, placeholder(k)), Map.put(brokered, k, v)}
      else
        {Map.put(sandbox, k, v), brokered}
      end
    end)
  end

  defp brokered?(key, bindings), do: Map.has_key?(bindings, key) or Map.has_key?(@catalog, key)

  # A slug the broker accepts (`[a-z0-9-]{3,64}`, no `--`, no edge hyphen)
  # that is stable for a key+host pair, so a re-prepare upserts rather than
  # accumulates.
  @doc false
  def service_name(key, host) do
    base =
      (key <> "-" <> host)
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    base = if String.length(base) < 3, do: base <> "-svc", else: base
    String.slice(base, 0, 64) |> String.trim("-")
  end

  # ---------------------------------------------------------------------------
  # The sandbox side

  @doc """
  The label half of a conversation's proxy credential. `[a-z0-9-]`, 3 to 64
  characters.

  It is not a secret and the proxy ignores it: the random session token is the
  whole binding. It exists because git refuses a proxy URL that carries a user
  and no password, and it is named `vault` because the vendor proxy this
  replaced addressed a real vault by it.
  """
  @spec vault_name(String.t()) :: String.t()
  def vault_name(conversation_id) when is_binary(conversation_id) do
    "c-" <> (conversation_id |> String.downcase() |> String.replace(~r/[^a-z0-9]/, ""))
  end

  @doc """
  The environment pairs a brokered sandbox gets: `proxy_env/1` and then
  `ca_env/0`, in the order this has always returned them.

  The two halves are not equal, and `Fountain.Conversations.SpriteEnv.build/4`
  puts them on either side of the tenant's own values rather than taking this
  list whole. `HTTPS_PROXY` carries
  the session token (as `http://<token>:<vault>@host:port`), so it is
  process-only (`Identity.@process_only`); the lower case twins are for apt
  and the tools that only read those.

  The CA variables make each toolchain trust the broker's MITM certificate.
  `install_broker_ca` puts the CA in the OS trust store, which curl, git and
  anything on OpenSSL then read — but a tool with its own bundled roots does
  not. Node is told through `NODE_EXTRA_CA_CERTS` (additive, so the broker CA
  alone); the rest replace their bundle and so must name the full system bundle
  (`@system_ca_bundle`), not the broker CA on its own. `UV_NATIVE_TLS` turns uv
  off its bundled webpki roots and onto that same OS store. Without these, a
  brokered `uv sync`, `pip install`, or `cargo fetch` fails with
  `invalid peer certificate: UnknownIssuer` the moment it reaches a MITM'd host.
  """
  @spec sandbox_env(session(), ca_files()) :: [{String.t(), String.t()}]
  def sandbox_env(%{token: _, vault: _} = session, files \\ system_ca_files()),
    do: proxy_env(session) ++ ca_env(files)

  @typedoc "The broker CA on its own, and the full bundle that includes it."
  @type ca_files :: %{ca: String.t(), bundle: String.t()}

  @doc "The OS trust store's files, which `install_broker_ca/2` writes with sudo."
  @spec system_ca_files() :: ca_files()
  def system_ca_files, do: %{ca: @ca_path, bundle: @system_ca_bundle}

  @doc """
  The half that points a toolchain at a trust store holding the broker's CA.

  These are **defaults**: `SpriteEnv.build/4` emits them before the
  environment's `env_vars` and the decrypted secrets, so a tenant that has a
  reason to name its own bundle can (#1674). Naming a bundle without the
  broker CA costs that tenant its own egress and nobody else's — the values
  are hints to a client, not the chokepoint.
  """
  @spec ca_env(ca_files()) :: [{String.t(), String.t()}]
  def ca_env(%{ca: ca, bundle: bundle} \\ system_ca_files()) do
    [
      {"NODE_EXTRA_CA_CERTS", ca},
      {"SSL_CERT_FILE", bundle},
      {"REQUESTS_CA_BUNDLE", bundle},
      {"CARGO_HTTP_CAINFO", bundle},
      {"GIT_SSL_CAINFO", bundle},
      {"HEX_CACERTS_PATH", bundle},
      {"UV_NATIVE_TLS", "1"}
    ]
  end

  @doc """
  The half that names the proxy, and the one thing a tenant may not have back.

  `SpriteEnv.build/4` emits these last. The broker is where an agent's egress
  is credentialed and logged (ADR 0019); an `env_vars` entry that could
  replace `HTTPS_PROXY` would be an opt-out of it.
  """
  @spec proxy_env(session()) :: [{String.t(), String.t()}]
  def proxy_env(%{token: token, vault: vault}) do
    url = proxy_url_with(token, vault)

    [
      {"HTTPS_PROXY", url},
      {"HTTP_PROXY", url},
      {"https_proxy", url},
      {"http_proxy", url},
      {"NO_PROXY", "localhost,127.0.0.1"}
    ]
  end

  @doc """
  Every variable `sandbox_env/1` sets. `Egress.reprepare/5` replaces the two
  halves separately (#1674), so the one caller left is the sudoers `env_keep`
  line — a different constraint: dropping a key there breaks apt inside a
  setup script rather than a token rotation.
  """
  @spec env_keys() :: [String.t()]
  def env_keys, do: proxy_keys() ++ ca_keys()

  @doc "The keys `proxy_env/1` sets."
  @spec proxy_keys() :: [String.t()]
  def proxy_keys, do: ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY)

  @doc "The keys `ca_env/0` sets."
  @spec ca_keys() :: [String.t()]
  def ca_keys,
    do:
      ~w(NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE CARGO_HTTP_CAINFO GIT_SSL_CAINFO HEX_CACERTS_PATH UV_NATIVE_TLS)

  @doc """
  The secrets inside a set of proxy variables: each session token, and not
  the URL that carries it.

  `proxy_env/1` puts the token in a URL's userinfo, so registering the pairs
  themselves with `Fountain.Conversations.Redaction` would register a value
  beginning `http://`. Every chunk of sandbox output ending in `h` would then
  be held back as a possible start of it (#2366), and the URL around the
  token is not a secret anyway: the proxy's host is on the broker stage event.
  Redacting the token alone still covers the whole URL wherever an agent
  prints its environment, as `http://[REDACTED]:vault@host`.

  The vault label beside it is not a secret either. It is there so git accepts
  the URL, and it is published on the same stage event.
  """
  @spec proxy_secrets([{String.t(), String.t()}]) :: [String.t()]
  def proxy_secrets(pairs) when is_list(pairs) do
    proxy_keys = proxy_keys()

    for {key, url} <- pairs,
        to_string(key) in proxy_keys,
        is_binary(url),
        token = userinfo_token(url),
        is_binary(token),
        uniq: true,
        do: token
  end

  def proxy_secrets(_), do: []

  # `URI.to_string/1` writes the userinfo verbatim, so the token is the part
  # before the first `:` exactly as it was minted.
  defp userinfo_token(url) do
    case URI.parse(url) do
      %URI{userinfo: info} when is_binary(info) -> info |> String.split(":", parts: 2) |> hd()
      _ -> nil
    end
  end

  @doc """
  The way out, and only that, from a conversation's process environment: its
  proxy variables and the CA variables a toolchain trusts the proxy through,
  as `sprite_env` holds them (so a tenant's own CA bundle stands, as it does
  for packages).

  For an exec that runs code Fountain did not write but needs the network,
  such as a GitHub skill fetch: it gets the session token every package
  command already gets, and none of the tenant's secrets.
  """
  @spec egress_env([{String.t(), String.t()}] | nil) :: [{String.t(), String.t()}]
  def egress_env(sprite_env) do
    keys = env_keys()
    Enum.filter(sprite_env || [], fn {key, _value} -> to_string(key) in keys end)
  end

  @doc "The variables that carry the session token, which `Identity` keeps off the shared `.env`."
  @spec process_only_keys() :: [String.t()]
  def process_only_keys, do: ~w(HTTPS_PROXY HTTP_PROXY https_proxy http_proxy)

  # Both userinfo fields, on purpose (gate 0): with the token alone curl is
  # happy and git stops to ask for a *proxy* password. Agent Vault reads
  # `Basic base64(token:label)`; the proxy reads the token and ignores the
  # label, which is there only so git accepts the URL.
  defp proxy_url_with(token, vault) do
    uri = proxy_url() |> URI.parse() |> Fountain.Broker.TransportRelay.client_uri()
    URI.to_string(%{uri | userinfo: token <> ":" <> vault})
  end

  @doc "True when the session ends within `within_seconds` (default ten minutes), or has no known end."
  @spec expiring?(session(), non_neg_integer()) :: boolean()
  def expiring?(session, within_seconds \\ 600)

  def expiring?(%{expires_at: %DateTime{} = at}, within_seconds) do
    DateTime.diff(at, DateTime.utc_now(), :second) < within_seconds
  end

  def expiring?(_, _), do: true

  @typedoc "What the environment's `networking_type` asks for: reach anything, or only these hosts."
  @type network :: :unrestricted | {:limited, [String.t()]}

  @doc "The network shape an environment asks for, as `prepare/4` takes it."
  @spec network_for(map() | nil) :: network()
  def network_for(%{networking_type: "limited", networking_config: config}) do
    {:limited, (config && (config["allowed_hosts"] || config[:allowed_hosts])) || []}
  end

  def network_for(_), do: :unrestricted

  # ---------------------------------------------------------------------------
  # Calls to the backend. Each returns `:ok`/`{:ok, _}` or `{:error, reason}`;
  # retries belong to the caller, per the repo's client convention.

  @doc "Is the broker up? The preflight; a failure here stops provisioning before a sandbox exists."
  @spec preflight() :: :ok | {:error, {:broker, :unreachable, term()}}
  def preflight do
    Native.preflight()
  end

  @doc "The root CA the proxy signs with. The sandbox trusts it or nothing works."
  @spec ca_pem() :: {:ok, binary()} | {:error, term()}
  def ca_pem do
    Native.ca_pem()
  end

  @doc """
  Make the broker ready for one conversation and mint its session.

  Idempotent, and run on every provision and reattach, so an edited secret
  or binding reaches the broker on the next wake, the same way the `.env`
  file is refreshed. Between wakes the conversation process holds the
  session, and `refresh/4` is how an edit reaches it before the next turn
  (#1736). `opts`: `network:` (`network_for/1`), `user_id:`, which the
  native backend needs to reach the tenant's key and looks up from the
  conversation when the caller has not got it to hand.
  """
  @spec prepare(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def prepare(conversation_id, brokered, bindings \\ %{}, opts \\ [])
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    Native.prepare(conversation_id, brokered, bindings, opts)
  end

  @doc """
  Replace the rules of the conversation's live sessions with what `brokered`
  and `bindings` say now, keeping every token (#1736). `prepare/4` mints a
  new token, and a new token reaches only the next process spawned with it:
  a sandbox process, and the idle ACP peer that carries the next turn, hold
  the token they started with. A secret edited or rotated during a live
  conversation goes through here. Same `opts` as `prepare/4`; returns how
  many sessions changed.
  """
  @spec refresh(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh(conversation_id, brokered, bindings \\ %{}, opts \\ [])
      when is_binary(conversation_id) and is_map(brokered) and is_map(bindings) do
    Native.refresh(conversation_id, brokered, bindings, opts)
  end

  @doc """
  Mint a workspace's session (ADR 0097, step 5): the broker rules an
  explicit workspace's provision on create runs under, from the workspace's
  own environment and vault, before any conversation exists. `opts` as
  `prepare/4`, with `user_id:` required.
  """
  @spec prepare_workspace(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, session()} | {:error, term()}
  def prepare_workspace(workspace_id, brokered, bindings, opts)
      when is_binary(workspace_id) and is_map(brokered) and is_map(bindings) do
    Native.prepare_workspace(workspace_id, brokered, bindings, opts)
  end

  @doc "`refresh/4` for a workspace's live sessions."
  @spec refresh_workspace(String.t(), %{String.t() => String.t()}, bindings(), keyword()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def refresh_workspace(workspace_id, brokered, bindings, opts)
      when is_binary(workspace_id) and is_map(brokered) and is_map(bindings) do
    Native.refresh_workspace(workspace_id, brokered, bindings, opts)
  end

  @doc "Release a workspace's sessions: its tokens stop working at once."
  @spec release_workspace(String.t()) :: :ok
  def release_workspace(workspace_id) when is_binary(workspace_id),
    do: Native.release_workspace(workspace_id)

  @doc """
  Release a conversation's session at the end of its life, so nothing
  brokers on its behalf again. The session rows go at once; the request log
  it wrote (gate 4) outlives it, until `Fountain.Workers.BrokerReaper`
  sweeps rows past `BROKER_LOG_RETENTION_HOURS`.
  """
  @spec release(String.t()) :: :ok
  def release(conversation_id) when is_binary(conversation_id) do
    Native.release(conversation_id)
  end

  @doc """
  Delete the session matching tenant, conversation and token. Repeated cleanup succeeds without touching other tokens.
  Subsequent lookups refuse the token; existing proxy tunnels are not closed.
  """
  @spec release_session(String.t(), String.t(), String.t()) :: :ok
  def release_session(user_id, conversation_id, token),
    do: Native.release_session(user_id, conversation_id, token)

  @typedoc "One outbound request the broker handled for a conversation."
  @type egress_event :: %{
          id: integer(),
          at: DateTime.t() | nil,
          method: String.t(),
          host: String.t(),
          path: String.t(),
          service: String.t() | nil,
          credential_keys: [String.t()],
          status: integer() | nil,
          latency_ms: integer() | nil,
          error: String.t() | nil
        }

  @doc """
  The broker's request log for a conversation, newest first (gate 4): what
  actually left the sandbox, to which host, with which credential attached,
  and what came back. `before:` pages by the previous page's oldest `id`.

  A row is written when the request **ends**, so a streamed reply appears
  when the stream finishes and its `latency_ms` is the whole duration
  (#1501 row 2). `status` is null where the proxy never got an answer,
  `error` is null where it did.
  """
  @spec request_log(String.t(), keyword()) ::
          {:ok, %{events: [egress_event()], next: integer() | nil}}
  def request_log(conversation_id, opts \\ []) when is_binary(conversation_id) do
    Native.request_log(conversation_id, opts)
  end
end
