defmodule Fountain.Conversations.ConfigHome do
  @moduledoc """
  A conversation's config home and working directory (ADR 0097, step 1).

  **The config home** is the directory the conversation's runtime keeps its
  configuration in: skills, the instructions file, MCP servers, its session
  store and its inference credential files. A conversation launched since
  ADR 0097 has one of its own, `/home/sprite/.managoat/c/<conversation_id>`,
  recorded on the row at launch (`config_home`) and fixed for its life. The
  runtime is pointed at it by one variable (`CLAUDE_CONFIG_DIR`, `CODEX_HOME`
  or `GEMINI_CLI_HOME`, see `Managoat.Runtimes.Layout`), which the
  conversation's every process carries.

  **A conversation from before that** has no `config_home` on its row. Its
  runtime session and its skills are in the shared directory its runtime used
  then (`~/.claude`, `~/.codex`, and `/tmp` for gemini, whose `HOME` it was),
  so `home/1` answers that directory for it, and the same variable points the
  runtime there. There is one code path: every reader asks `home/1`, and the
  legacy directory is only the value a row with no recorded home gets. It is
  not moved on wake: a reattached adapter from the previous release may still
  be running in it, and the conversation's sandbox goes when it ends, so the
  legacy layout drains out with the conversations that have it.

  **The working directory** is the launch's `cwd`, or the runtime's default
  (`Fountain.RuntimeDispatch.cwd/1`) when it named none, which is also what a
  conversation from before the field runs in. `validate_cwd/3` is the rule a
  launch is held to; `ensure/2` creates both directories on the machine
  before the adapter is spawned there.

  **Repository mounts** (#2999). Besides the image's home (and `/tmp` for
  gemini), a `cwd` may lie under the `mount_path` of a repository of the
  environment the launch resolves, so a checkout cloned to `/work/app` can be
  the agent's working directory. Only an eligible mount counts
  (`eligible_mounts/1`): normalised, not `/`, not overlapping the directory
  config homes live in, and not in a system tree. The same mounts are roots
  of `Fountain.SandboxFiles`.

  **Ending a conversation** removes its config home (`remove/2`), best
  effort, after its adapter has stopped. In this step the sandbox is
  destroyed straight after, so the removal matters only once a machine can
  outlive one of its conversations (ADR 0097's later steps); a legacy home is
  shared and is never removed.
  """

  require Logger

  alias Fountain.Conversations.Conversation
  alias Managoat.Runtimes.Layout

  # Where a launch's `cwd` may point: the image's home for every runtime, and
  # gemini's own default tree as well (its default cwd is under /tmp).
  @image_home Layout.image_home()
  @gemini_roots ["/tmp"]
  @max_cwd 1024

  # Trees a repository mount never makes a working directory or a file-read
  # root, whatever an environment names: the kernel's views, devices, the
  # system's configuration and binaries, root's home and runtime state. An
  # environment may still clone there; it only does not widen the rule.
  # `/.sprite` is the Sprites runtime's own; another user's home under `/home`
  # is refused by `eligible_mount?/1` beside these.
  @system_trees ~w(/.sprite /bin /boot /dev /etc /lib /lib32 /lib64 /libx32 /nix /proc /root /run /sbin /snap /sys /usr /var)

  @doc "The config home a conversation launched now gets: its own, by id."
  @spec for_launch(String.t()) :: String.t()
  def for_launch(conversation_id), do: Layout.config_home(conversation_id)

  @doc """
  The conversation's config home: the one on its row, or for a row from
  before config homes, the shared directory its runtime used then.
  """
  @spec home(map()) :: String.t()
  def home(%{config_home: home}) when is_binary(home) and home != "", do: home
  def home(conv), do: legacy_home(runtime(conv))

  @doc """
  The shared directory `runtime` used as its config home before ADR 0097.
  The `acp` runtime borrowed claude's tree (`Fountain.CommandRuntime`).
  """
  @spec legacy_home(String.t() | nil) :: String.t()
  def legacy_home(runtime), do: Layout.legacy_home(runtime) || Layout.legacy_home("claude")

  @doc "The working directory the conversation's agent runs in."
  @spec cwd(map()) :: String.t()
  def cwd(%{cwd: cwd}) when is_binary(cwd) and cwd != "", do: cwd
  def cwd(conv), do: Fountain.RuntimeDispatch.cwd(runtime(conv))

  @doc """
  The directories a launch's `cwd` may lie in (or be) for `runtime`:
  `/home/sprite` for every runtime, `/tmp` too for gemini, whose default
  working directory is there, and each of `mounts` that `eligible_mounts/1`
  keeps.
  """
  @spec cwd_roots(String.t() | nil, [String.t()]) :: [String.t()]
  def cwd_roots(runtime, mounts \\ [])

  def cwd_roots("gemini", mounts),
    do: Enum.uniq([@image_home | @gemini_roots] ++ eligible_mounts(mounts))

  def cwd_roots(_runtime, mounts), do: Enum.uniq([@image_home | eligible_mounts(mounts)])

  @doc """
  The repository mount paths (an environment's `mount_path`s) that may be a
  working directory or contain one, and that the file reads take as roots.
  Each is normalised (`.` and `..` resolved, no trailing slash), and kept
  only when it is absolute, free of control characters, not `/`, neither in
  nor around `/home/sprite/.managoat` (so never the home or an ancestor of
  it), not under another user's home in `/home`, and not in a system tree
  (`/etc`, `/proc`, `/usr`, `/var` and the
  like). A mount refused here is still cloned; it is only no root.
  """
  @spec eligible_mounts([String.t()] | nil) :: [String.t()]
  def eligible_mounts(mounts) when is_list(mounts) do
    for mount <- mounts,
        is_binary(mount),
        {:ok, normalized} <- [normalize(mount)],
        eligible_mount?(normalized),
        uniq: true,
        do: normalized
  end

  def eligible_mounts(_mounts), do: []

  defp eligible_mount?("/"), do: false

  defp eligible_mount?(mount) do
    not under?(mount, managoat_dir()) and not under?(managoat_dir(), mount) and
      not Enum.any?(@system_trees, &under?(mount, &1)) and
      (under?(mount, @image_home) or not under?(mount, "/home"))
  end

  @doc """
  The repository mounts of environment `environment_id`, read scoped to
  `user_id`: what a launch's `cwd` may also lie under (`validate_cwd/3`). A
  nil id, or an environment that is not the user's, has none.
  """
  @spec repository_mounts(String.t() | nil, String.t()) :: [String.t()]
  def repository_mounts(nil, _user_id), do: []

  def repository_mounts(environment_id, user_id)
      when is_binary(environment_id) and is_binary(user_id) do
    environment_id
    |> Fountain.Environments.get_environment(user_id)
    |> Fountain.Environments.Environment.repository_mounts()
  end

  @doc """
  Check a launch's `cwd` for `runtime` and normalise it.

  `nil` (or an empty string) asks for nothing: the runtime's default stands,
  and nil is what is recorded. Otherwise it must be an absolute path of at
  most #{@max_cwd} bytes with no control characters, under one of
  `cwd_roots/2` once `.` and `..` are resolved (`mounts` are the repository
  mounts of the environment the launch resolves, `repository_mounts/2`), and
  not inside the directory config homes live in. It is answered normalised
  (`/home/sprite/a/../b/` is `/home/sprite/b`). A refusal is a changeset
  error on `:cwd`, which the API renders as `422 validation_failed` naming
  the field.
  """
  @spec validate_cwd(term(), String.t() | nil, [String.t()]) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def validate_cwd(cwd, runtime, mounts \\ [])
  def validate_cwd(cwd, _runtime, _mounts) when cwd in [nil, ""], do: {:ok, nil}

  def validate_cwd(cwd, runtime, mounts) when is_binary(cwd) do
    roots = cwd_roots(runtime, mounts)

    with {:ok, normalized} <- normalize(cwd) do
      cond do
        not Enum.any?(roots, &under?(normalized, &1)) ->
          refuse("must be #{Enum.join(roots, " or ")}, or a directory under it")

        under?(normalized, managoat_dir()) ->
          refuse("must not be inside #{managoat_dir()}")

        true ->
          {:ok, normalized}
      end
    end
  end

  def validate_cwd(_cwd, _runtime, _mounts), do: refuse("must be a string")

  @doc """
  `validate_cwd/3` for a launch that resolved environment `environment_id`
  for `user_id`: the agent's own, the one the launch named, or the
  workspace's. The environment is read only when a `cwd` was named.
  """
  @spec validate_launch_cwd(term(), String.t() | nil, String.t() | nil, String.t()) ::
          {:ok, String.t() | nil} | {:error, Ecto.Changeset.t()}
  def validate_launch_cwd(cwd, runtime, _environment_id, _user_id) when cwd in [nil, ""],
    do: validate_cwd(cwd, runtime)

  def validate_launch_cwd(cwd, runtime, environment_id, user_id),
    do: validate_cwd(cwd, runtime, repository_mounts(environment_id, user_id))

  defp normalize(path) do
    cond do
      byte_size(path) > @max_cwd ->
        refuse("must be at most #{@max_cwd} bytes")

      not String.valid?(path) or String.match?(path, ~r/[\x00-\x1f\x7f]/) ->
        refuse("must not contain control characters")

      not String.starts_with?(path, "/") ->
        refuse("must be an absolute path")

      true ->
        {:ok, Path.expand(path)}
    end
  end

  defp managoat_dir, do: Path.dirname(Layout.config_homes())

  @doc """
  On a resume, a `cwd` the request names must be the one the conversation
  runs in: it is fixed for the conversation's life. nil asks for nothing.
  """
  @spec check_resume(Conversation.t(), term()) :: :ok | {:error, Ecto.Changeset.t()}
  def check_resume(_conv, cwd) when cwd in [nil, ""], do: :ok

  # The directory it runs in was checked at launch against the environment's
  # mounts as they were then, so naming it again resumes whatever the
  # environment says now. Anything else is held to the launch rule first,
  # for its message, then refused as a change.
  def check_resume(conv, cwd) when is_binary(cwd) do
    with {:ok, requested} <- normalize(cwd) do
      if requested == cwd(conv), do: :ok, else: refuse_change(conv, cwd)
    end
  end

  def check_resume(_conv, _cwd), do: refuse("must be a string")

  defp refuse_change(conv, cwd) do
    with {:ok, _} <- validate_cwd(cwd, runtime(conv)) do
      refuse("is fixed for the conversation's life; it runs in #{cwd(conv)}")
    end
  end

  @doc """
  Create the conversation's working directory, and its config home beside
  it, on the machine behind `handle` before its adapter is spawned there.
  Idempotent, so every provision, wake and reattach runs it.

  Only a launch that named its own `cwd` costs an exec. A runtime's default
  working directory is always there (`/home/sprite`, or gemini's, which its
  `prepare_sandbox/4` creates), and the config home is created by the first
  file written into it: the runtime's settings, its skills, its credential
  file.
  """
  @spec ensure(Managoat.Sandbox.Handle.t(), map()) :: :ok | {:error, term()}
  def ensure(handle, conv) do
    if Map.get(conv, :cwd) in [nil, ""], do: :ok, else: make_directories(handle, conv)
  end

  defp make_directories(handle, conv) do
    cwd = cwd(conv)
    # A cwd outside the home and /tmp was admitted under a repository mount,
    # read as the environment is now: it must lie in a checkout.
    checkout = if under?(cwd, @image_home) or under?(cwd, "/tmp"), do: "", else: "checkout"
    args = [home(conv), cwd, managoat_dir(), checkout]

    case Managoat.Sandbox.Retry.with_backoff(
           fn ->
             Managoat.Sandbox.exec(
               handle,
               "bash",
               ["-c", directories_script(), "fountain-dirs" | args],
               timeout: 15_000
             )
           end,
           label: "conversation directories"
         ) do
      {:ok, _out, 0} -> :ok
      {:ok, _out, 7} -> {:error, {:conversation_directories, :cwd_inside_config_homes}}
      {:ok, _out, 8} -> {:error, {:conversation_directories, :cwd_not_in_checkout}}
      {:ok, _out, code} -> {:error, {:conversation_directories, {:exit, code}}}
      {:error, reason} -> {:error, {:conversation_directories, reason}}
    end
  end

  @doc false
  # The script `ensure/2` runs, for the suite. `validate_cwd/3` refuses a cwd
  # inside the config homes by name only; a repository mount (or an ancestor
  # of it) that something on the machine replaced with a symlink into them
  # would put this conversation's agent in another's config home. So the
  # nearest existing ancestor of the cwd is resolved physically before
  # anything is created there, and the cwd itself after, and either inside
  # the physical config-homes directory is exit 7. With `checkout` (a cwd
  # outside the home and /tmp, so under a repository mount), the nearest
  # existing ancestor must lie in a checkout (it or an ancestor below `/` has
  # a `.git`), or it is exit 8: a mount added to the environment after the
  # machine was set up names nothing cloned. Paths are positional parameters,
  # never interpolated. These are checks at launch, not a guarantee: something
  # with root on the machine can swap a directory for a symlink afterwards.
  @spec directories_script() :: String.t()
  def directories_script do
    ~S"""
    home=$1
    cwd=$2
    managoat=$3
    checkout=$4
    in_checkout() {
      c=$1
      while [ -n "$c" ] && [ "$c" != / ]; do
        [ -e "$c/.git" ] && return 0
        c=${c%/*}
      done
      return 1
    }
    inside() {
      p=$(cd -- "$1" 2>/dev/null && pwd -P && printf '.') || exit 1
      p=${p%$'\n.'}
      case $p in "$m"|"$m"/*) exit 7 ;; esac
    }
    mkdir -p -- "$managoat" "$home" || exit 1
    m=$(cd -- "$managoat" && pwd -P && printf '.') || exit 1
    m=${m%$'\n.'}
    d=$cwd
    while [ ! -e "$d" ] && [ "$d" != / ]; do d=$(dirname -- "$d"); done
    inside "$d"
    if [ -n "$checkout" ]; then in_checkout "$p" || exit 8; fi
    mkdir -p -- "$cwd" || exit 1
    inside "$cwd"
    """
  end

  @doc """
  Remove the conversation's config home from the machine behind `handle`,
  best effort: a failure is logged and answered `:ok`, because the
  conversation is ending either way. Only a conversation's own home is
  removed (`Managoat.Runtimes.Layout.conversation_home?/1`); a legacy home is
  shared with whatever else ran there and is left alone. Never logs a value
  from inside the directory.
  """
  @spec remove(Managoat.Sandbox.Handle.t() | nil, map()) :: :ok
  def remove(nil, _conv), do: :ok

  def remove(handle, conv) do
    home = home(conv)

    if Layout.conversation_home?(home) do
      case Managoat.Sandbox.exec(handle, "bash", ["-c", "rm -rf -- #{quote_shell(home)}"],
             timeout: 5_000
           ) do
        {:ok, _out, 0} ->
          :ok

        other ->
          Logger.info("conv #{conv.id}: config home not removed: #{inspect(outcome(other))}")
          :ok
      end
    else
      :ok
    end
  end

  defp outcome({:ok, _out, code}), do: {:exit, code}
  defp outcome({:error, reason}), do: reason

  defp refuse(message) do
    {:error,
     %Conversation{}
     |> Ecto.Changeset.change()
     |> Ecto.Changeset.add_error(:cwd, message)
     |> Map.put(:action, :insert)}
  end

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # A conversation's runtime is validated-required and outlives its agent.
  defp runtime(%{runtime: runtime}) when is_binary(runtime), do: runtime
  defp runtime(_conv), do: "claude"

  defp quote_shell(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"
end
