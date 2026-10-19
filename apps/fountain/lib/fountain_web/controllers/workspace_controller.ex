defmodule FountainWeb.WorkspaceController do
  @moduledoc """
  `/api/workspaces` (ADR 0097, "The workspace API"): create, list, show and
  delete the caller's workspaces. Full scope only (the router's
  `:require_full_scope`, and `FountainWeb.Plugs.SandboxKeyScope`, which
  refuses a sandbox's own key every route not on its allowlist). Every read
  is scoped by the caller; another account's workspace is 404.

  The work is `Fountain.Workspaces`'; this is the HTTP shape of it.
  """
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Workspaces
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Workspaces"])

  operation(:index,
    summary: "List workspaces",
    description:
      "The caller's workspaces, newest first. Implicit workspaces, one per conversation " <>
        "launched without workspace_id, are left out unless `implicit=true`.",
    parameters: [
      implicit: [
        in: :query,
        type: :boolean,
        required: false,
        description: "Also list implicit workspaces. Defaults to false."
      ]
    ],
    responses: [ok: {"Workspaces", "application/json", Schemas.WorkspaceListResponse}]
  )

  def index(conn, params) do
    user = conn.assigns.current_user
    implicit? = params["implicit"] in [true, "true", "1"]
    workspaces = Workspaces.list_workspaces(user.id, implicit: implicit?)

    render(conn, :index,
      workspaces: workspaces,
      sandboxes: Workspaces.current_sandboxes(workspaces)
    )
  end

  operation(:show,
    summary: "Get a workspace",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Workspace", "application/json", Schemas.WorkspaceResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    case Workspaces.get_workspace(id, conn.assigns.current_user.id) do
      nil -> {:error, :not_found}
      workspace -> render(conn, :show, workspace: workspace, sandbox: current(workspace))
    end
  end

  operation(:create,
    summary: "Create a workspace",
    description:
      "Creates a workspace and starts setting up its machine at once, with no conversation: " <>
        "the environment's packages, repositories and setup script run under the broker's " <>
        "network floor (ADR 0019), with the vault's secrets overriding the environment's. " <>
        "Answers 201 with status provisioning; the status moves to ready, or to failed with " <>
        "an error, and each change is a workspace.status event on GET /api/events/stream. " <>
        "Launch conversations into it with workspace_id on POST /api/conversations, before " <>
        "or after it is ready. A ready workspace with no running conversation is parked " <>
        "after the idle timeout, like any sandbox, and woken by the next prompt. Refused " <>
        "with 503 fleet_full when every sandbox slot on its provider is in use.",
    request_body: {"Workspace attrs", "application/json", Schemas.WorkspaceCreateRequest},
    responses: [
      created: {"Workspace", "application/json", Schemas.WorkspaceResponse},
      not_found:
        {"Environment or vault not found (environment_not_found, vault_not_found)",
         "application/json", Schemas.Error},
      unprocessable_entity:
        {"Validation error, or a disabled provider", "application/json", Schemas.Error},
      service_unavailable:
        {"Every sandbox slot in use (fleet_full)", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user

    attrs = Map.take(params, ["name", "environment_id", "vault_id", "sandbox_provider"])

    with {:ok, workspace} <-
           Workspaces.create_workspace(user.id, attrs, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, workspace: workspace, sandbox: current(workspace))
    end
  end

  operation(:delete,
    summary: "Delete a workspace",
    description:
      "Terminates every live conversation in the workspace (their transcripts are kept) " <>
        "and destroys its machine. Not refused while conversations are running.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    case Workspaces.get_workspace(id, conn.assigns.current_user.id) do
      %Fountain.Workspaces.Workspace{implicit: false} = workspace ->
        with {:ok, _} <- Workspaces.delete_workspace(workspace, Audited.attribution(conn)) do
          send_resp(conn, :no_content, "")
        end

      # An implicit workspace ends with its conversation: deleting the
      # conversation is how it goes.
      _none_or_implicit ->
        {:error, :not_found}
    end
  end

  defp current(workspace), do: Workspaces.current_sandbox(workspace)
end
