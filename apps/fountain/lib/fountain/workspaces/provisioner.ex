defmodule Fountain.Workspaces.Provisioner do
  @moduledoc """
  An explicit workspace's provision on create (ADR 0097, "An explicit
  workspace is provisioned on create"; step 5).

  `Fountain.Workspaces.create_workspace/3` reserves the workspace's first
  sandbox in the same commit as the workspace, then starts `start/2`, which
  builds that machine with no conversation on it: the workspace's owner
  creates it, settles the network (`Fountain.Workspaces.Network`) and runs
  the environment's packages, repositories and setup script
  (`Fountain.Machines.Machine.set_up/3`). The bracket finalizes the sandbox
  `ready` or `failed` and settles the workspace's status with it
  (`Fountain.Workspaces.settle_provision/2`), which publishes the
  `workspace.status` event and, on a failure, the redacted error.

  It runs in a task under `Fountain.TaskSupervisor`, registered under the
  workspace id in `Fountain.WorkspaceSetupRegistry` so that a delete can stop
  it (`stop/1`). A deadline bounds it as `ProvisionWatchdog` bounds a
  conversation's provision: past `ProvisionWatchdog.deadline_ms/0` the
  machine is retired through its owner, taking the lease from the task, and
  the task is killed. A task lost with its node leaves the sandbox
  mid-provision with no live lease, which `SandboxReaper`'s pass over rows
  stuck mid-provision fails, and the workspace with it; the next prompt into
  the workspace retries the provision (a rebuild, ADR 0097 step 4).
  """

  require Logger

  alias Fountain.Conversations.ProvisionWatchdog
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Setup
  alias Fountain.Repo
  alias Fountain.Workspaces.Network
  alias Fountain.Workspaces.Workspace

  @registry Fountain.WorkspaceSetupRegistry

  @doc """
  Start the provision of `workspace`'s machine behind `sandbox_id` in the
  background. Answers once the task is started; what it does is reported
  through the workspace's status.
  """
  @spec start(Workspace.t(), Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Workspace{id: workspace_id}, sandbox_id) when is_binary(sandbox_id) do
    Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
      case Registry.register(@registry, workspace_id, sandbox_id) do
        {:ok, _owner} -> watched(workspace_id, sandbox_id)
        {:error, {:already_registered, _pid}} -> :already_running
      end
    end)
  end

  @doc """
  Stop `workspace_id`'s provision on create if it is running, and release its
  setup session: what a delete does before it destroys the machine, so the
  destroy can take the lease the task held rather than wait it out. The
  machine the task may have created is the destroy's.
  """
  @spec stop(Ecto.UUID.t()) :: :ok
  def stop(workspace_id) when is_binary(workspace_id) do
    case Registry.lookup(@registry, workspace_id) do
      [{pid, _sandbox_id}] ->
        ref = Process.monitor(pid)
        Process.exit(pid, :kill)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
        after
          5_000 -> :ok
        end

      [] ->
        :ok
    end

    Network.release(workspace_id)
  end

  @doc "Whether `workspace_id`'s provision on create is running on this node."
  @spec running?(Ecto.UUID.t()) :: boolean()
  def running?(workspace_id), do: Registry.lookup(@registry, workspace_id) != []

  defp watched(workspace_id, sandbox_id) do
    watchdog = deadline(self(), workspace_id, sandbox_id)

    try do
      run(workspace_id, sandbox_id)
    after
      send(watchdog, :done)
      # Whatever happened, the setup's session goes with it: the pipeline
      # releases it too, but not when something raised before its steps ran.
      Network.release(workspace_id)
    end
  end

  @doc false
  # The provision itself, on the calling process: `start/2`'s task, and the
  # tests. Answers what `Machine.set_up/3` answered.
  @spec run(Ecto.UUID.t(), Ecto.UUID.t()) :: term()
  def run(workspace_id, sandbox_id) do
    # ownership: the workspace the context created for its caller, by id.
    with %Workspace{} = workspace <- Repo.get(Workspace, workspace_id),
         {:ok, inputs} <- Network.inputs(workspace) do
      setup = %Setup{
        environment: inputs.environment,
        sprite_env: Network.setup_env(inputs),
        secrets: inputs.secrets,
        write_env_file?: true
      }

      Machine.set_up(sandbox_id, setup,
        network: inputs.network,
        environment: inputs.environment,
        actor: "system:workspace_setup",
        # The machine's clock (the idle bound, the ceiling) starts when it is
        # ready, not when its setup began (ADR 0097: a ready workspace with no
        # conversations "is idle from the moment it is ready").
        ready_attrs: fn -> [last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)] end
      )
    else
      nil ->
        {:error, :workspace_gone}

      {:error, reason} = error ->
        Logger.warning("workspace #{workspace_id}: not provisioned: #{inspect(reason)}")
        _ = Machine.fail_provision(sandbox_id, actor: "system:workspace_setup", reason: reason)
        error
    end
  end

  # The deadline, in a process of its own: the provision blocks the task for
  # its whole length, so a timer in it would queue behind the thing it bounds.
  defp deadline(task, workspace_id, sandbox_id) do
    fires_in = ProvisionWatchdog.deadline_ms()

    spawn(fn ->
      ref = Process.monitor(task)

      receive do
        :done ->
          :ok

        {:DOWN, ^ref, :process, ^task, _reason} ->
          :ok
      after
        fires_in -> expire(task, workspace_id, sandbox_id, fires_in)
      end
    end)
  end

  # The kill skips the task's `after`, so its session is released here.
  defp expire(task, workspace_id, sandbox_id, fires_in) do
    result =
      Machine.fail_provision(sandbox_id,
        actor: "system:workspace_setup",
        reason: :provision_deadline_exceeded,
        # The watchdog's own wait, for its reason: the retire takes the lease
        # from the task (`supersede:`), and the task has had its whole deadline.
        busy_wait_ms: ProvisionWatchdog.retire_wait_ms(),
        supersede: task
      )

    Logger.error(
      "machine #{sandbox_id}: the workspace's provision exceeded #{fires_in}ms " <>
        "(#{inspect(result)}); stopping it"
    )

    Process.exit(task, :kill)
    Network.release(workspace_id)
  end
end
