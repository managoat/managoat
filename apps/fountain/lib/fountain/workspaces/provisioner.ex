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
  alias Fountain.Conversations.Rebuild
  alias Fountain.Conversations.Sandbox
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

  A task of the workspace's already registered is waited out briefly, as
  `retry/2` waits: a rebuild (#2986) whose new row was made while a retry's
  task was registered builds it once that task, which follows the rebuild,
  has gone (review of #3013).
  """
  @spec start(Workspace.t(), Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def start(%Workspace{id: workspace_id}, sandbox_id) when is_binary(sandbox_id) do
    Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
      case register(workspace_id, sandbox_id) do
        :ok -> watched(workspace_id, sandbox_id)
        :busy -> :already_running
      end
    end)
  end

  @doc """
  Start the setup of `workspace`'s machine again, in the background: the
  retry of a failed workspace (`Fountain.Workspaces.retry_workspace/2`,
  #3013). `failed_sandbox_id` is the workspace's failed machine, which the
  new one succeeds (`Fountain.Machines.Machine.rebuild/3`), so the retry
  takes the same lease, and moves the same conversations, as a prompt into
  the failed workspace does: whichever of the two claims it first sets the
  workspace up, and the other follows that setup.

  Registered under the workspace id like `start/2`, so a delete stops it. A
  task of the workspace's still registered (a setup that has just settled
  `failed` and is releasing its session) is waited out briefly first.
  Whatever the rebuild answers, the workspace is then left settled
  (`Fountain.Workspaces.abandon_retry/3`): a retry that never reached a new
  machine puts it back to `failed`, with the reason.
  """
  @spec retry(Workspace.t(), Ecto.UUID.t()) :: {:ok, pid()} | {:error, term()}
  def retry(%Workspace{id: workspace_id}, failed_sandbox_id) when is_binary(failed_sandbox_id) do
    Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
      case register(workspace_id, failed_sandbox_id) do
        :ok ->
          retry_watched(workspace_id, failed_sandbox_id)

        :busy ->
          Logger.warning("workspace #{workspace_id}: retry refused, a setup is still registered")
          Fountain.Workspaces.abandon_retry(workspace_id, failed_sandbox_id, :setup_running)
      end
    end)
  end

  # How long a retry waits for the workspace's previous setup task to
  # unregister. That task has already settled the workspace, so this is only
  # the moment its `after` takes.
  @register_wait_ms 10_000

  defp register(workspace_id, sandbox_id) do
    case Registry.register(@registry, workspace_id, sandbox_id) do
      {:ok, _owner} ->
        :ok

      {:error, {:already_registered, pid}} ->
        ref = Process.monitor(pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _reason} ->
            case Registry.register(@registry, workspace_id, sandbox_id) do
              {:ok, _owner} -> :ok
              {:error, _} -> :busy
            end
        after
          @register_wait_ms ->
            Process.demonitor(ref, [:flush])
            :busy
        end
    end
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

  defp retry_watched(workspace_id, failed_sandbox_id) do
    watchdog = deadline(self(), workspace_id, failed_sandbox_id, :retry)

    result =
      try do
        rerun(workspace_id, failed_sandbox_id, watchdog)
      rescue
        error ->
          Logger.error("workspace #{workspace_id}: retry raised: #{Exception.message(error)}")
          {:error, :setup_raised}
      catch
        # An exit (a call that timed out) or a throw: the kind only, since the
        # reason may carry a call's arguments.
        kind, _reason ->
          Logger.error("workspace #{workspace_id}: retry stopped by an #{kind}")
          {:error, :setup_raised}
      after
        send(watchdog, :done)
        Network.release(workspace_id)
      end

    # Once, at the end: a second call could undo a retry that came after
    # this one settled.
    Fountain.Workspaces.abandon_retry(workspace_id, failed_sandbox_id, retry_reason(result))
    result
  end

  # What a retry that never reached a new machine says went wrong. A rebuild
  # that did reach one has settled the workspace through its own finalize,
  # and `abandon_retry/3` leaves a settled workspace alone.
  defp retry_reason({:error, reason, _result}), do: reason
  defp retry_reason({:error, reason}), do: reason
  defp retry_reason(_other), do: :setup_not_rebuilt

  defp watched(workspace_id, sandbox_id) do
    watchdog = deadline(self(), workspace_id, sandbox_id, :create)

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

  @doc false
  # The setup again, on the calling process: `retry/2`'s task, and the tests.
  # The workspace's machine is rebuilt from its failed row under the
  # workspace's lease, with the environment and vault as they are now, and
  # the new row's id is told to `watchdog`, so the deadline fails that
  # machine. Answers what `Machine.rebuild/3` answered.
  @spec rerun(Ecto.UUID.t(), Ecto.UUID.t(), pid() | nil) :: term()
  def rerun(workspace_id, failed_sandbox_id, watchdog \\ nil) do
    # ownership: the workspace the context retried for its caller, by id, and
    # its own failed machine.
    with %Workspace{user_id: user_id} = workspace when is_binary(user_id) <-
           Repo.get(Workspace, workspace_id),
         %Sandbox{workspace_id: ^workspace_id} = failed <-
           Fountain.Conversations._unsafe_get_sandbox(failed_sandbox_id),
         {:ok, inputs} <- Network.inputs(workspace) do
      setup = %Setup{
        environment: inputs.environment,
        sprite_env: Network.setup_env(inputs),
        secrets: inputs.secrets,
        write_env_file?: true
      }

      provider = Fountain.Conversations.sandbox_provider_atom(failed)
      {:ok, name} = Fountain.Conversations.mint_machine_name(provider, user_id, nil)
      pipeline = Setup.pipeline(setup, inputs.network)

      Machine.rebuild(
        failed_sandbox_id,
        fn next ->
          if watchdog, do: send(watchdog, {:building, next.id})
          pipeline
        end,
        actor: "system:workspace_setup",
        attrs: %{machine_name: name},
        # `Workspaces.retry_workspace/2` sent `provisioning` when it moved
        # the workspace out of `failed`; the succession is not to send it
        # again.
        announce: false,
        # What the new machine is built from, as read just now: its
        # `built_from_revision` (#2987).
        environment: inputs.environment,
        notice:
          "The workspace's setup failed and is being run again. Send another prompt " <>
            "once it is ready — the transcript above is kept, but the agent starts a " <>
            "fresh session and will not remember the earlier turns.",
        # A failed machine was destroyed when it failed, or is the reaper's
        # terminal-row pass's (as `Fountain.Conversations.Rebuild.machine/2`).
        provider: if(failed.status in ~w(terminated failed), do: :already_gone, else: :destroy),
        # A prompt into the workspace may hold its lease for a whole setup:
        # wait as long as its conversations would, then follow it.
        busy_wait_ms: Rebuild.follow_wait_ms(),
        ready_attrs: fn -> [last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)] end
      )
    else
      {:error, reason} = error ->
        Logger.warning("workspace #{workspace_id}: not set up again: #{inspect(reason)}")
        error

      _gone ->
        {:error, :workspace_gone}
    end
  end

  # The deadline, in a process of its own: the provision blocks the task for
  # its whole length, so a timer in it would queue behind the thing it bounds.
  # A retry names its machine only once the succession has made it
  # (`{:building, sandbox_id}`), and a retry the deadline stops is left
  # settled.
  defp deadline(task, workspace_id, sandbox_id, kind) do
    ends_at = System.monotonic_time(:millisecond) + ProvisionWatchdog.deadline_ms()

    spawn(fn ->
      ref = Process.monitor(task)

      wait(
        %{
          task: task,
          ref: ref,
          workspace_id: workspace_id,
          kind: kind,
          from: sandbox_id,
          ends_at: ends_at
        },
        sandbox_id
      )
    end)
  end

  defp wait(%{task: task, ref: ref} = watch, sandbox_id) do
    receive do
      :done ->
        :ok

      {:DOWN, ^ref, :process, ^task, _reason} ->
        :ok

      {:building, next_id} ->
        wait(watch, next_id)
    after
      max(watch.ends_at - System.monotonic_time(:millisecond), 0) ->
        expire(task, watch.workspace_id, sandbox_id, ProvisionWatchdog.deadline_ms())

        # The kill skipped the task's own settling. A retry that had built a
        # machine was failed with it above, which settles the workspace.
        if watch.kind == :retry,
          do:
            Fountain.Workspaces.abandon_retry(
              watch.workspace_id,
              watch.from,
              :provision_deadline_exceeded
            )
    end
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
