defmodule FountainWeb.WorkspaceJSON do
  @moduledoc false

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces.Workspace

  @live ~w(pending starting ready suspended)

  def index(%{workspaces: workspaces, sandboxes: sandboxes, standing: standing}),
    do: %{
      data:
        Enum.map(workspaces, &data(&1, Map.get(sandboxes, &1.id), Map.fetch!(standing, &1.id)))
    }

  def show(%{workspace: workspace, sandbox: sandbox, standing: standing}),
    do: %{data: data(workspace, sandbox, standing)}

  @doc false
  def data(%Workspace{} = w, sandbox, standing) do
    %{
      id: w.id,
      name: w.name,
      implicit: w.implicit,
      environment_id: w.environment_id,
      vault_id: w.vault_id,
      sandbox_provider: w.provider,
      status: w.status,
      error: w.error,
      # None after a loss or a failed provision (ADR 0097): an ended machine
      # is not one the workspace has.
      sandbox_id: if(sandbox_status(sandbox), do: sandbox.id),
      sandbox_status: sandbox_status(sandbox),
      # Which environment revision the machine was built from, and whether it
      # is behind (#2987): field names only, never a value.
      revision: standing.revision,
      built_from_revision: standing.built_from_revision,
      stale: standing.stale,
      changed_fields: standing.changed_fields,
      inserted_at: w.inserted_at,
      updated_at: w.updated_at
    }
  end

  defp sandbox_status(%Sandbox{status: status}) when status in @live, do: status
  defp sandbox_status(_none_or_ended), do: nil
end
