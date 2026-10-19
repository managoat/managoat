defmodule FountainWeb.WorkspaceJSON do
  @moduledoc false

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces.Workspace

  @live ~w(pending starting ready suspended)

  def index(%{workspaces: workspaces, sandboxes: sandboxes}),
    do: %{data: Enum.map(workspaces, &data(&1, Map.get(sandboxes, &1.id)))}

  def show(%{workspace: workspace, sandbox: sandbox}), do: %{data: data(workspace, sandbox)}

  @doc false
  def data(%Workspace{} = w, sandbox) do
    %{
      id: w.id,
      name: w.name,
      implicit: w.implicit,
      environment_id: w.environment_id,
      vault_id: w.vault_id,
      sandbox_provider: w.provider,
      status: w.status,
      error: w.error,
      sandbox_id: sandbox && sandbox.id,
      sandbox_status: sandbox_status(sandbox),
      inserted_at: w.inserted_at,
      updated_at: w.updated_at
    }
  end

  defp sandbox_status(%Sandbox{status: status}) when status in @live, do: status
  defp sandbox_status(_none_or_ended), do: nil
end
