defmodule Fountain.Conversations.Launch do
  @moduledoc """
  The channel door of a conversation launch: `start_or_resume_conversation/2`,
  the resume of a conversation already bound to a channel, the channel
  rotation it can be asked for, and the lookup a channel resolves to.

  Stage 7a of #2175 (one owner per conversation lifecycle verb) gave this
  module the channel door. Stage 7b added the fresh `start_conversation/2`
  family — the reservation, the admission inference resolve and the one
  `child_spec/3` builder every launch path now shares. Every launch
  provisions a sandbox of its own: attaching to an existing one by
  `sandbox_id` was removed with persistent homes (#2676). `Conversations`
  still keeps a delegate for every public name here, so no caller moves.
  """

  import Ecto.Query

  require Logger

  alias Fountain.Agents
  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.InferenceResolution

  alias Fountain.Conversations.{
    ConfigHome,
    Conversation,
    ConversationServer,
    InferenceBinding,
    PromptDelivery,
    Sandbox
  }

  alias Fountain.InferenceCredentials
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Machine
  alias Fountain.Repo

  @doc """
  Create a new sandbox + conversation pair, start a ConversationServer
  to drive it, optionally seed with the first prompt. Returns the
  persisted Conversation (preloaded).

  ## Required attrs
    - `agent_id`              — agent to run
    - `prompt`                — optional first prompt (sends turn 1 immediately)
    - `client_request_id`     — optional; the caller's name for that prompt, carried to the
                                turn it opens (#1406). Ignored without a `prompt`
    - `machine_name`          — optional suffix for the sandbox name, which is always
                                "fountain-<short-user-id>-<suffix>"; defaults to a random
                                suffix. Refused with `sandbox_api_access: "none"` (#1632).
                                `sprite_name` is its deprecated old name, accepted until
                                #2776; both with different values is `:machine_name_conflict`
    - `vault_id`              — optional vault whose secrets override the env's
    - `environment_id`        — optional environment to provision from instead of the
                                agent's own (#783); subject to `agent.allowed_environment_ids`
    - `permission_policy`     — optional per-tool permission override (#939); may only
                                narrow the agent's own policy, never widen it
    - `model`                 — optional model override (ADR 0061), checked as the agent's
                                own model is; nil runs the agent's model
    - `cwd`                   — optional absolute working directory for the agent, under
                                `/home/sprite` (or `/tmp` for gemini), created if missing and
                                fixed for the conversation's life; nil runs the runtime's
                                default (`Fountain.Conversations.ConfigHome.validate_cwd/2`)
    - `session_config`        — refused unless nil or `{}`: a conversation requests its
                                agent's ACP session config options, copied here and not
                                read again (ADR 0062, addendum of 2026-10-15, agent only)
    - `sandbox_mode`          — optional; only "ephemeral" is accepted (#2676): every
                                conversation gets a sandbox of its own
    - `sandbox_api_access`    — "owner" (default) or "none"
    - `source`                — optional; one of "ui", "api", "agent" (default "api")
    - `parent_conversation_id` — optional; UUID of the conversation that spawned this one.
                                It and `:sandbox_key_id` set `depth`; past `max_depth/0`
                                the start is refused with `conversation_depth_exceeded`.
                                A start with `:sandbox_key_id` is always a child of that
                                key's conversation (ADR 0096): this may be absent or name
                                it, and anything else is `:parent_not_found`
    - `title`                 — optional display title
    - `labels`                — optional `key => value` strings (#1637); see `Conversations.Labels`

  ## Options

  Attribution (`:actor`, `:request_ip`, `:sandbox_key_id`), and
  `:rotate_from` for a channel rotation. `:sandbox_key_id` also names the
  conversation a sandbox's start comes from, which sets the new
  conversation's `depth` (see `max_depth/0`).
  """
  def start_conversation(attrs, opts \\ [])

  # `sandbox_id` attached a conversation to a machine the caller already had
  # (ADR 0023 gate 3). Every conversation has a sandbox of its own since
  # #2676, so naming one is refused rather than silently ignored: a caller
  # that asked for a shared disk must not be handed a fresh one.
  def start_conversation(%{"sandbox_id" => sandbox_id}, _opts)
      when is_binary(sandbox_id) and sandbox_id != "",
      do: {:error, :sandbox_attach_unsupported}

  # A conversation's own `session_config` was removed (ADR 0062, addendum of
  # 2026-10-15, agent only): the options are the agent's. Refused rather than
  # ignored, as `sandbox_id` is, so a caller that asked for an option learns
  # it would not get it. nil and `{}` ask for nothing and are accepted.
  def start_conversation(%{"session_config" => config}, _opts)
      when not is_nil(config) and config != %{},
      do: {:error, :session_config_agent_only}

  def start_conversation(%{"agent_id" => agent_id, "user_id" => user_id} = attrs, opts)
      when is_binary(user_id) do
    response_timing = %{started_mono: System.monotonic_time(:millisecond), path: "cold"}

    with :ok <- Conversations.require_provider_commit_boundary(),
         :ok <- Fountain.Conversations.PromptInput.validate_initial(attrs),
         %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(agent),
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent),
         :ok <- check_sandbox_mode(attrs["sandbox_mode"]),
         {:ok, api_access} <- resolve_sandbox_api_access(attrs["sandbox_api_access"]),
         {:ok, requested_name} <- requested_machine_name(attrs),
         :ok <- check_sandbox_api_name(api_access, requested_name),
         {:ok, perm_policy} <-
           Conversations.resolve_permission_policy(attrs["permission_policy"], agent),
         {:ok, model} <- Conversations.resolve_model(attrs["model"], agent),
         {:ok, cwd} <- ConfigHome.validate_cwd(attrs["cwd"], agent.runtime),
         sandbox_key_id = Keyword.get(opts, :sandbox_key_id),
         {:ok, parent} <- resolve_parent(attrs["parent_conversation_id"], user_id, sandbox_key_id),
         {:ok, depth} <- resolve_depth(parent, user_id, sandbox_key_id),
         parent_id = parent && parent.id,
         {:ok, inference_source} <-
           resolve_admission_inference(user_id, agent, env_id, vault_id, model),
         {:ok, provider} <- Conversations.resolve_sandbox_provider(agent),
         {:ok, machine_name} <-
           Conversations.mint_machine_name(provider, user_id, requested_name),
         conv_id = Ecto.UUID.generate(),
         {:ok, {sandbox, conv}} <-
           reserve_initial_conversation(
             %{
               environment_id: env_id || agent.environment_id,
               agent_id: agent.id,
               vault_id: vault_id,
               machine_name: machine_name,
               status: "pending",
               provider: Atom.to_string(provider),
               user_id: user_id
             },
             %{
               id: conv_id,
               # Its own config home, named for it, and the working directory
               # the launch asked for (nil: the runtime's default). Both are
               # fixed for the conversation's life (ADR 0097).
               config_home: ConfigHome.for_launch(conv_id),
               cwd: cwd,
               agent_id: agent.id,
               # Ownership: agent came from the scoped get_agent above.
               agent_version_id: Agents._unsafe_current_version_id(agent.id),
               vault_id: vault_id,
               environment_id: env_id,
               inference_source: Source.dump(inference_source),
               user_id: user_id,
               runtime: agent.runtime,
               status: "pending",
               source: source(attrs, sandbox_key_id),
               parent_conversation_id: parent_id,
               depth: depth,
               channel_id: attrs["channel_id"],
               title: attrs["title"],
               sandbox_api_access: api_access,
               permission_policy: perm_policy,
               model: model,
               # The agent's options as of now, kept for the conversation's
               # life: an edit to the agent reaches new conversations only
               # (ADR 0062, addendum of 2026-10-15; #2664).
               agent_session_config: Agents.SessionConfig.for_launch(agent),
               labels: attrs["labels"] || %{}
             },
             opts
           ) do
      # Recorded here rather than in either branch below: both of them return
      # {:ok, conv}. The row exists and the sandbox reservation is spent even
      # when the server fails to start, so "a conversation was created" is
      # true either way, and a trail that only logged the happy path would
      # under-report exactly the runs someone is trying to explain.
      #
      # The prompt is described, never quoted — see `send_prompt/4`.
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
          "with_prompt" => is_binary(attrs["prompt"]) and attrs["prompt"] != "",
          "parent_conversation_id" => parent_id,
          "depth" => depth,
          "model" => model,
          "cwd" => cwd,
          "agent_session_config" => conv.agent_session_config
        }
      })

      # Through the one registration door (ADR 0058 stage 6a), like every other
      # starter: it starts the server under the per-sandbox lock. The
      # supervisor's answer comes back verbatim, so the `{:error, reason}` arm
      # below still catches `{:already_started, _}` and fails the launch
      # exactly as it did.
      start_result =
        Conversations.register_server(
          sandbox.id,
          child_spec(conv.id, sandbox.id, runtime_module)
        )

      case start_result do
        {:ok, pid} ->
          if is_binary(attrs["prompt"]) and attrs["prompt"] != "" do
            PromptDelivery.queue(
              pid,
              attrs["prompt"],
              attrs["images"] || [],
              Fountain.Conversations.PromptReceipt.accept(
                conv.id,
                Keyword.put(PromptDelivery.from_request(attrs), :response_timing, response_timing)
              )
            )
          end

          # ownership: conv is the row reserve_initial_conversation just
          # created above, in this same launch.
          result = Conversations._unsafe_get_conversation!(conv.id)

          if result.parent_conversation_id do
            root_id = get_root_conversation_id(result.id)
            broadcast_graph_update(root_id)
          end

          Conversations.broadcast_sidebar_update(user_id)
          {:ok, result}

        {:error, reason} ->
          # The conversation row was created successfully; mark it and its
          # sandbox failed so the status is visible on the conversation page,
          # then return it so callers (UI + API) navigate there rather than
          # leaving the user stuck on the new-conversation form.
          Logger.error(
            "ConversationServer failed to start for conv #{conv.id}: #{inspect(reason)}"
          )

          if fail_initial_start(conv, sandbox) == :failed,
            do: restore_rotated_channel(conv, opts)

          case Conversations.get_conversation(conv.id, user_id) do
            nil ->
              {:error, :not_found}

            result ->
              Conversations.broadcast_sidebar_update(user_id)
              {:ok, result}
          end
      end
    else
      nil ->
        {:error, :not_found}

      {:error, _} = err ->
        err
    end
  end

  defp resolve_sandbox_api_access(access) when access in [nil, "owner"], do: {:ok, "owner"}
  defp resolve_sandbox_api_access("none"), do: {:ok, "none"}
  defp resolve_sandbox_api_access(_access), do: {:error, :invalid_sandbox_api_access}

  # ADR 0045's machine isolation is a claim about a machine, not about a row:
  # a `none` conversation must be alone on a fresh one. A caller-supplied name
  # can name a machine that already exists — the provider adopts it rather
  # than failing — so the two cannot be asked for together (#1632).
  defp check_sandbox_api_name("none", name) when is_binary(name) and name != "",
    do: {:error, :invalid_sandbox_api_access}

  defp check_sandbox_api_name(_access, _name), do: :ok

  # `machine_name` is the provider-neutral name; `sprite_name` is the name it
  # had while Sprites was the only provider, accepted until the Fountain-name
  # aliases go (#2108, #2776). An empty value is no value, as
  # `mint_machine_name/3` treats it. Two different names are refused rather
  # than one silently winning.
  defp requested_machine_name(attrs) do
    case {blank_to_nil(attrs["machine_name"]), blank_to_nil(attrs["sprite_name"])} do
      {nil, old} -> {:ok, old}
      {new, nil} -> {:ok, new}
      {same, same} -> {:ok, same}
      {_new, _old} -> {:error, :machine_name_conflict}
    end
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  # `sandbox_mode` chose between a machine of the conversation's own and the
  # agent identity's persistent home (ADR 0023). Homes were removed (#2676);
  # clients that still send `"ephemeral"` keep working, and `"persistent"`
  # is refused with the reason, rather than quietly given a machine that
  # forgets everything when the conversation ends.
  # A sandbox's start is the agent's, header or not: its parent is always the
  # key's conversation (`resolve_parent/3`).
  defp source(_attrs, sandbox_key_id) when is_binary(sandbox_key_id), do: "agent"
  defp source(attrs, nil), do: attrs["source"] || "api"

  defp check_sandbox_mode(mode) when mode in [nil, "", "ephemeral"], do: :ok
  defp check_sandbox_mode("persistent"), do: {:error, :persistent_sandbox_removed}
  defp check_sandbox_mode(_mode), do: {:error, :invalid_sandbox_mode}

  # `parent_conversation_id` arrives from a client-supplied header
  # (X-Managoat-Parent-Conversation-Id). The changeset only enforced an FK, so
  # any conversation id in the system was accepted — including another tenant's,
  # which grafted this conversation onto their spawn tree and theirs onto ours.
  #
  # A legitimate spawn comes from inside a sprite holding that tenant's own
  # token, so ownership always matches; a mismatch is a bug or an attack.
  #
  # A sandbox's own key starts children of its conversation and nothing else
  # (#2981, ADR 0096), so the tree that key is confined to stays closed: with
  # no header the parent is the key's conversation, and a header naming any
  # other conversation is refused as an unknown parent. A key no conversation
  # names (a rotated-away one) starts nothing.
  defp resolve_parent(header, user_id, nil), do: resolve_parent(header, user_id)

  defp resolve_parent(header, user_id, sandbox_key_id) do
    case Conversations.get_conversation_for_callback_key(sandbox_key_id, user_id) do
      %Conversation{id: id} = own when header in [nil, "", id] -> {:ok, own}
      _ -> {:error, :parent_not_found}
    end
  end

  defp resolve_parent(nil, _user_id), do: {:ok, nil}
  defp resolve_parent("", _user_id), do: {:ok, nil}

  defp resolve_parent(id, user_id) when is_binary(id) and is_binary(user_id) do
    # A header that is not a uuid is not a conversation anyone owns.
    # `get_conversation/2` reads it as nil rather than raising (#1679), so this
    # stays the plain lookup it was.
    case Conversations.get_conversation(id, user_id) do
      nil -> {:error, :parent_not_found}
      conv -> {:ok, conv}
    end
  end

  @default_max_depth 5

  @doc """
  The deepest a spawn chain may go (#1269, ADR 0083): a conversation whose
  `depth` would be greater is refused with `conversation_depth_exceeded`.
  `CONVERSATION_MAX_DEPTH`, default #{@default_max_depth}; 0 lets no sandbox
  start a conversation.
  """
  @spec max_depth() :: non_neg_integer()
  def max_depth do
    Application.get_env(:fountain, :conversations, [])
    |> Keyword.get(:max_depth, @default_max_depth)
  end

  # A conversation's depth is one more than the conversation that started it,
  # and 0 when nothing did. Two things can name the starter, and the deeper of
  # them counts:
  #
  #   * the parent header, which a client sets and so may also leave out;
  #   * the sandbox callback token the request carries, which names the
  #     conversation it was minted for (`callback_api_key_id`) whether or not
  #     the header was sent. This is what stops an agent from resetting its
  #     chain to 0 by omitting the header.
  #
  # A start made with the owner's own key and no header is depth 0 however
  # it was made: the server cannot tell it came from inside a sandbox.
  defp resolve_depth(parent, user_id, sandbox_key_id) do
    starter_depth = max(depth_of(parent), depth_of_key(sandbox_key_id, user_id))
    depth = starter_depth + 1
    ceiling = max_depth()

    if depth > ceiling,
      do: {:error, {:conversation_depth_exceeded, depth, ceiling}},
      else: {:ok, depth}
  end

  # -1 is "no starter", so a top-level start comes out at depth 0.
  defp depth_of(nil), do: -1
  defp depth_of(%Conversation{depth: depth}), do: depth

  defp depth_of_key(nil, _user_id), do: -1

  defp depth_of_key(key_id, user_id),
    do: key_id |> Conversations.get_conversation_for_callback_key(user_id) |> depth_of()

  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
  # sobelow_skip ["SQL.Query"] — static SQL with a bound $1 UUID parameter.
  defp get_root_conversation_id(conversation_id) do
    sql = """
    WITH RECURSIVE ancestors(id, parent_conversation_id) AS (
      SELECT id, parent_conversation_id FROM conversations WHERE id = $1
      UNION ALL
      SELECT c.id, c.parent_conversation_id FROM conversations c
      INNER JOIN ancestors a ON c.id = a.parent_conversation_id
    )
    SELECT id FROM ancestors WHERE parent_conversation_id IS NULL LIMIT 1
    """

    {:ok, uuid} = Ecto.UUID.dump(conversation_id)

    case Repo.query!(sql, [uuid]) do
      %{rows: [[root_id]]} ->
        {:ok, str_id} = Ecto.UUID.load(root_id)
        str_id

      _ ->
        conversation_id
    end
  end

  defp broadcast_graph_update(root_id) do
    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      "conversations:graph:#{root_id}",
      {:graph_updated}
    )
  end

  defp reserve_inference(conv) do
    InferenceBinding.reserve(conv, Source.load(conv.inference_source))
  end

  # A start that never started: the row pair is failed together so the status
  # is visible on the conversation page.
  #
  # The machine's half goes through its owner (ADR 0058 stage 7b) and the
  # conversation's stays here, which splits a transaction `main` held across
  # both. The order is the machine first, deliberately. A failure between the
  # two leaves a `pending` conversation pointing at a `failed` machine, which
  # the next prompt resolves on its own — `Wake.wake_conversation/2` reads a
  # terminal row as `:create_new` — where the other order leaves a `pending`
  # machine holding a fleet slot with no server, which nothing but the reaper's
  # hourly pass collects.
  #
  # The machine's half goes through its owner (ADR 0058 stage 7b); the
  # conversation's is `:before_write`, run under the lease the protocol holds
  # and before it writes the row. So the *order* is `main`'s — conversation,
  # then machine, then the usage effect that observes both — without the
  # transaction that used to hold them together, which the machine's row can no
  # longer be part of. The binding check that used to be made under the advisory
  # lock is made there too: a delayed start error owns only its original,
  # still-pending binding, and a machine somebody has since started using is not
  # this error's to fail.
  defp fail_initial_start(conv, sandbox) do
    retired =
      Machine.fail_provision(sandbox.id,
        actor: "system:launch",
        reason: :server_start_failed,
        conversation_id: conv.id,
        before_write: &fail_pending_binding(&1, conv, sandbox)
      )

    case retired do
      {:ok, :failed} -> :failed
      _ -> :stale
    end
  end

  # Runs inside the protocol's own transaction, so this opens none of its own:
  # a `Repo.transaction` here would be a savepoint that buys nothing, and the
  # rollback that matters is the outer one.
  #
  # Match turn admission's parent-then-sandbox order: the machine is already
  # this caller's by lease, so the only lock taken here is the conversation's
  # row.
  defp fail_pending_binding(%Sandbox{} = machine, conv, sandbox) do
    parent = Repo.one(from c in Conversation, where: c.id == ^conv.id, lock: "FOR UPDATE")

    # ownership: conv/sandbox are the pair `fail_initial_start/2` was called
    # for, both created by this launch; `machine` is the row the protocol read
    # under the lease it holds, and `parent` is re-read `FOR UPDATE` just above.
    # The turn count below is scoped to that same machine.
    if pending_initial_binding?(parent, machine, conv, sandbox) and
         Conversations._unsafe_running_turns_elsewhere(sandbox.id, nil) == 0 do
      parent |> Conversation.changeset(%{status: "failed"}) |> Repo.update!()
      :ok
    else
      :stale
    end
  end

  defp pending_initial_binding?(%Conversation{} = parent, %Sandbox{} = machine, conv, sandbox) do
    Map.take(parent, [:user_id, :sandbox_id, :status]) ==
      %{user_id: conv.user_id, sandbox_id: sandbox.id, status: "pending"} and
      Map.take(machine, [:user_id, :provider, :machine_name, :status]) ==
        %{
          user_id: conv.user_id,
          provider: sandbox.provider,
          machine_name: sandbox.machine_name,
          status: "pending"
        }
  end

  defp pending_initial_binding?(_, _, _, _), do: false

  # An unlocked read was not enough: `create_sandbox/1` and the conversation
  # insert take `KEY SHARE` on `users` through their foreign keys, and any
  # write that holds that row `FOR UPDATE` would stall them. Taking `FOR SHARE`
  # out here
  # both settles the wait outside the fleet lock and satisfies those foreign
  # keys, so the inserts below cannot block on it. The rotation unbind is the
  # same category of wait and joins them.
  #
  # This is one transaction: the nested `Repo.transaction` inside
  # `with_sandbox_reservation/2` joins it rather than opening another, so the
  # sandbox and conversation still commit or roll back together.
  # That is also why the `case` below re-raises the inner rollback with its
  # reason: a nested rollback the outer transaction does not re-raise reaches
  # the caller as `{:error, :rollback}`, which would turn every fleet refusal
  # into a 500 instead of a 503.
  #
  # The wait does not disappear, it changes hands. This transaction holds
  # `users FOR SHARE` for its whole life, the fleet-lock wait included, and
  # `FOR SHARE` conflicts with `FOR UPDATE` — so a write that locks this
  # tenant's user row queues behind its own in-flight launch, which may itself
  # be queued behind every other tenant's. A tenant-scoped wait beats a
  # fleet-wide one, which is why it is the right trade.
  defp reserve_initial_conversation(sandbox_attrs, conversation_attrs, opts) do
    Repo.transaction(fn ->
      # Set/secret mutations take this same tenant lock. Take it before the
      # fleet reservation so a source edit cannot stall every tenant's launch.
      :ok = InferenceCredentials.lock_source(conversation_attrs.user_id)

      Repo.one(
        from u in Fountain.Accounts.User,
          where: u.id == ^conversation_attrs.user_id,
          select: u.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      Repo.one(
        from a in Agents.Agent,
          where:
            a.id == ^conversation_attrs.agent_id and a.user_id == ^conversation_attrs.user_id,
          select: a.id,
          lock: "FOR SHARE"
      ) || Repo.rollback(:not_found)

      case unbind_rotated_channel(conversation_attrs, opts) do
        :ok -> :ok
        {:error, reason} -> Repo.rollback(reason)
      end

      # The sandbox's implicit workspace (ADR 0097), from the same resolved
      # environment, vault and provider as its row. Inserted here, before the
      # fleet lock, so the global critical section is no longer than it was; a
      # refused reservation rolls it back with everything else. A new row, so
      # the live-workspace index cannot refuse the sandbox below.
      workspace =
        case Fountain.Workspaces.insert_implicit(sandbox_attrs) do
          {:ok, workspace} -> workspace
          {:error, reason} -> Repo.rollback(reason)
        end

      result =
        Fountain.Quotas.with_sandbox_reservation([provider: sandbox_attrs.provider], fn ->
          with {:ok, sandbox} <-
                 Fountain.Machines.Provision.reserve(
                   Map.put(sandbox_attrs, :workspace_id, workspace.id)
                 ),
               {:ok, conv} <-
                 Conversations.insert_conversation_row(
                   conversation_attrs
                   |> Map.put(:sandbox_id, sandbox.id)
                   |> Map.put(:workspace_id, workspace.id)
                 ),
               :ok <- reserve_inference(conv) do
            {:ok, {sandbox, conv}}
          end
        end)

      case result do
        {:ok, reserved} -> reserved
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  @doc """
  What admission resolves the launch's inference to: the user's own
  credential for the model's provider (ADR 0075). Not a request-facing entry
  point.
  """
  def resolve_admission_inference(user_id, agent, env_id, vault_id, model \\ nil) do
    with {:ok, source, _credentials} <-
           InferenceResolution.select(user_id, agent,
             environment_id: env_id,
             vault_id: vault_id,
             model: model
           ) do
      {:ok, source}
    end
  end

  @doc """
  The child spec for a `ConversationServer`. Built once here because
  the literal was written three times — `start_conversation/2`'s fresh
  clause above, `Wake.start_conversation_server/5` and the rehydrator's boot
  sweep (`Conversations.Rehydrator`) — and the three varied on exactly these
  three keys: `conversation_id`, `sandbox_id` and `runtime_module`. No
  prompt ever belongs here: the supervisor restarts a crashed child from
  its *stored* spec, and under Horde it replayed that spec on every deploy,
  so a prompt baked in resends the user's last message
  (`prompt_replay_test.exs`). `extra` exists only for the rehydrator, which
  keeps its own explicit `initial_prompt: nil` — a note-to-self that the
  field was considered and deliberately left out, not an omission.
  """
  def child_spec(conversation_id, sandbox_id, runtime_module, extra \\ []) do
    {ConversationServer,
     [
       conversation_id: conversation_id,
       sandbox_id: sandbox_id,
       runtime_module: runtime_module
     ] ++ extra}
  end

  @doc """
  Like `start_conversation/2`, but a conversation already bound to
  `attrs["channel_id"]` is resumed instead of a new one being opened.

  The channel key is opaque and client-supplied — a chat thread id from ACP
  `session/new` `_meta.channelId` (#774). A client that forgets its sessions
  (a restarted chat harness) then lands back on the same conversation, and so
  the same sandbox and workspace, rather than opening a fresh one per restart.

  Resumes the **latest live** conversation for the same user + agent + vault
  + environment override + channel — `terminated` and `failed` ones are past
  resuming, so a new one is opened and becomes the binding. So is one whose
  *sandbox* is `terminated` or `failed` (#779): the machine is gone, and the
  workspace with it, so the channel gets a new conversation on a working one
  rather than a continuous-looking transcript on a blank disk. A `suspended`
  sandbox is parked, not gone, and still resumes. Returns `{:ok, conv,
  :resumed}` or `{:ok, conv, :created}`; without a `channel_id` it always
  creates.

  `attrs["fresh"]` (`true`) skips the resume this once: the conversation
  currently bound to the channel is unbound (its `channel_id` cleared — it
  keeps running, and the sandbox reaper retires it like any other idle one)
  and a new one is opened as the binding. It is how a chat harness relays its
  owner's `!rotate` — ACP `session/new` `_meta.freshSession` — through a
  binding that would otherwise hand the old conversation straight back.
  Unbinding, rather than relying on "newest wins", keeps the outcome
  independent of `inserted_at`'s one-second precision. Admission commits the
  old unbinding and the replacement together. A refused replacement preserves
  the old binding; a later startup/prompt failure restores it unless another
  rotation has already moved the binding. Concurrent rotations of the same
  binding return a channel validation error to the loser.

  Two concurrent first calls for one channel can both create; the next call
  resumes whichever is newer. Nothing is audited on the resume path unless
  `attrs["labels"]` actually changes something: it is the same conversation,
  so labels merge into the row it hands back (#1637) and that write records
  `conversation.labels_set` like any other.
  """
  def start_or_resume_conversation(attrs, opts \\ [])

  # Refused on a resume as on a launch (`start_conversation/2`).
  def start_or_resume_conversation(%{"session_config" => config}, _opts)
      when not is_nil(config) and config != %{},
      do: {:error, :session_config_agent_only}

  def start_or_resume_conversation(
        %{"channel_id" => channel_id, "agent_id" => agent_id, "user_id" => user_id} = attrs,
        opts
      )
      when is_binary(channel_id) and channel_id != "" do
    with %Agents.Agent{} = agent <- Agents.get_agent(agent_id, user_id) || {:error, :not_found},
         {:ok, vault_id} <- Conversations.resolve_vault_id(attrs["vault_id"], user_id, agent),
         {:ok, env_id} <-
           Conversations.resolve_environment_id(attrs["environment_id"], user_id, agent) do
      case find_channel_conversation(user_id, agent.id, vault_id, env_id, channel_id) do
        %Conversation{} = conv ->
          if outside_sandbox_tree?(conv, user_id, Keyword.get(opts, :sandbox_key_id)),
            do: {:error, :not_found},
            else: resume_or_rotate(conv, agent, attrs, opts)

        nil ->
          with {:ok, conv} <- start_conversation(attrs, opts),
               do: {:ok, conv, :created}
      end
    end
  end

  def start_or_resume_conversation(attrs, opts) do
    with {:ok, conv} <- start_conversation(attrs, opts), do: {:ok, conv, :created}
  end

  # A sandbox's own key reaches its conversation tree only (ADR 0096): a
  # channel bound to a conversation outside it reads as not found, rather
  # than handing back, relabelling or rotating that conversation.
  defp outside_sandbox_tree?(_conv, _user_id, nil), do: false

  defp outside_sandbox_tree?(%Conversation{} = conv, user_id, sandbox_key_id) do
    case Conversations.get_conversation_for_callback_key(sandbox_key_id, user_id) do
      %Conversation{id: root_id} -> not Conversations.in_spawn_tree?(root_id, conv.id, user_id)
      nil -> true
    end
  end

  defp resume_or_rotate(conv, agent, attrs, opts) do
    if fresh_requested?(attrs) do
      with {:ok, fresh} <-
             start_conversation(
               attrs,
               Keyword.put(opts, :rotate_from, conv.id)
             ),
           do: {:ok, fresh, :created}
    else
      with {:ok, conv} <- resume_channel(conv, agent, attrs, opts),
           do: {:ok, conv, :resumed}
    end
  end

  defp resume_channel(conv, agent, attrs, opts) do
    result =
      InferenceCredentials.with_source_lock(conv.user_id, fn ->
        Conversations.with_sandbox_lock(conv.sandbox_id, fn ->
          # Match turn admission and teardown: sandbox advisory lock, then
          # conversation row. Codex reservation takes the sandbox row only
          # after this conversation lock too.
          current =
            Repo.one(
              from c in Conversation,
                where: c.id == ^conv.id and c.user_id == ^conv.user_id,
                lock: "FOR UPDATE",
                preload: [:sandbox, :agent, :vault, :agent_version]
            )

          # Ownership: `current` is the tenant-scoped `FOR UPDATE` read above.
          with %Conversation{} = current <- current || {:error, :not_found},
               :ok <-
                 if(current.sandbox_id == conv.sandbox_id,
                   do: :ok,
                   else: {:error, :provisioning}
                 ),
               :ok <- check_sandbox_api_resume(current, attrs["sandbox_api_access"]),
               :ok <- check_model_resume(current, agent, attrs["model"]),
               :ok <- ConfigHome.check_resume(current, attrs["cwd"]),
               {:ok, source} <- Conversations.resolve_saved_inference(current, agent),
               {:ok, current, audit} <-
                 Conversations.resume_labels(current, attrs["labels"], opts),
               :ok <- InferenceBinding.reserve(current, source) do
            {:ok, {Repo.reload!(current), audit}}
          end
        end)
      end)

    with {:ok, {conv, audit}} <- result do
      Conversations.audit_labels(conv, audit, opts)
      {:ok, conv}
    end
  end

  defp check_sandbox_api_resume(_conv, nil), do: :ok
  defp check_sandbox_api_resume(%Conversation{sandbox_api_access: access}, access), do: :ok
  defp check_sandbox_api_resume(_conv, _access), do: {:error, :invalid_sandbox_api_access}

  # The model is not part of the channel's resume key (ADR 0061 decision 5),
  # so a request can name one the conversation it resumes does not run.
  # Refused rather than resumed on the old model, which would take the field
  # and ignore it. Compared with the model the conversation runs, so naming
  # its agent's model resumes one with no override. An omitted model resumes
  # on whatever the conversation runs.
  defp check_model_resume(_conv, _agent, model) when model in [nil, ""], do: :ok

  defp check_model_resume(conv, agent, model) do
    case InferenceResolution.model(conv, agent) do
      ^model -> :ok
      current -> {:error, {:conversation_model_differs, current}}
    end
  end

  # `true` or `"true"` — the ACP adapter sends a JSON boolean, a hand-built
  # request may send a string. Anything else is not a request.
  defp fresh_requested?(%{"fresh" => fresh}), do: fresh in [true, "true"]
  defp fresh_requested?(_attrs), do: false

  # The rotated-away conversation stops being the channel's binding. Nothing
  # else about it changes: if it is mid-turn it finishes, and it stays in the
  # user's list under its own id.
  defp unbind_channel(%Conversation{} = conv) do
    conv
    |> Ecto.Changeset.change(channel_id: nil)
    |> Repo.update()
  end

  # Inside admission's transaction, before the attachment's sandbox row lock.
  # Keep the selected conversation stable while replacing its binding; reject
  # a competing rotation that has already moved it.
  # Public: `reserve_initial_conversation/4` and `Fountain.Machines.Binding.attach/3`
  # both call it — the attach's transaction moved behind the owner in ADR 0058
  # stage 8b and calls back here for the rotation.
  def unbind_rotated_channel(attrs, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil ->
        :ok

      id ->
        case lock_rotation_conversation(id, attrs) do
          %Conversation{channel_id: channel} = conv when channel == attrs.channel_id ->
            with {:ok, _} <- unbind_channel(conv), do: :ok

          :busy ->
            {:error, rotation_conflict("the previous conversation is busy; retry the rotation")}

          _ ->
            {:error, rotation_conflict("binding changed; retry the rotation")}
        end
    end
  end

  # Worker startup and attachment prompt delivery run after admission commits.
  # Restore only while this replacement still owns the binding; a later
  # rotation must win over this failure. Keep the old -> new row lock order.
  # Public: `fail_initial_start/2` and `deliver_attach_prompt/3` both call
  # it, now that stage 7c of #2175 moved the last outside caller
  # (`Fountain.Conversations`' attach) in here too.
  def restore_rotated_channel(conv, opts) do
    case Keyword.get(opts, :rotate_from) do
      nil -> :ok
      id -> report_restore(conv, id, attempt_restore(conv, id))
    end
  end

  defp attempt_restore(conv, id) do
    Repo.transaction(fn ->
      with %Conversation{channel_id: nil} = previous <- lock_rotation_conversation(id, conv),
           %Conversation{channel_id: channel} = replacement
           when channel == conv.channel_id <- lock_rotation_conversation(conv.id, conv) do
        replacement |> Ecto.Changeset.change(channel_id: nil) |> Repo.update!()
        previous |> Ecto.Changeset.change(channel_id: channel) |> Repo.update!()
        :restored
      else
        # Contention on a row this compensation cannot wait for.
        :busy -> Repo.rollback(:busy)
        # A newer rotation already owns the binding, or the rows moved. That
        # rotation must win over this failure, so leaving them alone is right.
        _ -> :superseded
      end
    end)
  rescue
    e -> {:error, e}
  end

  defp report_restore(_conv, _id, {:ok, _outcome}), do: :ok

  # A compensation, not a rollback: nothing retries it and no caller can act on
  # it. Failing silently leaves a channel bound to nothing, which is the bug
  # this path exists to prevent wearing a different hat, so say so.
  defp report_restore(conv, id, other) do
    Logger.warning(
      "conv #{conv.id}: could not restore channel #{inspect(conv.channel_id)} to conv #{id} " <>
        "after a failed rotation: #{inspect(other)}"
    )

    :ok
  end

  defp rotation_conflict(message) do
    %Conversation{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(:channel_id, message)
  end

  # How long a rotation may wait for the row it is replacing. On the fresh path
  # this runs inside `with_sandbox_reservation/2`, which holds the global fleet
  # advisory lock, and the row it wants is the one `_unsafe_create_turn_on_sandbox/3`
  # takes `FOR UPDATE` — so an unbounded wait would let one busy channel stall
  # provisioning for every tenant. Turn admission holds that row for a handful
  # of local queries, so this is orders of magnitude more than it ever
  # legitimately needs, and exceeding it means contention worth reporting
  # rather than waiting out.
  @rotation_lock_timeout_ms 250

  defp lock_rotation_conversation(id, attrs) do
    # Channel/ownership writes must serialize, but FK references may proceed.
    #
    # The bound is scoped to this read and handed straight back: `SET LOCAL`
    # lasts for the whole transaction, and admission goes on to insert rows
    # whose foreign keys take `KEY SHARE` on `users` — which any `FOR UPDATE`
    # on the user row conflicts with. Leaving 250ms in force over those would
    # turn a slow account write into an unrescued error on a path that has
    # none.
    Repo.query!("SET LOCAL lock_timeout = '#{@rotation_lock_timeout_ms}ms'")

    conversation =
      from(c in Conversation,
        where: c.id == ^id and c.user_id == ^attrs.user_id and c.agent_id == ^attrs.agent_id,
        lock: "FOR NO KEY UPDATE"
      )
      |> where_vault(attrs.vault_id)
      |> where_environment(attrs.environment_id)
      |> Repo.one()

    Repo.query!("SET LOCAL lock_timeout = DEFAULT")
    conversation
  rescue
    e in Postgrex.Error ->
      if e.postgres[:code] == :lock_not_available do
        :busy
      else
        reraise(e, __STACKTRACE__)
      end
  end

  # The newest conversation still worth resuming for this binding. `vault_id`
  # is part of the key: two entries on one agent with different vaults are
  # different identities (#727) and must not share a conversation. So is the
  # environment override (#783): an identity that switches environments must
  # not resume a conversation provisioned from the old one.
  #
  # The sandbox is part of it too (#779): the 24 hour ceiling destroys a
  # sandbox while its conversation stays `idle`, and resuming that row wakes
  # onto a *fresh* machine with the workspace gone (#778 makes the turn work;
  # #936 is the memory it loses) inside a transcript that reads as continuous.
  # A channel is better served by a new conversation on a working machine, so
  # the binding follows the machine, not just the conversation row.
  # `suspended` is not in the list: that sandbox is parked, not gone, and its
  # disk wakes back up with the workspace on it.
  defp find_channel_conversation(user_id, agent_id, vault_id, env_id, channel_id) do
    from(c in Conversation,
      join: s in assoc(c, :sandbox),
      where:
        c.user_id == ^user_id and c.agent_id == ^agent_id and c.channel_id == ^channel_id and
          c.status not in ["terminated", "failed"] and
          s.status not in ["terminated", "failed"],
      order_by: [desc: c.inserted_at],
      limit: 1
    )
    |> where_vault(vault_id)
    |> where_environment(env_id)
    |> Repo.one()
  end

  defp where_vault(query, nil), do: from(c in query, where: is_nil(c.vault_id))
  defp where_vault(query, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  defp where_environment(query, nil), do: from(c in query, where: is_nil(c.environment_id))
  defp where_environment(query, id), do: from(c in query, where: c.environment_id == ^id)
end
