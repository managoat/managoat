defmodule FountainWeb.WorkspaceFilesController do
  @moduledoc """
  A workspace's disk, read-only (ADR 0097, Files; ADR 0039): the four reads
  of `FountainWeb.SandboxFilesController`, addressed by workspace and served
  from its current sandbox, with the same admission, bounds, redaction and
  never-resume rule, all of which are `Fountain.SandboxFiles`'.

  A workspace's machine is shared, so a relative path resolves from
  `/home/sprite`, and a path may lie under `/home/sprite` or the working
  directory of any live conversation on it. Redaction covers the
  workspace's environment and vault and whatever every live conversation
  there registered. Full scope only, as every workspace route is.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Conversations.Sandbox
  alias Fountain.SandboxFiles
  alias Fountain.Workspaces
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Workspaces"])

  @workspace_param [in: :path, type: :string, required: true]

  @path_param [
    in: :query,
    type: :string,
    required: false,
    description:
      "In-sandbox path, absolute or relative to `/home/sprite`. Confined to `/home/sprite` " <>
        "and the working directory of every live conversation in the workspace: anything " <>
        "else is `422 path_outside_sandbox`."
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

  @not_ready {"The workspace's machine is not ready", "application/json", Schemas.Error}
  @not_found {"No such workspace, machine or path", "application/json", Schemas.Error}
  @forbidden {"Insufficient scope", "application/json", Schemas.Error}

  @about " Served from the workspace's current machine, as `/api/sandboxes/{id}` serves " <>
           "one, redacted with the workspace's environment and vault and every live " <>
           "conversation's credentials. Only a `ready` machine answers: one Managoat parked " <>
           "is `409 sandbox_not_ready` and a read never resumes it, and one being provisioned " <>
           "or lost is `409` with its status. A machine the provider put to sleep by itself is " <>
           "woken by the read, and billed. One being parked or destroyed is " <>
           "`503 sandbox_unavailable` with `Retry-After`. Full scope."

  @unreachable {"Sandbox provider unreachable, or the machine is being parked or destroyed " <>
                  "(`sandbox_unavailable`, with `Retry-After`)", "application/json",
                Schemas.Error}

  operation(:index,
    summary: "List a directory in a workspace",
    description:
      "The entries of one directory, directories first then by name. Without `path`, " <>
        "`/home/sprite`." <> @about,
    parameters: [workspace_id: @workspace_param, path: @path_param],
    responses: [
      ok: {"Directory listing", "application/json", Schemas.SandboxListingResponse},
      forbidden: @forbidden,
      not_found: @not_found,
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a directory, or outside the workspace's roots", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def index(conn, %{"workspace_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, listing} <- SandboxFiles.list(sandbox, params["path"]) do
      json(conn, %{data: listing})
    end
  end

  operation(:show,
    summary: "Read a file in a workspace",
    description:
      "The bytes of one file, redacted. `content` is the text when it is valid UTF-8 " <>
        "(`encoding: utf-8`) and base64 otherwise. `size` is the whole file; `truncated` " <>
        "says whether `content` is short of it." <> @about,
    parameters: [
      workspace_id: @workspace_param,
      path: Keyword.put(@path_param, :required, true),
      max_bytes: @max_bytes_param
    ],
    responses: [
      ok: {"File", "application/json", Schemas.SandboxFileResponse},
      forbidden: @forbidden,
      not_found: @not_found,
      conflict: @not_ready,
      unprocessable_entity:
        {"A directory, unreadable, or outside the workspace's roots", "application/json",
         Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def show(conn, %{"workspace_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, file} <-
           SandboxFiles.read(sandbox, params["path"], max_bytes: integer(params["max_bytes"])) do
      json(conn, %{data: file})
    end
  end

  operation(:diff,
    summary: "git diff in a workspace",
    description:
      "`git diff` of the repository containing `path` (default `/home/sprite`), redacted. " <>
        "`staged=true` compares the index; `ref` compares against a commit, branch or tag " <>
        "(`422 invalid_ref`, `404 ref_not_found`). A directory outside any repository is " <>
        "`422 not_a_repository`." <> @about,
    parameters: [
      workspace_id: @workspace_param,
      path: @path_param,
      staged: [in: :query, type: :boolean, required: false, description: "Diff the index."],
      ref: [
        in: :query,
        type: :string,
        required: false,
        description: "A commit, branch or tag to diff against."
      ],
      max_bytes: @max_bytes_param
    ],
    responses: [
      ok: {"Diff", "application/json", Schemas.SandboxDiffResponse},
      forbidden: @forbidden,
      not_found: {"No such workspace, machine, path or ref", "application/json", Schemas.Error},
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a repository, bad ref, or outside the workspace's roots", "application/json",
         Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def diff(conn, %{"workspace_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, diff} <-
           SandboxFiles.diff(sandbox, params["path"],
             staged: params["staged"] in [true, "true"],
             ref: params["ref"],
             max_bytes: integer(params["max_bytes"])
           ) do
      json(conn, %{data: diff})
    end
  end

  operation(:git_status,
    summary: "git status in a workspace",
    description:
      "`git status` of the repository containing `path` (default `/home/sprite`), one " <>
        "entry per changed path, each relative to `repo_root`; shows untracked files, which " <>
        "`/diff` cannot. A directory outside any repository is `422 not_a_repository`." <>
        @about,
    parameters: [
      workspace_id: @workspace_param,
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
          "Collapse an untracked directory to one entry (`normal`), list every file under " <>
            "it (`all`), or leave them out (`no`)."
      ]
    ],
    responses: [
      ok: {"Status", "application/json", Schemas.SandboxStatusResponse},
      forbidden: @forbidden,
      not_found: @not_found,
      conflict: @not_ready,
      unprocessable_entity:
        {"Not a repository, or outside the workspace's roots", "application/json", Schemas.Error},
      service_unavailable: @unreachable
    ]
  )

  def git_status(conn, %{"workspace_id" => id} = params) do
    with {:ok, sandbox} <- fetch(conn, id),
         {:ok, status} <-
           SandboxFiles.status(sandbox, params["path"], untracked: params["untracked"]) do
      json(conn, %{data: status})
    end
  end

  # Ownership: the scoped get_workspace establishes the workspace, and its
  # current sandbox is read from it; SandboxFiles trusts the row it is handed.
  defp fetch(conn, id) do
    with %Fountain.Workspaces.Workspace{} = workspace <-
           Workspaces.get_workspace(id, conn.assigns.current_user.id),
         %Sandbox{} = sandbox <- Workspaces.current_sandbox(workspace) do
      {:ok, sandbox}
    else
      nil -> {:error, :not_found}
    end
  end

  defp integer(nil), do: nil
  defp integer(n) when is_integer(n), do: n

  defp integer(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> n
      _ -> nil
    end
  end
end
