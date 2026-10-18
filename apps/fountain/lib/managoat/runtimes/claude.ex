defmodule Managoat.Runtimes.Claude do
  @moduledoc """
  Anthropic Claude runtime — provisioning only.

  Turns speak ACP through the pinned `claude-agent-acp` adapter
  (`Managoat.Runtimes.ACP`); the CLI argv builder that used to live here went
  with the legacy spawn path. What remains is the half ADR 0014 deliberately
  kept: how credentials, skills and MCP servers get into the sandbox.

  The adapter runs on the Claude Agent SDK, which reads the same skills tree
  as the CLI (`$CLAUDE_CONFIG_DIR/skills`; `/home/sprite/.claude/skills` was
  verified live 2026-08-10) and honours the same credential env vars. Every
  path here is under the conversation's config home, which `config_env/1`
  exports as `CLAUDE_CONFIG_DIR` (ADR 0097). On Sprites the adapter reuses the
  image's Claude executable when it meets ACP's version floor; elsewhere,
  or when the image CLI cannot be used, it runs the SDK's bundled binary.
  The measurements below describe the bundled pin unless stated otherwise.

  ## MCP servers are provisioned, not delivered over ACP (#837)

  ACP defines a session-scoped channel for MCP servers (`session/new`'s
  `mcpServers`), and `Managoat.ACP.Peer` sends the agent's servers
  there correctly (pinned by `peer_mcp_test.exs`). But `claude-agent-acp`
  0.66–0.70 never launched stdio servers passed that way — reproduced
  standalone, upstream bug [agentclientprotocol/claude-agent-acp#883]. On
  the 0.75.1 pin (2026-09-07), and again on 0.81.2 (2026-09-25), a stdio
  server passed only over `session/new` *does* reach the model, and a server
  named on both paths is registered once; `http`/`sse` entries over the
  session-scoped path are not yet measured, which is why this provisioning
  stays until they are.

  So `write_config/3` provisions the servers into the sandbox instead, as
  **user-scope** servers: the `mcpServers` key of the CLI's own config file,
  `$CLAUDE_CONFIG_DIR/.claude.json`. The `${VAR}` refs are already resolved
  because the caller hands us the substituted agent.

  User scope because it is the conversation's own. Until ADR 0097 the servers
  were a project-scope `<cwd>/.mcp.json`, which two conversations in one
  folder would overwrite. The CLI keeps that file's `mcpServers` as its
  user-scope servers when it adds its own state to the file (Claude CLI
  2.1.296: `claude mcp get` reports them as "User config"; `claude-agent-acp`
  0.81.2, whose `settingSources` are `["user", "project", "local"]`, started a
  stdio server named there on `session/new`; measured on a sprite on
  2026-10-18). The same measurement found that a project `.mcp.json` is
  started too, approved or not, and that project scope outranks user scope on
  a name collision, so for a conversation provisioned before config homes
  the `/home/sprite/.mcp.json` it already has is kept written with the same
  servers (see `write_config/3`).

  When the upstream bug is fixed, the session-scoped path will start working
  too; at that point drop the file provisioning to avoid double-registration
  (cf. the same lesson in `Managoat.Runtimes.Gemini`). Registered as
  `:claude_mcp_via_files` in `Managoat.Runtimes.Quirks`, which carries the
  re-probe procedure and is guarded by a test that fails if this function
  disappears without the entry.

  ## Models: the pinned CLI lists them itself, with one alias to pin

  The adapter advertises whatever its selected Claude Code binary
  reports, and `session/set_config_option` accepts only those rows (a full
  model id resolves onto the alias row that serves it). On the 0.81.2 pin
  (CLI 2.1.280) the org's additional models, Fable among them, are listed
  on a cold `session/new`, on an API key and on a Claude.ai OAuth token
  alike. Measured 2026-09-25 with a fresh `CLAUDE_CONFIG_DIR` per run and a
  real turn on `claude-fable-5-1`. Before it (0.75.1, CLI 2.1.257) they
  arrived only after a first session had cached them, which is why this
  module used to warm that cache at provisioning.

  The same CLI moved its `opus` alias to Opus 5.5, so `claude-opus-5` is
  refused unless the alias is pointed back at it with
  `ANTHROPIC_DEFAULT_OPUS_MODEL`. `model_env/1` returns that pair for a turn
  that asks for Opus 5. It is per process: one adapter serves one Opus.
  Registered as `:claude_opus_alias` in `Managoat.Runtimes.Quirks`.

  ## Thinking is shown only when asked for

  The 0.81.2 CLI defaults `showThinkingSummaries` to false, and the API then
  returns thinking with its display omitted: the adapter has no text to send,
  so no `agent_thought_chunk` reaches the host. `write_config/3` therefore
  always writes `showThinkingSummaries: true` into
  `$CLAUDE_CONFIG_DIR/settings.json`. Registered as
  `:claude_thinking_summaries`.

  ## Form elicitation is declared, so `AskUserQuestion` is offered

  claude-agent-acp removes its `AskUserQuestion` tool from the session unless
  the client declares form elicitation on `initialize`
  (`disallowedTools = elicitationSupport.form ? [] : ["AskUserQuestion"]`,
  read in 0.81.2's `dist/acp-agent.js`), because the tool's questions reach a
  person only as an ACP `elicitation/create` form. `client_capabilities/1`
  declares it (#2492) when the conversation's permission policy already asks
  a person (some verdict is `ask`), and the peer holds each form for a human
  the way it holds an `ask` permission request (`Managoat.ACP.Elicitation`).
  A conversation whose policy asks nobody does not declare it, so the
  adapter keeps the tool removed and an unwatched conversation never waits
  on a question (ADR 0084).

  The same declaration also forwards an MCP server's form elicitations (the
  SDK declines them by itself otherwise) and the CLI's refusal-fallback
  consent prompt (the turn otherwise ends on the refusal). The value is an
  empty object, not `true`: ACP's `ElicitationFormCapabilities` is an object,
  and the adapter's schema validation discards a boolean, which would leave
  the tool removed.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "claude"

  # The project-scope file Fountain wrote MCP servers to before config homes,
  # in the working directory those conversations ran in; still written for
  # them (see `write_config/3`).
  @legacy_mcp_config Path.join(Layout.cwd(@runtime), ".mcp.json")

  @impl true
  def skills_root(home), do: Layout.skills_root(@runtime, home)

  @impl true
  def config_env(home), do: Layout.config_env(@runtime, home)

  @impl true
  def default_env(_agent, inference_credentials) do
    # OAuth token takes precedence — it bills against a Claude.ai
    # subscription (Pro/Team) instead of metered API usage. When set, we
    # do NOT also export ANTHROPIC_API_KEY: claude prefers the oauth
    # path, but mixing the two has caused observable surprises (auth
    # picked from the wrong env var, depending on CLI version), so we
    # pick exactly one here.
    oauth = Map.get(inference_credentials, :claude_code_oauth_token)
    api_key = Map.get(inference_credentials, :anthropic_api_key)

    credential =
      cond do
        is_binary(oauth) and oauth != "" -> [{"CLAUDE_CODE_OAUTH_TOKEN", oauth}]
        is_binary(api_key) and api_key != "" -> [{"ANTHROPIC_API_KEY", api_key}]
        true -> []
      end

    # A fresh sandbox's first session otherwise waits on the CLI's
    # non-essential traffic (see `:claude_nonessential_traffic` in
    # `Managoat.Runtimes.Quirks`). It also stops the auto-updater, which the
    # pinned adapter wants off anyway.
    credential ++ [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]
  end

  @doc """
  Write the CLI's settings and the agent's MCP servers under `home`, the
  conversation's config home (see the moduledoc for why the servers go in a
  file and not only over the ACP session-scoped channel).

  `settings.json` is written on every call, agent or not, because it carries
  `showThinkingSummaries`. The servers are set as the `mcpServers` of
  `.claude.json` on every call too, `%{}` included, so an agent that drops a
  server drops it on its next wake. The rest of that file is the CLI's own
  state and is kept: the file is read, the key replaced, and the result
  renamed into place, so a CLI reading it never sees half a file. A file
  whose servers are already these is left alone: last writer wins between
  two whole-file writers, and a write that changes nothing is a race not
  worth running. That covers an agent whose servers carry no token Fountain
  rotates; a reattach rotates the callback key, so an agent with a
  Fountain-authenticated server is rewritten on every reattach and still
  races a CLI running in the home, as the project file did before. A file
  that is there but is not a JSON object (a CLI halfway through its own
  write) is read once more, then is an error, not something to overwrite.

  On a conversation from before config homes (`home` is the legacy
  `~/.claude`), the project `/home/sprite/.mcp.json` is also written as it
  always was, when the agent has servers. It is the file the previous
  release's adapter, still running after a deploy, reads; and project scope
  outranks user scope on a name collision, so a stale copy there would shadow
  these servers with the token it was written with. Writing it with the same
  servers keeps the two in step. A legacy agent with no servers leaves the
  file alone, as before: it may be the tenant's. (One that dropped its last
  server keeps the stale file, which the CLI starts approved or not; that
  was so before config homes too.)
  """
  @impl true
  def write_config(handle, agent, home) do
    # Every write is idempotent, so a transport blip on a sprite that has
    # only just booted is retried rather than failing the provision: the
    # first filesystem call into a fresh sprite timed out once in prod and
    # took the whole conversation with it.
    with :ok <- write_retrying(handle, Path.join(home, "settings.json"), settings()),
         :ok <- write_mcp_servers(handle, home, mcp_servers(agent)) do
      write_legacy_project_config(handle, home, mcp_servers(agent))
    end
  end

  @doc "The CLI's own config file under `home`, which carries the user-scope MCP servers."
  @spec user_config_path(String.t()) :: String.t()
  def user_config_path(home), do: Path.join(home, ".claude.json")

  @doc """
  The ACP default, plus form elicitation when `policy` asks a person (see
  the moduledoc). URL elicitation is never declared: there is nothing in
  Managoat to open a URL for a person, so the adapter keeps declining those
  itself.
  """
  @impl true
  def client_capabilities(policy) do
    default = Managoat.ACP.Protocol.default_client_capabilities()

    if Managoat.ACP.Permissions.asks_person?(policy),
      do: Map.put(default, :elicitation, %{form: %{}}),
      else: default
  end

  defp mcp_servers(%{mcp_servers: servers}) when is_map(servers), do: servers
  defp mcp_servers(_agent), do: %{}

  # User-scope servers need no approval, unlike the project-scope ones this
  # used to write, so the settings carry no `enableAllProjectMcpServers`: a
  # repository's own `.mcp.json` is the CLI's to decide about.
  defp settings, do: Jason.encode!(%{"showThinkingSummaries" => true}, pretty: true)

  # Read, replace `mcpServers`, write beside, rename over. The read answers an
  # empty object for a file that is not there yet (a fresh config home); the
  # CLI's state in a readable one is kept. Mode 600: the servers carry
  # resolved credentials. The temporary name is this call's own, so two
  # writers never move each other's file, and the rename succeeds when it
  # finds its file already moved: a retried exec whose first reply was lost
  # has done its work.
  defp write_mcp_servers(handle, home, servers) do
    path = user_config_path(home)
    tmp = path <> ".managoat." <> Integer.to_string(System.unique_integer([:positive])) <> ".tmp"

    with {:ok, current} <- read_user_config(handle, path) do
      if Map.get(current, "mcpServers") == servers and current != %{} do
        :ok
      else
        body = Jason.encode!(Map.put(current, "mcpServers", servers), pretty: true)

        with :ok <- write_retrying(handle, tmp, body, mode: 0o600) do
          run_retrying(handle, rename_script(tmp, path), path)
        end
      end
    end
  end

  @doc false
  def rename_script(tmp, path) do
    "if [ -e #{quote_shell(tmp)} ]; then mv -f -- #{quote_shell(tmp)} #{quote_shell(path)}; " <>
      "else [ -f #{quote_shell(path)} ]; fi"
  end

  defp read_user_config(handle, path, attempt \\ 1) do
    script = "if [ -f #{quote_shell(path)} ]; then cat -- #{quote_shell(path)}; fi"

    case exec_retrying(handle, script, path) do
      {:ok, out} ->
        case decode_object(out, path) do
          {:error, {:runtime_config, _, :unreadable}} when attempt == 1 ->
            Process.sleep(200)
            read_user_config(handle, path, 2)

          decoded ->
            decoded
        end

      {:error, _} = error ->
        error
    end
  end

  defp decode_object("", _path), do: {:ok, %{}}

  defp decode_object(text, path) do
    case Jason.decode(text) do
      {:ok, %{} = map} -> {:ok, map}
      _ -> {:error, {:runtime_config, path, :unreadable}}
    end
  end

  defp write_legacy_project_config(handle, home, servers) do
    if home == Layout.legacy_home(@runtime) and servers != %{} do
      body = Jason.encode!(%{"mcpServers" => servers}, pretty: true)
      write_retrying(handle, @legacy_mcp_config, body)
    else
      :ok
    end
  end

  defp run_retrying(handle, script, path) do
    case exec_retrying(handle, script, path) do
      {:ok, _out} -> :ok
      {:error, _} = error -> error
    end
  end

  defp exec_retrying(handle, script, path) do
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.exec(handle, "bash", ["-c", script], timeout: 15_000) end,
           label: "claude config #{path}"
         ) do
      {:ok, out, 0} -> {:ok, to_string(out)}
      {:ok, _out, code} -> {:error, {:runtime_config, path, {:exit, code}}}
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  @doc """
  The env a turn on `model` needs in the adapter's process, beyond
  `default_env/2` (see the moduledoc). `claude-opus-5` points the CLI's `opus`
  alias back at Opus 5; every other model needs nothing.

  Accepts the id bare or with its `anthropic/` provider prefix. The pairs
  belong to the spawn, not the sandbox: an adapter already running with them
  serves only that Opus, so a host that reuses a process across turns has to
  respawn it when this answer changes.
  """
  @impl true
  def model_env("anthropic/" <> model), do: model_env(model)
  def model_env("claude-opus-5"), do: [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]
  def model_env(_model), do: []

  defp write_retrying(handle, path, body, opts \\ []) do
    case Managoat.Sandbox.Retry.with_backoff(
           fn -> Managoat.Sandbox.write_file(handle, path, body, opts) end,
           label: "claude config write #{path}"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_config, path, reason}}
    end
  end

  @doc """
  Swaps `CLAUDE_CODE_OAUTH_TOKEN` for `ANTHROPIC_API_KEY` in an already-built
  env list — what a live turn asks for after the org has refused the OAuth
  token (#655). Left as-is (still carrying the doomed OAuth token) when no
  API key is on file: the caller decides what to tell the tenant when there
  is nothing to fall back to.

  Deliberately not folded into `default_env/2` as a "skip oauth" flag: that
  function runs at provisioning, before any turn has been attempted, so it
  has no way to know the token is bad. This is reached only after the specific
  ACP failure that says so.
  """
  @spec fall_back_to_api_key([{String.t(), String.t()}], %{atom() => String.t()}) ::
          [{String.t(), String.t()}]
  def fall_back_to_api_key(env, inference_credentials) do
    case Map.get(inference_credentials, :anthropic_api_key) do
      key when is_binary(key) and key != "" ->
        env
        |> Enum.reject(fn {k, _v} -> k == "CLAUDE_CODE_OAUTH_TOKEN" end)
        |> List.keystore("ANTHROPIC_API_KEY", 0, {"ANTHROPIC_API_KEY", key})

      _ ->
        env
    end
  end
end
