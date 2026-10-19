defmodule Fountain.Conversations.WorkspaceLaunch do
  @moduledoc """
  A launch into one of the caller's explicit workspaces (ADR 0097,
  "Launching into a workspace"): `POST /api/conversations` with a
  `workspace_id`, reached through `Fountain.Conversations.Launch.start_conversation/2`.

  The agent supplies the runtime, model, skills, MCP servers, instructions
  and permission policy; the workspace supplies the machine, the environment
  and the vault, and its provider wins over the agent's. So:

    * The workspace must be the caller's and explicit: another account's, an
      implicit one, or one being deleted is `:not_found`.
    * An `environment_id` or `vault_id` that differs from the workspace's is
      `:workspace_fixes_environment`; the workspace's own is accepted.
    * The agent's `allowed_environment_ids` and vault allowlist still apply,
      to the workspace's environment and vault.
    * `sandbox_api_access: "none"` is `:invalid_sandbox_api_access`: it is a
      claim about a machine, and a workspace's machine is shared (ADR 0097,
      "One trust boundary"; ADR 0045).
    * A sandbox's own key may not name a workspace (`:insufficient_scope`):
      a child of a sandbox's conversation gets a sandbox of its own.
    * A `machine_name` is `:machine_name_with_workspace`: the workspace names
      its machine.

  The conversation is bound to the workspace's current sandbox in one commit,
  under the workspace's advisory lock (the one a rebuild's succession and a
  teardown fence take), so it is either moved with the workspace's other
  conversations by a rebuild or bound to the machine the rebuild left. No
  fleet slot is reserved: the fleet counts machines, and the workspace's is
  already counted. With its own config home and working directory, it
  attaches to the machine as a reattach does (`ConversationServer`), so its
  server is started at once when the machine is up. A workspace whose machine
  is parked, still being provisioned, failed or lost gets no server yet: the
  conversation's first prompt wakes it (a wake is lazy per conversation, so a
  launch with no prompt resumes nothing), which resumes a parked machine,
  waits for a provision in progress, retries a failed one and rebuilds a lost one
  (`Fountain.Conversations.Wake`, `Fountain.Conversations.Rebuild`). A prompt
  sent with the launch is handed to that wake.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Agents
  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{ConfigHome, Conversation, Launch, PromptDelivery, Sandbox}
  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Repo
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Workspace

  @terminal_statuses ~w(terminated failed)

  # The machine advisory lock's namespace, keyed by the workspace (ADR 0097
  # step 3b): `Fountain.Conversations`' and `Fountain.Machines.Provision`'s own.
  @machine_lock_namespace 4316

  @doc "Start a conversation in `attrs[\"workspace_id\"]`. See the moduledoc."
  @spec start(map(), keyword()) :: {:ok, Conversation.t()} | {:error, term()}
  def start(
        %{"workspace_id" => workspace_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(workspace_id) and is_binary(user_id) do
    response_timing = %{started_mono: System.monotonic_time(:millisecond), path: "workspace"}

    with :ok <- refuse_sandbox_key(opts),
         :ok <- Conversations.require_provider_commit_boundary(),
         :ok <- Fountain.Conversations.PromptInput.validate_initial(attrs),
         %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         %Workspace{implicit: false} = workspace <-
           Workspaces.get_workspace(workspace_id, user_id) || {:error, :not_found},
         :ok <- check_fixed(attrs, workspace),
         :ok <- check_allowed(agent, workspace),
         :ok <- Launch.check_sandbox_mode(attrs["sandbox_mode"]),
         :ok <- owner_access(attrs["sandbox_api_access"]),
         :ok <- no_machine_name(attrs),
         {:ok, perm_policy} <-
           Conversations.resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, model} <- Conversations.resolve_model(attrs["model"], agent),
         {:ok, cwd} <-
           ConfigHome.validate_launch_cwd(
             attrs["cwd"],
             agent.runtime,
             workspace.environment_id,
             user_id
           ),
         {:ok, parent} <- Launch.resolve_parent(attrs["parent_conversation_id"], user_id, nil),
         {:ok, depth} <- Launch.resolve_depth(parent, user_id, nil),
         {:ok, inference_source} <-
           Launch.resolve_admission_inference(
             user_id,
             agent,
             workspace.environment_id,
             workspace.vault_id,
             model
           ),
         conv_id = Ecto.UUID.generate(),
         {:ok, {sandbox, conv}} <-
           reserve(
             workspace,
             %{
               id: conv_id,
               config_home: ConfigHome.for_launch(conv_id),
               cwd: cwd,
               agent_id: agent.id,
               # Ownership: agent came from the scoped get_agent above.
               agent_version_id: Agents._unsafe_current_version_id(agent.id),
               # Fixed by the workspace (ADR 0097), and named on the row so the
               # live secret refresh and every provision read the workspace's,
               # not the agent's default.
               vault_id: workspace.vault_id,
               environment_id: workspace.environment_id,
               inference_source: Source.dump(inference_source),
               user_id: user_id,
               runtime: agent.runtime,
               status: "pending",
               source: Launch.source(attrs, nil),
               parent_conversation_id: parent && parent.id,
               depth: depth,
               channel_id: attrs["channel_id"],
               title: attrs["title"],
               sandbox_api_access: "owner",
               permission_policy: perm_policy,
               model: model,
               agent_session_config: Agents.SessionConfig.for_launch(agent),
               labels: attrs["labels"] || %{}
             },
             opts
           ) do
      Audit.record(%{
        user_id: user_id,
        action: "conversation.created",
        resource_type: "conversation",
        resource_id: conv.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "agent_id" => agent.id,
          "agent_name" => agent.name,
          "source" => conv.source,
          "with_prompt" => prompt?(attrs),
          "parent_conversation_id" => conv.parent_conversation_id,
          "depth" => depth,
          "model" => model,
          "cwd" => cwd,
          "workspace_id" => workspace.id,
          "agent_session_config" => conv.agent_session_config
        }
      })

      start_server(conv, sandbox, runtime_module, attrs, response_timing)

      # ownership: conv is the row `reserve/3` just created, in this launch.
      result = Conversations._unsafe_get_conversation!(conv.id)

      if result.parent_conversation_id do
        result.id |> Launch.get_root_conversation_id() |> Launch.broadcast_graph_update()
      end

      Conversations.broadcast_sidebar_update(user_id)
      {:ok, result}
    else
      nil -> {:error, :not_found}
      # An implicit workspace is not one a caller names.
      %Workspace{} -> {:error, :not_found}
      {:error, _} = error -> error
    end
  end

  def start(%{"workspace_id" => _}, _opts), do: {:error, :not_found}

  # A sandbox's own key may not name a workspace (ADR 0097): a conversation
  # started from a sandbox is a child, and a child gets a sandbox of its own.
  defp refuse_sandbox_key(opts) do
    if Keyword.get(opts, :sandbox_key_id), do: {:error, :insufficient_scope}, else: :ok
  end

  @doc """
  `:ok` unless `attrs` names an environment or vault other than
  `workspace`'s, which is `{:error, :workspace_fixes_environment}`. For the
  channel resume too.
  """
  @spec check_fixed(map(), Workspace.t()) :: :ok | {:error, :workspace_fixes_environment}
  def check_fixed(attrs, %Workspace{} = workspace) do
    with :ok <- fixed(attrs["environment_id"], workspace.environment_id) do
      fixed(attrs["vault_id"], workspace.vault_id)
    end
  end

  # The workspace's own environment or vault, or none named, is accepted; any
  # other is refused rather than ignored.
  defp fixed(requested, _workspace_value) when requested in [nil, ""], do: :ok

  defp fixed(requested, workspace_value) when is_binary(requested) do
    case Ecto.UUID.cast(requested) do
      {:ok, ^workspace_value} when is_binary(workspace_value) -> :ok
      _ -> {:error, :workspace_fixes_environment}
    end
  end

  defp fixed(_requested, _workspace_value), do: {:error, :workspace_fixes_environment}

  @doc """
  `:ok` when `agent`'s environment and vault allowlists admit `workspace`'s
  environment and vault (ADR 0097: they "still apply"), else
  `{:error, :environment_not_allowed}` or `{:error, :vault_not_allowed}`.
  For the channel resume too, as a resume re-checks an implicit launch's.
  """
  @spec check_allowed(Agents.Agent.t(), Workspace.t()) :: :ok | {:error, atom()}
  def check_allowed(agent, %Workspace{} = workspace) do
    with :ok <- environment_allowed(agent, workspace.environment_id) do
      vault_allowed(agent, workspace.vault_id)
    end
  end

  defp environment_allowed(agent, environment_id) when is_binary(environment_id) do
    if Agents.Agent.environment_allowed?(agent, environment_id),
      do: :ok,
      else: {:error, :environment_not_allowed}
  end

  defp environment_allowed(_agent, nil), do: :ok

  defp vault_allowed(_agent, nil), do: :ok

  defp vault_allowed(agent, vault_id) do
    if Agents.Agent.vault_allowed?(agent, vault_id), do: :ok, else: {:error, :vault_not_allowed}
  end

  # `"none"` exists only on an implicit workspace (ADR 0097, "One trust
  # boundary"): it is a claim that the conversation is alone on a fresh
  # machine.
  defp owner_access(access) do
    case Launch.resolve_sandbox_api_access(access) do
      {:ok, "owner"} -> :ok
      {:ok, "none"} -> {:error, :invalid_sandbox_api_access}
      {:error, _} = error -> error
    end
  end

  @doc false
  # Also the channel resume's, so a resume into a workspace refuses a name too.
  def no_machine_name(attrs) do
    case Launch.requested_machine_name(attrs) do
      {:ok, name} when name in [nil, ""] -> :ok
      {:ok, _name} -> {:error, :machine_name_with_workspace}
      {:error, _} = error -> error
    end
  end

  defp prompt?(attrs), do: is_binary(attrs["prompt"]) and attrs["prompt"] != ""

  # The conversation bound to the workspace's current sandbox, in one commit
  # under the tenant's source lock (as every launch takes it) and then the
  # workspace's machine lock, before any row: the machine layer's order (the
  # advisory lock, then conversations, then the workspace), which a rebuild's
  # succession and a turn admission take too. A rotation's row lock on the
  # conversation it replaces therefore comes after it (review of step 5b: the
  # other order deadlocks against a succession). The workspace is read again
  # under it, so one deleted meanwhile reads as gone, and its current sandbox
  # is the one a rebuild's succession has left.
  defp reserve(%Workspace{} = workspace, conversation_attrs, opts) do
    Repo.transaction(fn ->
      :ok = InferenceCredentials.lock_source(conversation_attrs.user_id)

      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
        @machine_lock_namespace,
        # `Conversations.sandbox_lock_key/1` of any of the workspace's sandboxes.
        :erlang.phash2(workspace.id)
      ])

      Repo.one(
        from(a in Agents.Agent,
          where:
            a.id == ^conversation_attrs.agent_id and a.user_id == ^conversation_attrs.user_id,
          select: a.id,
          lock: "FOR SHARE"
        )
      ) || Repo.rollback(:not_found)

      case Launch.unbind_rotated_channel(conversation_attrs, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      locked =
        Repo.one(
          from(w in Workspace,
            where:
              w.id == ^workspace.id and w.user_id == ^conversation_attrs.user_id and
                not w.implicit,
            lock: "FOR SHARE"
          )
        ) || Repo.rollback(:not_found)

      sandbox = Workspaces.current_sandbox(locked) || Repo.rollback(:not_found)

      if sandbox.transition == "destroying" and sandbox.status not in @terminal_statuses,
        do: Repo.rollback(:sandbox_reset_pending)

      with {:ok, conv} <-
             conversation_attrs
             |> Map.put(:sandbox_id, sandbox.id)
             |> Map.put(:workspace_id, locked.id)
             |> Conversations.insert_conversation_row(),
           :ok <- Launch.reserve_inference(conv) do
        {sandbox, conv}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # The machine is up: its server attaches the conversation now, as a
  # reattach does, and the launch's prompt is queued behind that. Anything
  # else (parked, provisioning, failed, lost), or a server the machine refuses
  # right now (a co-tenant's park holds it), is left to the conversation's
  # first prompt, whose wake resumes, waits for or rebuilds the machine; a
  # prompt sent with the launch is handed to that wake. A launch with no
  # prompt does not resume a parked machine (ADR 0097: wake is lazy).
  defp start_server(conv, %Sandbox{status: "ready"} = sandbox, runtime_module, attrs, timing) do
    case Conversations.register_server(
           sandbox.id,
           Launch.child_spec(conv.id, sandbox.id, runtime_module)
         ) do
      {:ok, pid} ->
        if prompt?(attrs) do
          PromptDelivery.queue(
            pid,
            attrs["prompt"],
            attrs["images"] || [],
            Fountain.Conversations.PromptReceipt.accept(
              conv.id,
              Keyword.put(PromptDelivery.from_request(attrs), :response_timing, timing)
            )
          )
        end

        :ok

      {:error, reason} ->
        Logger.info(
          "conv #{conv.id}: no server on workspace machine #{sandbox.id} yet (#{inspect(reason)})"
        )

        wake_for_prompt(conv, attrs)
    end
  end

  defp start_server(conv, _sandbox, _runtime_module, attrs, _timing),
    do: wake_for_prompt(conv, attrs)

  defp wake_for_prompt(conv, attrs) do
    if prompt?(attrs) do
      Fountain.Conversations.Wake.wake_in_background(
        conv.id,
        {attrs["prompt"], PromptDelivery.from_request(attrs)},
        attrs["images"] || []
      )
    end

    :ok
  end
end
