defmodule Managoat.Runtimes.Template do
  @moduledoc """
  The runtime template: runtime configuration an environment's setup script
  writes once, copied into each conversation's config home when the home is
  made (#2998).

  Since ADR 0097 every conversation has a config home of its own
  (`~/.managoat/c/<conversation_id>`), and a workspace's setup script runs
  before any conversation exists, so a setup script cannot write into the
  config home an agent will use, and the image's `~/.claude`, `~/.codex` and
  `~/.gemini` are not read. The setup script writes into the template
  instead: it runs with `MANAGOAT_RUNTIME_TEMPLATE` set to
  `Managoat.Runtimes.Layout.runtime_template_root/0`, whose `claude/`,
  `codex/` and `gemini/` directories are made, empty, before it runs
  (`prepare_script/0`). Each mirrors the runtime's config directory: what
  `~/.claude`, `~/.codex` or `~/.gemini` would hold.

  ## When it is copied

  Once per config home, when the home is made, never after: a later change
  to the template reaches only conversations whose homes are made after it.
  There are two moments a home is made, so `seed/5` has two modes:

    * `:new`, for a conversation attaching to a machine that is already up
      (a launch into a workspace, or a conversation following its
      workspace onto a rebuilt machine). It runs before Managoat writes
      anything into the home, and copies only when the home is not there
      yet: a wake finds its home and leaves it alone. The copy is built
      beside the home and renamed into place, so a seed that stops halfway
      leaves no home, and the next attach seeds again.
    * `:into`, for a conversation whose own provision built the machine.
      Managoat writes the home's config while the setup script is still
      running, so the template is copied in after the setup: the stage gets
      the template, then the home Managoat filled is copied over it, so
      Managoat's files win by going last, and the stage is swapped in.

  Both are a few processes however large the template, and the home ends
  mode 700 whatever the template directory's mode. A commit retried after a
  lost reply finds its stage gone and reports the work done.

  ## Collisions: Managoat's files win

  The result is the same in both modes. Managoat's own files win: the
  instructions file when the agent has a `system` prompt, the codex
  `auth.json`, the skills it installs (a template skill of the same name is
  replaced, whole directory and all; in `:new` the names come from
  `Fountain.SandboxSkills.owned_names/1`, named GitHub skills included,
  because a reconciliation that found a template's copy under such a name
  would take it for the skill and never fetch it), the session. A path that
  is a directory on one side and a file on the other is Managoat's.
  Everything else in the template is copied as it is.

  The JSON files Managoat writes keys into (`Layout.merged_files/1`: claude's
  `settings.json` and `.claude.json`, gemini's `settings.json`) are merged
  instead, at the top level: the template's file is the base and the keys
  Managoat owns are put over it (`showThinkingSummaries`, `mcpServers`), so
  a template's `hooks`, `permissions` or `env` survive. `mcpServers` is
  replaced whole, not merged by server name: the servers that run are the
  agent's, which is what lets an agent that drops a server drop it on its
  next wake, and what keeps every server's credentials on the agent's path
  (resolved `${VAR}` references, the broker's placeholders, the callback
  token rotated on reattach). A template's `mcpServers` is dropped at the
  seed itself, so its servers never run even where Managoat's own write
  after it fails. The merged files land mode 600 (the servers carry resolved
  credentials). Every later write keeps the merge
  (`Managoat.Runtimes.JsonConfig`). A template file of these that is not a
  JSON object fails the seed, naming the file, rather than being dropped, and
  so does a file or directory in the template the sandbox user cannot read
  (the path is named, never its contents).

  ## What is copied

  Regular files and directories only, with their modes (a hook script stays
  executable). A symlink is neither followed nor copied, so nothing outside
  the template is read through one, and nothing Managoat later writes into
  the home is written through one; nor is a fifo, socket or device. A
  template, or a runtime's directory in it, that is itself a symlink is not
  used. Managoat's own bookkeeping (the skills manifest, a skill fetch's
  staging directory, a config write's temporary file) is never taken from a
  template.

  The template is not a secret store. It is on the machine's disk like the
  config homes, where the file routes can read it, redacted like every other
  file there (`Fountain.SandboxFiles`).
  """

  alias Managoat.Runtimes.{JsonConfig, Layout}
  alias Managoat.Sandbox
  alias Managoat.Sandbox.Retry

  @type mode :: :new | :into

  @env_var "MANAGOAT_RUNTIME_TEMPLATE"
  @timeout 60_000

  # Arguments: phase (stage | commit | abort), mode (new | into), the
  # runtime's template directory, the config home, the runtime's config
  # directory relative to the home ("" or ".gemini"), the stage (commit and
  # abort only), the merged files and the skill names Managoat will write,
  # each newline-separated. Every line it prints starts with
  # `managoat-template`, and every run that exits 0 prints one status:
  # `none`, `present`, `unreadable <path>`, `staged <stage>` or `done`.
  #
  # The copy is built in a stage beside the homes. `:new` renames the stage
  # into place. `:into` copies the home Managoat wrote over the stage, so
  # Managoat's files win by going last, then swaps the two directories. The
  # merged JSON files are written by the caller into `<stage>.m`, and moved in
  # last, mode 600. Both are a handful of processes whatever the template's
  # size. A commit that finds its stage gone has already run (a retry after a
  # lost reply), and says so.
  @script ~S"""
  set -u
  phase=$1 mode=$2 src=$3 home=$4 rel=$5 stage=$6 merged=$7 skills=$8
  base=$(dirname -- "$(dirname -- "$home")")

  under() { if [ -n "$rel" ]; then printf '%s/%s' "$1" "$rel"; else printf '%s' "$1"; fi; }

  own_stage() {
    case "$stage" in
      "$base"/.template-stage.*) [ -d "$stage" ] && [ ! -L "$stage" ] ;;
      *) return 1 ;;
    esac
  }

  commit() {
    s=$(under "$stage")
    m="$stage.m"
    while IFS= read -r n; do
      case "$n" in ''|.|..|*/*) continue ;; esac
      rm -rf -- "$s/skills/$n"
    done <<< "$skills"
    d=$(under "$home")
    if [ "$mode" = into ] && [ -d "$d" ] && [ ! -L "$d" ]; then
      while IFS= read -r -d '' f; do
        f=${f#./}
        if [ -d "$d/$f" ] && [ ! -L "$d/$f" ]; then
          case "$f" in
            skills/*/*) ;;
            skills/*) rm -rf -- "$s/$f" ;;
            *) if [ -L "$s/$f" ] || { [ -e "$s/$f" ] && [ ! -d "$s/$f" ]; }; then rm -rf -- "$s/$f"; fi ;;
          esac
        else
          rm -rf -- "$s/$f"
        fi
      done < <(cd -- "$d" && find . -mindepth 1 -print0)
      cp -RP --preserve=mode,timestamps -- "$d/." "$s/" || return 1
    fi
    if [ -d "$m" ]; then
      for f in "$m"/* "$m"/.[!.]*; do
        if [ ! -f "$f" ]; then continue; fi
        mv -f -- "$f" "$s/${f##*/}" && chmod 600 -- "$s/${f##*/}" || return 1
      done
      rm -rf -- "$m"
    fi
    chmod 700 -- "$stage" "$s" || return 1
    mkdir -p -- "$(dirname -- "$home")" || return 1
    if [ "$mode" = new ]; then
      if [ -e "$home" ] || [ -L "$home" ] || ! mv -T -- "$stage" "$home" 2>/dev/null; then
        rm -rf -- "$stage"
        echo "managoat-template present"
        return 0
      fi
    else
      mkdir -p -- "$(dirname -- "$d")" || return 1
      aside="$stage.old"
      if [ -e "$d" ] || [ -L "$d" ]; then mv -T -- "$d" "$aside" || return 1; fi
      if ! mv -T -- "$s" "$d"; then
        if [ -e "$aside" ]; then mv -T -- "$aside" "$d"; fi
        return 1
      fi
      rm -rf -- "$aside" "$stage"
    fi
    echo "managoat-template done"
  }

  case "$phase" in
    commit)
      if ! own_stage; then
        if [ -e "$stage" ] || [ -L "$stage" ]; then exit 2; fi
        if [ "$mode" = new ]; then echo "managoat-template present"; else echo "managoat-template done"; fi
        exit 0
      fi
      commit || { rm -rf -- "$stage" "$stage.m"; exit 1; }
      exit 0
      ;;
    abort)
      own_stage && rm -rf -- "$stage" "$stage.m"
      echo "managoat-template none"
      exit 0
      ;;
  esac

  if [ "$mode" = new ] && { [ -e "$home" ] || [ -L "$home" ]; }; then
    echo "managoat-template present"
    exit 0
  fi
  root=$(dirname -- "$src")
  if [ -L "$root" ] || [ -L "$src" ] || [ ! -d "$src" ] || [ -z "$(ls -A -- "$src" 2>/dev/null)" ]; then
    echo "managoat-template none"
    exit 0
  fi
  bad=$(cd -- "$src" && find . -mindepth 1 \( -type f -o -type d \) \
    \( ! -readable -o \( -type d ! -executable \) \) -print -quit 2>/dev/null)
  if [ -n "$bad" ]; then
    printf 'managoat-template unreadable %s\n' "${bad#./}"
    exit 0
  fi

  mkdir -p -- "$base" || exit 1
  find "$base" -maxdepth 1 -name '.template-stage.*' -mmin +60 -exec rm -rf -- {} + 2>/dev/null
  stage=$(mktemp -d -- "$base/.template-stage.XXXXXX") || exit 1
  s=$(under "$stage")
  if ! { mkdir -p -- "$s" && cp -RP --preserve=mode,timestamps -- "$src/." "$s/"; }; then
    rm -rf -- "$stage"
    exit 1
  fi
  find "$stage" -mindepth 1 ! -type f ! -type d -delete
  rm -rf -- "$s/skills/.fountain-managed-skills" "$s"/.managoat-skill-fetch-*
  find "$s" -maxdepth 1 -type f -name '*.managoat.*.tmp' -delete

  found=0
  while IFS= read -r f; do
    if [ -z "$f" ]; then continue; fi
    if [ -e "$s/$f" ] && [ ! -f "$s/$f" ]; then
      rm -rf -- "$stage"
      printf 'managoat-template unreadable %s\n' "$f"
      exit 0
    fi
    if [ -f "$s/$f" ]; then
      found=1
      printf 'managoat-template file %s ' "$f"
      base64 -w0 -- "$s/$f" || { rm -rf -- "$stage"; exit 1; }
      printf '\n'
      if [ "$mode" = into ] && [ -f "$(under "$home")/$f" ]; then
        printf 'managoat-template current %s ' "$f"
        base64 -w0 -- "$(under "$home")/$f" || { rm -rf -- "$stage"; exit 1; }
        printf '\n'
      fi
    fi
  done <<< "$merged"

  if [ "$found" = 1 ]; then
    echo "managoat-template staged $stage"
    exit 0
  fi
  commit || { rm -rf -- "$stage"; exit 1; }
  """

  @doc "The variable the setup script finds the template's root in."
  @spec env_var() :: String.t()
  def env_var, do: @env_var

  @doc """
  The env pair a setup script runs with: `MANAGOAT_RUNTIME_TEMPLATE` and the
  template's root.
  """
  @spec setup_env() :: [{String.t(), String.t()}]
  def setup_env, do: [{@env_var, Layout.runtime_template_root()}]

  @doc """
  Shell that makes the template's runtime directories, mode 700, before a
  setup script runs. It prints nothing and never fails the setup: where the
  template cannot be made, a script that writes into it fails with its own
  error, and the conversations get no template.
  """
  @spec prepare_script() :: String.t()
  def prepare_script do
    root = Layout.runtime_template_root()
    dirs = Enum.map_join(Layout.runtimes(), " ", &quote_shell(Path.join(root, &1)))

    "mkdir -p -m 700 -- #{quote_shell(root)} #{dirs} >/dev/null 2>&1 || true\n"
  end

  @doc false
  def script, do: @script

  @doc """
  Copy the runtime's template into the config home `home` (see the
  moduledoc for the two modes and the collision rule).

  Options:

    * `:template_root` — where the template is; default
      `Layout.runtime_template_root/0`.
    * `:skills` — `:new` only: the names of the skills Managoat writes into
      the home after the seed, whose template copies are dropped so that
      Managoat's is whole.

  Answers `:ok` when there was nothing to copy, the home was there already
  (`:new`), or the copy is done; `{:error, {:runtime_template, reason}}`
  otherwise, with nothing committed.
  """
  @spec seed(Sandbox.Handle.t(), String.t(), String.t(), mode(), keyword()) ::
          :ok | {:error, term()}
  def seed(handle, runtime, home, mode, opts \\ []) when mode in [:new, :into] do
    root = Keyword.get(opts, :template_root, Layout.runtime_template_root())

    case Layout.config_dir(runtime, home) do
      nil ->
        :ok

      dir ->
        args = %{
          mode: Atom.to_string(mode),
          src: Path.join(root, runtime),
          home: home,
          rel: if(dir == home, do: "", else: Path.relative_to(dir, home)),
          merged: Enum.join(Layout.merged_files(runtime), "\n"),
          skills: Enum.join(Keyword.get(opts, :skills, []), "\n")
        }

        with {:ok, out} <- run(handle, "stage", args, "") do
          case parse(out) do
            {:staged, stage, files} -> merge_and_commit(handle, args, stage, files)
            other -> settled(other)
          end
        end
    end
  end

  defp merge_and_commit(handle, args, stage, files) do
    result =
      Enum.reduce_while(files, :ok, fn {file, found}, :ok ->
        with {:ok, map} <- merged(file, found.template, Map.get(found, :current)),
             :ok <- write_staged(handle, Path.join(stage <> ".m", file), map) do
          {:cont, :ok}
        else
          {:error, _} = error -> {:halt, error}
        end
      end)

    case result do
      :ok ->
        with {:ok, out} <- run(handle, "commit", args, stage), do: settled(parse(out))

      {:error, _} = error ->
        _ = run(handle, "abort", args, stage)
        error
    end
  end

  defp settled(:done), do: :ok
  defp settled(:none), do: :ok
  defp settled(:present), do: :ok
  defp settled({:unreadable, path}), do: {:error, {:runtime_template, {:unreadable, path}}}
  defp settled(:unrecognised), do: {:error, {:runtime_template, :no_answer}}

  # The template's file is the base, without `mcpServers` (the agent's alone,
  # even before Managoat's own write puts them), and what Managoat already
  # wrote goes over it.
  defp merged(file, template, current) do
    with {:ok, base} <- decode(file, template, :not_a_json_object),
         {:ok, over} <- decode(file, current, :unreadable) do
      {:ok, base |> Map.delete("mcpServers") |> Map.merge(over)}
    end
  end

  defp decode(_file, nil, _why), do: {:ok, %{}}

  defp decode(file, text, why) do
    case JsonConfig.decode_object(text) do
      {:ok, map} -> {:ok, map}
      :error -> {:error, {:runtime_template, {why, file}}}
    end
  end

  defp write_staged(handle, path, map) do
    body = Jason.encode!(map, pretty: true)

    case Retry.with_backoff(fn -> Sandbox.write_file(handle, path, body, mode: 0o600) end,
           label: "runtime template merge"
         ) do
      :ok -> :ok
      {:error, reason} -> {:error, {:runtime_template, reason}}
    end
  end

  defp run(handle, phase, args, stage) do
    argv = [
      "-c",
      @script,
      "managoat-template",
      phase,
      args.mode,
      args.src,
      args.home,
      args.rel,
      stage,
      args.merged,
      args.skills
    ]

    case Retry.with_backoff(
           fn -> Sandbox.exec(handle, "bash", argv, timeout: @timeout) end,
           label: "runtime template #{phase}"
         ) do
      {:ok, out, 0} -> {:ok, to_string(out)}
      {:ok, _out, code} -> {:error, {:runtime_template, {phase, {:exit, code}}}}
      {:error, reason} -> {:error, {:runtime_template, {phase, reason}}}
    end
  end

  # The script's status line, and with `staged` the merged files' contents.
  # Output with no status (stdout lost on the way back) is not taken for
  # success: the seed fails and a later attach tries again.
  defp parse(out) do
    out
    |> String.split("\n", trim: true)
    |> Enum.reduce(%{status: :unrecognised, files: %{}}, fn line, acc ->
      case String.split(line, " ", parts: 4) do
        ["managoat-template", "staged", stage] ->
          %{acc | status: {:staged, stage}}

        ["managoat-template", status] when status in ["none", "present", "done"] ->
          %{acc | status: String.to_existing_atom(status)}

        ["managoat-template", "unreadable" | path] ->
          %{acc | status: {:unreadable, Enum.join(path, " ")}}

        ["managoat-template", kind, file, encoded] when kind in ["file", "current"] ->
          key = if kind == "file", do: :template, else: :current
          # A frame that does not decode reads as a file that is not JSON.
          text =
            case Base.decode64(encoded) do
              {:ok, text} -> text
              :error -> "\u0000"
            end

          %{acc | files: Map.update(acc.files, file, %{key => text}, &Map.put(&1, key, text))}

        _ ->
          acc
      end
    end)
    |> case do
      %{status: {:staged, stage}, files: files} ->
        {:staged, stage, Enum.filter(files, fn {_f, found} -> Map.has_key?(found, :template) end)}

      %{status: status} ->
        status
    end
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
