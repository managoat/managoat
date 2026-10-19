defmodule Managoat.Runtimes.Layout do
  @moduledoc """
  Where a runtime keeps its files inside a sandbox — one table, derived
  everywhere else.

  Every path Fountain writes for a runtime is a function of one directory,
  the conversation's **config home** (ADR 0097):

      <config_home>/<config_dir>/<leaf>

  and the runtime is pointed at that directory by one environment variable,
  so the path Fountain writes to and the path the CLI reads from are the same
  value by construction. Each runtime module used to restate its own half of
  that from memory, and once got it wrong: gemini ran with `HOME=/tmp` while
  its system prompt was written under `/home/sprite`, where its CLI never
  looks.

  ## The table

  | runtime  | variable            | config dir           | instructions   | default cwd             |
  |----------|---------------------|----------------------|----------------|-------------------------|
  | claude   | `CLAUDE_CONFIG_DIR` | `<home>`             | `CLAUDE.md`    | `/home/sprite`          |
  | codex    | `CODEX_HOME`        | `<home>`             | `AGENTS.md`    | `/home/sprite`          |
  | gemini   | `GEMINI_CLI_HOME`   | `<home>/.gemini`     | `GEMINI.md`    | `/tmp/gemini-workspace` |

  `CLAUDE_CONFIG_DIR` and `CODEX_HOME` name the config directory itself;
  `GEMINI_CLI_HOME` names the directory gemini-cli treats as its home
  (`homedir()` in `packages/core/src/utils/paths.ts` returns it when set),
  under which it keeps `.gemini/`.

  ## A config home per conversation

  A conversation's config home is `/home/sprite/.managoat/c/<conversation_id>`
  (`config_home/1`), whatever its runtime: skills, the instructions file,
  MCP configuration, the runtime's session store and the inference
  credential files all live there, not in the shared `~/.claude`, `~/.codex`
  or `~/.gemini`. Two conversations on one machine therefore share no runtime
  state.

  The gemini row used to set `HOME=/tmp`: gemini-cli aborts during init if it
  cannot rename `~/.gemini/projects.json.<uuid>.tmp` onto `projects.json`, and
  that rename failed in the image's own `~/.gemini`. Measured on a live
  sprite on 2026-10-18 (sprite `0.0.2-beta.7`, gemini-cli 0.59.0 and the
  image's 0.63.0): `ACP session/new` under `GEMINI_CLI_HOME=~/.managoat/c/<id>`
  wrote `projects.json` cleanly every time, with `/home/sprite` and a folder
  under it as cwd, while the image's `~/.gemini` (a directory of the image's
  lower overlay layer) kept collecting empty `.tmp` files. So the failure
  belongs to that one pre-existing directory, not to `/home/sprite`, and the
  gemini config home sits beside the others with `HOME` left as the image's.

  ## The runtime template

  `runtime_template_root/0` (`/home/sprite/.managoat/template`) is where an
  environment's setup script writes runtime configuration, one directory per
  runtime mirroring that runtime's config directory; a new config home starts
  as a copy of it (#2998, `Managoat.Runtimes.Template`). `merged_files/1`
  names the JSON files Managoat writes keys into, which are merged with a
  template's copy rather than replacing it.

  ## Conversations from before config homes

  `legacy_home/1` is the shared directory a runtime used before ADR 0097
  (`/home/sprite/.claude`, `/home/sprite/.codex`, and `/tmp` for gemini,
  whose `HOME` it was). A conversation provisioned then has its runtime
  session and its skills there, so it keeps that directory as its config home
  for its life, and the same variable points the runtime at it: for codex and
  gemini that is exactly the directory the CLI used by default, and for
  claude the only difference is that the CLI's own state file moves from
  `~/.claude.json` into the directory, which costs one first-start fetch.

  This is layout only — where files go. What goes *in* those files
  (credentials, MCP servers, the agent's prompt) stays with the runtime
  modules, and the imperative bootstrap each runtime needs stays in its
  `prepare_sandbox/4`. See `Managoat.Runtimes`.
  """

  # The sandbox image's own home directory. `/home/sprite` is the convention
  # `Managoat.Sandbox` documents (its `host_path/2` is the identity on the
  # hosted providers and maps this directory on a self-hosted runner), not a
  # host application's setting, so it is fixed here rather than taken as an
  # argument.
  @image_home "/home/sprite"

  # Where every conversation's config home lives, one directory each.
  @config_homes Path.join(@image_home, ".managoat/c")

  # The runtime template an environment's setup script fills, one directory
  # per runtime, copied into each new config home (#2998).
  @runtime_template Path.join(@image_home, ".managoat/template")

  @layouts %{
    "claude" => %{
      config_var: "CLAUDE_CONFIG_DIR",
      config_dir: nil,
      legacy_home: Path.join(@image_home, ".claude"),
      instructions_file: "CLAUDE.md",
      merged_files: ["settings.json", ".claude.json"],
      cwd: @image_home
    },
    "codex" => %{
      config_var: "CODEX_HOME",
      config_dir: nil,
      legacy_home: Path.join(@image_home, ".codex"),
      instructions_file: "AGENTS.md",
      merged_files: [],
      cwd: @image_home
    },
    # The default cwd is separate because gemini walks up from cwd looking
    # for a `.git` and trips on /home/sprite's permissions;
    # `Managoat.Runtimes.Gemini.prepare_sandbox/4` git-inits exactly this
    # directory.
    "gemini" => %{
      config_var: "GEMINI_CLI_HOME",
      config_dir: ".gemini",
      legacy_home: "/tmp",
      instructions_file: "GEMINI.md",
      merged_files: ["settings.json"],
      cwd: "/tmp/gemini-workspace"
    }
  }

  @type runtime :: String.t()

  @doc "Every runtime with a layout. Sorted, so callers get a stable order."
  @spec runtimes() :: [runtime()]
  def runtimes, do: @layouts |> Map.keys() |> Enum.sort()

  @doc "The sandbox image's own home directory."
  @spec image_home() :: String.t()
  def image_home, do: @image_home

  @doc "The directory every conversation's config home is created under."
  @spec config_homes() :: String.t()
  def config_homes, do: @config_homes

  @doc """
  The runtime template's root, `/home/sprite/.managoat/template`: an
  environment's setup script runs with it as `MANAGOAT_RUNTIME_TEMPLATE`,
  and each runtime's directory under it (`runtime_template/1`) is copied
  into a conversation's config home when the home is made
  (`Managoat.Runtimes.Template`).
  """
  @spec runtime_template_root() :: String.t()
  def runtime_template_root, do: @runtime_template

  @doc """
  The runtime's template directory, `<runtime_template_root>/<runtime>`,
  whose contents mirror the runtime's config directory (`config_dir/2`):
  `claude/` what `~/.claude` would hold, `codex/` `~/.codex`, `gemini/`
  `~/.gemini`. nil for a runtime we do not know, which has no template.
  """
  @spec runtime_template(runtime()) :: String.t() | nil
  def runtime_template(runtime) do
    if Map.has_key?(@layouts, runtime), do: Path.join(@runtime_template, runtime)
  end

  @doc """
  The JSON files, relative to the runtime's config directory, that Managoat
  writes keys into and otherwise keeps: claude's `settings.json`
  (`showThinkingSummaries`) and `.claude.json` (`mcpServers`), gemini's
  `settings.json` (`mcpServers`). A template's copy of one of these is
  merged with what is there rather than skipped (`Managoat.Runtimes.Template`).
  """
  @spec merged_files(runtime()) :: [String.t()]
  def merged_files(runtime), do: get_in(@layouts, [runtime, :merged_files]) || []

  @doc """
  The config home of the conversation `conversation_id`, for every runtime:
  `/home/sprite/.managoat/c/<conversation_id>`.
  """
  @spec config_home(String.t()) :: String.t()
  def config_home(conversation_id) when is_binary(conversation_id) and conversation_id != "",
    do: Path.join(@config_homes, conversation_id)

  @doc """
  Whether `path` is a conversation's own config home: a direct child of
  `config_homes/0`. Only such a directory is ever removed when a
  conversation ends; a legacy home is shared and is never one.
  """
  @spec conversation_home?(String.t() | nil) :: boolean()
  def conversation_home?(path) when is_binary(path) do
    expanded = Path.expand(path)

    expanded == path and Path.dirname(expanded) == @config_homes and
      Path.basename(expanded) not in ["", ".", ".."]
  end

  def conversation_home?(_path), do: false

  @doc """
  The shared directory the runtime used as its config home before ADR 0097,
  or nil for a runtime we do not know. See the moduledoc.
  """
  @spec legacy_home(runtime()) :: String.t() | nil
  def legacy_home(runtime), do: get_in(@layouts, [runtime, :legacy_home])

  @doc """
  The env pair that points the runtime at `home`: `CLAUDE_CONFIG_DIR`,
  `CODEX_HOME` or `GEMINI_CLI_HOME`. `[]` for a runtime we do not know.
  """
  @spec config_env(runtime(), String.t()) :: [{String.t(), String.t()}]
  def config_env(runtime, home) when is_binary(home) do
    case get_in(@layouts, [runtime, :config_var]) do
      nil -> []
      var -> [{var, home}]
    end
  end

  @doc "The runtime's config directory under `home`, absolute, or nil for a runtime we do not know."
  @spec config_dir(runtime(), String.t()) :: String.t() | nil
  def config_dir(runtime, home) when is_binary(home) do
    case Map.fetch(@layouts, runtime) do
      {:ok, %{config_dir: nil}} -> home
      {:ok, %{config_dir: dir}} -> Path.join(home, dir)
      :error -> nil
    end
  end

  @doc """
  Absolute path the runtime's CLI scans for skills under `home`, written as
  `<skills_root>/<name>/SKILL.md` by `Managoat.Runtimes.Skills`.

  Every runtime puts this directly under its config directory; none of them
  has ever needed to differ, which is why it is derived rather than listed.
  """
  @spec skills_root(runtime(), String.t()) :: String.t() | nil
  def skills_root(runtime, home) do
    case config_dir(runtime, home) do
      nil -> nil
      dir -> Path.join(dir, "skills")
    end
  end

  @doc """
  The user-level instructions file the runtime reads at session start — where
  the agent's `system` prompt is delivered. See
  `Managoat.Runtimes.Instructions`.
  """
  @spec instructions_path(runtime(), String.t()) :: String.t() | nil
  def instructions_path(runtime, home) do
    with dir when is_binary(dir) <- config_dir(runtime, home),
         file when is_binary(file) <- get_in(@layouts, [runtime, :instructions_file]) do
      Path.join(dir, file)
    else
      _ -> nil
    end
  end

  @doc """
  The working directory a conversation of this runtime runs in when its
  launch names none — the cwd handed to the ACP session, and the directory a
  runtime's `prepare_sandbox/4` git-inits when it needs one. Returns nil for
  a runtime we do not know; `Managoat.Runtimes.ACP.cwd/1` is where the
  fallback for that lives.
  """
  @spec cwd(runtime()) :: String.t() | nil
  def cwd(runtime), do: get_in(@layouts, [runtime, :cwd])
end
