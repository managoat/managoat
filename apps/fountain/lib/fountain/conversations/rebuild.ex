defmodule Fountain.Conversations.Rebuild do
  @moduledoc """
  A conversation whose machine is gone gets the next one in its workspace
  (ADR 0097, "Sandbox lost"; step 4).

  Until step 4 a wake that found the machine gone reserved a fresh sandbox in
  a fresh implicit workspace and moved the conversation to it. Now the
  workspace is kept: the prompt that meets a lost machine starts the
  conversation's server on the lost row, and the server rebuilds the
  workspace's machine under its one owner (`Fountain.Machines.Machine.rebuild/3`),
  with its own pipeline (`Fountain.Conversations.FreshProvision`). Every live
  conversation of the workspace follows the new machine in the succession's
  commit, with its transcript kept and its runtime session cleared; the next
  prompt in any of them reaches the new machine. Nothing is rebuilt until a
  prompt asks (the rebuild is lazy).

  This module is the conversation's half of that, kept out of
  `ConversationServer` (whose size only shrinks) and `Wake`:

    * `wake_target/2`, the wake's decision: rebuild in the conversation's
      workspace, or (no workspace to keep) the fresh implicit workspace a
      wake has always made.
    * `target/2` and `machine/2`, the server's: rebuild through the owner,
      with the pipeline aimed at the new row.
    * `follow/2`, for a server whose conversation another conversation's
      rebuild has already moved: wait for that machine and reattach to it.

  ## Which workspace is kept

  An **explicit** workspace always: it fixes the environment, vault and
  provider, and its conversations share its machine. An **implicit** one
  only while it still says what a launch would resolve now (the agent's
  provider, the conversation's environment and vault): it was made from that
  resolution, and today's wake re-resolves it on a lost machine, so a
  conversation whose agent moved provider or environment while its machine
  was gone still gets a fresh implicit workspace, as before. Its old one has
  then ended, and the termination path or the reaper deletes it.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Output, Provisioning, Sandbox}
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Provision
  alias Fountain.Repo
  alias Fountain.Workspaces.Workspace

  @terminal_statuses ~w(terminated failed)

  # How long a server waits for its workspace's machine while another
  # conversation's prompt is building it: the claim of the workspace's lease
  # in `Machine.rebuild/3`, and `follow/2`'s wait for the row to settle. A
  # rebuild runs a whole provision (packages, clones, a setup script), so this
  # is minutes, not the five seconds a duplicate server waits; it stays well
  # inside `ProvisionWatchdog.deadline_ms/0`, which bounds the server itself.
  @follow_wait_ms :timer.minutes(10)
  @poll_ms 1_000

  # Where a server records the row its rebuild's succession made (`failed/4`).
  # The server's own process dictionary: `machine/2`'s succession callback and
  # `failed/4` both run in it (the rebuild is the server's bracket, inline),
  # and one server makes at most one rebuild attempt before it stops.
  @attempt_key {__MODULE__, :attempt}

  @doc false
  @spec follow_wait_ms() :: pos_integer()
  def follow_wait_ms, do: Application.get_env(:fountain, :rebuild_follow_wait_ms, @follow_wait_ms)

  @doc """
  What a wake does for a conversation whose machine is gone (or stranded
  mid-provision with nobody building it): `{:rebuild, sandbox}`, start its
  server on that row in its kept workspace, or `:fresh`, a fresh implicit
  workspace as before. See the moduledoc for which workspace is kept.

  `conv` and `agent` are the waking conversation's own, established by the
  wake's caller.
  """
  @spec wake_target(map(), map()) :: {:rebuild, Sandbox.t()} | :fresh
  def wake_target(%{sandbox_id: nil}, _agent), do: :fresh

  def wake_target(conv, agent) do
    # ownership: the conversation's own machine and its workspace.
    with %Sandbox{workspace_id: workspace_id} = sandbox when is_binary(workspace_id) <-
           Conversations._unsafe_get_sandbox(conv.sandbox_id),
         %Workspace{} = workspace <- Repo.get(Workspace, workspace_id),
         true <- workspace.user_id == conv.user_id,
         true <- kept?(workspace, conv, agent) do
      {:rebuild, sandbox}
    else
      _ -> :fresh
    end
  end

  defp kept?(%Workspace{implicit: false}, _conv, _agent), do: true

  defp kept?(%Workspace{} = workspace, conv, agent) do
    case Conversations.resolve_sandbox_provider(agent) do
      {:ok, provider} ->
        Atom.to_string(provider) == workspace.provider and
          (conv.environment_id || agent.environment_id) == workspace.environment_id and
          conv.vault_id == workspace.vault_id

      {:error, _} ->
        false
    end
  end

  @doc """
  What a server started on a terminal row does: `:rebuild` the workspace's
  machine through that row, `:follow` the conversation to the machine another
  conversation's rebuild has moved it to, or `:none` (no workspace to rebuild
  in), which stops the server as a terminal row always has.
  """
  #
  # **Only a wake asks for a rebuild** (review of step 4b): it sets the
  # conversation `pending` before it starts the server
  # (`Wake.rebuild_and_start`), the status a fresh wake has always given it.
  # A server restarted from its child spec after a crash, which carries no
  # prompt, finds an `idle` conversation on a terminal row and stops, as it
  # did before, rather than building a machine nobody asked for. And the
  # workspace must still be one a wake keeps (`kept?/3`), re-read here.
  @spec target(map(), Sandbox.t(), map() | nil) :: :rebuild | :follow | :none
  def target(conv, %Sandbox{} = sandbox, agent) do
    cond do
      # A conversation that has ended takes no machine (#394: a server
      # restarted onto a row its watchdog failed, with the conversation, must
      # not provision a second machine).
      conv.status in @terminal_statuses -> :none
      conv.status != "pending" -> :none
      conv.sandbox_id != sandbox.id and moved_within?(conv, sandbox) -> :follow
      conv.sandbox_id != sandbox.id -> :none
      kept_workspace?(conv, sandbox, agent) -> :rebuild
      true -> :none
    end
  end

  # ownership: the conversation's own machine's workspace.
  defp kept_workspace?(_conv, %Sandbox{workspace_id: nil}, _agent), do: false

  defp kept_workspace?(conv, %Sandbox{workspace_id: workspace_id}, agent) do
    case Repo.get(Workspace, workspace_id) do
      %Workspace{implicit: false} = workspace -> workspace.user_id == conv.user_id
      %Workspace{} = workspace when not is_nil(agent) -> kept?(workspace, conv, agent)
      _ -> false
    end
  end

  @doc """
  What a server whose terminal row will not be rebuilt says before it stops:
  the prompt reported as not run for a conversation a wake asked to rebuild
  (its workspace went, or no longer matches), so the next prompt takes a
  fresh machine. With no such mark (a restart from the child spec, or a
  server registered onto a machine that went in the instant after its wake
  saw it up), only a prompt the server holds is reported (#3001), and
  nothing is said without one.
  """
  @spec not_rebuilt(map(), map()) :: {:stop, :normal, map()}
  def not_rebuilt(state, conv) do
    cond do
      conv.status == "pending" ->
        retryable_stop(state, "workspace_not_kept", :machine_lost)

      # An ended conversation takes no prompt: a retry is refused as gone.
      conv.status in @terminal_statuses ->
        Fountain.Conversations.Wake.report_queued_unrun(state.conversation_id, :gone, bare: false)

      true ->
        Fountain.Conversations.Wake.report_queued_unrun(state.conversation_id, :machine_lost,
          bare: false
        )
    end

    {:stop, :normal, state}
  end

  # ownership: the server's own conversation's current machine.
  defp moved_within?(conv, %Sandbox{workspace_id: workspace_id}) do
    case conv.sandbox_id && Conversations._unsafe_get_sandbox(conv.sandbox_id) do
      %Sandbox{workspace_id: ^workspace_id} when is_binary(workspace_id) -> true
      _ -> false
    end
  end

  @doc """
  Rebuild the workspace's machine through `ctx.sandbox`, the conversation's
  lost row, running `pipeline` (`FreshProvision`'s, `(ctx, handle, epoch)`)
  aimed at the new row. Answers what `Machine.provision/3` does, so the
  caller's arms handle it, with the rebuild's own answers wrapped as
  `{:rebuild, reply}`: a `{:follow, ...}` when another conversation has the
  workspace's machine, and a stop for a refusal that must not fail the
  conversation (a full fleet).
  """
  @spec machine(map(), (map(), term(), term() -> term())) :: term()
  def machine(%{state: state, conv: conv, sandbox: old} = ctx, pipeline) do
    provider = Conversations.sandbox_provider_atom(old)

    {:ok, name} = Conversations.mint_machine_name(provider, conv.user_id, nil)

    old.id
    |> Machine.rebuild(
      fn next ->
        # Called in this server's process right after the succession commits,
        # before the create: the row this attempt made (`failed/4`).
        remember_attempt(next)
        fn handle, epoch -> pipeline.(aim(ctx, next), handle, epoch) end
      end,
      actor: "system:conversation_server",
      conversation_id: conv.id,
      attrs: %{machine_name: name, agent_id: conv.agent_id},
      # What this server's pipeline builds from (#2987).
      environment: ctx.env,
      # A terminal row: whoever retired it destroyed its machine, or the
      # reaper's pass over terminal rows does.
      provider: if(old.status in @terminal_statuses, do: :already_gone, else: :destroy),
      busy_wait_ms: follow_wait_ms(),
      on_claim: fn _interrupted? -> announce(state, provider) end
    )
    |> answer(state, conv)
  end

  defp announce(state, provider) do
    Output.publish_stage(state.conversation_id, "provision", "started", %{
      retry: "the sandbox was lost; building a new one in its workspace"
    })

    Provisioning.check_broker_support(provider, state.conversation_id)
  end

  # The pipeline's context, aimed at the new row: the row it records a URL on
  # and dates the ceiling from, the server state's `sandbox_id`, and the
  # conversation as the succession left it (moved, its session cleared).
  defp aim(ctx, %Sandbox{} = next) do
    # ownership: the server's own conversation.
    conv = Conversations._unsafe_get_conversation!(ctx.conv.id)

    %{
      ctx
      | sandbox: next,
        conv: conv,
        state: %{ctx.state | sandbox_id: next.id, runtime_session_id: nil}
    }
  end

  defp answer({:ok, :rebuilt, %Sandbox{}, result}, _state, _conv), do: {:ok, :provisioned, result}

  # The workspace already has a live machine: another conversation's prompt
  # rebuilt it first (`:occupied`), or held its lease past the wait.
  defp answer({:error, :occupied}, state, conv), do: {:rebuild, follow(state, conv)}
  defp answer({:ok, :claimed_elsewhere}, state, conv), do: {:rebuild, follow(state, conv)}

  # No room for a machine. Retryable, and not the conversation's failure:
  # the prompt is reported as not run and the conversation stays as it was.
  defp answer({:error, :fleet_full}, state, _conv) do
    retryable_stop(state, "fleet_full", :fleet_full, bare: false)
    {:rebuild, {:stop, :normal, state}}
  end

  defp answer({:error, reason}, state, _conv)
       when reason in [:name_reused] or
              (is_tuple(reason) and elem(reason, 0) == :not_rebuildable) do
    Logger.warning(
      "conv #{state.conversation_id}: machine not rebuilt: #{inspect(Provision.without_output(reason))}"
    )

    {:rebuild, {:stop, :normal, state}}
  end

  # Everything else with no pipeline state to unwind. After the succession
  # (a create that failed, a refusal before it), the conversation is bound
  # to the failed new row, so it is failed there, as a fresh provision's
  # failure fails it, rather than against the old row, which the binding
  # check would refuse silently (review of step 4b). Before it (a fence, a
  # lease lost, a database fault) nothing moved: the prompt is reported as
  # not run and the conversation stays resumable, as a refused wake left it.
  defp answer({:error, reason}, state, conv) do
    {:rebuild, failed(state, conv, reason, %{reason: inspect(Provision.without_output(reason))})}
  end

  defp answer(other, _state, _conv), do: other

  @doc """
  Where a rebuild's failure lands, for an answer with no pipeline state to
  unwind and for a raise out of the pipeline (`FreshProvision`'s rescue).

  After the succession the conversation is bound to the new row this
  attempt built, which is `failed` or left mid-provision: that row is
  retired through its owner and the conversation failed against it, as a
  fresh provision's failure fails it (review of step 4b). Otherwise nothing
  of this attempt's moved it (an error before the succession, or a
  co-tenant's rebuild moved it to a machine that is not this attempt's): the
  prompt is reported as not run and the conversation is left resumable, its
  wake's `pending` mark undone.
  """
  @spec failed(map(), map(), term(), map()) :: {:stop, :normal, map()}
  def failed(state, conv, reason, metadata) do
    # ownership: the server's own conversation and its current machine.
    current = Conversations._unsafe_get_conversation(conv.id)

    sandbox =
      current && current.sandbox_id != state.sandbox_id &&
        Conversations._unsafe_get_sandbox(current.sandbox_id)

    if this_attempts?(sandbox) do
      # The failure's own reason on the row and the workspace's `error`
      # (#3001): `:provision_raised` only for a raise. `Provision` keeps a
      # step's output off the row, and the workspace's error is redacted.
      Fountain.Conversations.ConversationServer.fail_machine(sandbox.id, reason, conv.id)

      Fountain.Conversations.ActorStatus.fail(
        %{conversation_id: conv.id, sandbox_id: sandbox.id},
        metadata
      )
    else
      Logger.warning(
        "conv #{conv.id}: machine not rebuilt: #{inspect(Provision.without_output(reason))}"
      )

      retryable_stop(state, to_string_reason(reason), reason)
    end

    {:stop, :normal, state}
  end

  # The row this attempt's succession made and could not finish: the one
  # `machine/2` recorded when its succession committed, failed, or still
  # mid-provision with nobody holding its lease (this server's lease was
  # released when the bracket unwound).
  #
  # By id, not by status alone (#3001): a co-tenant's rebuild can move this
  # conversation to a row that then fails, and an error in this server before
  # its own succession would otherwise read that failed row as its own and
  # fail the conversation for the co-tenant's failure. A row this attempt did
  # not make is never this attempt's to fail.
  defp this_attempts?(%Sandbox{id: id} = sandbox) do
    Process.get(@attempt_key) == id and unfinished?(sandbox)
  end

  defp this_attempts?(_sandbox), do: false

  defp unfinished?(%Sandbox{status: "failed"}), do: true

  defp unfinished?(%Sandbox{status: status} = sandbox) when status in ["pending", "starting"],
    do: not Machine.busy?(sandbox)

  defp unfinished?(_sandbox), do: false

  defp remember_attempt(%Sandbox{id: id}), do: Process.put(@attempt_key, id)

  # A retryable stop's stage, the prompts this server was started for
  # reported as not run with their receipts (#3001), and the wake's `pending`
  # mark undone, so the conversation does not read as active until its next
  # prompt. `bare: false` for a stop that reports only a prompt it holds.
  defp retryable_stop(state, reason, unrun, opts \\ []) do
    Output.publish_stage(state.conversation_id, "provision", "failed", %{
      reason: reason,
      retryable: true
    })

    Fountain.Conversations.Wake.report_queued_unrun(state.conversation_id, unrun, opts)
    unmark(state.conversation_id)
  end

  defp unmark(conv_id) do
    import Ecto.Query, only: [from: 2]

    # ownership: the server's own conversation.
    _ =
      Repo.update_all(
        from(c in Fountain.Conversations.Conversation,
          where: c.id == ^conv_id and c.status == "pending"
        ),
        set: [status: "idle", updated_at: DateTime.utc_now()]
      )

    :ok
  end

  @doc "Whether `sandbox`'s workspace has a live machine other than it."
  @spec workspace_has_other_live?(Sandbox.t()) :: boolean()
  def workspace_has_other_live?(%Sandbox{workspace_id: nil}), do: false

  def workspace_has_other_live?(%Sandbox{workspace_id: workspace_id, id: id}) do
    import Ecto.Query, only: [from: 2]

    Repo.exists?(
      from(s in Sandbox,
        where:
          s.workspace_id == ^workspace_id and s.id != ^id and
            s.status not in ^@terminal_statuses
      )
    )
  end

  @doc """
  Wait, up to `follow_wait_ms/0`, while the machine behind `sandbox_id` is
  being built by an owner: `:settled` once it is no longer `pending` or
  `starting`, or nobody holds it any more; `:timeout` otherwise. For a wake
  into a shared workspace whose machine a co-tenant's prompt is rebuilding.
  """
  @spec await_settled(Ecto.UUID.t()) :: :settled | :timeout
  def await_settled(sandbox_id) do
    await_settled(sandbox_id, System.monotonic_time(:millisecond) + follow_wait_ms())
  end

  defp await_settled(sandbox_id, deadline) do
    # ownership: the waking conversation's own machine, read by the wake.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{status: status} = sandbox when status in ["pending", "starting"] ->
        cond do
          not Machine.busy?(sandbox) ->
            :settled

          System.monotonic_time(:millisecond) < deadline ->
            Process.sleep(@poll_ms)
            await_settled(sandbox_id, deadline)

          true ->
            :timeout
        end

      _ ->
        :settled
    end
  end

  @doc """
  Follow the conversation to the machine another conversation's rebuild moved
  it to: wait while that machine is being built (bounded by
  `follow_wait_ms/0`), then answer `{:follow, state, sandbox}` for the server
  to reattach to it, with a parked one woken first. A machine that failed, or
  a conversation that has not moved, stops the server, with the prompt it was
  started for reported as not run.
  """
  @spec follow(map(), map()) :: {:follow, map(), Sandbox.t()} | {:stop, :normal, map()}
  def follow(state, conv) do
    await(state, conv.id, System.monotonic_time(:millisecond) + follow_wait_ms())
  end

  defp await(state, conv_id, deadline) do
    # ownership: the server's own conversation and its current machine.
    conv = Conversations._unsafe_get_conversation(conv_id)
    sandbox = conv && conv.sandbox_id && Conversations._unsafe_get_sandbox(conv.sandbox_id)

    cond do
      is_nil(sandbox) or sandbox.id == state.sandbox_id ->
        not_followed(state, "not_moved")

      sandbox.status == "ready" ->
        {:follow, %{state | sandbox_id: sandbox.id, runtime_session_id: nil}, sandbox}

      sandbox.status == "suspended" ->
        case sandbox.id
             |> Machine.ensure_up(actor: "system:wake", requesting_conversation_id: conv_id)
             |> Fountain.Conversations.Termination.tidy_after_resume(sandbox.id) do
          {:ok, _} -> await(state, conv_id, deadline)
          {:error, reason} -> not_followed(state, reason)
        end

      sandbox.status in ["pending", "starting"] and
          System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(@poll_ms)
        await(state, conv_id, deadline)

      true ->
        not_followed(state, "rebuild_unfinished")
    end
  end

  defp not_followed(state, reason) do
    Logger.info(
      "conv #{state.conversation_id}: not following the workspace's machine (#{inspect(reason)})"
    )

    retryable_stop(state, to_string_reason(reason), unrun_reason(reason), bare: false)
    {:stop, :normal, state}
  end

  # A follow that did not happen: the refusal's own word when it has one (a
  # resume's `fleet_full`), otherwise a machine still lost, which the next
  # prompt rebuilds.
  defp unrun_reason(reason) when is_atom(reason), do: reason
  defp unrun_reason({reason, _detail} = refusal) when is_atom(reason), do: refusal
  defp unrun_reason(_reason), do: :machine_lost

  defp to_string_reason(reason) when is_binary(reason), do: reason
  defp to_string_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_string_reason(reason), do: inspect(Provision.without_output(reason))
end
