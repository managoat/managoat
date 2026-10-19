defmodule FountainWeb.WorkspaceJSON do
  @moduledoc false

  alias Fountain.Conversations.Sandbox
  alias Fountain.Workspaces.SetupLog
  alias Fountain.Workspaces.Workspace

  @live ~w(pending starting ready suspended)

  def index(%{
        workspaces: workspaces,
        sandboxes: sandboxes,
        standing: standing,
        setup_steps: steps
      }),
      do: %{
        data:
          Enum.map(
            workspaces,
            &data(&1, Map.get(sandboxes, &1.id), Map.fetch!(standing, &1.id), steps)
          )
      }

  def show(%{workspace: workspace, sandbox: sandbox, standing: standing, setup_steps: steps}),
    do: %{data: data(workspace, sandbox, standing, steps)}

  def setup_log(%{log: nil}), do: %{data: nil}

  def setup_log(%{log: %SetupLog{} = log}) do
    %{
      data: %{
        workspace_id: log.workspace_id,
        sandbox_id: log.sandbox_id,
        status: log.status,
        step: log.step,
        started_at: log.started_at,
        finished_at: log.finished_at,
        steps: Enum.map(log.steps, &step/1)
      }
    }
  end

  @doc false
  def data(%Workspace{} = w, sandbox, standing, steps) do
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
      # The step its setup is running, while it is provisioning (#3009).
      setup_step: if(w.status == "provisioning", do: Map.get(steps, w.id)),
      inserted_at: w.inserted_at,
      updated_at: w.updated_at
    }
  end

  # A stored step, in the order the schema names its fields.
  defp step(%{} = step) do
    %{
      step: step["step"],
      status: step["status"],
      started_at: step["started_at"],
      finished_at: step["finished_at"],
      output: step["output"] || "",
      omitted_lines: step["omitted_lines"] || 0,
      omitted_bytes: step["omitted_bytes"] || 0
    }
  end

  defp sandbox_status(%Sandbox{status: status}) when status in @live, do: status
  defp sandbox_status(_none_or_ended), do: nil
end
