defmodule FountainWeb.EnvironmentController do
  @moduledoc false
  use FountainWeb, :controller
  use OpenApiSpex.ControllerSpecs

  alias Fountain.Environments
  alias Fountain.Environments.Environment
  alias FountainWeb.Audited
  alias FountainWeb.Schemas

  action_fallback FountainWeb.FallbackController

  plug OpenApiSpex.Plug.CastAndValidate,
    replace_params: false,
    render_error: FountainWeb.Plugs.CastRenderError

  tags(["Environments"])

  operation(:index,
    summary: "List environments",
    responses: [
      ok: {"Environments", "application/json", Schemas.EnvironmentListResponse}
    ]
  )

  def index(conn, _params) do
    user = conn.assigns.current_user
    render(conn, :index, environments: Environments.list_environments_with_counts(user.id))
  end

  operation(:show,
    summary: "Get an environment",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      ok: {"Environment", "application/json", Schemas.EnvironmentResponse},
      not_found: {"Not found", "application/json", Schemas.Error}
    ]
  )

  def show(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Environments.get_environment_with_counts(id, user.id) do
      nil -> {:error, :not_found}
      env -> render(conn, :show, environment: env)
    end
  end

  operation(:create,
    summary: "Create an environment",
    request_body: {"Environment attributes", "application/json", Schemas.EnvironmentRequest},
    responses: [
      created: {"Environment", "application/json", Schemas.EnvironmentResponse},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def create(conn, params) do
    user = conn.assigns.current_user
    attrs = Map.put(params, "user_id", user.id)

    with {:ok, %Environment{} = env} <-
           Environments.create_environment(attrs, Audited.attribution(conn)) do
      conn
      |> put_status(:created)
      |> render(:show, environment: Environments.get_environment_with_counts(env.id, user.id))
    end
  end

  operation(:update,
    summary: "Update an environment (partial)",
    description: "Every field is optional; the server merges into the existing record.",
    parameters: [id: [in: :path, type: :string, required: true]],
    request_body:
      {"Partial environment attributes", "application/json", Schemas.EnvironmentUpdate},
    responses: [
      ok: {"Environment", "application/json", Schemas.EnvironmentResponse},
      not_found: {"Not found", "application/json", Schemas.Error},
      unprocessable_entity: {"Validation error", "application/json", Schemas.Error}
    ]
  )

  def update(conn, %{"id" => id} = params) do
    user = conn.assigns.current_user
    attrs = params |> Map.delete("id") |> Map.delete("user_id")

    case Environments.get_environment(id, user.id) do
      nil ->
        {:error, :not_found}

      env ->
        with {:ok, env} <- Environments.update_environment(env, attrs, Audited.attribution(conn)) do
          # Re-read for the counts: a response that advertises secret_count and
          # agent_count must not report the struct defaults after a write.
          render(conn, :show,
            environment: Environments.get_environment_with_counts(env.id, user.id)
          )
        end
    end
  end

  operation(:delete,
    summary: "Delete an environment",
    description:
      "Refused with 409 `source_in_use_by_workspace` while a workspace was created from it: " <>
        "a workspace fixes its environment for its life. Delete the workspace first.",
    parameters: [id: [in: :path, type: :string, required: true]],
    responses: [
      no_content: "Deleted",
      not_found: {"Not found", "application/json", Schemas.Error},
      conflict: {"A workspace names it", "application/json", Schemas.Error}
    ]
  )

  def delete(conn, %{"id" => id}) do
    user = conn.assigns.current_user

    case Environments.get_environment(id, user.id) do
      nil ->
        {:error, :not_found}

      env ->
        with {:ok, _} <- Environments.delete_environment(env, Audited.attribution(conn)) do
          send_resp(conn, :no_content, "")
        end
    end
  end
end
