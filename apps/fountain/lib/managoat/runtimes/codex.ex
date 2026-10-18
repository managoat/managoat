defmodule Managoat.Runtimes.Codex do
  @moduledoc """
  OpenAI Codex runtime — provisioning only.

  Turns speak ACP through the pinned `codex-acp` adapter
  (`Managoat.Runtimes.ACP`); the `codex exec` argv builder — and with it the
  resume-by-guessing `--last` flag, the worst thing this module shipped —
  went with the legacy spawn path. What remains is the half ADR 0014
  deliberately kept: credentials and skills.

  Every file is under the conversation's config home, which `config_env/1`
  exports as `CODEX_HOME` (ADR 0097): the adapter and the CLI keep their
  sessions, logs and `auth.json` there, so two codex conversations on one
  machine never share a store.

  Auth: `OPENAI_API_KEY` is consumed once at provision time via
  `prepare_sandbox/4` (see below) — codex reads `$CODEX_HOME/auth.json`, not
  the process env, and the adapter runs on the same store.
  """

  @behaviour Managoat.Runtimes

  alias Managoat.Runtimes.Layout

  @runtime "codex"

  @impl true
  def skills_root(home), do: Layout.skills_root(@runtime, home)

  @impl true
  def config_env(home), do: Layout.config_env(@runtime, home)

  @impl true
  def default_env(_agent, inference_credentials) do
    case Map.get(inference_credentials, :openai_api_key) do
      nil -> []
      "" -> []
      key -> [{"OPENAI_API_KEY", key}]
    end
  end

  # MCP servers travel in `session/new`'s `mcpServers` param on the ACP path
  # (#636); the `~/.codex/config.toml` writer that used to live here served
  # the bare CLI. An agent opted out of ACP runs its legacy turns without MCP
  # servers.

  # codex 0.118+ does NOT read OPENAI_API_KEY at exec time; it reads
  # `<CODEX_HOME>/auth.json`, and codex-acp runs on the same store. Write that
  # file directly, in the shape `codex login --with-api-key` writes (checked
  # against 0.147.0: mode 600, `auth_mode` "apikey"), rather than running the
  # login.
  #
  # The login needed a `codex` binary on PATH, which the Sprites and E2B images
  # carry and a self-hosted runner does not: there `codex login` exited before
  # it read the key and every codex conversation failed at provision with
  # `{:codex_login_write, :command_exited}` (managoat/fountain, 2026-10-06).
  # The file write needs nothing installed, keeps the key off argv and stdin,
  # and costs one call instead of a spawn and its exit.
  #
  # A ChatGPT grant's `auth.json` is the host's (Fountain's CodexChatGPT),
  # written to the same path.
  @impl true
  def prepare_sandbox(handle, _agent, sprite_env, home) do
    case List.keyfind(sprite_env, "OPENAI_API_KEY", 0) do
      {"OPENAI_API_KEY", key} when is_binary(key) and key != "" ->
        case Managoat.Sandbox.write_file(handle, auth_path(home), auth_json(key), mode: 0o600) do
          :ok -> :ok
          {:error, reason} -> {:error, {:codex_auth_write, reason}}
        end

      _ ->
        # No key in env — surface that explicitly; without it the
        # subsequent turn will 401 with a confusing message.
        {:error, :missing_openai_api_key}
    end
  end

  @doc false
  def auth_path(home), do: Path.join(Layout.config_dir(@runtime, home), "auth.json")

  @doc false
  def auth_json(key), do: Jason.encode!(%{"auth_mode" => "apikey", "OPENAI_API_KEY" => key})
end
