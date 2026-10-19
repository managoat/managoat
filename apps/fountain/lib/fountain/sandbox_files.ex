defmodule Fountain.SandboxFiles do
  @moduledoc """
  Read-only views of a sandbox's disk for the apps that watch an agent work:
  a directory listing, one file's bytes, `git status` and `git diff`
  (ADR 0039).

  Three things this deliberately is not:

    * **Not exec.** The four operations are fixed scripts; the caller
      chooses a path and a few flags, never a command. Exec over the API
      would be a second I/O path beside ACP, outside the turn's audit and
      usage accounting, and unredacted.
    * **Not a new seam.** `Managoat.Sandbox` has `exec/4` on every adapter
      and no read primitive, so the scripts run through `exec` and every
      provider — Sprites, E2B — is covered without an adapter change.
      Paths cross `Managoat.Sandbox.host_path/2`, so an adapter that maps
      `/home/sprite` elsewhere still holds.
    * **Not a resume.** A parked sandbox costs nothing; a read that resumed
      it would cost provider time outside any turn. Anything but `ready`
      is refused with `{:sandbox_not_ready, status}`, decided on the row read
      under the machine's lock rather than on the struct handed in, and a
      machine a park or a destroy holds is refused `:sandbox_unavailable`.
      A read admitted first finishes before that operation calls the provider
      (`Fountain.Machines.Reads`, #2394). A machine the provider put to
      sleep by itself under a `ready` row (a sprite scaled to zero) is woken
      by the exec: ADR 0039's 2026-10-15 addendum accepts that (#2395).

  Every path is confined to the sandbox home (`/home/sprite`) or the
  conversation's working directory (its launch's `cwd`, else the runtime's
  default, `Fountain.Conversations.ConfigHome.cwd/1`), or on an explicit
  workspace's shared machine, the home or the working directory of any live
  conversation on it, with a relative path resolved from the home (ADR
  0097), and either way the eligible repository mounts of the machine's
  environment (#2999) — including the one
  the caller never names, the repository root `git rev-parse --show-toplevel`
  finds by walking up. A root outside those is `not_a_repository`, not a
  listing of it.

  File and directory targets are resolved physically before access, so a
  symlink must also stay within an allowed root. This is a path check, not
  descriptor-relative access: concurrent filesystem mutations can still race
  resolution and opening.

  Every byte that leaves goes through the same redaction the transcript
  gets: the values of the identity's environment and vault, plus whatever a
  live `ConversationServer` registered, replaced with `[REDACTED]`. The
  `.env` file is on that disk in plaintext, so this is what keeps a
  third-party app holding the user's key from reading the user's secrets
  back through it.

  Callers hand in a sandbox from the tenant-scoped
  `Fountain.Conversations.get_sandbox/2`; ownership is theirs to establish.
  """

  import Ecto.Query, only: [from: 2, select: 3, where: 3]

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Redaction
  alias Fountain.Conversations.Sandbox
  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.Machines.Reads
  alias Fountain.Repo
  alias Fountain.Vaults

  @home "/home/sprite"
  @default_max_bytes 262_144
  @max_max_bytes 4_194_304
  @max_entries 2_000
  # Status is listing-shaped, so the caller's bound is `@max_entries`, not a
  # byte count. This is the guard behind it: `-uall` on a repository with an
  # unignored build tree can emit far more than the entry cap will keep, and
  # the whole stream is read into memory before anything counts it.
  @max_status_bytes 1_048_576
  @timeout 30_000
  @ref_pattern ~r|\A[A-Za-z0-9][A-Za-z0-9._/~^@{}-]*\z|

  # Exit codes the scripts reserve. Anything else nonzero is the command
  # itself failing, surfaced with its output.
  #
  # 8 is the one nonzero code a script produces that is *not* named here:
  # git failing after the repository was found. It is deliberately left to
  # the catch-all, so the caller gets `{:sandbox_command_failed, 8, output}`
  # with git's own message rather than an error word this module invented.
  @exit_missing 3
  @exit_wrong_kind 4
  @exit_unreadable 5
  @exit_not_repository 6
  @exit_ref_not_found 7
  @exit_outside 9

  # The porcelain v1 status letters, one per side. `change_states/0` is these
  # values, so the vocabulary is written once.
  @states %{
    " " => "unchanged",
    "M" => "modified",
    "T" => "type_changed",
    "A" => "added",
    "D" => "deleted",
    "R" => "renamed",
    "C" => "copied",
    "U" => "unmerged",
    "?" => "untracked",
    "!" => "ignored"
  }

  @typedoc "A directory entry."
  @type entry :: %{name: String.t(), type: String.t(), size: non_neg_integer() | nil}

  @typedoc """
  One path `git status` reports, with the index and the working tree read
  separately. `renamed_from` is set only when that side is a rename or a copy.
  """
  @type change :: %{
          path: String.t(),
          index: String.t(),
          worktree: String.t(),
          renamed_from: String.t() | nil
        }

  @type error ::
          {:sandbox_not_ready, String.t()}
          | :sandbox_unavailable
          | :not_found
          | :invalid_path
          | :path_outside_sandbox
          | :path_not_found
          | :not_a_directory
          | :is_a_directory
          | :path_unreadable
          | :not_a_repository
          | :invalid_ref
          | :ref_not_found
          | {:sandbox_unreachable, term()}
          | {:sandbox_command_failed, integer(), String.t()}

  @doc "What the listing script classifies an entry as."
  @spec entry_types() :: [String.t()]
  def entry_types, do: ~w(file directory symlink other)

  @doc "How a file's bytes travel: the text itself, or base64 when not UTF-8."
  @spec encodings() :: [String.t()]
  def encodings, do: ~w(utf-8 base64)

  @doc """
  How `git status` describes one side of a path, its porcelain letter in
  words. An untracked path reads `untracked` on both sides, because that is
  what git reports for it (`??`), and it is the one state `diff/3` cannot
  show at all.
  """
  @spec change_states() :: [String.t()]
  def change_states, do: @states |> Map.values() |> Enum.sort()

  @doc """
  What a caller may ask `git status` to do about untracked paths: collapse an
  untracked directory to one entry (`normal`), list every file under it
  (`all`), or leave them out (`no`).
  """
  @spec untracked_modes() :: [String.t()]
  def untracked_modes, do: ~w(normal all no)

  @doc "The largest `max_bytes` a read accepts."
  @spec max_max_bytes() :: pos_integer()
  def max_max_bytes, do: @max_max_bytes

  @doc "The read size when the caller names none."
  @spec default_max_bytes() :: pos_integer()
  def default_max_bytes, do: @default_max_bytes

  @doc """
  The directories a path may live under: the sandbox home and the
  conversation's working directory (by default the same for claude and
  codex, `/tmp/…` for gemini; a launch may name its own `cwd`).

  On an explicit workspace's machine, which several conversations share
  (ADR 0097, Files), the home and the working directory of every live
  conversation on it.

  Either way, also each repository mount of the environment the machine was
  provisioned from (the workspace's), as far as
  `Fountain.Conversations.ConfigHome.eligible_mounts/1` keeps it (#2999).
  The environment is read at each request, so the scripts admit a mount only
  where it is a checkout on the machine (it has a `.git`): a mount added
  after the machine was set up names nothing that was cloned.
  The home is always first: the scripts treat the first root as the home.
  """
  @spec roots(Sandbox.t()) :: [String.t()]
  def roots(%Sandbox{} = sandbox), do: sandbox |> tagged_roots() |> Enum.map(&elem(&1, 0))

  # Each root with how the scripts are told of it: a repository mount is
  # tagged so the script admits it only where it is a checkout. A mount that
  # is also a working directory or the home counts as that, untagged.
  defp tagged_roots(%Sandbox{} = sandbox) do
    working =
      case Fountain.Workspaces.machine_kind(sandbox) do
        :explicit -> live_cwds(sandbox)
        :implicit -> [cwd(sandbox)]
      end

    Enum.uniq_by(
      [{@home, "sandbox:"} | Enum.map(working, &{&1, working_tag(&1)})] ++
        Enum.map(mount_roots(sandbox), &{&1, "mount:"}),
      &elem(&1, 0)
    )
  end

  # A working directory outside the home and /tmp was admitted at its launch
  # under a repository mount, read as the environment was then, so it is held
  # to a mount's rule: a root only inside a checkout.
  defp working_tag(dir) do
    if under?(dir, @home) or under?(dir, "/tmp"), do: "sandbox:", else: "mount:"
  end

  # ownership: the caller fetched `sandbox` tenant-scoped, and the
  # environment is read scoped to its owner.
  defp mount_roots(%Sandbox{environment_id: env_id, user_id: user_id})
       when is_binary(env_id) and is_binary(user_id) do
    env_id
    |> Fountain.Conversations.ConfigHome.repository_mounts(user_id)
    |> Fountain.Conversations.ConfigHome.eligible_mounts()
  end

  defp mount_roots(%Sandbox{}), do: []

  # ownership: the caller fetched `sandbox` tenant-scoped; its conversations
  # are the same tenant's.
  defp live_cwds(%Sandbox{} = sandbox) do
    sandbox
    |> on_machine()
    |> where([c], not is_nil(c.runtime) and c.status not in ["terminated", "failed"])
    |> select([c], %{runtime: c.runtime, cwd: c.cwd})
    |> Repo.all()
    |> Enum.map(&Fountain.Conversations.ConfigHome.cwd/1)
  end

  @doc """
  Where a relative path resolves from — the working directory of the
  conversation on this disk (one per machine since #2676): its launch's
  `cwd`, else its runtime's default, else its agent's runtime's. On an
  explicit workspace's machine, which has no one conversation's directory,
  `/home/sprite` (ADR 0097, Files).
  """
  @spec cwd(Sandbox.t()) :: String.t()
  def cwd(%Sandbox{} = sandbox) do
    case Fountain.Workspaces.machine_kind(sandbox) do
      :explicit -> @home
      :implicit -> conversation_cwd(sandbox)
    end
  end

  defp conversation_cwd(%Sandbox{} = sandbox) do
    case conversation_layout(sandbox) do
      %{runtime: _} = conv ->
        Fountain.Conversations.ConfigHome.cwd(conv)

      nil ->
        case agent_runtime(sandbox) do
          runtime when is_binary(runtime) -> Fountain.RuntimeDispatch.cwd(runtime)
          nil -> @home
        end
    end
  end

  # ownership: the caller fetched `sandbox` tenant-scoped; its conversations
  # are the same tenant's.
  defp conversation_layout(%Sandbox{id: id}) do
    Repo.one(
      from c in Conversation,
        where: c.sandbox_id == ^id and not is_nil(c.runtime),
        order_by: [desc: c.inserted_at, desc: c.id],
        limit: 1,
        select: %{runtime: c.runtime, cwd: c.cwd}
    )
  end

  defp agent_runtime(%Sandbox{} = sandbox) do
    case with_agent(sandbox) do
      %Sandbox{agent: %{runtime: runtime}} -> runtime
      _ -> nil
    end
  end

  @doc """
  Resolve a caller's path against the sandbox: relative to `cwd/1`,
  normalised, and refused unless it is one of `roots/1` or inside one.
  `nil` is the working directory itself.
  """
  @spec resolve_path(Sandbox.t(), String.t() | nil) ::
          {:ok, String.t()} | {:error, :invalid_path | :path_outside_sandbox}
  def resolve_path(%Sandbox{} = sandbox, nil), do: {:ok, cwd(sandbox)}
  def resolve_path(%Sandbox{} = sandbox, ""), do: {:ok, cwd(sandbox)}

  def resolve_path(%Sandbox{} = sandbox, path) when is_binary(path) do
    if String.contains?(path, <<0>>) or not String.valid?(path) do
      {:error, :invalid_path}
    else
      absolute = Path.expand(path, cwd(sandbox))

      if Enum.any?(roots(sandbox), &under?(absolute, &1)),
        do: {:ok, absolute},
        else: {:error, :path_outside_sandbox}
    end
  end

  def resolve_path(%Sandbox{}, _other), do: {:error, :invalid_path}

  @doc """
  The entries of a directory, directories first then by name. `path` is
  `nil` for the working directory. At most #{@max_entries} entries are
  returned; `truncated` says whether there were more.
  """
  @spec list(Sandbox.t(), String.t() | nil) ::
          {:ok, %{path: String.t(), entries: [entry()], truncated: boolean()}} | {:error, error()}
  def list(%Sandbox{} = sandbox, path) do
    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         {:ok, output} <- run(sandbox, list_script(), [absolute] ++ path_roots(sandbox)) do
      entries = parse_entries(output)
      values = secret_values(sandbox)

      {:ok,
       %{
         path: to_text(redact_with(values, absolute)),
         entries:
           entries
           |> Enum.take(@max_entries)
           |> Enum.map(fn entry -> %{entry | name: to_text(redact_with(values, entry.name))} end),
         truncated: length(entries) > @max_entries
       }}
    end
  end

  @doc """
  One file's bytes, redacted, at most `opts[:max_bytes]` of them (default
  #{@default_max_bytes}, at most #{@max_max_bytes}). `content` is the text
  itself when it is valid UTF-8 (`encoding: "utf-8"`) and base64 otherwise
  (`encoding: "base64"`); `size` is the whole file and `truncated` says
  whether `content` is short of it — because the file is longer than
  `max_bytes`, or because redaction grew what was read past the cap.

  Redaction runs before the cap, never after: `max_bytes` is the caller's to
  choose, so a cut taken first would let them place it inside a value and
  read the piece in front of it (#1907).
  """
  @spec read(Sandbox.t(), String.t(), keyword()) ::
          {:ok,
           %{
             path: String.t(),
             size: non_neg_integer(),
             truncated: boolean(),
             encoding: String.t(),
             content: String.t()
           }}
          | {:error, error()}
  def read(%Sandbox{} = sandbox, path, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes) |> clamp_max_bytes()

    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         values = secret_values(sandbox),
         # `overlap/1` bytes past the cap, so a secret lying across it is
         # whole when redaction runs; `redact_to_cap/3` cuts back down.
         {:ok, output} <-
           run(
             sandbox,
             read_script(),
             [Integer.to_string(max_bytes + overlap(values)), absolute] ++ path_roots(sandbox)
           ),
         {:ok, size, bytes} <- parse_read(output) do
      {bytes, capped?} = redact_to_cap(values, bytes, max_bytes)
      {encoding, content} = encode(bytes)

      {:ok,
       %{
         path: absolute,
         size: size,
         truncated: size > max_bytes or capped?,
         encoding: encoding,
         content: content
       }}
    end
  end

  @doc """
  `git diff` of the repository at `path` (any directory inside it), redacted.
  `opts[:staged]` compares the index instead of the working tree
  (`--cached`); `opts[:ref]` compares against a commit, branch or tag.
  `opts[:max_bytes]` caps the text like `read/3`.
  """
  @spec diff(Sandbox.t(), String.t() | nil, keyword()) ::
          {:ok,
           %{
             path: String.t(),
             repo_root: String.t(),
             staged: boolean(),
             ref: String.t() | nil,
             diff: String.t(),
             truncated: boolean()
           }}
          | {:error, error()}
  def diff(%Sandbox{} = sandbox, path, opts \\ []) do
    max_bytes = opts |> Keyword.get(:max_bytes) |> clamp_max_bytes()
    staged = Keyword.get(opts, :staged, false) == true
    ref = Keyword.get(opts, :ref)

    with :ok <- ready?(sandbox),
         {:ok, ref} <- validate_ref(ref),
         {:ok, absolute} <- resolve_path(sandbox, path),
         values = secret_values(sandbox),
         # One byte past the cap tells truncation from an exact fit, and
         # `overlap/1` past that is what lets redaction see a secret lying
         # across the cap whole.
         {:ok, output} <-
           run(
             sandbox,
             diff_script(),
             [
               absolute,
               Integer.to_string(max_bytes + 1 + overlap(values)),
               ref || "",
               if(staged, do: "1", else: "0")
             ] ++ path_roots(sandbox)
           ),
         {:ok, root, bytes} <- parse_diff(output) do
      {text, capped?} = redact_to_cap(values, bytes, max_bytes)

      {:ok,
       %{
         path: absolute,
         # A root is a path the agent chose, so it travels like the entry
         # paths beside it: through the same replacement and the same
         # recoding, not raw.
         repo_root: to_text(redact_with(values, root)),
         staged: staged,
         ref: ref,
         diff: to_text(text),
         truncated: byte_size(bytes) > max_bytes or capped?
       }}
    end
  end

  @doc """
  `git status` of the repository at `path`, one entry per changed path.

  This is the view that shows a file the agent made and never staged:
  `diff/3` compares tracked content, so an untracked file is invisible to it
  whatever flags it is given. A deletion is visible to both.

  Entries cover the whole repository whatever `path` names inside it, and
  each entry's `path` is relative to `repo_root` — that is what git's
  porcelain reports, and it is not the shape `list/2` and `read/3` use.
  `index` and `worktree` are the two porcelain columns read separately, so a
  file staged and then edited again reports both. `opts[:untracked]` is one
  of `untracked_modes/0`; anything else reads as the default, `"normal"`.
  """
  @spec status(Sandbox.t(), String.t() | nil, keyword()) ::
          {:ok,
           %{
             path: String.t(),
             repo_root: String.t(),
             branch: String.t() | nil,
             untracked: String.t(),
             entries: [change()],
             truncated: boolean()
           }}
          | {:error, error()}
  def status(%Sandbox{} = sandbox, path, opts \\ []) do
    untracked = untracked_mode(Keyword.get(opts, :untracked))

    with :ok <- ready?(sandbox),
         {:ok, absolute} <- resolve_path(sandbox, path),
         # One byte past the cap, like `diff/3`: it tells a stream that was
         # cut from one that ended on the boundary.
         {:ok, output} <-
           run(
             sandbox,
             status_script(),
             [absolute, Integer.to_string(@max_status_bytes + 1), untracked] ++
               path_roots(sandbox)
           ),
         {:ok, root, branch, body} <- parse_status(output) do
      {records, cut?} = status_records(body)
      changes = parse_changes(records)
      values = secret_values(sandbox)

      {:ok,
       %{
         path: absolute,
         repo_root: to_text(redact_with(values, root)),
         branch: branch && to_text(redact_with(values, branch)),
         untracked: untracked,
         entries: changes |> Enum.take(@max_entries) |> Enum.map(&redact_change(values, &1)),
         truncated: cut? or length(changes) > @max_entries
       }}
    end
  end

  # ── guards ─────────────────────────────────────────────────────────────

  defp ready?(%Sandbox{status: "ready"}), do: :ok
  defp ready?(%Sandbox{status: status}), do: {:error, {:sandbox_not_ready, status}}

  defp under?(path, root), do: path == root or String.starts_with?(path, root <> "/")

  # Like `clamp_max_bytes/1`: an unknown value reads as the default rather
  # than as an error. The API's own enum refuses a typo before this, so the
  # fallback only serves a direct caller of the context.
  defp untracked_mode(mode) when is_binary(mode) do
    if mode in untracked_modes(), do: mode, else: "normal"
  end

  defp untracked_mode(_), do: "normal"

  defp clamp_max_bytes(nil), do: @default_max_bytes
  defp clamp_max_bytes(n) when is_integer(n) and n > 0, do: min(n, @max_max_bytes)
  defp clamp_max_bytes(_), do: @default_max_bytes

  # The shape of a revision, not its existence — the script asks git that
  # (`ref_not_found`). No leading `-`, so a ref can never read as a flag.
  defp validate_ref(nil), do: {:ok, nil}
  defp validate_ref(""), do: {:ok, nil}

  defp validate_ref(ref) when is_binary(ref) do
    if Regex.match?(@ref_pattern, ref) and not String.contains?(ref, ".."),
      do: {:ok, ref},
      else: {:error, :invalid_ref}
  end

  defp validate_ref(_), do: {:error, :invalid_ref}

  defp with_agent(%Sandbox{agent: %Ecto.Association.NotLoaded{}} = sandbox),
    do: Repo.preload(sandbox, :agent)

  defp with_agent(%Sandbox{} = sandbox), do: sandbox

  # ── running the scripts ────────────────────────────────────────────────

  # `bash -c SCRIPT NAME ARGS…`: the path and flags are positional
  # parameters, never interpolated into the script, so a filename is data
  # whatever it contains. Paths cross `host_path/2` for an adapter that maps them.
  #
  # The exec runs inside a read admitted by `Fountain.Machines.Reads` (#2394):
  # the row is re-read under the machine's lock, a park or a destroy in flight
  # refuses the read before it reaches the provider, and one that starts after
  # it waits for it. The handle is built from the row the admission checked,
  # not from the caller's struct, which may be stale.
  defp run(%Sandbox{} = sandbox, script, args) do
    case Reads.run(sandbox.id, fn admitted, budget -> exec(admitted, script, args, budget) end) do
      {:ok, output, 0} -> {:ok, output}
      {:ok, _output, @exit_missing} -> {:error, :path_not_found}
      {:ok, _output, @exit_unreadable} -> {:error, :path_unreadable}
      {:ok, _output, @exit_not_repository} -> {:error, :not_a_repository}
      {:ok, _output, @exit_ref_not_found} -> {:error, :ref_not_found}
      {:ok, _output, @exit_outside} -> {:error, :path_outside_sandbox}
      {:ok, output, @exit_wrong_kind} -> {:error, wrong_kind(script, output)}
      {:ok, output, code} -> {:error, command_failed(sandbox, code, output)}
      {:error, {:exec, reason}} -> {:error, {:sandbox_unreachable, reason}}
      {:error, _refusal} = refusal -> refusal
    end
  end

  # The provider call, and nothing else, inside the read's window. `budget` is
  # what the window has left; it only ever shortens the timeout, never lengthens it.
  defp exec(%Sandbox{} = sandbox, script, args, budget) do
    handle =
      Managoat.Sandbox.build_handle(
        Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    args = Enum.map(args, &map_path(handle, &1))

    case Managoat.Sandbox.exec(handle, "bash", ["-c", script, "fountain-files" | args],
           timeout: min(@timeout, budget)
         ) do
      {:ok, _output, _code} = done -> done
      {:error, reason} -> {:error, {:exec, reason}}
    end
  end

  # Git's own message, on its way to a 422 body. The scripts cap a failing
  # command's diagnostic with `head -c`, which cuts on a byte and so can drop
  # half of the character that straddles the cap — a filename in a non-Latin
  # script, or a locale-translated message, is all it takes. `json/2` would
  # refuse to encode that and the caller would read a 500 instead of the
  # failure it describes, so the output is recoded like a path or a diff is.
  # Redaction runs first, over the bytes the script produced, because a
  # secret's own bytes are what `:binary.replace/4` is looking for.
  defp command_failed(%Sandbox{} = sandbox, code, output),
    do: {:sandbox_command_failed, code, to_text(redact(sandbox, output))}

  # Pair each mapped host root with its sandbox spelling. The tag keeps
  # run/3 from mapping that spelling too; both remain literal argv values.
  # A repository mount's tag is `mount:` (see `physical_root_script/0`).
  defp path_roots(sandbox),
    do: Enum.flat_map(tagged_roots(sandbox), fn {root, tag} -> [root, tag <> root] end)

  defp map_path(handle, "/" <> _ = path), do: Managoat.Sandbox.host_path(handle, path)
  defp map_path(_handle, other), do: other

  # The read script's wrong-kind is a directory; the other two want one.
  defp wrong_kind(script, _output) do
    if script == read_script(), do: :is_a_directory, else: :not_a_directory
  end

  # The exec timeout every script runs with, for the bounds suite: the read
  # window in `Fountain.Machines.Reads` has to hold it.
  @doc false
  @spec exec_timeout_ms() :: pos_integer()
  def exec_timeout_ms, do: @timeout

  # The scripts themselves, for the suite. A mocked `exec` proves what parses
  # the output and nothing about what produces it, and all three defects
  # #1596 found were in the shell rather than in the parsing.
  @doc false
  @spec script(:list | :read | :diff | :status) :: String.t()
  def script(:list), do: list_script()
  def script(:read), do: read_script()
  def script(:diff), do: diff_script()
  def script(:status), do: status_script()

  # `type \t size \t name \0` per entry; the name goes last so a tab in it
  # survives, and NUL ends it so a newline does too.
  defp list_script do
    ~S"""
    p=$1
    shift
    [ -e "$p" ] || exit 3
    [ -d "$p" ] || exit 4
    cd -- "$p" 2>/dev/null || exit 5
    physical=$(pwd -P && printf '.') || exit 5
    physical=${physical%$'\n.'}
    outside=9
    """ <>
      physical_root_script() <>
      ~S"""
      shopt -s dotglob nullglob
      for f in *; do
        if [ -L "$f" ]; then t=symlink
        elif [ -d "$f" ]; then t=directory
        elif [ -f "$f" ]; then t=file
        else t=other; fi
        s=
        if [ "$t" = file ]; then s=$(wc -c < "$f" 2>/dev/null | tr -d ' '); fi
        printf '%s\t%s\t%s\0' "$t" "$s" "$f"
      done
      """
  end

  # The size on the first line, then the first N bytes base64-encoded, so
  # the bytes survive whichever transport an adapter streams stdout over.
  defp read_script do
    ~S"""
    n=$1
    p=$2
    shift 2
    [ -e "$p" ] || exit 3
    physical=$(realpath -- "$p" 2>/dev/null && printf '.') || exit 5
    physical=${physical%$'\n.'}
    outside=9
    """ <>
      physical_root_script() <>
      ~S"""
      p=$physical
      [ -d "$p" ] && exit 4
      [ -r "$p" ] || exit 5
      wc -c < "$p" | tr -d ' '
      head -c "$n" "$p" | base64
      """
  end

  # Discover and confine in the execution namespace, then return the matched
  # root in the caller's namespace. Physical roots cover symlinked homes
  # without exposing their host paths in /diff or /git-status.
  defp git_root_script do
    ~S"""
    [ -e "$d" ] || exit 3
    [ -d "$d" ] || exit 4
    cd -- "$d" 2>/dev/null || exit 5
    physical=$(git rev-parse --show-toplevel 2>/dev/null && printf '.') || exit 6
    physical=${physical%$'\n.'}
    outside=6
    """ <>
      physical_root_script() <>
      ~S"""
      root=$confined_path
      """
  end

  # All operations compare physical paths to physical roots in the provider's
  # execution namespace. The sentinel preserves trailing newlines that command
  # substitution would otherwise trim. Git also needs the sandbox spelling.
  defp physical_root_script do
    ~S"""
    inside=
    home=
    first=1
    # The directory, or one of its ancestors below /, has a `.git`.
    in_checkout() {
      c=$1
      while [ -n "$c" ] && [ "$c" != / ]; do
        [ -e "$c/.git" ] && return 0
        c=${c%/*}
      done
      return 1
    }
    while [ "$#" -ge 2 ]; do
      named=$1
      case $2 in
        mount:*) mount=1; logical=${2#mount:} ;;
        *) mount=; logical=${2#sandbox:} ;;
      esac
      shift 2
      if r=$(cd -- "$named" 2>/dev/null && pwd -P && printf '.'); then
        r=${r%$'\n.'}
      else
        r=
      fi
      # The first root is the home, whether or not it resolves: one that does
      # not is no root, and nothing lies under it. Any other is a working
      # directory or a repository mount, and is a root only where it
      # physically lies: exactly where it is named (no symlink anywhere on
      # its path), under the home, or under /tmp for one that names /tmp. A
      # root replaced by a symlink to somewhere else (another process on a
      # shared machine can make one) does not carry the read there; which
      # names may be roots at all is the server's rule. `/tmp` is read in the
      # execution namespace as it is named, so an adapter that mapped it
      # elsewhere would refuse such roots rather than widen them.
      if [ -n "$first" ]; then
        first=
        home=$r
        [ -n "$r" ] || continue
      elif [ -z "$r" ] || [ -z "$home" ]; then
        # With no home, no other root counts either: the home that did not
        # resolve may be the one a working directory was checked against.
        continue
      elif [ -n "$mount" ] && ! in_checkout "$r"; then
        # A repository mount, or a working directory outside the home and
        # /tmp (which can only lie under one), is a root only inside a
        # checkout: the environment is read as it is now, and a mount added
        # to it after the machine was set up names a directory nothing
        # cloned to.
        continue
      elif [ "$r" != "$named" ]; then
        case $logical in
          /tmp|/tmp/*) base=$(cd /tmp 2>/dev/null && pwd -P) || continue ;;
          *) base=$home ;;
        esac
        case $r in
          "$base"|"$base"/*) ;;
          *) continue ;;
        esac
      fi
      case $physical in
        "$r"|"$r"/*) confined_path="$logical${physical#"$r"}"; inside=1; break ;;
      esac
    done
    [ -n "$inside" ] || exit "$outside"
    """
  end

  # The repository root, NUL-terminated, then the diff base64-encoded. A
  # newline would not do: a directory name may contain one.
  # The ref is verified first because a pipeline's status is `base64`'s,
  # which would turn an unknown ref into an empty diff. `--no-optional-locks`
  # keeps a read from contending with the agent's own git for the index.
  #
  # `path_roots/1` follows the arguments, and the discovered root has to be one of
  # them or under one — see `status_script/0` for why.
  # Retain git's status, allowing SIGPIPE from the intentional byte cap. Keep
  # encoded output private until success: on failure the catch-all redacts raw
  # diagnostics, which cannot redact a partial base64-encoded diff.
  defp diff_script do
    ~S"""
    d=$1
    n=$2
    ref=$3
    staged=$4
    shift 4
    """ <>
      git_root_script() <>
      ~S"""
      if [ -n "$ref" ]; then
        git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1 || exit 7
      fi
      if [ "$staged" = 1 ]; then set -- --cached; else set --; fi
      if [ -n "$ref" ]; then set -- "$@" "$ref"; fi
      encoded=$(
        set -o pipefail
        git --no-pager --no-optional-locks diff --no-color --no-ext-diff "$@" | head -c "$n" | base64
      )
      case $? in
        0|141) printf '%s\0%s' "$root" "$encoded" ;;
        *)
          git --no-pager --no-optional-locks diff --no-color --no-ext-diff "$@" 2>&1 >/dev/null | head -c 4096
          exit 8
          ;;
      esac
      """
  end

  # The repository root and the branch NUL-terminated, then the porcelain
  # records as they come: `-z` already frames them with NUL, so unlike a
  # file's bytes they need no base64 to survive a transport. The header is
  # framed the same way for the same reason — a path may hold a newline and
  # cannot hold a NUL.
  #
  # The branch is asked for separately rather than parsed out of the `-b`
  # header, whose one line has to carry "no branch", "no commits yet" and an
  # ahead/behind suffix; an empty second line is a detached HEAD.
  # `--no-optional-locks` matters more here than for a diff, because a plain
  # `git status` refreshes the index: without it a read takes `index.lock`
  # and breaks the agent's own commit.
  #
  # The mode chooses between fixed flags rather than reaching the command
  # line, so caller data is never adjacent to a `--`.
  #
  # `path_roots/1` follows the three arguments, and the root `rev-parse` discovers
  # has to be one of them or under one. `resolve_path/2` confines the
  # *request*; `--show-toplevel` then walks up its ancestors, and without this
  # check a repository above the sandbox answers instead — inert on Sprites,
  # where no ancestor of `/home/sprite` is one, but not on a backend whose
  # sandbox is a directory under a repository. A root outside is `exit 6`, the same
  # `not_a_repository` a caller gets for a plain directory: there is no
  # repository *here*, and saying which one was found above would answer the
  # question the check exists to refuse. The physical root goes in the
  # comparison too, because `--show-toplevel` resolves symlinks and a root
  # reached through one would otherwise read as outside.
  #
  # The last command is a pipeline, so the script's own status is `head`'s and
  # is always 0. `${PIPESTATUS[0]}` is git's, and it is the difference between
  # a clean tree and a repository git could not read at all — a corrupt
  # `.git/index`, or an LFS clone with no `git-lfs` on PATH, otherwise answers
  # a rewritten tree with `entries: []`. `set -o pipefail` is the wrong
  # instrument: `head -c` closes the pipe at the byte cap, git dies of SIGPIPE
  # with status 141, and the truncation this script asks for would read as a
  # failure. So 141 passes with 0, and everything else exits 8 carrying git's
  # own message — collected by a second run that reads only stderr, because
  # `exec/4` leaves `stderr_to_stdout: false` and the first run's went
  # nowhere. Merging stderr into stdout instead would interleave a git warning
  # into the NUL-framed records on the *success* path, which is a worse trade
  # than a second invocation on a path that has already failed.
  defp status_script do
    ~S"""
    d=$1
    n=$2
    untracked=$3
    shift 3
    """ <>
      git_root_script() <>
      ~S"""
      branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null)
      printf '%s\0%s\0' "$root" "$branch"
      case $untracked in
        all) set -- --untracked-files=all ;;
        no) set -- --untracked-files=no ;;
        *) set -- --untracked-files=normal ;;
      esac
      git --no-pager --no-optional-locks status --porcelain=v1 -z "$@" | head -c "$n"
      st=${PIPESTATUS[0]}
      case $st in
        0|141) ;;
        *)
          git --no-pager --no-optional-locks status --porcelain=v1 "$@" 2>&1 >/dev/null | head -c 4096
          exit 8
          ;;
      esac
      """
  end

  # ── parsing ────────────────────────────────────────────────────────────

  defp parse_entries(output) do
    output
    |> String.split(<<0>>, trim: true)
    |> Enum.flat_map(fn record ->
      case String.split(record, "\t", parts: 3) do
        [type, size, name] -> [%{name: name, type: type, size: parse_size(size)}]
        _ -> []
      end
    end)
    |> Enum.sort_by(fn %{name: name, type: type} ->
      {if(type == "directory", do: 0, else: 1), String.downcase(name), name}
    end)
  end

  defp parse_size(""), do: nil

  defp parse_size(size) do
    case Integer.parse(size) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp parse_read(output) do
    with [size_line, encoded] <- String.split(output, "\n", parts: 2),
         {size, ""} <- Integer.parse(String.trim(size_line)),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      {:ok, size, bytes}
    else
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable read output"}}
    end
  end

  # The header is framed with NUL like the records are, not with a newline:
  # a directory name may contain a newline and may not contain a NUL, so a
  # repository at `<home>/re\npo` otherwise reported `repo_root` as
  # `<home>/re` and read the rest of its own path as the payload.
  defp parse_diff(output) do
    with [root, encoded] <- String.split(output, <<0>>, parts: 2),
         {:ok, bytes} <- Base.decode64(encoded, ignore: :whitespace) do
      {:ok, root, bytes}
    else
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable diff output"}}
    end
  end

  # NUL-framed for the reason `parse_diff/1` gives, and here it cost an entry
  # as well as the header: the branch read as the tail of the root's own path,
  # and the one real record decoded from bytes that were never a record and
  # was dropped — `entries: []` for a repository with a change.
  defp parse_status(output) do
    case String.split(output, <<0>>, parts: 3) do
      [root, branch, body] -> {:ok, root, blank_to_nil(branch), body}
      _ -> {:error, {:sandbox_command_failed, 0, "unparseable status output"}}
    end
  end

  defp blank_to_nil(branch) do
    case String.trim(branch) do
      "" -> nil
      name -> name
    end
  end

  # Only a NUL-terminated record is whole, so the last element of the split is
  # either the empty string (the stream ended on a boundary) or a record the
  # byte cap cut in half. Either way it is not an entry. A body one byte past
  # the cap is a cut that landed on a boundary, which the tail cannot show.
  defp status_records(body) do
    {tail, records} = body |> :binary.split(<<0>>, [:global]) |> List.pop_at(-1)
    {records, tail != "" or byte_size(body) > @max_status_bytes}
  end

  # `XY <path>`, and for a rename or a copy the origin follows as its own
  # record: `-z` drops git's arrow and reverses the pair, so the destination
  # comes first and the origin second.
  defp parse_changes(records), do: records |> parse_changes([]) |> Enum.sort_by(& &1.path)

  defp parse_changes([], acc), do: acc

  defp parse_changes([record | rest], acc) do
    case decode_record(record) do
      {:ok, change, :with_origin} ->
        case rest do
          # The origin was past the byte cap. Keep the destination and lose
          # the origin rather than read the next entry as one.
          [] -> parse_changes([], [change | acc])
          [origin | rest] -> parse_changes(rest, [%{change | renamed_from: origin} | acc])
        end

      {:ok, change, :plain} ->
        parse_changes(rest, [change | acc])

      :error ->
        parse_changes(rest, acc)
    end
  end

  defp decode_record(<<index::binary-1, worktree::binary-1, " ", path::binary>>)
       when path != "" do
    with {:ok, index_state} <- decode_state(index),
         {:ok, worktree_state} <- decode_state(worktree) do
      change = %{path: path, index: index_state, worktree: worktree_state, renamed_from: nil}
      origin? = index in ~w(R C) or worktree in ~w(R C)
      {:ok, change, if(origin?, do: :with_origin, else: :plain)}
    end
  end

  defp decode_record(_record), do: :error

  defp decode_state(letter), do: Map.fetch(@states, letter)

  # ── output ─────────────────────────────────────────────────────────────

  defp encode(bytes) do
    if String.valid?(bytes), do: {"utf-8", bytes}, else: {"base64", Base.encode64(bytes)}
  end

  # A diff is text by construction (git says "Binary files differ" for the
  # rest), but a latin-1 source file makes an invalid UTF-8 hunk; recode it
  # rather than refuse the whole diff.
  defp to_text(bytes) do
    if String.valid?(bytes), do: bytes, else: :unicode.characters_to_binary(bytes, :latin1)
  end

  # ── redaction ──────────────────────────────────────────────────────────

  defp redact(%Sandbox{} = sandbox, bytes) when is_binary(bytes),
    do: redact_with(secret_values(sandbox), bytes)

  # `secret_values/1` reads the vault and the environment, so a caller that
  # needs the values for something else too looks them up once.
  defp redact_with([], bytes), do: bytes

  defp redact_with(values, bytes),
    do: :binary.replace(bytes, values, Redaction.placeholder(), [:global])

  # A path is data the agent chose, so it goes through redaction like file
  # content does, and through `to_text/1` because git reports a name verbatim
  # and a byte sequence that is not UTF-8 would fail to encode as JSON.
  defp redact_change(values, change) do
    %{
      change
      | path: to_text(redact_with(values, change.path)),
        renamed_from: change.renamed_from && to_text(redact_with(values, change.renamed_from))
    }
  end

  # Redaction has to see a secret whole: `:binary.replace/4` matches the
  # value's own bytes, so a cut through one leaves a prefix that matches
  # nothing and travels on in the clear. The scripts cut first, with
  # `head -c`, and on `read/3` the cut lands at `max_bytes` — which the
  # caller chooses, making an incidental boundary case a repeatable one
  # (#1907). So the scripts are asked for `overlap/1` bytes past the cap,
  # redaction runs over that, and only then is the result cut to the cap.
  #
  # Returns the bytes and whether that last cut dropped anything, which it
  # can when a value is shorter than the placeholder standing in for it.
  defp redact_to_cap(values, bytes, max_bytes) do
    kept = binary_part(bytes, 0, cut_at(values, bytes, max_bytes))
    redacted = redact_with(values, kept)

    if byte_size(redacted) > max_bytes,
      do: {binary_part(redacted, 0, max_bytes), true},
      else: {redacted, false}
  end

  # How much of `bytes` survives into redaction: the cap, carried forward to
  # the end of a value lying across it. At most one value can, because
  # matches do not overlap, and `:binary.matches/2` picks the same ones
  # `:binary.replace/4` will.
  #
  # Cutting at the cap instead is the defect. Cutting *after* redacting is
  # not the fix either: an earlier value replaced by a shorter placeholder
  # shifts the bytes behind it, which can pull an unmatched fragment out of
  # the overlap and back inside the cap.
  defp cut_at([], bytes, max_bytes), do: min(byte_size(bytes), max_bytes)

  defp cut_at(values, bytes, max_bytes) do
    limit = min(byte_size(bytes), max_bytes)

    bytes
    |> :binary.matches(values)
    |> Enum.find_value(limit, fn {start, length} ->
      if start < limit and start + length > limit, do: start + length
    end)
  end

  # How far past the cap a value can lie across it: one byte less than the
  # longest, which `secret_values/1` sorts to the front. Ask a script for
  # that many bytes more and any value with a byte inside the cap arrives
  # whole.
  defp overlap([]), do: 0
  defp overlap([longest | _]), do: byte_size(longest) - 1

  # The identity's own values (what `.env` on that disk holds) plus what any
  # live server registered — the latter covers the inference credential and
  # the callback token, which come from Fountain rather than the identity.
  # Longest first, like `Redaction.put/2`, so a value that contains another
  # is replaced whole.
  defp secret_values(%Sandbox{} = sandbox), do: redaction_values(sandbox)

  @doc """
  What a read of `sandbox` redacts, longest first: the values of its
  environment and vault, and whatever a live server of a conversation on it
  registered. Also what a failed workspace's `error` is redacted with
  (`Fountain.Workspaces.describe_failure/2`). `sandbox` is the caller's,
  established by a scoped fetch or by the machine's own owner.
  """
  @spec redaction_values(Sandbox.t()) :: [String.t()]
  def redaction_values(%Sandbox{} = sandbox) do
    (identity_values(sandbox) ++ registered_values(sandbox))
    |> Enum.filter(&(is_binary(&1) and byte_size(&1) >= Redaction.min_length()))
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  # Every conversation on the machine, and on an explicit workspace's every
  # conversation of the workspace: one moved to a rebuilt machine by its wake
  # can be running there a moment before its row names it (ADR 0097).
  defp registered_values(%Sandbox{} = sandbox) do
    sandbox
    |> on_machine()
    |> select([c], c.id)
    |> Repo.all()
    |> Enum.flat_map(&Redaction.lookup/1)
  end

  # ownership: the caller fetched `sandbox` tenant-scoped; its workspace's
  # conversations are the same tenant's.
  defp on_machine(%Sandbox{id: id, workspace_id: workspace_id} = sandbox) do
    if is_binary(workspace_id) and Fountain.Workspaces.machine_kind(sandbox) == :explicit,
      do: from(c in Conversation, where: c.sandbox_id == ^id or c.workspace_id == ^workspace_id),
      else: from(c in Conversation, where: c.sandbox_id == ^id)
  end

  defp identity_values(%Sandbox{environment_id: nil, vault_id: nil}), do: []

  defp identity_values(%Sandbox{user_id: user_id} = sandbox) do
    case Crypto.load_tenant_key(user_id) do
      {:ok, dek} ->
        # Ownership: the sandbox row is the caller's (scoped get_sandbox);
        # its environment and vault are fetched scoped to the same tenant.
        env =
          sandbox.environment_id && Environments.get_environment(sandbox.environment_id, user_id)

        vault = sandbox.vault_id && Vaults.get_vault(sandbox.vault_id, user_id)

        env_values = if env, do: Map.values(Environments.decrypted_env(env, dek)), else: []
        vault_values = if vault, do: Map.values(Vaults.decrypted_env(vault, dek)), else: []
        env_values ++ vault_values

      _ ->
        []
    end
  end
end
