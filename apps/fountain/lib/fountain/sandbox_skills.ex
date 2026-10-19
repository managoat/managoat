defmodule Fountain.SandboxSkills do
  @moduledoc """
  The skills every Fountain sandbox gets, and the call that mounts them with
  the agent's own.

  The mechanism — inline `SKILL.md` writes under the runtime's skills root,
  fetching and copying github sources, the shell allow-list — is
  `Managoat.Runtimes.Skills`. What is Fountain's is the content: the bundled
  skills under `priv/sprite_skills/`, prepended to every agent's list so the
  per-conversation callback API is discoverable inside the sprite.
  """

  require Logger

  @bundle_root "sprite_skills"
  # Written at the skills root: which directories each Fountain-managed skill
  # put there, so a later reconciliation knows what it owns.
  @manifest_name ".fountain-managed-skills"
  @managoat_skill_name "managoat"
  # Every sandbox gets these.
  @bundled_skills [@managoat_skill_name]
  @plain_name ~r/\A[A-Za-z0-9_][A-Za-z0-9._-]*\z/

  @doc """
  Mount `skills` (a list of inline/github maps, the agent's `skills` field)
  on the sandbox behind `handle` for the named runtime. The bundled skills
  are always prepended.

  A runtime **string** is resolved here, through `Fountain.RuntimeDispatch`
  rather than through the library's own dispatcher (#1634).
  `Managoat.Runtimes.Skills` resolves a string through
  `Managoat.Runtimes.for_runtime/1`, which is a closed map of the four
  packaged runtimes and does not know `acp` — so
  passing the string straight through returned
  `{:error, "unsupported runtime: acp"}` and an acp sandbox came up with no
  skills at all and nothing said so.

  Failure is logged rather than raised, and returned for a caller that wants
  it. A missing skill is a degraded agent, not a broken one, which is the
  trade `Managoat.Runtimes.Skills` already makes for one skill that will not
  install; this extends it to a runtime that cannot be resolved.
  """
  @spec mount(Managoat.Sandbox.Handle.t(), String.t() | module(), [map()] | nil, keyword()) ::
          :ok | {:error, String.t()}
  def mount(handle, runtime, skills, opts \\ [])

  def mount(handle, runtime, skills, opts) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        mount(handle, module, skills, opts)

      {:error, reason} ->
        Logger.warning("skills not mounted for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def mount(handle, runtime_module, skills, opts) when is_atom(runtime_module) do
    with {:ok, _failed} <- reconcile(handle, runtime_module, skills, [], opts), do: :ok
  end

  @doc """
  `mount/3` for a machine this provision has just created.

  A fresh machine has no manifest and nothing to remove, so reconciling it
  only reads an absent manifest, `mkdir`s the root and rewrites the manifest
  before each skill: 2 execs and 6 writes for the bundled skills, ~0.85 s on
  a sprite (measured 2026-09-26). When every selected skill is inline, this
  writes the manifest reconciliation would end with, then the skills, under
  the same lock: no execs, one write per file. The manifest still goes
  first, so a failure part-way leaves files it owns rather than files nobody
  owns. A
  remote skill names its own directories, which only a real reconcile
  discovers, so any remote skill falls back to `mount/4`, which installs it
  with the `:env` given (see `reconcile/5`).

  Only for a machine nothing else has written skills to: a reattach
  reconciles.
  """
  @spec mount_fresh(
          Managoat.Sandbox.Handle.t(),
          String.t() | module(),
          [map()] | nil,
          keyword()
        ) ::
          :ok | {:error, term()}
  def mount_fresh(handle, runtime, skills, opts \\ [])

  def mount_fresh(handle, runtime, skills, opts) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        mount_fresh(handle, module, skills, opts)

      {:error, reason} ->
        Logger.warning("skills not mounted for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def mount_fresh(handle, runtime_module, skills, opts) when is_atom(runtime_module) do
    selected = normalize(bundled() ++ (skills || []))

    if remote?(selected) do
      mount(handle, runtime_module, skills, opts)
    else
      home = Keyword.fetch!(opts, :config_home)
      root = runtime_module.skills_root(home)

      with_skill_lock(handle, root, fn ->
        with :ok <-
               write_manifest(handle, Path.join(root, @manifest_name), named_manifest(selected)) do
          Managoat.Runtimes.Skills.install(handle, selected,
            runtime: runtime_module,
            config_home: home
          )
        end
      end)
    end
  end

  @doc """
  Whether any of `skills` is installed from GitHub rather than written.

  Such a skill needs the network, through the conversation's proxy, so a
  provision mounts it after the network floor and the broker CA are in place
  and passes their variables as `:env`.
  """
  @spec remote?([map()] | nil) :: boolean()
  def remote?(skills), do: Enum.any?(normalize(skills), &(not is_binary(&1["content"])))

  @doc """
  Replace the Fountain-managed skills on a machine, leaving everything else
  under the skills root alone (#1565).

  Installing is not enough once an agent's skills can change under a machine
  that outlives a wake. A skill the agent no longer names is still on the
  disk, and the runtime still reads it, so removing one from an agent would
  change nothing until the machine was rebuilt. Reconciling deletes what
  Fountain put there and is no longer selected, and only that.

  Ownership comes from these records:

  - **A manifest, written at the skills root.** It maps each selected skill
    to the directory names its install produced, so a later pass knows what
    it owns. A GitHub install without a skill name installs every skill its
    repository holds, which is why the manifest records the names the fetch
    found rather than what was asked for. They are recorded after the fetch,
    which only stages, and before the copy into the skills root, so an
    interrupted copy leaves directories the manifest owns.
  - **`previous`, used only when the manifest is absent.** The
    conversation's recorded Agent version names the skills that were
    installed, and the skills.sh source lock names the directories an unnamed
    GitHub install produced on a machine from before Managoat fetched GitHub
    skills itself. Recovery is persisted before any skill changes.
    A present manifest is authoritative; historical names are never merged
    back into it. Anything neither can account for is left where
    it is: an entry with no ownership record is somebody else's.
  - **An install left pending by the skills.sh installer.** That installer
    recorded each install's intent in the manifest first. A pass refuses a
    manifest still holding one: what that install created cannot be told
    apart from what it found.
  - **Only direct children of the skills root are ever removed**, each one
    matched against a conservative name pattern. Neither a forged manifest
    nor a legacy skill name can turn reconciliation into a delete somewhere
    else on the disk.

  A remote skill that is still selected and whose recorded directories are
  all on the disk is not installed again: a wake costs no network for it.
  One that is newly selected, has lost a directory, or is named in
  `:refresh` (its `ref` changed) is installed. A failed reinstall keeps the
  recorded directories, so the copy on the disk stays the working one.

  Returns `{:ok, failed}`: the selected remote skills whose fetch failed, as
  string-keyed maps. The library has already logged each one. A caller that
  records what the disk carries keeps its previous entry for these rather
  than the selected one, so a failed re-pin is tried again on the next pass
  instead of being recorded as applied (#2971).

  Options:

    * `:config_home` (required, here and in `mount/4` and `mount_fresh/4`) —
      the conversation's config home (`Fountain.Conversations.ConfigHome`);
      the skills root is the runtime's `skills_root/1` of it.
    * `:env` — the `{name, value}` pairs a GitHub install runs with: the
      conversation's proxy and CA variables (`Fountain.Broker.egress_env/1`).
      Without them a brokered sandbox cannot resolve the registry.
    * `:refresh` — selected remote skills to install even when present.
  """
  @spec reconcile(
          Managoat.Sandbox.Handle.t(),
          String.t() | module(),
          [map()] | nil,
          [map()] | nil,
          keyword()
        ) ::
          {:ok, [map()]} | {:error, term()}
  def reconcile(handle, runtime, skills, previous, opts \\ [])

  def reconcile(handle, runtime, skills, previous, opts) when is_binary(runtime) do
    case Fountain.RuntimeDispatch.for_agent(%{runtime: runtime, user_id: nil}) do
      {:ok, module} ->
        reconcile(handle, module, skills, previous, opts)

      {:error, reason} ->
        Logger.warning("skills not reconciled for runtime #{runtime}: #{reason}")
        {:error, reason}
    end
  end

  def reconcile(handle, runtime_module, skills, previous, opts) when is_atom(runtime_module) do
    root = runtime_module.skills_root(Keyword.fetch!(opts, :config_home))

    with_skill_lock(handle, root, fn ->
      do_reconcile(handle, runtime_module, root, skills, previous, opts)
    end)
  end

  defp do_reconcile(handle, runtime_module, root, skills, previous, opts) do
    manifest = Path.join(root, @manifest_name)
    selected = bundled() ++ (skills || [])

    with {:ok, managed} <- ensure_manifest(handle, manifest, previous),
         obsolete = obsolete_names(managed, selected),
         {:ok, _} <- run(handle, remove(root, obsolete)),
         {:ok, installed, failed} <-
           install_selected(handle, runtime_module, root, selected, managed, opts),
         :ok <- write_manifest(handle, manifest, installed) do
      {:ok, failed}
    end
  end

  # A sandbox is one conversation's (ADR 0073), but a fresh mount and a
  # reattach's reconcile can still overlap when a conversation's server is
  # replaced mid-step. Refuse the second rather than interleave two manifest
  # writers. The lock is local: this node is the only one (ADR 0072).
  defp with_skill_lock(handle, root, fun) do
    lock = {{__MODULE__, handle.provider, handle.name, root}, self()}
    nodes = [node()]

    if :global.set_lock(lock, nodes, 0) do
      try do
        fun.()
      after
        :global.del_lock(lock, nodes)
      end
    else
      {:error, :skill_reconciliation_busy}
    end
  end

  defp ensure_manifest(handle, manifest, previous) do
    case read_manifest(handle, manifest) do
      {:ok, nil} ->
        with {:ok, recovered} <- legacy_manifest(handle, previous),
             :ok <- write_manifest(handle, manifest, recovered) do
          {:ok, recovered}
        end

      {:ok, {:pending, _, _}} ->
        {:error, :skill_installation_incomplete}

      result ->
        result
    end
  end

  defp write_manifest(handle, path, state),
    do: Managoat.Sandbox.write_file(handle, path, Jason.encode!(state))

  defp read_manifest(handle, manifest) do
    # The newline distinguishes an empty (invalid) file from an absent file.
    # Reject symlinks and non-files rather than following them outside root.
    script = """
    if [ -L #{quote_shell(manifest)} ]; then
      printf 'invalid'
    elif [ -f #{quote_shell(manifest)} ]; then
      cat -- #{quote_shell(manifest)} || exit
      printf '\n'
    elif [ -e #{quote_shell(manifest)} ]; then
      printf 'invalid'
    fi
    """

    with {:ok, raw} <- run(handle, script), do: decode_manifest(raw)
  end

  # Stable across content and ref edits: a retained remote skill stays usable
  # when its best-effort reinstall is refused by the network policy.
  defp identity(skill), do: Jason.encode!([skill["source"], skill["name"]])

  defp normalize(skills),
    do: Enum.map(skills || [], fn s -> Map.new(s, fn {k, v} -> {to_string(k), v} end) end)

  defp named_manifest(skills),
    do: Map.new(normalize(skills), fn s -> {identity(s), names(s)} end)

  # skills.sh records globally installed names by source, including installs
  # made without --skill. Recover those on disks predating Fountain's own
  # manifest. Format: https://github.com/vercel-labs/skills/blob/main/src/skill-lock.ts
  defp legacy_manifest(_handle, nil), do: {:error, :legacy_skill_ownership_unknown}

  defp legacy_manifest(handle, previous) do
    unnamed = Enum.filter(normalize(previous), &(is_binary(&1["source"]) and is_nil(&1["name"])))

    if unnamed == [] do
      {:ok, named_manifest(previous)}
    else
      with {:ok, locked} <- source_lock(handle) do
        recovered =
          Map.new(unnamed, fn entry ->
            names =
              Enum.flat_map(locked, fn
                {name, %{"source" => source, "sourceType" => "github"}} ->
                  if source == entry["source"] and safe_name?(name), do: [name], else: []

                _ ->
                  []
              end)

            {identity(entry), names}
          end)

        if Enum.any?(recovered, fn {_identity, names} -> names == [] end) do
          {:error, :legacy_skill_ownership_unknown}
        else
          {:ok, Map.merge(named_manifest(previous), recovered)}
        end
      end
    end
  end

  defp source_lock(handle) do
    script = ~S"""
    if [ -n "${XDG_STATE_HOME:-}" ]; then
      skills_lock="$XDG_STATE_HOME/skills/.skill-lock.json"
    else
      skills_lock="$HOME/.agents/.skill-lock.json"
    fi
    if [ -f "$skills_lock" ]; then cat -- "$skills_lock"; fi
    """

    with {:ok, raw} <- run(handle, script) do
      case Jason.decode(raw) do
        {:ok, %{"skills" => skills}} when is_map(skills) -> {:ok, skills}
        _ -> {:ok, %{}}
      end
    end
  end

  defp decode_manifest(""), do: {:ok, nil}

  defp decode_manifest(raw) do
    case Jason.decode(raw) do
      {:ok, %{"version" => 1, "managed" => managed, "installing" => pending}} ->
        if valid_managed?(managed) and valid_pending?(pending),
          do: {:ok, {:pending, managed, pending}},
          else: {:error, :invalid_skill_manifest}

      {:ok, map} when is_map(map) ->
        if valid_managed?(map) do
          {:ok, map}
        else
          {:error, :invalid_skill_manifest}
        end

      _ ->
        {:error, :invalid_skill_manifest}
    end
  end

  defp valid_managed?(map) when is_map(map),
    do: Enum.all?(map, fn {_key, values} -> valid_names?(values) end)

  defp valid_managed?(_), do: false

  defp valid_pending?(%{
         "source" => source,
         "name" => name,
         "before" => before,
         "locked_before" => locked
       }),
       do:
         is_binary(source) and source != "" and (is_nil(name) or safe_name?(name)) and
           valid_names?(before) and valid_names?(locked)

  defp valid_pending?(_), do: false
  defp valid_names?(values), do: is_list(values) and Enum.all?(values, &safe_name?/1)

  # A name is obsolete when it belonged to a skill that is no longer selected
  # and no selected skill claims it. Two skills can produce the same directory
  # name, so a retained claim always wins over a dropped one.
  defp obsolete_names(managed, selected) do
    wanted = named_manifest(selected)
    retained = managed |> Map.take(Map.keys(wanted)) |> Map.values() |> List.flatten()
    removed = managed |> Map.drop(Map.keys(wanted)) |> Map.values() |> List.flatten()
    Enum.uniq(removed -- (retained ++ (wanted |> Map.values() |> List.flatten())))
  end

  defp install_selected(handle, runtime, root, selected, managed, opts) do
    {inline, remote} = Enum.split_with(normalize(selected), &is_binary(&1["content"]))
    env = Keyword.get(opts, :env, [])

    with {:ok, remote, present} <- remote_to_install(handle, root, remote, managed, opts),
         {:ok, installed, failed} <- install_remote(handle, root, remote, managed, present, env),
         {:ok, installed} <-
           install_inline(handle, runtime, root, inline, installed, opts[:config_home]) do
      {:ok, Map.take(installed, Enum.map(normalize(selected), &identity/1)), failed}
    end
  end

  # A remote skill whose recorded directories are all on the disk is the
  # working copy; installing it again is a network round trip at best and, on
  # a wake, the whole wake at worst (144 s on 2026-10-15). Inline skills are
  # always rewritten: they are local writes, and their content may have
  # changed.
  defp remote_to_install(_handle, _root, [], _managed, _opts), do: {:ok, [], []}

  defp remote_to_install(handle, root, remote, managed, opts) do
    refresh = opts |> Keyword.get(:refresh, []) |> normalize() |> MapSet.new(&identity/1)

    with {:ok, listed} <- run(handle, listing(root)) do
      present = entries(listed)

      {:ok,
       Enum.reject(remote, fn skill ->
         names = Map.get(managed, identity(skill), [])

         names != [] and not MapSet.member?(refresh, identity(skill)) and
           Enum.all?(names, &(&1 in present))
       end), present}
    end
  end

  # Fetch every remote skill's repository (once each, concurrently), record
  # the directories they will produce, then copy them in. Recording first
  # means a copy cut short leaves directories the manifest owns, which the
  # next pass finds missing and installs again, never directories nobody
  # owns.
  #
  # A directory that was already on the disk and not this skill's is
  # replaced but not claimed, as with skills.sh: an entry with no ownership
  # record is somebody else's. The names already recorded for a skill are
  # kept too, so a reinstall the network refused does not make the copy on
  # disk look unowned and get deleted on the next pass.
  #
  # The skills whose fetch failed are returned beside the manifest, so the
  # caller does not record them as installed.
  defp install_remote(_handle, _root, [], managed, _present, _env), do: {:ok, managed, []}

  defp install_remote(handle, root, remote, managed, present, env) do
    results = Managoat.Runtimes.Skills.stage_github(handle, root, remote, env)
    failed = for {skill, {:error, _}} <- results, do: skill

    staged =
      results
      |> Enum.map(fn
        {skill, {:ok, placements}} ->
          {skill, Enum.filter(placements, fn {name, _} -> safe_name?(name) end)}

        {skill, {:error, _}} ->
          {skill, []}
      end)

    next =
      Enum.reduce(staged, managed, fn {skill, placements}, acc ->
        new = placements |> Enum.map(&elem(&1, 0)) |> Enum.reject(&(&1 in present))
        owned = Enum.uniq(new ++ names(skill) ++ Map.get(managed, identity(skill), []))
        Map.put(acc, identity(skill), owned)
      end)

    placements = Enum.flat_map(staged, &elem(&1, 1))

    case write_manifest(handle, Path.join(root, @manifest_name), next) do
      :ok ->
        # A copy that fails is logged by the library; what landed is owned.
        _ = Managoat.Runtimes.Skills.place(handle, root, placements)
        {:ok, next, failed}

      {:error, _} = error ->
        _ = Managoat.Runtimes.Skills.place(handle, root, [])
        error
    end
  end

  defp install_inline(handle, runtime, root, inline, managed, home) do
    Enum.reduce_while(inline, {:ok, managed}, fn skill, {:ok, installed} ->
      next = Map.put(installed, identity(skill), names(skill))

      # Inline installs have an explicit destination: record it before writing.
      with :ok <- write_manifest(handle, Path.join(root, @manifest_name), next),
           :ok <-
             Managoat.Runtimes.Skills.install(handle, [skill],
               runtime: runtime,
               config_home: home
             ) do
        {:cont, {:ok, next}}
      else
        {:error, _} = error -> {:halt, error}
      end
    end)
  end

  defp names(skill), do: if(safe_name?(skill["name"]), do: [skill["name"]], else: [])

  defp safe_name?(name) when is_binary(name),
    do: Regex.match?(~r/\A[A-Za-z0-9][A-Za-z0-9._-]*\z/, name)

  defp safe_name?(_), do: false
  defp entries(text), do: text |> String.split("\n", trim: true) |> Enum.filter(&safe_name?/1)

  defp remove(root, names) do
    "mkdir -p -- #{quote_shell(root)}\n" <>
      Enum.map_join(names, "\n", fn name -> "rm -rf -- #{quote_shell(Path.join(root, name))}" end)
  end

  defp listing(root) do
    """
    for path in #{quote_shell(root)}/*; do
      [ -e "$path" ] || [ -L "$path" ] || continue
      basename -- "$path"
    done
    """
  end

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  defp run(handle, script) do
    case Managoat.Sandbox.exec(handle, "bash", ["-c", script], stderr_to_stdout: true) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, code} -> {:error, "skill reconciliation exited with #{code}"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  The directory names a mount of `skills` is sure to write under the skills
  root: the bundled skills and the agent's inline ones. A GitHub skill's
  directories are known only once it is fetched, and its install replaces
  each one whole anyway. Only plain names (no `/`, not `.` or `..`) are
  answered.
  """
  @spec inline_names([map()] | nil) :: [String.t()]
  def inline_names(skills) do
    agent =
      for s <- normalize(skills), is_binary(s["content"]), is_binary(s["name"]), do: s["name"]

    Enum.uniq(for name <- @bundled_skills ++ agent, name =~ @plain_name, do: name)
  end

  @doc """
  The bundled skills as inline entries, in the order they are mounted.
  """
  @spec bundled() :: [%{String.t() => String.t()}]
  # sobelow_skip ["Traversal.FileModule"] — fixed path assembled from
  # priv_dir and a module attribute; no user input.
  def bundled do
    Enum.map(@bundled_skills, fn name ->
      %{"name" => name, "content" => File.read!(Path.join([priv_dir(), name, "SKILL.md"]))}
    end)
  end

  defp priv_dir do
    Path.join(:code.priv_dir(:fountain) |> to_string(), @bundle_root)
  end
end
