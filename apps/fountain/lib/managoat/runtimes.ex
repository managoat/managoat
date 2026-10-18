defmodule Managoat.Runtimes do
  @moduledoc """
  Behaviour every runtime (claude/codex/gemini) implements,
  plus a small dispatcher.

  How a coding agent CLI gets into a sandbox and comes up speaking the Agent
  Client Protocol: which adapter to install and at what version
  (`Managoat.Runtimes.ACP`), where its files go (`Managoat.Runtimes.Layout`),
  the instructions file (`Managoat.Runtimes.Instructions`), the skills tree
  (`Managoat.Runtimes.Skills`), the credential env vars (each runtime's
  `default_env/2`), and the per-runtime workarounds with the condition for
  deleting each (`Managoat.Runtimes.Quirks`). The protocol session itself is
  `Managoat.ACP.Peer`; this library is the **provisioning** half that a peer
  needs to have happened first.

  No runtime builds a CLI argv for a turn: every turn travels over ACP
  (`session/prompt`), so the behaviour has no turn callback.

  What varies between runtimes here falls into three kinds, and only the last
  needs code:

    * **Layout** — where files go. Perfectly regular
      (`<config_home>/<config_dir>/…`, one config home per conversation, ADR
      0097) and stated once, in `Managoat.Runtimes.Layout`. `skills_root/1`,
      the instructions path, the variable that points the runtime at its
      config home and the default working directory are derived from that
      table rather than restated per module.
    * **Workarounds** — a defect each runtime carries, with a deletion
      condition. Registered in `Managoat.Runtimes.Quirks`, which names the
      function implementing each one and is guarded by a test, so a workaround
      cannot outlive its defect unnoticed.
    * **Credential delivery** — genuinely irreducible, and two shapes rather
      than three: an env var (claude, gemini) or a login exec that consumes
      the key on stdin (codex, whose CLI ignores the process env). See
      `c:default_env/2` and `c:prepare_sandbox/4`.

  ## Calling the optional callbacks

  Five callbacks are optional and the implementation matrix is genuinely
  sparse, so a host has to guard the call — and the obvious guard is wrong:

      # WRONG: silently no-ops in an escript or a release
      if function_exported?(mod, :default_env, 2), do: mod.default_env(agent, creds), else: []

  `function_exported?/3` answers `false` for a module that is merely **not
  loaded yet**, which is the normal state of any module nobody has called
  under an escript or a release. It has already cost one host a provisioning
  run that reported every stage green and then failed on an authentication
  error, because `Managoat.Runtimes.Claude` was unloaded rather than because
  it was missing `default_env/2` — which it implements, as do all three
  runtimes.

  So dispatch through the functions here instead. They load the module first
  and fall back to the documented no-op:

      env = Managoat.Runtimes.default_env(mod, agent, credentials)   # or []
      env = env ++ Managoat.Runtimes.config_env(mod, home)            # or []
      :ok = Managoat.Runtimes.write_config(mod, handle, agent, home) # or :ok
      :ok = Managoat.Runtimes.prepare_sandbox(mod, handle, agent, env, home)
      env = env ++ Managoat.Runtimes.model_env(mod, model)            # or []
      caps = Managoat.Runtimes.client_capabilities(mod, policy)      # or the ACP default

  `home` is the conversation's config home (`Managoat.Runtimes.Layout`):
  every callback that writes a file or names a path takes it, so nothing in a
  runtime module is a compile-time path.

  When the default is not what you need, ask `implements?/3` and decide.
  """

  @typedoc """
  What a runtime reads from the agent it provisions for.

  A plain map, so the host's own record satisfies it whatever else it
  carries: an Ecto struct, a decoded JSON document, a literal in a test. The
  five keys are the whole surface the library reads, and each is optional
  because every reader treats a missing one as "none":

    * `model` — the canonical `provider/model_id` (`Managoat.Runtimes.Model`).
    * `mcp_servers` — the agent's MCP servers in Claude's own config shape
      (`%{name => %{"command" | "args" | "env" | "type" | "url" | "headers"}}`),
      read by `write_config/3` and `Managoat.Runtimes.ACP.mcp_servers/1`.
    * `system` and `name` — the instructions file
      (`Managoat.Runtimes.Instructions`).
    * `runtime` — `Managoat.Runtimes.ACP.enabled?/1` accepts the agent as well
      as the bare runtime string.
  """
  @type agent :: %{
          optional(:model) => String.t() | nil,
          optional(:mcp_servers) => map() | nil,
          optional(:system) => String.t() | nil,
          optional(:name) => String.t() | nil,
          optional(:runtime) => String.t() | nil,
          optional(atom()) => term()
        }

  @doc """
  Default env vars for the runtime — typically the inference credential
  for the chosen provider (e.g. `ANTHROPIC_API_KEY`).

  `inference_credentials` is a map of `%{provider_atom => plaintext_string}`
  the host decrypts for the tenant at conversation start. The keys a runtime
  reads are `:anthropic_api_key`, `:claude_code_oauth_token`,
  `:openai_api_key` and `:gemini_api_key`; providers the user hasn't set are
  simply absent from the map.

  ## Why this cannot be a table

  Three things happen here that layout cannot express, and they are the
  reason this stays a callback rather than another column:

    * **Which provider.** claude, codex and gemini each have one, so the
      variable is fixed per runtime today. A multi-provider runtime (the
      removed opencode was one) would need a function of `agent.model`.
    * **Which credential, for one provider.** claude takes either a
      `CLAUDE_CODE_OAUTH_TOKEN` (bills a Claude.ai subscription) or an
      `ANTHROPIC_API_KEY` (metered), never both — exporting both has picked
      the wrong one depending on CLI version. The precedence, and the
      mid-conversation fall back to the API key when an org refuses the OAuth
      token (#655), are provider policy with no analogue on the others.
    * **Whether an env var works at all.** codex 0.118+ does not read
      `OPENAI_API_KEY` at exec time. It reads `$CODEX_HOME/auth.json`, the file
      `codex login --with-api-key` writes, so its credential is delivered by
      `prepare_sandbox/4` writing that file instead — see there.

  So the shape is two-of-three, not three-of-three: an env var, or a file.
  Worth restating whenever another runtime arrives, because "just add a column
  for the variable name" is right up until it is codex.

  Optional, so call it through `default_env/3`, which is the loaded-first
  dispatcher — not through a `function_exported?/3` guard, which no-ops it
  in an escript or a release. See
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback default_env(
              agent :: agent(),
              inference_credentials :: %{atom() => String.t()}
            ) :: [{String.t(), String.t()}]

  @doc """
  Optionally name the env pairs that point the runtime at `config_home`, the
  conversation's config home: `CLAUDE_CONFIG_DIR`, `CODEX_HOME` or
  `GEMINI_CLI_HOME`, from `Managoat.Runtimes.Layout.config_env/2`. `[]` by
  default.

  A host adds these to every process it runs the runtime in, so the path a
  runtime module writes under and the path the CLI reads from are one value.

  Optional, so call it through `config_env/2` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback config_env(config_home :: String.t()) :: [{String.t(), String.t()}]

  @doc """
  Optionally write runtime-specific config files into the conversation's
  config home at provision and wake (e.g. claude's `.claude.json` for MCP
  servers). No-op by default.

  Optional, so call it through `write_config/4` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback write_config(
              handle :: Managoat.Sandbox.Handle.t(),
              agent :: agent() | nil,
              config_home :: String.t()
            ) ::
              :ok | {:error, term()}

  @doc """
  Optionally run any sprite-side bootstrap that has to happen *before*
  the first turn — e.g. codex needs its credentials in
  `<config_home>/auth.json` since it doesn't read `OPENAI_API_KEY` from the
  live process env.

  Receives the same `sprite_env` pairs the spawn will use. Implementers
  pull whichever keys they need out of that list. No-op by default.

  ## This is the escape hatch, and it should stay one

  Three runtimes implement it and each does something genuinely imperative —
  a credential file written from the key, a `bun install`, a `git init`. None
  of those is expressible as data, and an abstraction that swallowed them
  would cost more than the duplication it removed. What *was* data (where the
  workspace lives, what HOME is) has already moved to
  `Managoat.Runtimes.Layout`; what is left here is the residue that has to be
  code.

  Runs after `Managoat.Runtimes.ACP.install/3` and after the host's whole
  provisioning pipeline, so it can assume the adapter is on PATH. Note the
  ordering costs something: if the host has already applied a network policy
  to the sandbox, an install here needs its registry on the allowlist of any
  restricted one.

  Optional, so call it through `prepare_sandbox/5` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback prepare_sandbox(
              handle :: Managoat.Sandbox.Handle.t(),
              agent :: agent() | nil,
              sprite_env :: [{String.t(), String.t()}],
              config_home :: String.t()
            ) :: :ok | {:error, term()}

  @doc """
  Optionally name env pairs the adapter process needs for a turn on `model`,
  on top of `c:default_env/2`. `model` is the id the host will select, bare
  or with its provider prefix. `[]` by default.

  This is for a model the pinned adapter selects only through its process
  environment: claude's `opus` alias names one Opus per process, and
  `claude-opus-5` needs `ANTHROPIC_DEFAULT_OPUS_MODEL` to be that one (see
  `Managoat.Runtimes.Claude`). The pairs belong to the spawn, not the sandbox,
  so a host that keeps an adapter running across turns respawns it when the
  answer for the next turn's model differs from the one it was spawned with.

  Optional, so call it through `model_env/2` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback model_env(model :: String.t() | nil) :: [{String.t(), String.t()}]

  @doc """
  Optionally name the ACP client capabilities the host declares on
  `initialize` for this runtime's adapter, in place of
  `Managoat.ACP.Protocol.default_client_capabilities/0`. `policy` is the
  conversation's effective permission policy (nil for none).

  A capability is a promise the host keeps for the adapter, and it changes
  what the adapter does: claude-agent-acp removes its `AskUserQuestion` tool
  unless form elicitation is declared, and claude declares it only under a
  policy that asks a person (`Managoat.Runtimes.Claude`). The peer services
  only what was declared.

  Optional, so call it through `client_capabilities/2` — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @callback client_capabilities(policy :: map() | nil) :: map()

  @doc """
  Absolute path on the sprite where skills are written as
  `<skills_root>/<name>/SKILL.md`, inline and github alike, under the
  conversation's `config_home`. Each runtime points this at whatever
  directory its CLI scans for skills.

  Answered from `Managoat.Runtimes.Layout` by every packaged implementation —
  it stays a callback because `Managoat.Runtimes.Skills` reaches it through
  the module, not because any runtime has ever needed to depart from the
  table.
  """
  @callback skills_root(config_home :: String.t()) :: String.t()

  @optional_callbacks default_env: 2,
                      config_env: 1,
                      write_config: 3,
                      prepare_sandbox: 4,
                      model_env: 1,
                      client_capabilities: 1

  @runtime_modules %{
    "claude" => Managoat.Runtimes.Claude,
    "codex" => Managoat.Runtimes.Codex,
    "gemini" => Managoat.Runtimes.Gemini
  }

  @doc "Look up the runtime module for an agent's runtime string."
  def for_runtime(name) when is_binary(name) do
    case Map.fetch(@runtime_modules, name) do
      {:ok, mod} -> {:ok, mod}
      :error -> {:error, "unsupported runtime: #{name}"}
    end
  end

  @doc """
  Dispatch `c:default_env/2`, or `[]` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec default_env(module(), agent(), %{atom() => String.t()}) :: [{String.t(), String.t()}]
  def default_env(mod, agent, inference_credentials) when is_atom(mod),
    do: dispatch(mod, :default_env, [agent, inference_credentials], [])

  @doc """
  Dispatch `c:config_env/1`, or `[]` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec config_env(module(), String.t()) :: [{String.t(), String.t()}]
  def config_env(mod, config_home) when is_atom(mod) and is_binary(config_home),
    do: dispatch(mod, :config_env, [config_home], [])

  @doc """
  Dispatch `c:write_config/3`, or `:ok` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec write_config(module(), Managoat.Sandbox.Handle.t(), agent() | nil, String.t()) ::
          :ok | {:error, term()}
  def write_config(mod, handle, agent, config_home) when is_atom(mod),
    do: dispatch(mod, :write_config, [handle, agent, config_home], :ok)

  @doc """
  Dispatch `c:prepare_sandbox/4`, or `:ok` when the runtime does not
  implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec prepare_sandbox(
          module(),
          Managoat.Sandbox.Handle.t(),
          agent() | nil,
          [{String.t(), String.t()}],
          String.t()
        ) :: :ok | {:error, term()}
  def prepare_sandbox(mod, handle, agent, sprite_env, config_home) when is_atom(mod),
    do: dispatch(mod, :prepare_sandbox, [handle, agent, sprite_env, config_home], :ok)

  @doc """
  Dispatch `c:model_env/1`, or `[]` when the runtime does not implement it.

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec model_env(module(), String.t() | nil) :: [{String.t(), String.t()}]
  def model_env(mod, model) when is_atom(mod),
    do: dispatch(mod, :model_env, [model], [])

  @doc """
  Dispatch `c:client_capabilities/1`, or
  `Managoat.ACP.Protocol.default_client_capabilities/0` when the runtime does
  not implement it (and for a custom `acp` runtime, which has no module).

  Use this rather than guarding the call yourself — see
  ["Calling the optional callbacks"](#module-calling-the-optional-callbacks).
  """
  @spec client_capabilities(module() | nil, map() | nil) :: map()
  def client_capabilities(mod, policy) when is_atom(mod),
    do:
      dispatch(
        mod,
        :client_capabilities,
        [policy],
        Managoat.ACP.Protocol.default_client_capabilities()
      )

  @doc """
  Whether `mod` implements the optional callback `fun/arity`, loading it
  first if it has not been loaded yet.

  Each optional callback has a dispatcher above that falls back to a
  default. Ask this instead when the host has to tell "the runtime does not
  implement it" apart from "it returned the default". Fountain's
  `Conversations.Connection` does that for `c:model_env/1`: an open
  connection that recorded no model env still matches only when the runtime
  has no `model_env/1` at all.

      if Managoat.Runtimes.implements?(mod, :model_env, 1) do
        Managoat.Runtimes.model_env(mod, model)
      else
        :no_model_env
      end

  `Code.ensure_loaded?/1` is the whole point: `function_exported?/3` alone
  answers `false` for a module that is merely not loaded yet, which in an
  escript or a release is the normal state of a module nobody has called.
  """
  @spec implements?(module(), atom(), arity()) :: boolean()
  def implements?(mod, fun, arity) when is_atom(mod) and is_atom(fun) and is_integer(arity),
    do: Code.ensure_loaded?(mod) and function_exported?(mod, fun, arity)

  defp dispatch(mod, fun, args, default) do
    if implements?(mod, fun, length(args)) do
      apply(mod, fun, args)
    else
      default
    end
  end
end
