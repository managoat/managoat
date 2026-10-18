defmodule Managoat.Runtimes.Skills do
  @moduledoc """
  Materialize an agent's skills onto its sandbox at provision time.

  Each entry in `skills` is one of:

    * `%{"name" => name, "content" => skill_md}` — inline. Written
      directly to `<runtime.skills_root>/<name>/SKILL.md`.
    * `%{"source" => "owner/repo", "ref" => optional, "name" => optional}` —
      github. The repository is fetched onto the sandbox with one shallow
      `git fetch` of `ref` (a tag, branch or full commit sha; the default
      branch without one), its skills are found by the rules skills.sh uses
      (`Managoat.Runtimes.Skills.Discovery`), and the selected ones are
      copied to `<runtime.skills_root>/<skill name>`. A `name` selects the
      skill of that name; without one, every skill in the repository. The
      source may name a directory inside the repository,
      `owner/repo/path/to/skills`, to search there instead.

  Atom keys are accepted too and normalised to strings. The list is the
  host's to assemble: Fountain prepends the skills every sandbox gets (its
  own API skill) before the agent's own, and this module writes them in the
  order given.

  ## GitHub installs

  Two steps, so a host can record what it is about to own in between
  (`Fountain.SandboxSkills` does):

    1. `stage_github/4` fetches each distinct repository and ref once, all
       of them concurrently, into a staging directory beside the skills root,
       and answers with the directories each entry selects. Nothing under the
       skills root changes.
    2. `place/3` copies those directories into the skills root, each one
       replacing what was there under its name, and removes the staging
       directories.

  The fetch reaches github.com, so on a sandbox behind a network policy it
  needs the way out passed in `:env`: the proxy variables, and the CA
  variables that make git trust the proxy. The exec gets those and nothing
  else of the host's environment. Every value interpolated into the scripts
  is either allow-listed (`safe_token!/1`) or single-quoted.

  Before 2026-10-15 a GitHub skill was installed with `npx -y skills@latest
  add`, about 7 s a skill on a fresh sprite, almost all of it starting npx
  and fetching the CLI from npm; the git fetch is about 1 s a repository.
  """

  require Logger

  alias Managoat.Runtimes
  alias Managoat.Runtimes.Skills.Discovery
  alias Managoat.Sandbox

  @typedoc """
  One skill: inline (`name` + `content`) or github (`source`, optional `ref`
  and `name`). String or atom keys.
  """
  @type skill :: %{optional(String.t() | atom()) => String.t() | nil}

  @typedoc "A selected skill directory: the name it is installed under and where it was staged."
  @type placement :: {name :: String.t(), staged_dir :: String.t()}

  @fetch_timeout 120_000
  @staging_prefix ".managoat-skill-fetch-"

  # What every fetch runs with, before the caller's `:env`. git asks for
  # credentials on a terminal it does not have rather than failing, and a
  # stalled transfer otherwise waits on TCP.
  @fetch_env [{"GIT_TERMINAL_PROMPT", "0"}]

  @doc """
  Install `skills` (a list of inline/github maps) on the sandbox behind
  `handle` for the runtime named in `opts`.

  Options:

    * `:runtime` (required) — the runtime string (`"claude"`, resolved
      through `Managoat.Runtimes.for_runtime/1`) or a module implementing the
      `Managoat.Runtimes` behaviour.
    * `:config_home` (required) — the conversation's config home; the skills
      go under the runtime's `skills_root/1` of it.
    * `:env` — `{name, value}` pairs for the github fetches' exec, such as
      a proxy and the CA it is trusted through. Default `[]`.

  Returns `:ok`, or `{:error, message}` for a runtime string the dispatcher
  does not know. A skill that fails to land is logged and skipped rather
  than failing the provision: a missing skill is a degraded agent, not a
  broken one.
  """
  @spec install(Sandbox.Handle.t(), [skill()], keyword()) :: :ok | {:error, String.t()}
  def install(handle, skills, opts) when is_list(skills) and is_list(opts) do
    case Keyword.fetch!(opts, :runtime) do
      runtime when is_binary(runtime) ->
        case Runtimes.for_runtime(runtime) do
          {:ok, mod} -> install_for(handle, mod, skills, opts)
          {:error, _} = err -> err
        end

      mod when is_atom(mod) ->
        install_for(handle, mod, skills, opts)
    end
  end

  defp install_for(handle, runtime_module, skills, opts) do
    skills_root = runtime_module.skills_root(Keyword.fetch!(opts, :config_home))

    {inline, github} =
      skills
      |> normalize()
      |> Enum.split_with(fn s -> is_binary(s["content"]) end)

    # Github installs first, inline writes second: a blocking exec waits for
    # the sandbox to be running, so by the time we touch the file-write
    # endpoints they're definitely up.
    if github != [] do
      placements =
        handle
        |> stage_github(skills_root, github, Keyword.get(opts, :env, []))
        |> Enum.flat_map(fn
          {_entry, {:ok, placements}} -> placements
          {_entry, {:error, _}} -> []
        end)

      place(handle, skills_root, placements)
    end

    write_inline_skills(handle, skills_root, inline)
    :ok
  end

  defp normalize(skills) do
    Enum.map(skills, fn entry ->
      Map.new(entry, fn
        {k, v} when is_atom(k) -> {Atom.to_string(k), v}
        {k, v} -> {k, v}
      end)
    end)
  end

  defp write_inline_skills(_handle, _root, []), do: :ok

  defp write_inline_skills(handle, root, inline) do
    Enum.each(inline, fn %{"name" => name, "content" => content} ->
      # write_file/4 creates the `<root>/<name>` directory atomically with
      # the file write, so we don't need a separate mkdir round-trip (each
      # one was another opportunity for the same readiness race).
      path = Path.join([root, name, "SKILL.md"])

      case Sandbox.write_file(handle, path, content) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.warning("inline skill write failed for #{name} at #{path}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Fetch the repositories `entries` name and find the skill directories each
  entry selects, without touching `skills_root`.

  Each distinct repository and ref is fetched once, and the fetches run
  concurrently. Answers each entry (normalised to string keys) with its
  placements, or with why it has none: the fetch failed, the repository has
  no skills there, or none has the requested name. Each failure is logged.
  Raises `ArgumentError` for a source, ref or name that is not shell-safe.
  """
  @spec stage_github(Sandbox.Handle.t(), String.t(), [skill()], [{String.t(), String.t()}]) ::
          [{map(), {:ok, [placement()]} | {:error, term()}}]
  def stage_github(handle, skills_root, entries, env) do
    entries = entries |> normalize() |> Enum.map(&{&1, parse_source!(&1)})
    env = @fetch_env ++ env

    fetched =
      entries
      |> Enum.flat_map(fn
        {_entry, {:ok, source}} -> [Map.take(source, [:repo, :ref])]
        _ -> []
      end)
      |> Enum.uniq()
      |> Task.async_stream(&{&1, fetch(handle, skills_root, &1, env)},
        timeout: @fetch_timeout + 10_000,
        on_timeout: :kill_task,
        ordered: false,
        max_concurrency: 4
      )
      |> Map.new(fn
        {:ok, {key, result}} -> {key, result}
        {:exit, _} -> {nil, nil}
      end)

    Enum.map(entries, fn
      {entry, {:error, _} = error} ->
        {entry, warn(entry, error)}

      {entry, {:ok, source}} ->
        result =
          case Map.get(fetched, Map.take(source, [:repo, :ref]), {:error, :timeout}) do
            {:ok, stage, files, manifests} -> select(entry, source, stage, files, manifests)
            {:error, _} = error -> error
          end

        {entry, warn(entry, result)}
    end)
  end

  defp warn(_entry, {:ok, _} = ok), do: ok

  defp warn(entry, {:error, reason} = error) do
    Logger.warning("github skill install failed for #{inspect(entry)}: #{format_reason(reason)}")
    error
  end

  defp format_reason({:fetch_failed, code, output}), do: "fetch exited #{code}: #{output}"
  defp format_reason(reason), do: inspect(reason)

  defp select(entry, source, stage, files, manifests) do
    name = entry["name"]
    named? = name not in [nil, ""]

    files
    |> Discovery.discover(manifests, source.subpath, include_internal: named?)
    |> Discovery.select(name)
    |> Enum.map(fn skill ->
      {Discovery.sanitize_name(skill.name), Path.join([stage, skill.dir])}
    end)
    |> case do
      [] when named? -> {:error, {:skill_not_found, name}}
      [] -> {:error, :no_skills_found}
      placements -> {:ok, placements}
    end
  end

  # `owner/repo` or `owner/repo/sub/path`. A value git would read as an
  # option, or a path that climbs, is refused here; anything the shell would
  # read specially never gets past `safe_token!/1`.
  defp parse_source!(entry) do
    source = safe_token!(entry["source"])
    ref = if entry["ref"] in [nil, ""], do: nil, else: safe_token!(entry["ref"])
    if entry["name"] not in [nil, ""], do: safe_token!(entry["name"])

    case String.split(source, "/") do
      [owner, repo | sub] ->
        repo = String.replace_suffix(repo, ".git", "")

        cond do
          Enum.any?([owner, repo], &(&1 in ["", ".", ".."] or String.starts_with?(&1, "-"))) ->
            {:error, {:invalid_source, source}}

          Enum.any?(sub, &(&1 == "..")) ->
            {:error, {:invalid_source, source}}

          ref && String.starts_with?(ref, "-") ->
            {:error, {:invalid_ref, ref}}

          true ->
            {:ok, %{repo: owner <> "/" <> repo, ref: ref, subpath: Enum.join(sub, "/")}}
        end

      _ ->
        {:error, {:invalid_source, source}}
    end
  end

  defp fetch(handle, skills_root, %{repo: repo, ref: ref}, env) do
    case Sandbox.exec(handle, "bash", ["-c", fetch_script(skills_root, repo, ref)],
           env: env,
           stderr_to_stdout: true,
           timeout: @fetch_timeout
         ) do
      {:ok, output, 0} ->
        parse_fetch(output)

      {:ok, output, code} ->
        {:error, {:fetch_failed, code, output |> redact(env) |> String.slice(-500, 500)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc false
  # One shallow fetch of the ref into a fresh staging directory beside the
  # skills root (the same filesystem, out of the runtime's sight), then every
  # SKILL.md's frontmatter and every plugin manifest, base64 so a path or a
  # file cannot forge a line.
  def fetch_script(skills_root, repo, ref) do
    parent = Path.dirname(skills_root)

    """
    set -eu
    mkdir -p -- #{quote_shell(parent)}
    stage=$(mktemp -d #{quote_shell(Path.join(parent, @staging_prefix <> "XXXXXX"))})
    cd "$stage"
    git init -q
    git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 fetch -q --depth 1 --no-tags \
      #{quote_shell("https://github.com/" <> repo <> ".git")} #{quote_shell(ref || "HEAD")}
    git -c advice.detachedHead=false checkout -q FETCH_HEAD
    rm -rf .git
    printf 'stage %s\\n' "$stage"
    find . -maxdepth 9 \\( -name .git -o -name node_modules \\) -prune -o \\
      \\( -name SKILL.md -o -path '*/.claude-plugin/marketplace.json' -o -path '*/.claude-plugin/plugin.json' \\) \\
      \\( -type f -o -type l \\) -print |
    while IFS= read -r file; do
      case "$file" in
        */SKILL.md)
          body=$(awk 'NR == 1 && index($0, "---") == 0 { exit } { print } NR > 1 && index($0, "---") == 1 { exit } NR >= 400 { exit }' "$file" | base64 -w0) ;;
        *)
          body=$(head -c 262144 -- "$file" | base64 -w0) ;;
      esac
      printf 'file %s %s\\n' "$(printf '%s' "${file#./}" | base64 -w0)" "$body"
    done
    """
  end

  @doc false
  def parse_fetch(output) do
    lines = String.split(output, "\n", trim: true)

    with [stage] <- for("stage " <> stage <- lines, do: stage) do
      {skill_files, manifests} =
        lines
        |> Enum.flat_map(fn
          "file " <> rest ->
            with [path, body] <- String.split(rest, " ", parts: 2) |> pad(),
                 {:ok, path} <- Base.decode64(path),
                 {:ok, body} <- Base.decode64(body) do
              [{path, body}]
            else
              _ -> []
            end

          _ ->
            []
        end)
        |> Enum.split_with(fn {path, _} -> Path.basename(path) == "SKILL.md" end)

      skill_files =
        Map.new(skill_files, fn {path, body} ->
          dir = Path.dirname(path)
          {if(dir == ".", do: "", else: dir), body}
        end)

      {:ok, stage, skill_files, Map.new(manifests)}
    else
      _ -> {:error, {:unexpected_fetch_output, String.slice(output, 0, 200)}}
    end
  end

  defp pad([path]), do: [path, ""]
  defp pad(parts), do: parts

  @doc """
  Copy staged skill directories into `skills_root` and remove every staging
  directory beside it.

  Each directory replaces whatever is under its name, through a copy beside
  it and a rename, so the runtime never reads a half-copied skill. Symlinks
  are copied as what they point at, and `.git`, `__pycache__`,
  `__pypackages__` and `metadata.json` are left out, as skills.sh did. With
  no placements it only removes the staging directories. Answers
  `{:error, reason}` when any directory did not land; the others did.
  """
  @spec place(Sandbox.Handle.t(), String.t(), [placement()]) :: :ok | {:error, term()}
  def place(handle, skills_root, placements) do
    case Sandbox.exec(handle, "bash", ["-c", place_script(skills_root, placements)],
           stderr_to_stdout: true,
           timeout: @fetch_timeout
         ) do
      {:ok, _output, 0} ->
        :ok

      {:ok, output, code} ->
        Logger.warning("github skill copy failed (#{code}): #{String.slice(output, 0, 500)}")
        {:error, {:place_failed, code}}

      {:error, reason} = error ->
        Logger.warning("github skill copy failed: #{inspect(reason)}")
        error
    end
  end

  @doc false
  def place_script(skills_root, placements) do
    copies =
      Enum.map_join(placements, "\n", fn {name, staged} ->
        "place #{quote_shell(safe_token!(name))} #{quote_shell(staged)}"
      end)

    """
    set -u
    root=#{quote_shell(skills_root)}
    status=0
    mkdir -p -- "$root" || exit 1
    place() {
      new="$root/.$1.managoat-new"
      rm -rf -- "$new"
      cp -RL -- "$2" "$new" 2>/dev/null
      find "$new" \\( -type d \\( -name .git -o -name __pycache__ -o -name __pypackages__ \\) \\
        -o -type f -name metadata.json \\) -prune -exec rm -rf -- {} + 2>/dev/null
      if [ -f "$new/SKILL.md" ] && rm -rf -- "$root/$1" && mv -T -- "$new" "$root/$1"; then
        :
      else
        rm -rf -- "$new"
        echo "skill $1 did not land"
        status=1
      fi
    }
    #{copies}
    rm -rf -- #{quote_shell(Path.dirname(skills_root))}/#{@staging_prefix}*
    exit "$status"
    """
  end

  # The proxy URL carries the conversation's broker token in its userinfo.
  defp redact(output, env) do
    env
    |> Enum.flat_map(fn {_key, value} ->
      case URI.parse(to_string(value)) do
        %URI{userinfo: info} when is_binary(info) and info != "" -> [info]
        _ -> []
      end
    end)
    |> Enum.reduce(output, &String.replace(&2, &1, "[REDACTED]"))
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # Allow-list guard for a value that reaches a shell script or git's
  # command line. Permits `[A-Za-z0-9._/-]` which is the full set needed for
  # owner/repo identifiers, refs and skill names. Anything else raises rather
  # than silently passing through — we never want a `;` or `$` smuggled into
  # a shelled-out command. A host that validates a skill ref at write time
  # mirrors this expression.
  @doc false
  def safe_token!(value) when is_binary(value) do
    if Regex.match?(~r{\A[A-Za-z0-9._/-]+\z}, value) do
      value
    else
      raise ArgumentError, "unsafe skill token (rejected by allow-list): #{inspect(value)}"
    end
  end

  def safe_token!(value),
    do: raise(ArgumentError, "unsafe skill token (rejected by allow-list): #{inspect(value)}")
end
