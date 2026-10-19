defmodule Managoat.Runtimes.Gemini do
  @moduledoc """
  Google Gemini CLI runtime.

  Provisioning only. Gemini speaks ACP since #659, so a turn spawns
  `gemini --acp` (`Managoat.Runtimes.ACP`) and the prompt, the model, the
  session id and the MCP servers all travel over the protocol rather than in
  argv. This module is what remains: the workspace, the skills paths, the
  settings file and `GEMINI_API_KEY`.

  `build_command/5` is gone with #941. It was the last implementation of that
  callback and the last place Fountain passed a vendor permission-bypass flag
  (`--approval-mode yolo`, matching the `--dangerously-*` flags claude, codex
  and opencode lost when their legacy spawn paths were deleted). Permissions
  are now a policy (#939) answered per tool over `session/request_permission`,
  with `ask` reaching a human (#940).

  Two things that lived in that argv and did not disappear with it:

  * **the model.** `--model` took the bare id, stripped from the canonical
    `google/` prefix. ACP pins it per session instead — gemini advertises
    `models`, so `Peer` sends `session/set_model` (see "model selection" in
    `acp/peer_test.exs`). The #553 regression it guarded against is still
    guarded, one layer down.
  * **`--resume`.** It re-entered "the most recent conversation in the
    workspace", correct only while one conversation ever ran per workspace.
    ACP names the session, which is the whole reason the conversion was worth
    doing.

  Every file is under the conversation's config home, which `config_env/1`
  exports as `GEMINI_CLI_HOME` (ADR 0097): gemini-cli resolves its home
  through it and keeps `.gemini/` (settings, skills, `GEMINI.md`, its chat
  store, its project registry) under it. `HOME` stays the image's; it used to
  be `/tmp`, which `Managoat.Runtimes.Layout` says why and why no longer.

  Auth: `GEMINI_API_KEY` exported into the sprite.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.{JsonConfig, Layout}

  @runtime "gemini"

  # Run gemini from a workspace dir we own and have git-init'd; avoids
  # the noisy `[WARN] [MemoryDiscovery] EACCES at /home/sprite/.git`
  # message (gemini walks up from cwd looking for .git, and /home/sprite's
  # perms trip it).  Also gives MemoryDiscovery a real workspace root
  # to anchor on instead of crawling /home. `Managoat.Runtimes.Layout` owns
  # the path, and a conversation that names no cwd of its own runs in the
  # same place because it reads the same row.
  @workdir Layout.cwd(@runtime)

  @impl true
  def skills_root(home), do: Layout.skills_root(@runtime, home)

  @impl true
  def config_env(home), do: Layout.config_env(@runtime, home)

  @impl true
  def default_env(_agent, inference_credentials) do
    base =
      case Map.get(inference_credentials, :gemini_api_key) do
        nil -> []
        "" -> []
        key -> [{"GEMINI_API_KEY", key}]
      end

    # GEMINI_CLI_TRUST_WORKSPACE: gemini-cli turns `security.folderTrust` on by
    # default from some release after 0.59.0, and the Sprites image ships its
    # own, newer CLI (0.63.0 on 2026-10-16), which wins over `@cli_package`.
    # An untrusted workspace starts none of its MCP servers
    # (`startConfiguredMcpServers` returns early), so an agent's servers,
    # session ones included, silently never appeared. The workspace is the
    # agent's own sandbox, and trusting it grants nothing the agent's shell
    # does not already have.
    base ++ [{"GEMINI_CLI_TRUST_WORKSPACE", "true"}]
  end

  @doc "The user-scope settings file under `home`, the conversation's config home."
  @spec settings_path(String.t()) :: String.t()
  def settings_path(home), do: Path.join(Layout.config_dir(@runtime, home), "settings.json")

  # Gemini reads user-scope MCP servers from `<home>/.gemini/settings.json`,
  # under `mcpServers` (camelCase, same shape as Claude). That key is put on
  # every call, an empty map included, so an agent that drops a server drops
  # it on its next wake; the rest of the file is kept, which is where a
  # runtime template's settings live (#2998, `Managoat.Runtimes.JsonConfig`).
  # Only here: duplicating it into a second settings file had gemini register
  # every MCP tool twice on startup and spam the log with
  # `Tool ... already registered. Overwriting.` lines.
  #
  # Idempotent, so a transport blip on a fresh sprite is retried; a write
  # that still fails is reported, not swallowed — the agent would otherwise
  # start with none of its servers and no record of why.
  @impl true
  def write_config(handle, agent, home) do
    path = settings_path(home)

    with {:ok, %{^path => current}} <- JsonConfig.read(handle, [path]) do
      JsonConfig.put(handle, path, current, %{"mcpServers" => mcp_servers(agent)})
    end
  end

  defp mcp_servers(%{mcp_servers: servers}) when is_map(servers), do: servers
  defp mcp_servers(_agent), do: %{}

  # The CLI the image would carry, for a sandbox that has none. Gemini speaks
  # ACP natively, so there is no adapter install to bring it; the Sprites and
  # E2B images ship it, and a self-hosted runner does not, where every turn
  # exited 127 (`gemini: No such file or directory`, 2026-10-06). Pinned
  # because this install is ours. Nothing older than 0.63.0 will do: before
  # it, `session/load` erased the session it was asked to load
  # (google-gemini/gemini-cli#28775, fixed by #29463). 0.64.0 also resolves
  # the session by exact id (#29580) and is what loam's E2B image ships. An
  # image's own copy wins.
  @cli_package "@google/gemini-cli@0.64.0"

  # Install the CLI when it is missing, then make sure the default workspace
  # exists and is a git repo; gemini's MemoryDiscovery is happy as long as it
  # finds *some* .git when it walks up from cwd. A conversation's own cwd is
  # created by the host and never git-init'd: it may be where a clone lands.
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env, _home) do
    script = """
    set -e
    if ! command -v gemini >/dev/null; then
      npm install -g --no-progress --silent #{@cli_package}
    fi
    if [ ! -d #{@workdir}/.git ]; then
      mkdir -p #{@workdir}
      cd #{@workdir}
      git init -q
      git config user.email aod@local
      git config user.name AoD
    fi
    """

    # Long enough for the ~120 MB install on a sandbox without the CLI; a
    # sandbox with it skips the install and returns in well under a second.
    case Managoat.Sandbox.exec(handle, "bash", ["-lc", script],
           env: sprite_env,
           timeout: 180_000
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, code} -> {:error, {:gemini_workspace_init_exit, code}}
      {:error, reason} -> {:error, {:gemini_workspace_init, reason}}
    end
  end
end
