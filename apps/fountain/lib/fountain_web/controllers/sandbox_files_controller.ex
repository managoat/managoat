defmodule FountainWeb.SandboxFilesController do
  @moduledoc """
  A sandbox's disk, read-only: a directory listing, one file, `git status`
  and `git diff` (ADR 0039). What an app that watches an agent work needs
  once the transcript is not enough — and deliberately not exec.

  Full scope only: a sandbox's own `sprite` token must not be able to read
  another sandbox of the same tenant, whose disk holds a different vault.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.SandboxFiles
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Sandboxes"])

  @path_param [
    in: :query,
    type: :string,
    required: false,
    description:
      "In-sandbox path, absolute or relative to the conversation's working directory " <>
        "(its launch's `cwd`, else `/home/sprite` for claude and codex and " <>
        "`/tmp/gemini-workspace` for gemini). Confined to `/home/sprite` and that " <>
        "directory: anything else is `422 path_outside_sandbox`. On an explicit workspace's machine, " <>
        "which several conversations share, a relative path resolves from `/home/sprite` " <>
        "and the working directory of every live conversation there is also allowed."
  ]

  @max_bytes_param [
    in: :query,
    type: :integer,
    required: false,
    description:
      "How many bytes to return, at most #{SandboxFiles.max_max_bytes()} " <>
        "(default #{SandboxFiles.default_max_bytes()}). `truncated` says whether " <>
        "the content stopped short."
  ]

  @not_ready {"Sandbox is not ready", "application/json", Schemas.Error}

  # Said once and appended to each operation's description, because the four
  # behave the same way when the machine is asleep (ADR 0039 decision 6 and its
  # 2026-10-15 addendum).
  @parked " Only a `ready` sandbox answers: a sandbox Managoat parked (`suspended`) is " <>
            "`409 sandbox_not_ready` and a read never resumes it. A `ready` sandbox the " <>
            "provider put to sleep by itself (a sprite scaled to zero, an E2B sandbox paused " <>
            "on its timeout) is woken by the read, and that provider time is billed."
  @unreachable {"Sandbox provider unreachable, or the sandbox is being parked or destroyed " <>
                  "(`sandbox_unavailable`, with `Retry-After`)", "application/json",
                Schemas.Error}

  operation(:index,
    summary: "List a directory on a sandbox",
    description:
      "The entries of one directory, directories first then by name. Without `path`, " <>
        "the agent's working directory (on an explicit workspace's machine, `/home/sprite`). A sandbox being parked or destroyed is " <>
        "`503 sandbox_unavailable`; retry after the `Retry-After`. Full scope." <> @parked,
    parameters: [sandbox_id: [in: :path, type: :string, required: true], path: @path_param],
    responses: [
      ok: {"Directory listing", "application/json", Schemas.SandboxListingResponse},
      not_found: {"No such sandbox or path", "application/json", Schemas.Error},
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a directory, or outside the sandbox", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def index(conn, %{"sandbox_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, listing} <- SandboxFiles.list(sandbox, params["path"]) do
      json(conn, %{data: listing})
    end
  end

  operation(:show,
    summary: "Read a file on a sandbox",
    description:
      "The bytes of one file, redacted: every value of the sandbox's environment and " <>
        "vault is replaced with `[REDACTED]`, as in the transcript. `content` is the text " <>
        "when it is valid UTF-8 (`encoding: utf-8`) and base64 otherwise " <>
        "(`encoding: base64`). `size` is the whole file; `truncated` says whether `content` " <>
        "is short of it, which happens when the file is longer than `max_bytes` and also " <>
        "when redaction grows what was read past that cap. Full scope." <> @parked,
    parameters: [
      sandbox_id: [in: :path, type: :string, required: true],
      path: Keyword.put(@path_param, :required, true),
      max_bytes: @max_bytes_param
    ],
    responses: [
      ok: {"File", "application/json", Schemas.SandboxFileResponse},
      not_found: {"No such sandbox or path", "application/json", Schemas.Error},
      conflict: @not_ready,
      unprocessable_entity:
        {"A directory, unreadable, or outside the sandbox", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def show(conn, %{"sandbox_id" => id} = params) do
    # `path` is required by the operation, so CastAndValidate has already
    # refused a request without one.
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, file} <-
           SandboxFiles.read(sandbox, params["path"], max_bytes: integer(params["max_bytes"])) do
      json(conn, %{data: file})
    end
  end

  operation(:diff,
    summary: "git diff on a sandbox",
    description:
      "`git diff` of the repository containing `path` (default: the agent's working " <>
        "directory), redacted like a file read. `staged=true` compares the index " <>
        "(`--cached`); `ref` compares against a commit, branch or tag " <>
        "(`422 invalid_ref` for a malformed one, `404 ref_not_found` for an unknown one). " <>
        "A directory outside any repository is `422 not_a_repository`. Full scope." <>
        @parked,
    parameters: [
      sandbox_id: [in: :path, type: :string, required: true],
      path: @path_param,
      staged: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Diff the index (`--cached`)."
      ],
      ref: [
        in: :query,
        type: :string,
        required: false,
        description:
          "A commit, branch or tag to diff against. Without it the comparison is the " <>
            "working tree against the index, or with `staged`, the index against HEAD."
      ],
      max_bytes: @max_bytes_param
    ],
    responses: [
      ok: {"Diff", "application/json", Schemas.SandboxDiffResponse},
      not_found: {"No such sandbox, path or ref", "application/json", Schemas.Error},
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a repository, bad ref, or outside the sandbox", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def diff(conn, %{"sandbox_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, diff} <-
           SandboxFiles.diff(sandbox, params["path"],
             staged: boolean(params["staged"]),
             ref: params["ref"],
             max_bytes: integer(params["max_bytes"])
           ) do
      json(conn, %{data: diff})
    end
  end

  operation(:git_status,
    summary: "git status on a sandbox",
    description:
      "`git status` of the repository containing `path` (default: the agent's working " <>
        "directory), one entry per changed path. This is the view that shows a file the " <>
        "agent created and never staged: `/diff` compares tracked content, so an " <>
        "untracked file is invisible to it whatever flags it is given. Entries cover the " <>
        "whole repository whatever `path` names inside it, and each entry's `path` is " <>
        "relative to `repo_root`. `index` and `worktree` are git's two porcelain columns " <>
        "read separately, so a file staged and then edited again reports a state in both; " <>
        "an untracked file reads `untracked` in both. `renamed_from` is set only where " <>
        "that side is a rename or a copy. `branch` is null on a detached HEAD. " <>
        "A directory outside any repository is `422 not_a_repository`. Full scope." <>
        @parked,
    parameters: [
      sandbox_id: [in: :path, type: :string, required: true],
      path: @path_param,
      untracked: [
        in: :query,
        type: %OpenApiSpex.Schema{
          type: :string,
          enum: SandboxFiles.untracked_modes(),
          default: "normal"
        },
        required: false,
        description:
          "What to do about untracked paths: collapse an untracked directory to one " <>
            "entry (`normal`), list every file under it (`all`), or leave them out (`no`)."
      ]
    ],
    responses: [
      ok: {"Status", "application/json", Schemas.SandboxStatusResponse},
      # The three sibling reads declare no 403 because 401/403/429 are
      # composed from `:api` pipeline membership. This one says it out loud,
      # since full scope is the whole story of the operation and a generated
      # client reads the operation rather than the pipeline. Nothing about
      # the wire differs; `FountainWeb.SchemaGuardAllowlist` is a ratchet for
      # rendered-response disagreements and holds none of these.
      forbidden: {"Insufficient scope", "application/json", Schemas.Error},
      not_found: {"No such sandbox or path", "application/json", Schemas.Error},
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a repository, or outside the sandbox", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def git_status(conn, %{"sandbox_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, status} <-
           SandboxFiles.status(sandbox, params["path"], untracked: params["untracked"]) do
      json(conn, %{data: status})
    end
  end

  # Ownership: the scoped get_sandbox establishes it; SandboxFiles trusts
  # the row it is handed.
  defp fetch(conn, id) do
    case Conversations.get_sandbox(id, conn.assigns.current_user.id) do
      %Sandbox{} = sandbox -> {:ok, sandbox}
      nil -> {:error, :not_found}
    end
  end

  # CastAndValidate has already checked the shapes; `replace_params: false`
  # leaves the raw strings in `params`, so read them back leniently.
  defp integer(nil), do: nil
  defp integer(n) when is_integer(n), do: n

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end

  defp boolean(true), do: true
  defp boolean("true"), do: true
  defp boolean(_), do: false
end
