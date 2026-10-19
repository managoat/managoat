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
    sandboxes = Workspaces.current_sandboxes(workspaces)

    render(conn, :index,
      workspaces: workspaces,
      sandboxes: sandboxes,
      standing: Workspaces.staleness(workspaces, sandboxes)
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
      workspace -> render_one(conn, workspace)
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
        {"Validation error, or a provider this instance has not enabled " <>
           "(sandbox_provider_disabled)", "application/json", Schemas.Error},
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
      |> render_one(workspace)
    else
      # The fallback's message names the agent's sandbox_provider override,
      # which is not what a workspace's caller sent.
      {:error, {:sandbox_provider_disabled, provider}} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{
          error: "sandbox_provider_disabled",
          message: Fountain.SandboxProviders.disabled_message(provider, :workspace_create)
        })

      error ->
        error
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

  operation(:rebuild,
    summary: "Rebuild a workspace's machine",
    description:
      "Destroys the workspace's machine, with everything on its disk, and builds a new one " <>
        "from its environment as it is now, under the same workspace. Save any work first: " <>
        "GET /api/workspaces/{id}/diff reads it while the machine is ready. Every " <>
        "conversation in the workspace keeps its transcript and stays in the workspace, " <>
        "with its runtime session cleared: its agent starts fresh on its next prompt. " <>
        "Answers 202 with status provisioning; the status moves to ready or failed, each a " <>
        "workspace.status event. Refused with 409 turns_running while any conversation in " <>
        "it has a running turn or a prompt accepted and not yet started, unless interrupt " <>
        "is true, which ends those turns as " <>
        "interrupted (transcripts kept). A rebuild while the workspace is provisioning is " <>
        "409 rebuild_in_progress. An implicit workspace is 404, as on DELETE: it is a " <>
        "conversation's own sandbox. A workspace whose sandbox provider has been disabled " <>
        "since it was made is 422 sandbox_provider_disabled, before anything moves. The " <>
        "vault is not touched.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Rebuild options", "application/json", Schemas.WorkspaceRebuildRequest, required: false},
    responses: [
      accepted: {"Workspace", "application/json", Schemas.WorkspaceResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict:
        {"A running turn (turns_running), or a rebuild in progress (rebuild_in_progress)",
         "application/json", Schemas.Error},
      unprocessable_entity:
        {"The workspace's sandbox provider has been disabled since it was made " <>
           "(sandbox_provider_disabled); nothing was changed", "application/json", Schemas.Error},
      service_unavailable:
        {"Every sandbox slot in use (fleet_full), or the machine busy with another " <>
           "operation (sandbox_unavailable)", "application/json", Schemas.Error}
    ]
  )

  def rebuild(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    interrupt? = params["interrupt"] in [true, "true"]

    case Workspaces.get_workspace(id, user.id) do
      %Fountain.Workspaces.Workspace{implicit: false} = workspace ->
        opts = Audited.attribution(conn) ++ [interrupt: interrupt?]

        case Workspaces.rebuild_workspace(workspace, opts) do
          {:ok, workspace} ->
            conn |> put_status(:accepted) |> render_one(workspace)

          {:error, {:turns_running, ids}} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "turns_running",
              message:
                "a conversation in this workspace is running a turn, or has a prompt that was " <>
                  "accepted and has not started yet; wait for it to end, or rebuild with " <>
                  "interrupt: true to interrupt it",
              conversation_ids: ids
            })

          {:error, :rebuild_in_progress} ->
            conn
            |> put_status(:conflict)
            |> json(%{
              error: "rebuild_in_progress",
              message:
                "this workspace's machine is being built; wait for its status to be ready " <>
                  "or failed"
            })

          error ->
            error
        end

      # An implicit workspace is a conversation's own sandbox, as on DELETE.
      _none_or_implicit ->
        {:error, :not_found}
    end
  end

  defp render_one(conn, workspace) do
    sandboxes = Workspaces.current_sandboxes([workspace])
    standing = Workspaces.staleness([workspace], sandboxes)

    render(conn, :show,
      workspace: workspace,
      sandbox: Map.get(sandboxes, workspace.id),
      standing: Map.fetch!(standing, workspace.id)
    )
  end
end
