defmodule Fountain.Conversations.ConversationServer do
  @moduledoc """
  Owns one running conversation: its sprite, the active runtime command (if
  any), and the per-turn state. Streams sprite stdout/stderr into the DB
  (LogEvent rows) and broadcasts on Phoenix.PubSub topic `"conv:<id>"` so
  SSE subscribers can tail it live.

  Lifecycle:
    pending → starting → ready ⇄ running → terminated|failed
  """

  use GenServer, restart: :transient
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.{Conversations, Environments, Vaults}

  alias Fountain.Conversations.{CallbackKey, Connection, Conversation, KeyHandover}
  alias Fountain.Conversations.{Egress, FreshProvision}
  alias Fountain.Conversations.{Lifecycle, MachineEvents, MachineLoss, McpConnections, McpServers}
  alias Fountain.Conversations.{Output, Pending}
  alias Fountain.Conversations.{PromptDelivery, ProvisionWatchdog, Reattachment, ServerPhase}
  alias Fountain.Conversations.{Redaction, SpriteEnv, Termination, TurnLaunch, TurnMachine, Wake}
  alias Fountain.Machines.Machine

  # ── public api ────────────────────────────────────────────────────────────

  def start_link(args) do
    conv_id = Keyword.fetch!(args, :conversation_id)
    GenServer.start_link(__MODULE__, args, name: via(conv_id))
  end

  def via(conv_id), do: {:via, Registry, {Fountain.ConversationRegistry, conv_id}}

  def whereis(conv_id) do
    case lookup(conv_id) do
      {pid, _} -> pid
      nil -> nil
    end
  end

  # The registered server and its phase, or `nil`. Registration is synchronous
  # (ADR 0072), so `nil` means no server; but the registry drops an exited
  # process's entry a moment after it exits, so a pid that is no longer alive
  # is read as no server too, and the caller wakes the conversation rather than
  # calling a process that has gone.
  defp lookup(conv_id) do
    case Registry.lookup(Fountain.ConversationRegistry, conv_id) do
      [{pid, value}] -> if Process.alive?(pid), do: {pid, value}
      [] -> nil
    end
  end

  @registry_settle_ms 3_000
  @registry_poll_ms 50
  @acp_cancel_grace_ms 3_000

  @doc """
  `whereis/1`, but willing to wait for a server that is about to register.

  A launch writes the `pending` sandbox row before it starts the server, so a
  caller that reads that row can arrive in between. A caller that already
  knows a server *should* exist — the sandbox row says `pending` — polls for
  `:conversation_registry_settle_ms` (#{@registry_settle_ms} ms) and never
  decides on one lookup (#1429). Returns `{:ok, pid}` or `:timeout`.

  This is what keeps a `session/new` + first-prompt pair from provisioning two
  sprites for one conversation (#800): the prompt used to miss the registry
  and take `:create_new` while the first server was 20 s from finishing. Under
  Horde the gap was also registry propagation between pods; on one node
  (ADR 0072) it is only the launch's own.
  """
  def await_registered(conv_id, timeout_ms \\ nil) do
    timeout_ms =
      timeout_ms ||
        Application.get_env(:fountain, :conversation_registry_settle_ms, @registry_settle_ms)

    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_registered(conv_id, deadline, 1)
  end

  # `owed` is lookups still due whatever the clock says: the deadline is set
  # before the first, so a stall used to end this after one poll (#1429, #800).
  defp do_await_registered(conv_id, deadline, owed) do
    case whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, pid}

      nil ->
        if owed <= 0 and System.monotonic_time(:millisecond) >= deadline do
          :timeout
        else
          Process.sleep(@registry_poll_ms)
          do_await_registered(conv_id, deadline, owed - 1)
        end
    end
  end

  @doc """
  Send another prompt. If the conversation's GenServer is gone (e.g. server
  restart), transparently wake the conversation — provision a fresh sprite
  and queue this prompt as the first turn of the new sandbox.

  The persisted `runtime_session_id` is what the next turn resumes by
  (`session/resume` under ACP). Note that it only carries the conversation
  while the *sandbox* survives: a runtime session lives in the sandbox
  filesystem, so a wake that provisions a fresh sprite cannot resume it. The
  server clears the id when it provisions fresh (#778, `TurnMachine.forget_runtime_session/4`)
  and the next turn starts a new session on the new disk; `log_events` still
  render the whole transcript.
  """
  def send_prompt(conv_id, prompt, images \\ [], opts \\ []) do
    started_mono = System.monotonic_time(:millisecond)

    result =
      case lookup(conv_id) do
        nil ->
          # `images` travels the wake road too, or the woken turn opens
          # without them while this still answers :ok (#2373; see `Wake`). The
          # correlation rides with the prompt, in the shape `Wake` takes.
          opts = Keyword.put(opts, :response_timing, %{started_mono: started_mono, path: "wake"})
          Wake.for_prompt(conv_id, PromptDelivery.for_wake(prompt, opts), images, opts)

        {pid, phase} ->
          opts = Keyword.put(opts, :response_timing, %{started_mono: started_mono, path: "warm"})
          deliver_or_queue(conv_id, {pid, phase}, prompt, images, opts)
      end

    # Size and image count, never the text. A prompt is the tenant's content —
    # frequently the most sensitive thing in the system — and #545 is explicit
    # that the trail records that a prompt happened, not what it said.
    Termination.audit_lifecycle(conv_id, "conversation.prompted", result, opts, %{
      "prompt_bytes" => byte_size(prompt),
      "image_count" => length(images)
    })

    result
  end

  # A server setting up its machine cannot answer a call until it is done, so
  # the API's prompt (`wake: :background`) is queued behind the setup and
  # answered `queued` once the refusals that need no provider have run, as a
  # prompt to a parked conversation is (#2577). Everyone else calls.
  defp deliver_or_queue(conv_id, {pid, phase}, prompt, images, opts) do
    if Keyword.get(opts, :wake) == :background and phase == ServerPhase.setting_up_value() do
      with :ok <- Wake.admit_prompt_wake(conv_id),
           do:
             PromptDelivery.queue(
               pid,
               prompt,
               images,
               Fountain.Conversations.PromptReceipt.accept(
                 conv_id,
                 PromptDelivery.travelling(opts)
               )
             )
    else
      PromptDelivery.deliver(pid, prompt, images, opts)
    end
  end

  # Public entry points contain common GenServer.call exits here (#412).
  # Provisioning blocks the mailbox, so a timeout answers :provisioning.
  # Normal process death returns :not_running; unclassified exits still
  # propagate.
  @doc false
  def call_server(pid, msg) do
    timeout = Application.get_env(:fountain, :conversation_call_timeout_ms, 30_000)
    GenServer.call(pid, msg, timeout)
  catch
    :exit, {:timeout, _} ->
      {:error, :provisioning}

    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown] ->
      {:error, :not_running}

    :exit, {{:shutdown, _}, _} ->
      {:error, :not_running}
  end

  @doc """
  Deliver the prompt a conversation was started for, after the server exists.

  Deliberately not a `start_link` argument. The supervisor restarts a crashed
  child from its *stored child spec*, so anything in there is replayed — and
  under Horde, every deploy replayed it. A prompt in the spec therefore re-ran
  the user's last message.

  Takes the pid `start_child` returned, not the conversation id: the pid is
  for exactly the server just started, and if that server already died,
  losing the cast is the right outcome (#367).

  A cast rather than a call: it queues behind `handle_continue(:provision)`,
  which can take minutes, and no caller is waiting on the turn to finish.
  """
  def queue_initial_prompt(pid, prompt, images \\ [], opts \\ []) when is_pid(pid) do
    GenServer.cast(pid, PromptDelivery.cast(pid, prompt, images, opts))
  end

  @doc """
  Answer an outstanding permission request (#940).

  Tenant scoping is the caller's job — reach this through
  `Conversations.answer_permission_request/4`, which establishes ownership
  first.

  `{:error, :no_pending_permission}` covers every "too late": another attached
  client answered it, the timeout denied it, the turn ended, or the server is
  no longer running. That is deliberately not distinguished from "never
  existed" — a client that lost the race and a client guessing ids get the same
  answer.
  """
  @spec answer_permission(binary(), String.t(), String.t()) ::
          :ok | {:error, :no_pending_permission | :unknown_option | :not_running}
  def answer_permission(conv_id, request_id, option_id) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_permission, request_id, option_id})
    end
  end

  @doc """
  Answer an outstanding form (`elicitation/create`, #2492) with `action` and,
  for `accept`, `content`.

  The same rules as `answer_permission/3`: tenant scoping is the caller's
  (`Conversations.answer_elicitation_request/6`), and
  `{:error, :no_pending_permission}` is every "too late".
  """
  @spec answer_elicitation(binary(), String.t(), String.t(), map() | nil) ::
          :ok | {:error, term()}
  def answer_elicitation(conv_id, request_id, action, content) do
    case whereis(conv_id) do
      nil -> {:error, :not_running}
      pid -> call_server(pid, {:answer_elicitation, request_id, action, content})
    end
  end

  # ── GenServer ─────────────────────────────────────────────────────────────

  @impl true
  def init(args) do
    # Without trap_exit, terminate/2 only runs on {:stop, …} or a raise — a
    # supervisor or application shutdown (i.e. every deploy) sends an
    # exit signal and skips it, so the callback-token revoke never fired on
    # the most common teardown there is (#322). Trapping makes OTP call
    # terminate/2 on supervisor shutdown, bounded by the child shutdown
    # timeout.
    Process.flag(:trap_exit, true)

    state = %{
      conversation_id: Keyword.fetch!(args, :conversation_id),
      sandbox_id: Keyword.fetch!(args, :sandbox_id),
      runtime_module: Keyword.fetch!(args, :runtime_module),
      user_id: nil,
      # The conversation's config home (`ConfigHome.home/1`, ADR 0097), set
      # with `user_id` once the row is read; every process env points at it.
      config_home: nil,
      handle: nil,
      sprite_env: [],
      # ADR 0019 gate 1a. `brokered` holds the catalog secrets the sandbox
      # never sees (the broker gets them); `broker` is the minted session.
      # Both stay empty/nil on an unbrokered conversation.
      brokered: %{},
      # The tenant's enabled bindings by key (gate 1b), loaded once per
      # provision; what the broker's services are built from.
      broker_bindings: %{},
      # Where the tenant's own brokered secrets came from and which keys they
      # were (#1736); `Egress.refresh_before_turn/1` reads the rows again.
      secret_sources: nil,
      tenant_keys: [],
      # This conversation's one resolved MCP configuration (#1404). See
      # `McpServers.resolve_for_session/2`.
      resolved_mcp_servers: nil,
      # The connections the agent's MCP servers name (ADR 0085), each token's
      # expiry, and the timer that refreshes them during a turn. See
      # `Fountain.Conversations.McpConnections`.
      connections: [],
      connection_expiries: %{},
      connection_timer: nil,
      # The environment's networking shape, enforced at the broker (gate 2).
      broker_network: :unrestricted,
      # What the runtime's default_env/2 is handed (gate 3): the real
      # credentials, or placeholders when the conversation is brokered.
      env_credentials: %{},
      # #1388, ADR 0053: the `InferenceCredentials.Source` that ran this one.
      inference_source: nil,
      inference_model: nil,
      broker: nil,
      current_command: nil,
      current_command_ref: nil,
      current_turn: nil,
      runtime_session_id: nil,
      # OTel span context for the in-flight turn (started in kick_turn,
      # ended in the :exit / :interrupt handlers).
      current_turn_span: nil,
      # Aggregate-metric bookkeeping for the in-flight turn (#536, #535):
      # `%{started_mono: ms, runtime: "claude", provider: "sprites", first_output?: bool}`, set
      # once the turn's command is spawned and dropped on every terminal
      # path. nil whenever no turn is running. Monotonic rather than the
      # turn row's timestamps because `now/0` truncates to the second,
      # which rounds a sub-second turn to a duration of zero.
      turn_metrics: nil,
      # Stream tracer for ACP tool updates into OTel child spans and events.
      stream_tracer: nil,
      # The `session_gone` detail this turn has already been restarted for
      # (#1667), or nil. `TurnMachine` reads it to refuse a second restart.
      turn_session_retry: nil,
      # What the runtime reported about a failed model call in this turn
      # (#2545), or nil. `TurnMachine` reads it when the prompt is answered.
      turn_provider_failure: nil,
      # The ACP peer driving the adapter connection. Monitored
      # rather than linked: a protocol bug must fail a turn, not take down a
      # server that is holding a sprite handle and a tenant's secrets.
      acp_peer: nil,
      # The model env the peer's adapter was spawned with (`Connection.stale_reason/4`).
      acp_model_env: nil,
      # The effective permission policy the peer was started with, which also
      # chose codex's approval mode (`Connection.stale_reason/4`, #2708).
      acp_permission_policy: nil,
      # The callback key whose plaintext the peer's session headers carry
      # (ADR 0086, `Connection.stale_reason/4`). nil for a peer reattached
      # across a deploy, whose key belonged to the previous server.
      acp_callback_key_id: nil,
      # Timer refusing an unanswered permission request (#940).
      permission_timer: nil,
      acp_peer_mon: nil,
      # Timer closing an autonomous turn that went quiet without a
      # `cycle_end` (#817) — an adapter too old to mark its origin must not
      # hold a turn open forever. nil outside an autonomous turn.
      autonomous_quiet: nil,
      # ACP reattach: the `acp` lines already persisted for the in-flight
      # turn, so the sprite's replayed tail is not written twice. Consumed as
      # matches arrive and cleared on a timer; empty outside a reattach
      # window. See attempt_session_attach.
      replay_dedup: MapSet.new(),
      # Per-tenant DEK + decrypted inference credentials. Loaded in
      # handle_continue(:provision) once the conversation row tells us the
      # owning user_id; held for the conversation lifetime; dropped on
      # terminate. See ADR 0008 (BYO inference credentials).
      tenant_key: nil,
      inference_credentials: %{},
      # Plaintext of the per-conversation API key that's injected into the
      # sprite as MANAGOAT_TOKEN. The hash and a row in `api_keys` is the
      # durable record; we keep the raw value in memory only while this
      # GenServer is alive. Rotated on every fresh provision/reattach;
      # revoked in terminate/2.
      callback_token: nil,
      # The id of the key THIS server minted. Revocation acts only on this
      # id, never on whatever the conversation row currently points at:
      # duplicate servers have existed (Horde CRDT merges mass-terminated
      # losers, registry lag started seconds-apart doubles — #367), and a server
      # that revokes the row's key can be revoking the credential the
      # SURVIVING server's sprite is actively using.
      callback_api_key_id: nil,
      # `{key_id, turn_id}`: a key handed over to the reattached turn this
      # server drives, revoked when it ends (`KeyHandover`, #2835).
      handover_callback_key: nil,
      # `{parent_key_id, plaintext}`: the `"conversation"`-scoped key this
      # turn's `"auth": "conversation"` MCP servers receive, minted from
      # `callback_api_key_id` and revoked with it (`ConversationKey`, #2934).
      conversation_key: nil,
      # Sandbox lifetime bookkeeping. `started_at` is set once the sprite
      # exists; `last_activity_at` moves on every turn start and end. See
      # Fountain.Conversations.Lifecycle for what the bounds are and why
      # reclaiming a sandbox does not end the conversation.
      sandbox_started_at: nil,
      last_activity_at: DateTime.utc_now(),
      # Durable-output budget bookkeeping (#331). `output_bytes` is loaded
      # lazily from the DB on the first output of this server's lifetime, so
      # the budget is cumulative per conversation across wakes rather than
      # per BEAM lifetime. `output_carry` is what #2359's carry holds back.
      output_bytes: nil,
      output_capped: false,
      output_carry: nil
    }

    Lifecycle.schedule_check()
    ProvisionWatchdog.start(state.conversation_id, state.sandbox_id)
    {:ok, state, {:continue, :provision}}
  end

  @impl true
  # Calls wait while this runs, so the registry says so (`ServerPhase`).
  def handle_continue(:provision, state) do
    ServerPhase.setting_up(state.conversation_id)
    result = provision(state)
    ServerPhase.ready(state.conversation_id)
    result
  end

  defp provision(state) do
    conv = Conversations._unsafe_get_conversation(state.conversation_id)
    sandbox = state.sandbox_id && Conversations._unsafe_get_sandbox(state.sandbox_id)

    if is_nil(conv) or is_nil(sandbox) do
      # A conversation or sandbox deleted between start_child and this
      # continue used to raise Ecto.NoResultsError — unrescued, in a
      # restart: :transient child, so the supervisor restarted it straight
      # back into the same raise. That burns the supervisor's SHARED
      # restart budget, and exhausting it terminates every conversation on
      # the node. A server whose rows are gone has nothing to provision.
      Logger.warning(
        "conv #{state.conversation_id}: row missing before provisioning " <>
          "(conversation_gone=#{is_nil(conv)}, sandbox_gone=#{is_nil(sandbox)}); stopping"
      )

      {:stop, :normal, state}
    else
      provision_with_rows(state, conv, sandbox)
    end
  end

  defp provision_with_rows(state, conv, sandbox) do
    # Non-bang for the same reason as the rows above: a deleted agent must
    # not crash-loop the server. Provisioning proceeds without it, exactly
    # as for a conversation created with no agent.
    agent = TurnMachine.agent_for(conv)

    if conv.agent_id && is_nil(agent) do
      Logger.warning("conv #{conv.id}: agent #{conv.agent_id} is gone; provisioning without it")
    end

    # The conversation's own override wins over the agent's environment (#783);
    # nil falls back to the agent's, resolved fresh each provision.
    #
    # Scoped by the conversation's owner even though create/update_agent and
    # start_conversation already validate ownership: a cross-tenant
    # environment_id that predates that check (or slips in through a future
    # path) must not materialise another tenant's secrets here.
    env_id = conv.environment_id || (agent && agent.environment_id)

    env =
      if env_id do
        case Environments.get_environment(env_id, conv.user_id) do
          nil ->
            Logger.warning(
              "conv #{conv.id}: environment #{env_id} " <>
                "not owned by user #{conv.user_id}; provisioning without it"
            )

            nil

          env ->
            env
        end
      end

    vault = if conv.vault_id, do: Vaults._unsafe_get_vault(conv.vault_id)

    case SpriteEnv.resolve_inference(conv, agent, env, vault) do
      {:ok, dek, inference_source, inference_creds} ->
        # Before the selection: a tenant secret named after a credential wins
        # in the sandbox, so it decides the source too (ADR 0053 decision 5).
        tenant_secrets =
          SpriteEnv.without_inference_inputs(
            agent && agent.model,
            SpriteEnv.merge_secrets(env, vault, dek)
          )

        bindings = Egress.bindings(conv.user_id)

        {secrets, brokered} = Egress.split_brokered(tenant_secrets, bindings)

        # The tenant's own brokered keys: what the environment and vault
        # rows contributed (#1736). Read again before each turn by
        # `broker_refresh/1`.
        tenant_keys = brokered |> Map.keys() |> Enum.sort()

        {env_creds, brokered, bindings} =
          Egress.split_inference(inference_creds, brokered, bindings)

        # Last, so a connection's token is the value its reserved key carries
        # whatever the tenant's secrets hold (ADR 0085).
        connections = McpConnections.refs(agent)

        {brokered, bindings, connection_expiries} =
          McpConnections.attach(conv.user_id, connections, brokered, bindings)

        state =
          %{
            state
            | user_id: conv.user_id,
              config_home: Fountain.Conversations.ConfigHome.home(conv),
              runtime_session_id: conv.runtime_session_id,
              tenant_key: dek,
              inference_credentials: inference_creds,
              inference_source: inference_source,
              inference_model: agent && agent.model,
              env_credentials: env_creds,
              brokered: brokered,
              broker_bindings: bindings,
              connections: connections,
              connection_expiries: connection_expiries,
              secret_sources: %{environment_id: env && env.id, vault_id: vault && vault.id},
              tenant_keys: tenant_keys,
              broker_network: Fountain.Broker.network_for(env)
          }

        dispatch_provision(state, conv, sandbox, agent, env, vault, secrets)

      {:error, :configuration_changed} ->
        # A reassignment won after this actor read its rows. Its successor
        # must wake the committed binding, not a failed row.
        {:stop, :normal, state}

      {:error, reason} ->
        Logger.error(
          "ConversationServer could not load tenant credentials for conv #{conv.id} (user #{conv.user_id}): #{inspect(reason)}"
        )

        # Through the owner (ADR 0058 stage 7b), which re-reads the status this
        # used to test itself: `fail_provision/2` answers `:not_provisioning`
        # for a row that is no longer pending or starting.
        fail_machine(sandbox.id, :tenant_credential_load_failed, conv.id)

        Conversations.ActorStatus.fail(state, %{
          reason: "tenant_credential_load_failed: #{inspect(reason)}"
        })

        {:stop, :normal, state}
    end
  end

  # The two pre-flight failures: a row that never reached the provision bracket
  # and has to be retired anyway. Best effort: the caller fails the conversation
  # only if it still holds the binding. A machine the owner refuses to retire
  # is one another owner is already settling.
  @doc false
  def fail_machine(sandbox_id, reason, conv_id) do
    Machine.fail_provision(sandbox_id,
      actor: "system:conversation_server",
      reason: reason,
      conversation_id: conv_id
    )
  end

  defp dispatch_provision(state, conv, sandbox, agent, env, _vault, secrets) do
    case McpServers.substitute_agent(agent, env, secrets) do
      {:ok, agent} ->
        # A connection entry becomes an HTTP server with the bearer's
        # placeholder, in the one resolved document (ADR 0085).
        agent = McpConnections.rewrite(agent)
        state = %{state | resolved_mcp_servers: agent && agent.mcp_servers}
        # An `"auth": "conversation"` server reaches the runtime over
        # `session/new` only, with headers no file holds (ADR 0086).
        agent = McpServers.for_disk(agent)

        case sandbox.status do
          s when s in ["ready", "suspended"] ->
            # Provisioned in a previous BEAM lifetime: reattach, never recreate.
            # `suspended` here is a park that landed mid-wake (the reaper's, or
            # a co-tenant's, ADR 0097), resumed through its owner first.
            case Reattachment.awake(sandbox, conv.id) do
              {:ok, sandbox} -> reattach(state, conv, sandbox, agent, env, secrets)
              {:error, _} -> {:stop, :normal, state}
            end

          s when s in ["pending", "starting"] ->
            FreshProvision.run(state, conv, sandbox, agent, env, secrets)

          # A lost machine: rebuilt in its workspace, or followed to the one
          # another conversation rebuilt (ADR 0097, `Conversations.Rebuild`).
          terminal when terminal in ["terminated", "failed"] ->
            case FreshProvision.rebuild(state, conv, sandbox, agent, env, secrets) do
              {:follow, state, live} -> reattach(state, current(conv), live, agent, env, secrets)
              reply -> reply
            end

          _ ->
            FreshProvision.run(state, conv, sandbox, agent, env, secrets)
        end

      {:error, {:missing_vars, names}} ->
        reason = "missing env/vault keys referenced in mcp_servers: #{Enum.join(names, ", ")}"
        Logger.error("provision failed for conv #{conv.id}: #{reason}")
        fail_machine(sandbox.id, :missing_mcp_vars, conv.id)
        Conversations.ActorStatus.fail(state, %{reason: reason})
        {:stop, :normal, state}
    end
  end

  # ownership: this server's own conversation, as the rebuild that moved it left it.
  defp current(conv), do: Conversations._unsafe_get_conversation!(conv.id)

  defp reattach(state, conv, sandbox, agent, env, secrets) do
    Fountain.Telemetry.span(
      [:reattach],
      %{
        conv_id: state.conversation_id,
        machine_name: sandbox.machine_name,
        provider: Conversations.sandbox_provider_atom(sandbox),
        runtime: conv.runtime || (agent && agent.runtime) || "claude"
      },
      fn -> {do_reattach(state, conv, sandbox, agent, env, secrets), %{}} end
    )
  end

  # The `started` event is published **after** the sprite answers, not on the
  # way in, and that is deliberate (#971).
  #
  # A restarted `ConversationServer` runs this function again from the top,
  # and under Horde (before ADR 0072) cluster churn restarted it constantly.
  # Announcing on entry turned that into a transcript: production logged 51 `reattach`
  # `started` events for one conversation inside one second, in lockstep with a
  # second conversation on the same node, and exactly one of them reached
  # `done`. Fifty of those describe a process that was replaced before it
  # touched anything, which is a fact about our supervision tree and not about
  # the user's conversation.
  #
  # The provider round trip outlives a restart, so a start that is going to
  # be replaced is replaced before this line and writes nothing. What survives
  # to publish has a live sprite and is really reattaching.
  #
  # The node is stamped on every reattach event for the same incident: it is
  # what tells a redistribution storm (many nodes, one conversation) from a
  # crash loop (one node, restarting) without guessing.
  defp do_reattach(state, conv, sandbox, agent, env, secrets) do
    handle =
      Managoat.Sandbox.build_handle(
        Fountain.Conversations.sandbox_provider_atom(sandbox),
        sandbox.machine_name
      )

    # A broker failure lands in the transient arm below: it says nothing
    # about the sandbox, and the next wake mints again.
    with {:ok, _info} <-
           Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.get(handle) end,
             label: "sprite lookup on wake"
           ),
         {:ok, state} <- Egress.prepare_state(state),
         {:ok, ca_files} <- Egress.ca_files(state.broker, handle),
         :ok <- Egress.reattach_policy(handle, state.conversation_id) do
      Output.publish_stage(state.conversation_id, "reattach", "started", %{
        machine_name: sandbox.machine_name,
        # The old key, kept beside machine_name until #2776.
        sprite_name: sandbox.machine_name
      })

      # Read before the rotation; claimed once the turn is back or not (#2835).
      handover_key = conv.handover_callback_api_key_id
      {state, _conv} = rotate_callback_api_key(state, conv)
      sprite_env = build_sprite_env(state, agent, env, secrets, nil, ca_files)

      with :ok <- Reattachment.prepare_source(handle, state, conv, agent, sprite_env) do
        # Validate even a cached ready row: retirement may have won while the
        # provider was waking. Through the machine's owner since ADR 0058 stage
        # 7b, and split in two, because the two rows meant different things all
        # along and only one of them was a wake. See `take_machine/2`.
        case take_machine(sandbox, conv) do
          {:ok, sandbox} ->
            new_state = %{
              state
              | handle: handle,
                sprite_env: sprite_env,
                sandbox_started_at: Lifecycle.clock_start(sandbox)
            }

            new_state =
              case Reattachment.reattach_running_turn(%{new_state | current_turn: nil}) do
                {:relaunch, state, turn} ->
                  state |> KeyHandover.claim(handover_key) |> relaunch_unsent(turn)

                state ->
                  KeyHandover.claim(state, handover_key)
              end

            {:noreply, new_state}

          {:error, _reason} ->
            # Wake owns this connection's credentials, not the existing disk or
            # another connection's session. Never destroy the machine here.
            Egress.release_prepared({:ok, state})
            {:stop, :normal, state}
        end
      else
        {:error, reason} ->
          failed = Reattachment.failed_stage(state, reason)
          Output.publish_stage(state.conversation_id, "reattach", "failed", failed)

          Egress.release_prepared({:ok, state})
          {:stop, :normal, state}
      end
    else
      {:error, :not_found} ->
        # The provider says the sandbox is gone. That is the one answer that
        # justifies retiring the row: the disk no longer exists, so the next
        # prompt must provision fresh.
        Logger.warning(
          "reattach failed for sprite #{sandbox.machine_name}: not found — retiring the machine"
        )

        # Retired through its owner with the provider step skipped, quietly
        # (`MachineLoss.retire/3`). The conversation is not failed: the prompt
        # this server was started for, if any, goes to the machine's rebuild,
        # and only with none is the client told to prompt again.
        MachineLoss.retire(sandbox.id, conv.id, "system:conversation_server")

        if MachineLoss.requeue(conv.id) == 0,
          do:
            Output.publish_stage(conv.id, "reattach", "failed", %{
              reason: "not_found",
              retryable: false
            })

        {:stop, :normal, state}

      {:error, reason} ->
        # Anything else — a transport error, a timeout, a 5xx, a credential
        # problem — says nothing about the sandbox, only about our ability to
        # reach the provider right now. The row is left exactly as it was and
        # the server stops; the next prompt takes the same reattach path again.
        #
        # This arm used to mark the row `failed` too. On 2026-08-18 a 70-second
        # DNS outage did exactly that to nine live sandboxes at once (a Horde
        # failover re-ran reattach for every conversation on the partitioned
        # pod, and every probe answered nxdomain), and `SandboxReaper`'s
        # destroy pass would have taken the sprites — one of them holding a
        # completed turn and a live ACP session — an hour later (#799). A
        # transient failure must not become a destroyed disk; the same rule
        # `probe_sandbox/4` applies on the wake path.
        Logger.warning(
          "reattach failed for sprite #{sandbox.machine_name}: #{inspect(reason)} — " <>
            "nothing about the sandbox; its row is left untouched"
        )

        meta = %{retryable: true}
        failed = Reattachment.failed_stage(state, reason, meta)
        Output.publish_stage(state.conversation_id, "reattach", "failed", failed)

        {:stop, :normal, state}
    end
  end

  # The reattach arm's row write, through the machine's owner (ADR 0058 stage
  # 7b). `main` wrote both of these with one `claim_sandbox/2` and told them
  # apart by an `attrs` map, which hid that they are two different operations:
  #
  #   * a **`ready`** row is a machine this server is taking possession of and
  #     nothing more. `confirm_up/2` asserts under the machine's own lease that
  #     retirement did not win while the provider was answering, and writes the
  #     status back over itself so `updated_at` moves — which is what
  #     `SandboxReaper.release_stuck_sandboxes/0` reads as a sign of life.
  #   * a **`suspended`** row is a machine the reaper parked between the wake's
  #     own resume and this server starting, whose disk the probe above has just
  #     said is running. The row comes back to `ready` with `last_resumed_at`
  #     and its usage row exactly as `main` wrote them, and — new — with the
  #     `sandbox.resumed` event every other way of bringing a machine back has
  #     recorded since stage 7a. No provider call and no admission; `confirm_up/2`
  #     argues both.
  #
  # The reload is what this returns rather than anything the door hands back:
  # `Lifecycle.clock_start/1` reads `last_resumed_at`, which the door may have
  # just written.
  defp take_machine(sandbox, conv) do
    sandbox.id
    |> Machine.confirm_up(actor: "system:reattach", conversation_id: conv.id)
    |> settle_take(sandbox)
  end

  # Only `:confirmed` means this server may attach. `:already_terminal` is
  # retirement having won while the provider was answering and
  # `:claimed_elsewhere` another server holding the machine; neither is a machine
  # to reattach to, and both are this caller's cue to release its credentials and
  # stop — which is what `main`'s `:retired` and `{:error, :sandbox_reset_pending}`
  # arms did.
  defp settle_take({:ok, :confirmed}, sandbox),
    do: {:ok, Conversations._unsafe_get_sandbox!(sandbox.id)}

  defp settle_take({:ok, outcome}, _sandbox), do: {:error, outcome}
  defp settle_take({:error, _reason} = error, _sandbox), do: error

  # ── sprite environment and egress (ADR 0019 gate 1a) ──────────────────────

  # The server's half of `SpriteEnv.build/4`: unpack what the state holds and
  # hand it over. The name stays because the tests and the comments that say
  # "build_sprite_env registers the secrets" still mean this call.
  @doc false
  def build_sprite_env(state, agent, env, secrets, sandbox_url \\ nil, ca_files \\ nil) do
    SpriteEnv.build(agent, env, secrets,
      runtime_module: state.runtime_module,
      config_home: state.config_home,
      env_credentials: state.env_credentials,
      callback_token: state.callback_token,
      conversation_id: state.conversation_id,
      sandbox_id: state.sandbox_id,
      sandbox_url: sandbox_url,
      brokered: Egress.sandbox_env(state.broker, ca_files || Fountain.Broker.system_ca_files()),
      broker_credentials: state.brokered
    )
  end

  @impl true
  def handle_call({:send_prompt, prompt, images}, from, state),
    do: handle_call({:send_prompt, prompt, images, []}, from, state)

  def handle_call({:send_prompt, prompt, images, meta}, _from, state) do
    if Connection.user_turn_running?(state.current_turn) do
      {:reply, {:error, :busy}, state}
    else
      # This server already owns the conversation. Refuse before superseding
      # autonomous work or touching its connection; turn admission rechecks.
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      with :ok <- TurnMachine.gate(conv.user_id, state.inference_source),
           :ok <- McpConnections.gate(conv.user_id, state.connections) do
        state = close_autonomous_turn(state, "superseded_by_prompt")
        agent = if conv.agent_id, do: TurnMachine.agent_for!(conv)

        # Admission can refuse under its row locks, and a caller that asked
        # for a turn has to hear that. Every other outcome keeps the cast
        # shape `kick_turn/4` answers in.
        case kick_turn(state, prompt, agent, images, meta) do
          {:error, reason, next} -> {:reply, {:error, reason}, next}
          cast_shape -> replying_ok(cast_shape)
        end
      else
        {:error, _} = err -> {:reply, err, state}
      end
    end
  end

  # Busy means a turn, not a connection (#817): an idle adapter between
  # turns is nothing to interrupt. An autonomous turn is interruptible — it
  # is the one way to cut a background task the agent left running.
  def handle_call(:interrupt, _from, %{current_turn: nil} = state) do
    {:reply, {:error, :idle}, state}
  end

  def handle_call(:interrupt, _from, state) do
    {:reply, :ok, state |> await_cancelled_usage() |> interrupt_turn()}
  end

  # First answer wins (`Pending.answer_permission/6`): the web apps and an
  # editor (#708) are peer clients of this door, not fallbacks for one
  # another, so a second answer to the same request is "too late" rather
  # than an error in the caller.
  def handle_call({:answer_permission, request_id, option_id}, _from, state) do
    if Pending.holds?(state.current_turn, request_id) do
      {reply, state} = Pending.answer(state, request_id, option_id)
      {:reply, reply, state}
    else
      {:reply, {:error, :no_pending_permission}, state}
    end
  end

  def handle_call({:answer_elicitation, request_id, action, content}, _from, state) do
    if Pending.holds?(state.current_turn, request_id) do
      {reply, state} = Pending.answer_elicitation(state, request_id, action, content)
      {:reply, reply, state}
    else
      {:reply, {:error, :no_pending_permission}, state}
    end
  end

  # The last-detach decision is the owner's (ADR 0058 stage 8b, keyed by the
  # workspace's kind by ADR 0097): kept (`:detached`), or fenced and this
  # server's to finish once its adapter is closed. A machine somebody else
  # already finished reads as fenced too, as a terminal row did.
  def handle_call({:terminate_conv, opts}, _from, state) when is_list(opts) do
    case detach_machine(state, opts) do
      {:ok, outcome} when outcome in [:detached, :fenced, :already_terminal] ->
        terminate_machine(state, opts, outcome)

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  # Catch-all: an unmatched call must not die with a FunctionClauseError at
  # the callback head — that exception's message embeds the full state
  # (plaintext secrets included) in the crash report, and format_status/1
  # cannot redact an exception message (#315).
  def handle_call(msg, _from, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected call #{inspect(msg)}")
    {:reply, {:error, :unknown_call}, state}
  end

  # The prompt a conversation was started for. Ignored if a turn is somehow
  # already running — the cast is queued behind provisioning, so that should not
  # happen, and re-running is the failure this whole mechanism exists to avoid.
  @impl true
  def handle_cast({:initial_prompt, prompt, images}, state),
    do: handle_cast({:initial_prompt, prompt, images, []}, state)

  def handle_cast({:initial_prompt, prompt, images, meta}, state) do
    if Connection.user_turn_running?(state.current_turn) do
      Logger.warning(
        "conv #{state.conversation_id}: initial prompt arrived while a turn was running; dropping it"
      )

      Wake.report_unrun_prompt(state.conversation_id, :conversation_busy, meta)

      {:noreply, state}
    else
      conv = Conversations._unsafe_get_conversation!(state.conversation_id)

      # Ownership: this server owns conv. Policy may have changed since wake.
      with :ok <- TurnMachine.gate(conv.user_id, state.inference_source),
           :ok <- McpConnections.gate(conv.user_id, state.connections) do
        state = close_autonomous_turn(state, "superseded_by_prompt")
        agent = if conv.agent_id, do: TurnMachine.agent_for!(conv)

        # Admission can refuse under its row locks after these preflights pass.
        # Unlike the `else` below, the connection is already dropped by here.
        case kick_turn(state, prompt, agent, images, meta) do
          {:error, reason, next} -> {:noreply, log_initial_refusal(next, reason, meta)}
          cast_shape -> cast_shape
        end
      else
        # A connection to reconnect is the owner's to act on, so it is
        # reported on the stream as well as logged (ADR 0085).
        {:error, {:connection_reconnect_required, _}} = error ->
          {:noreply, log_initial_refusal(state, elem(error, 1), meta)}

        {:error, reason} ->
          # A cast has no caller to reply to. Preserve existing work and its
          # connection when this queued prompt cannot be admitted.
          TurnMachine.log_refusal(state.conversation_id, "dropping initial prompt", reason)
          Wake.report_unrun_prompt(state.conversation_id, reason, meta)

          {:noreply, state}
      end
    end
  end

  def handle_cast({:machine_gone, sandbox_id, event, reason, message}, state) do
    MachineEvents.gone(
      state,
      sandbox_id,
      {event, reason, message},
      &interrupt_turn/1,
      &drop_connection/2
    )
  end

  # A vault or environment secret was written (#2548): `Egress.refresh_live/1`,
  # mid-turn too. It rewrites rules only; the turn and the token stay.
  def handle_cast(:refresh_secrets, state), do: {:noreply, Egress.refresh_live(state)}

  # Catch-all for the same reason as the handle_call one above (#315).
  def handle_cast(msg, state) do
    Logger.warning("conv #{state.conversation_id}: unexpected cast #{inspect(msg)}")
    {:noreply, state}
  end

  # ACP path: stdout is protocol, not transcript. The peer frames it, decides
  # what is worth keeping and reports that back as `{:acp, ref, _}` — a
  # JSON-RPC response to `initialize` is not something a user should find in
  # their conversation, and a `session/load` replay is history we already hold.
  @impl true
  def handle_info(
        {:stdout, %{ref: ref}, data},
        %{current_command_ref: ref, acp_peer: peer} = state
      )
      when is_pid(peer) do
    if data != "", do: Managoat.ACP.Peer.stdout(peer, data)
    {:noreply, maybe_emit_first_output(state)}
  end

  # A connection's token is due a refresh during a turn (ADR 0085): refresh
  # it and rewrite the live broker rules. Between turns there is nothing to
  # do; the next turn's refresh reads it.
  def handle_info(:refresh_connections, %{current_turn: nil} = state),
    do: {:noreply, %{state | connection_timer: nil}}

  def handle_info(:refresh_connections, state) do
    state = %{state | connection_timer: nil} |> Egress.refresh_live() |> McpConnections.schedule()
    {:noreply, state}
  end

  # A connection refresh running in a task moved a token (ADR 0085).
  def handle_info({:connection_refreshed, _id}, state),
    do: {:noreply, McpConnections.refreshed(state)}

  def handle_info({:stdout, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    # Preserve adapter diagnostics when its peer is no longer available.
    # The tracer only consumes protocol reports from a live peer.
    state = maybe_emit_first_output(state)
    {:noreply, log_output(state, "stdout", data)}
  end

  def handle_info({:stderr, %{ref: ref}, data}, %{current_command_ref: ref} = state) do
    {:noreply, log_output(state, "stderr", data)}
  end

  # ── ACP peer reports (0014 gate 2) ────────────────────────────────────────

  # No `cycle_end` came. Close the autonomous turn as completed — the updates
  # it collected are real — and say why.
  def handle_info(
        {:autonomous_quiet, turn_id},
        %{current_turn: %{id: turn_id}} = state
      ) do
    if TurnMachine.autonomous_turn?(state) do
      {:noreply,
       finish_acp_turn(state, "completed", %{"origin" => "quiet"}, %{
         origin: "autonomous",
         cycle: "quiet"
       })}
    else
      {:noreply, state}
    end
  end

  def handle_info({:autonomous_quiet, _turn_id}, state), do: {:noreply, state}

  # Nobody answered in time. Deny — the only safe default — and say so on the
  # stream so a card stops waiting.
  def handle_info({:permission_timeout, request_id}, state) do
    {:noreply, Pending.resolve_if_held(state, request_id, "timeout", nil)}
  end

  # #655: the org has refused this account's Claude OAuth token. The machine
  # words the outcome and ends the turn; what has to happen first, and here,
  # is the swap: the API key sitting in the same `inference_credentials` row
  # replaces the refused token in the sprite env and the broker session for
  # the rest of this server's life. Whether a key was there to swap in is
  # what the machine's message turns on.
  def handle_info(
        {:acp, ref, {:failed, {:oauth_org_not_allowed, _detail}} = payload},
        %{
          current_command_ref: ref,
          runtime_module: Managoat.Runtimes.Claude,
          inference_source: %{identity: identity}
        } = state
      )
      when is_binary(identity) do
    # A bound peer cannot switch credential kind behind its persisted source.
    {:noreply, drive_turn(state, payload, oauth_switched?: false)}
  end

  def handle_info(
        {:acp, ref, {:failed, {:oauth_org_not_allowed, detail}} = payload},
        %{current_command_ref: ref, runtime_module: Managoat.Runtimes.Claude} = state
      ) do
    Logger.warning("conv #{state.conversation_id}: Claude OAuth token refused by org: #{detail}")

    # On a brokered conversation the API key is a placeholder in the env and
    # the value moves to the broker; the vault is re-prepared so its
    # substitution now carries the key instead of the refused OAuth token.
    state = Egress.switch_to_api_key(state)

    fallback_env =
      Managoat.Runtimes.Claude.fall_back_to_api_key(state.sprite_env, state.env_credentials)

    switched? = fallback_env != state.sprite_env

    %{conversation_id: id, env_credentials: creds, brokered: brokered} = state
    SpriteEnv.register_exported(id, fallback_env, creds, brokered)

    state = %{
      state
      | sprite_env: fallback_env,
        inference_credentials: Map.delete(state.inference_credentials, :claude_code_oauth_token),
        env_credentials: Map.delete(state.env_credentials, :claude_code_oauth_token)
    }

    {:noreply, drive_turn(state, payload, oauth_switched?: switched?)}
  end

  # Every other report is the turn state machine's (#1374): one call, then
  # the effects it hands back, applied in order.
  def handle_info({:acp, ref, payload}, %{current_command_ref: ref} = state),
    do: {:noreply, drive_turn(state, payload)}

  # A report from a superseded turn's peer. The turn it belonged to is already
  # over; acting on it would end the *current* one.
  def handle_info({:acp, _stale_ref, _payload}, state), do: {:noreply, state}

  # The peer died without reporting. Whatever it was, the turn has no driver
  # any more, and leaving `current_command` set is the #413 shape: every prompt
  # answered `:busy`, idle reclaim suppressed, sprite billing to the ceiling.
  def handle_info(
        {:DOWN, mon, :process, _pid, reason},
        %{acp_peer_mon: mon, current_turn: turn} = state
      )
      when not is_nil(turn) do
    Logger.error("conv #{state.conversation_id}: acp peer down: #{inspect(reason)}")

    {:noreply,
     finish_acp_turn(state, "failed", %{"error" => "peer_down"}, %{
       reason: "acp peer down: #{inspect(reason)}"
     })}
  end

  # The peer died between turns (#817): a lost connection, not a failed
  # turn. Say so on the transcript, let the adapter go, and let the next
  # prompt spawn a fresh one (`mode: :continue` → `session/resume`).
  def handle_info({:DOWN, mon, :process, _pid, reason}, %{acp_peer_mon: mon} = state) do
    Logger.warning("conv #{state.conversation_id}: idle acp peer down: #{inspect(reason)}")
    state = %{state | acp_peer: nil, acp_peer_mon: nil}
    {:noreply, drop_connection(state, "peer_down")}
  end

  # The adapter exited between turns (#817): the connection is gone, no turn
  # is. Record it and clear the connection; the next prompt spawns afresh.
  def handle_info(
        {:exit, %{ref: ref}, code},
        %{current_command_ref: ref, current_turn: nil} = state
      ) do
    Logger.info("conv #{state.conversation_id}: idle acp adapter exited #{code}")
    {:noreply, connection_lost(state, "adapter_exited", %{exit_code: code})}
  end

  # A native crash before any output relaunches once (#2402, `TurnLaunch.relaunch_crashed/3`).
  def handle_info({:exit, %{ref: ref}, code}, %{current_command_ref: ref} = state),
    do: TurnLaunch.relaunch_crashed(Output.flush_state(state), code, &finish_exited_turn/2)

  # An error naming the CURRENT command is terminal for the turn (#413):
  # The adapter sends it when the transport to the sandbox drops mid-run,
  # then stops — and since the command process is neither linked nor
  # monitored, this message is the only signal there will ever be. Ignoring
  # it left current_command set forever: every prompt answered {:error,
  # :busy}, idle reclaim was suppressed (busy? true), the reaper skipped the
  # sandbox (server alive), and the sprite billed until max_lifetime. Fail
  # the turn and return to idle, exactly like a non-zero :exit.
  def handle_info(
        {:error, %{ref: ref}, reason},
        %{current_command_ref: ref, current_turn: nil} = state
      )
      when not is_nil(ref) do
    Logger.warning("sprite command error between turns: #{inspect(reason)} — connection lost")
    {:noreply, connection_lost(state, "transport_error", %{reason: inspect(reason)})}
  end

  def handle_info({:error, %{ref: ref}, reason}, %{current_command_ref: ref} = state)
      when not is_nil(ref) do
    fail_transport(state, reason)
  end

  # A stale ref — an error from a command already superseded or finished.
  def handle_info({:error, _ref, reason}, state) do
    Logger.error("sprite command error: #{inspect(reason)}")
    {:noreply, state}
  end

  # The ACP reattach window is over; anything still in the set is a persisted
  # line the replay did not repeat, and must not suppress a genuine repeat.
  def handle_info(:clear_replay_dedup, state) do
    {:noreply, %{state | replay_dedup: MapSet.new()}}
  end

  # ── permissions, reclaim and redaction ────────────────────────────────────

  def handle_info(:lifecycle_check, state) do
    Lifecycle.schedule_check()

    started_at = state.sandbox_started_at

    cond do
      # No sprite yet: provisioning is still in flight and there is nothing to
      # reclaim. The reaper handles a provision that never finishes.
      is_nil(started_at) ->
        {:noreply, state}

      true ->
        # Busy is a turn in flight, autonomous ones included (#817) — an idle
        # adapter between turns is not a reason to hold the sandbox open.
        case Lifecycle.check(started_at, state.last_activity_at, state.current_turn != nil) do
          {:expired, reason} -> reclaim_sandbox(state, reason)
          :ok -> {:noreply, state}
        end
    end
  end

  # trap_exit is on (see init/1), so exit signals from linked processes
  # arrive here instead of killing the server outright. Preserve the
  # pre-trap semantics: a linked crash still takes the server down (through
  # terminate/2, which is the point), a :normal exit is ignored. Exits from
  # the parent supervisor never reach this clause — OTP intercepts those
  # and calls terminate/2 directly.
  def handle_info({:EXIT, _from, :normal}, state), do: {:noreply, state}
  def handle_info({:EXIT, _from, reason}, state), do: {:stop, reason, state}

  def handle_info(_msg, state), do: {:noreply, state}

  defp finish_exited_turn(state, code) do
    turn = state.current_turn

    # Finalize stream tracer: close any tool spans still open (abandoned calls).
    TurnMachine.finalize_tracer(state.stream_tracer)

    # An ACP adapter can exit before answering session/prompt. Attempt local
    # peer cleanup before rechecking ownership: its callback may change the
    # conversation while this actor waits for it to stop.
    stop_acp_peer(state)

    status = if(code == 0, do: "completed", else: "failed")

    # Ownership: this actor supplies the sandbox binding captured at startup,
    # through the owner's door (`Machines.Admission`, ADR 0058 stage 8a).
    case Machine.end_turn(turn, {:finish, status, [exit_code: code]},
           sandbox_id: state.sandbox_id
         ) do
      {:ok, ended} ->
        Output.publish_stage(
          state.conversation_id,
          "turn",
          "done",
          Map.merge(
            %{turn_id: ended.id, turn_number: ended.turn_number},
            TurnLaunch.exit_meta(code)
          )
        )

        TurnMachine.end_span(
          state.current_turn_span,
          if(code == 0, do: :ok, else: :error),
          %{"exit_code" => code}
        )

        emit_turn_completed(state, ended.status)

      :noop ->
        TurnMachine.end_span(state.current_turn_span, :error, %{"outcome" => "completion_ignored"})

      {:error, reason} ->
        Logger.warning("turn #{turn.id}: completion refused (#{inspect(reason)})")

        TurnMachine.end_span(state.current_turn_span, :error, %{"outcome" => "completion_refused"})
    end

    {:noreply,
     KeyHandover.settle(%{
       touch_activity(state)
       | current_command: nil,
         current_command_ref: nil,
         current_turn: nil,
         current_turn_span: nil,
         turn_metrics: nil,
         stream_tracer: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     })}
  end

  # `Pending.resolve_held/2` is the family's own (#1369); this call site came
  # from the shared-sandbox reattach fix and moves with it.
  defp fail_transport(state, reason) do
    {:noreply, state} =
      Reattachment.fail_transport(Pending.resolve_held(state, "turn_ended"), reason)

    {:noreply, KeyHandover.settle(state)}
  end

  # ownership: init/1 established this actor's conversation and sandbox; the
  # detach's fence rechecks this actor's parent and owner under its lock. No
  # machine is no binding to end, and answers as the fence did: unavailable.
  defp detach_machine(%{sandbox_id: nil}, _opts), do: {:error, :sandbox_unavailable}

  defp detach_machine(state, opts) do
    opts = [conversation_id: state.conversation_id] ++ Keyword.take(opts, [:actor, :request_ip])
    Machine.detach(state.sandbox_id, opts)
  end

  # The machine goes through its owner (ADR 0058 stage 5): the fence the
  # detach committed is repeated there — idempotently, no second
  # `sandbox.teardown_requested`, both timestamps preserved — and the provider
  # destroy, the terminal write and the `sandbox.destroyed` event are the
  # protocol's. `terminating_conversation_id: nil` because the kept-or-destroy
  # decision was the detach's and is not reopened here;
  # `Termination._unsafe_destroy_machine/2` says why. A refusal is logged, not
  # raised: this conversation ends either way, and `Workers.SandboxReaper`
  # collects a destroy that could not finish.
  #
  # ownership: init/1 established this actor's conversation and sandbox, and
  # the detach above has just re-checked the binding under the sandbox lock.
  defp terminate_machine(state, opts, outcome) do
    state = if state.current_turn, do: interrupt_turn(state), else: state
    state = drop_connection(state, "terminated")
    :ok = Termination.remove_config_home(state)
    opts = Keyword.put(opts, :terminating_conversation_id, nil)

    Termination.end_machine(state.sandbox_id, outcome, opts)
    Egress.release(state.conversation_id)
    finish_termination(state, %{})
  end

  defp finish_termination(state, metadata) do
    # Ownership: this actor's IDs came from init; the write rechecks its binding.
    result =
      case Termination._unsafe_finish_conversation_termination(
             state.conversation_id,
             state.sandbox_id
           ) do
        {:ok, _} ->
          Output.publish_stage(state.conversation_id, "terminate", "done", metadata)
          :ok

        {:error, _} = error ->
          error
      end

    {:stop, :normal, result, state}
  end

  # The server's own clock stamp: the input `Lifecycle.check/4` reads. Nothing
  # but this process writes it.
  defp touch_activity(state), do: %{state | last_activity_at: DateTime.utc_now()}

  # Idle: the machine's verdict, not this conversation's (ADR 0023 step 5).
  #
  # The in-memory `current_turn` is not the only word on whether a turn is in
  # flight (#2529). A `running` turn row this server is not holding — a
  # reattach that could not take its turn back, a binding that moved under it —
  # is still a turn somebody may be waiting on, and an idle reclaim is never
  # the thing that should end it. `Machines.Park` refuses a park over the
  # requester's running turn already; the destroy a provider that cannot park
  # takes had no such check, so this one covers both. The row is read only
  # once the clock has already said idle, so a busy server pays nothing.
  defp reclaim_sandbox(state, :idle) do
    if running_turn_row?(state) do
      Logger.warning(
        "idle reclaim skipped for conv #{state.conversation_id}: a turn row is " <>
          "still running that this server is not driving"
      )

      {:noreply, state}
    else
      case Lifecycle.idle_machine_action(state.conversation_id, state.sandbox_id, state.handle) do
        :keep -> {:noreply, state}
        :park -> park_sandbox(state)
        :destroy -> destroy_sandbox(state, :idle)
      end
    end
  end

  # Max lifetime: destroyed on an implicit workspace, parked on an explicit
  # one after every turn on it is cut (`Lifecycle.ceiling_action/2`, ADR 0097).
  defp reclaim_sandbox(state, :max_lifetime) do
    case Lifecycle.ceiling_action(state.sandbox_id, state.handle) do
      :park -> park_sandbox(state, :max_lifetime)
      :destroy -> destroy_sandbox(state, :max_lifetime)
    end
  end

  # ownership: the conversation this actor was started for; no id here came
  # from a request.
  defp running_turn_row?(state),
    do: Reattachment.find_running_turn(state.conversation_id) != nil

  # A reclaim that lands mid-turn ends the turn itself, on the turn stage and
  # with the reason (#2529), before the connection goes. Left to `terminate/2`
  # the turn was orphaned after the fact, and a client waiting on the turn
  # stage saw `sandbox/done` and then nothing about its turn at all. Only the
  # max-lifetime ceiling reaches here with a turn in flight today — the idle
  # verdict is suppressed while one runs — and this keeps the next path that
  # does from cutting a turn silently.
  defp cut_turn(%{current_turn: nil} = state, _event, _reason), do: state

  defp cut_turn(state, event, reason) do
    state = Pending.resolve_held(state, "turn_ended")
    interrupt_turn(state, %{reason: "sandbox_#{event}", detail: to_string(reason)})
  end

  # The log line and the connection are the process's; the rest of a park is
  # `Lifecycle.park/4` and, behind it, the machine's owner — which can refuse,
  # where `main`'s park could not. `Lifecycle.park/4` documents each answer;
  # the two that degrade to a destroy are the ones ADR 0017 priced, because an
  # unparked machine keeps billing.
  defp park_sandbox(state, reason \\ :idle) do
    Logger.info(
      "suspending sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    # A parked sprite never keeps a live adapter (#817), and never a turn.
    state = state |> cut_turn("suspended", reason) |> drop_connection("suspended")

    case Lifecycle.park(state.conversation_id, state.sandbox_id, state.handle, reason) do
      # The conversation stays idle and resumable; the sprite stays parked.
      :ok -> {:stop, :normal, %{state | handle: nil}}
      {:error, no} when no in [:suspend_failed, :cannot_park] -> destroy_sandbox(state, reason)
      {:error, error} -> reclaim_refused(state, error)
    end
  end

  # The same shape for a destroy (`Lifecycle.destroy/4`).
  defp destroy_sandbox(state, reason) do
    Logger.info(
      "reclaiming sandbox for conv #{state.conversation_id}: #{reason} " <>
        "(sprite #{inspect(state.handle && state.handle.name)})"
    )

    with :ok <- Lifecycle.prepare_destroy(state.sandbox_id, reason) do
      state = state |> cut_turn("reclaimed", reason) |> drop_connection("reclaimed")

      case Lifecycle.destroy(
             state.conversation_id,
             state.sandbox_id,
             state.handle,
             reason
           ) do
        :ok -> {:stop, :normal, %{state | handle: nil}}
        {:error, error} -> reclaim_refused(state, error)
      end
    else
      {:error, error} -> reclaim_refused(state, error)
    end
  end

  defp reclaim_refused(state, error) do
    Logger.warning("reclaim refused for conv #{state.conversation_id}: #{inspect(error)}")
    {:noreply, state}
  end

  # Best-effort revoke of the per-conversation API key when this server
  # exits — clean termination (`:terminate_conv`), crash paths that hit
  # `{:stop, :normal, state}`, and (because init/1 traps exits, #322)
  # supervisor shutdown on deploys. `CallbackKey.revoke/2`
  # owns the rule about whose key it is safe to take back.
  #
  # Except a graceful stop mid-turn, which hands the key to the server that
  # reattaches the turn (`KeyHandover.on_stop/2`, #2835).
  @impl true
  def terminate(reason, state) do
    Redaction.delete(state.conversation_id)
    _ = KeyHandover.on_stop(reason, state)

    # Last and best-effort, so it cannot skip the revocation above.
    _ =
      TurnMachine.orphan_on_normal_stop(reason, state.current_turn, state.conversation_id,
        sandbox_id: state.sandbox_id
      )

    :ok
  end

  # Keeps secrets out of crash reports and :sys.get_status output (#315). The
  # redactor itself is `Redaction.server_state/1`.
  @impl true
  def format_status(status), do: Redaction.server_status(status)

  # ── turns ─────────────────────────────────────────────────────────────────

  @doc """
  The options a sprite's callback key is minted with: `CallbackKey.api_key_opts/0`.

  Re-exported here because `conversation_server_shutdown_revoke_test`,
  `api_key_scope_test` and `audit_coverage_test` pin the scope and expiry
  through this module, and the server tests do not change (#1369).
  """
  def callback_api_key_opts, do: CallbackKey.api_key_opts()

  # Rotate the sandbox's callback key (`CallbackKey.rotate/2`) and hold the
  # result: the plaintext and the row id on success. On failure only the
  # token is cleared; `callback_api_key_id` is left as it was.
  @doc false
  def rotate_callback_api_key(state, %Conversation{} = conv) do
    case CallbackKey.rotate(conv, state.callback_api_key_id) do
      {:ok, raw, key_id, conv} ->
        {%{state | callback_token: raw, callback_api_key_id: key_id}, conv}

      {:error, conv} ->
        {%{state | callback_token: nil}, conv}
    end
  end

  # End the running turn without a verdict from the agent: the user asked, or
  # the machine under it is going away. Tells the agent before killing its
  # process — `session/cancel` is a notification with no reply, so it costs
  # one write and does not delay the kill, but it is the difference between
  # an agent that stops its tool calls and one that is shot mid-write. This is
  # the other reason stdin stays open on the ACP path.
  defp interrupt_turn(state, stage_meta \\ %{}) do
    if state.acp_peer, do: Managoat.ACP.Peer.cancel(state.acp_peer)
    # EOF before the handle goes: a detachable session survives its client
    # disconnecting, so closing the WebSocket alone would leave the adapter —
    # and whatever background task it was running — alive on the machine.
    if state.current_command, do: Managoat.Sandbox.close_stdin(state.current_command)
    if state.current_command, do: Managoat.Sandbox.stop_command(state.current_command)
    state = state |> cancel_autonomous_quiet() |> Output.flush_state()

    turn = TurnMachine.mark_interrupted(TurnMachine.from_state(state), stage_meta)

    # An ACP turn can also end here — the adapter exits, is interrupted, or its
    # socket drops before it ever answers `session/prompt`. The peer has nothing
    # left to drive and must not outlive the turn.
    stop_acp_peer(state)

    state = TurnMachine.into_state(state, TurnMachine.close_interrupted(turn))

    KeyHandover.settle(%{
      state
      | current_command: nil,
        current_command_ref: nil,
        acp_peer: nil,
        acp_peer_mon: nil
    })
  end

  # A user's interrupt reaches a live adapter, which answers the cancelled
  # `session/prompt` with the turn's usage (#2821). `interrupt_turn/2` stops
  # the adapter at once, so wait for that answer first, up to
  # `:acp_cancel_grace_ms`, and record what it reports. The adapter's stdout
  # still has to reach the peer meanwhile, or the answer never arrives, and
  # the lines it reports still land on the transcript. Other reports are
  # dropped, as they are once the turn is interrupted; everything else stays
  # in the mailbox. A machine that is going away gets no wait: nothing on it
  # will answer. Nor does an autonomous turn, which has no prompt to answer.
  defp await_cancelled_usage(%{acp_peer: peer, current_command_ref: ref} = state)
       when is_pid(peer) and not is_nil(ref) do
    if TurnMachine.autonomous_turn?(state) do
      state
    else
      Managoat.ACP.Peer.cancel(peer)
      grace = Application.get_env(:fountain, :acp_cancel_grace_ms, @acp_cancel_grace_ms)
      await_cancelled_usage(state, System.monotonic_time(:millisecond) + grace)
    end
  end

  defp await_cancelled_usage(state), do: state

  defp await_cancelled_usage(%{acp_peer: peer, current_command_ref: ref} = state, deadline) do
    receive do
      {:stdout, %{ref: ^ref}, data} ->
        if data != "", do: Managoat.ACP.Peer.stdout(peer, data)
        await_cancelled_usage(state, deadline)

      {:acp, ^ref, {:done, _stop_reason, usage}} ->
        TurnMachine.record_usage(TurnMachine.from_state(state), usage)
        state

      {:acp, ^ref, {:failed, _reason}} ->
        state

      # The command is gone, so no answer is coming. Put the message back for
      # the handlers that log it; by then it names a retired command.
      {tag, %{ref: ^ref}, _detail} = gone when tag in [:exit, :error] ->
        send(self(), gone)
        state

      {:acp, ^ref, {:lines, _stream, _data} = lines} ->
        state |> drive_turn(lines) |> await_cancelled_usage(deadline)

      {:acp, ^ref, _report} ->
        await_cancelled_usage(state, deadline)
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> state
    end
  end

  defp log_initial_refusal(state, reason, meta) do
    TurnMachine.log_refusal(state.conversation_id, "initial turn refused", reason)
    Wake.report_unrun_prompt(state.conversation_id, reason, meta)

    state
  end

  # Returns the cast's callback tuple, or a three-element refusal.
  defp kick_turn(state, prompt, agent, images, meta) do
    # A new turn has not been restarted (#1667), whatever the last one did.
    state = touch_activity(%{state | turn_session_retry: nil, turn_provider_failure: nil})

    case TurnMachine.open(
           state.conversation_id,
           state.sandbox_id,
           prompt,
           agent,
           state.inference_source,
           meta
         ) do
      {:ok, conv, turn} ->
        TurnMachine.store_images(turn, images)
        state = run_turn(state, conv, turn, prompt, agent, images)

        TurnMachine.stamp_span(state.current_turn_span, %{
          provider: to_string(state.handle.provider)
        })

        metrics =
          TurnMachine.with_response_timing(
            state.turn_metrics,
            Keyword.get(meta, :response_timing)
          )

        {:noreply, %{state | turn_metrics: metrics}}

      :no_command ->
        Wake.report_unrun_prompt(state.conversation_id, :no_runtime_command, meta)
        {:noreply, state}

      # Three-element, so a refusal is distinguishable from the other
      # outcomes that also keep the connection-dropping state. `send_prompt`
      # turns it into a reply; the casts below drop the prompt as they always
      # have, because a cast has no caller to answer.
      {:error, reason} ->
        {:error, reason, drop_connection(state, "admission_refused")}
    end
  end

  # `kick_turn/4` answers a cast's shape; a call needs `:ok` in front of it.
  defp replying_ok({:noreply, state}), do: {:reply, :ok, state}

  defp run_turn(state, conv, turn, prompt, agent, images) do
    # A turn starting here means a reattached one is over.
    state = KeyHandover.settle(%{state | inference_model: agent && agent.model})

    # Before either path (#1736): a fresh spawn takes the env this rebuilds, an
    # idle peer holds its token, and one whose token was replaced is closed.
    {state, replaced?} = Egress.refresh_before_turn(state)
    # Tokens that expire during the turn are refreshed before they do.
    state = McpConnections.schedule(state)
    why = Connection.stale_reason(state, replaced?, conv, agent)
    state = if why, do: drop_connection(state, why), else: state

    # An idle peer carries the next turn without spawn, handshake or resume
    # (#817). It applies the model before prompting; background tasks and
    # Codex session grants survive.
    if Connection.alive?(Connection.from_state(state)) do
      resume_acp_connection(state, conv, turn, prompt, images)
    else
      run_fresh_turn(state, conv, turn, prompt, agent, images)
    end
  end

  # A turn whose prompt never reached the agent, found on reattach: run it again
  # on this server, with the images it was admitted with.
  defp relaunch_unsent(state, turn) do
    # ownership: the turn reattach found running on this server's own conversation.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)
    images = Conversations._unsafe_list_turn_images(turn.id)
    run_turn(state, conv, turn, turn.prompt, TurnMachine.agent_for(conv), images)
  end

  # The launch itself lives in `TurnLaunch` (see its moduledoc): this module's
  # line count only ratchets down, and a pure launch given a state it does not
  # own is the natural seam. `fail_turn_before_start/3` logs the failure.
  defp run_fresh_turn(state, conv, turn, prompt, agent, images) do
    TurnLaunch.run(
      state,
      conv,
      turn,
      prompt,
      agent,
      images,
      &fail_turn_before_start/3
    )
  end

  # A machine the provider says is gone is rebuilt for this prompt (#3005).
  defp fail_turn_before_start(state, turn, reason) do
    detail = inspect(reason)
    Logger.error("conv #{state.conversation_id}: spawn failed: #{detail}")

    if MachineLoss.gone?(state.handle),
      do: MachineLoss.hand_off(state, turn, detail),
      else: TurnMachine.fail_before_start(turn, state.conversation_id, state.sandbox_id, detail)

    %{state | current_turn: nil, turn_session_retry: nil, turn_provider_failure: nil}
  end

  # Time to first token (#535), one-shot per turn: `TurnMachine.maybe_emit_first_output/1`.
  defp maybe_emit_first_output(state) do
    TurnMachine.into_state(
      state,
      TurnMachine.maybe_emit_first_output(TurnMachine.from_state(state))
    )
  end

  # The aggregate turn-duration event (#536), from every path that ends a turn
  # which actually ran: `TurnMachine.emit_completed/2`.
  defp emit_turn_completed(state, status),
    do: TurnMachine.emit_completed(TurnMachine.from_state(state), status)

  # Persistence for peer-relayed lines: the log budget, redaction and the
  # replay deduplication all live on this path; the tracer reads protocol lines
  # from the peer's reports, never raw chunks.
  defp persist_acp_lines(state, stream, data) do
    new_state = log_output(state, stream, data)

    # Each "acp" report is one session/update line; the tracer turns tool_call
    # / tool_call_update into child spans. Peer-relayed lines carry no byte
    # replay-suffix arithmetic: a fresh peer's lines never replay, and an
    # attached peer's replayed lines were matched by content before this.
    tracer =
      if stream == "acp" do
        Managoat.ACP.Tracer.handle_line(new_state.stream_tracer, data)
      else
        new_state.stream_tracer
      end

    %{new_state | stream_tracer: tracer}
  end

  # Terminal path for an ACP turn. The order matters: stdin closes first so the
  # adapter starts exiting while we do the bookkeeping, and `current_command_ref`
  # is cleared at the end so the `{:exit, …}` that follows finds no match and
  # falls through to the catch-all. A turn ends on the prompt response *or* the
  # process exit, whichever arrives first, and never waits for both.
  #
  # End a turn, and only a turn (#817). The connection — `current_command`,
  # `current_command_ref`, `acp_peer` — is left alive and idle for the next
  # `prompt/3`; what is cleared here is the turn's own bookkeeping. The
  # connection is closed elsewhere, by `drop_connection/2`, when the sandbox
  # stops being this server's.
  defp finish_acp_turn(state, status, span_attrs, stage_meta) do
    # Resolve a held permission request as the turn ends (#940): a card left
    # open is a client waiting on an answer that can never come, and the
    # turn's `pending_permission` would stay set on a turn that is over.
    state = Pending.resolve_held(state, "turn_ended")

    state = state |> cancel_autonomous_quiet() |> Output.flush_state()

    turn = TurnMachine.finish(TurnMachine.from_state(state), status, span_attrs, stage_meta)
    KeyHandover.settle(touch_activity(TurnMachine.into_state(state, turn)))
  end

  # One peer report through the turn state machine (#1374): the turn the
  # server holds goes in, the next one comes back with the effects to apply,
  # in order. `ctx` is what the machine needs that is not the turn's own.
  defp drive_turn(state, payload, extra \\ []),
    do: TurnMachine.drive(state, payload, extra, &apply_effect/2)

  # What the machine hands back: the server's state, processes, timers,
  # output persistence and pending registries, one clause each.
  defp apply_effect(state, {:persist_lines, stream, data}),
    do: persist_acp_lines(state, stream, data)

  defp apply_effect(state, :open_autonomous_turn), do: open_autonomous_turn(state)
  defp apply_effect(state, :arm_autonomous_quiet), do: arm_autonomous_quiet(state)

  defp apply_effect(state, {:session_id, id}),
    do: TurnMachine.accept_runtime_session(state, id)

  # The row must stop naming a session that is not on the disk, or every later
  # turn resumes the same absent one. Re-read for the reason the clause above
  # re-reads it: what is written goes onto the row as it is now.
  defp apply_effect(state, {:forget_runtime_session, reason, detail}),
    do: TurnMachine.forget_turn_session(state, reason, detail)

  defp apply_effect(state, {:restart_session, detail}),
    do: restart_session(state, detail)

  defp apply_effect(state, {:ask_permission, request_id, tool, options}),
    do: Pending.ask(state, request_id, tool, options)

  defp apply_effect(state, {:ask_elicitation, request_id, message, schema}),
    do: Pending.ask_elicitation(state, request_id, message, schema)

  defp apply_effect(state, {:finish, status, span_attrs, stage_meta}),
    do: finish_acp_turn(state, status, span_attrs, stage_meta)

  defp apply_effect(state, {:drop_connection, why}), do: drop_connection(state, why)

  # ── the connection (#817) ─────────────────────────────────────────────────

  # This turn rides the open connection (`Connection.resume/7`): the span, the
  # stage event and the peer's answer are the connection's; the turn fields
  # they land in are the server's. A peer that refuses the prompt is dropped
  # and the turn runs on a fresh spawn against the row that already exists.
  defp resume_acp_connection(state, conv, turn, prompt, images) do
    case Connection.resume(
           Connection.from_state(state),
           state.conversation_id,
           state.user_id,
           conv,
           turn,
           prompt,
           images
         ) do
      {:ok, turn_span, tracer, started_mono} ->
        %{
          touch_activity(state)
          | current_turn: turn,
            current_turn_span: turn_span,
            turn_metrics:
              TurnMachine.start_metrics(
                conv.runtime,
                state.handle.provider,
                started_mono,
                turn.turn_number
              ),
            stream_tracer: tracer
        }

      {:error, _reason} ->
        state = drop_connection(state, "peer_refused_reuse")
        run_fresh_turn(state, conv, turn, prompt, TurnMachine.agent_for(conv), images)
    end
  end

  # The failed resume never prompted. Keep the initialized peer, remote
  # command and admitted execution so its original deadline and fences hold.
  defp restart_session(%{current_turn: nil} = state, _detail), do: state

  defp restart_session(state, detail) do
    case TurnMachine.try_forget_turn_session(state, "session_gone", detail) do
      {:ok, state} ->
        restart_current_session(state, detail)

      {:error, state} ->
        abandon_session_restart(state)
    end
  end

  defp abandon_session_restart(state) do
    state
    |> TurnMachine.into_state(TurnMachine.abandon_fenced(TurnMachine.from_state(state)))
    |> drop_connection("restart_fenced")
    |> KeyHandover.settle()
  end

  defp restart_current_session(state, detail) do
    case Connection.restart_peer_session(state.acp_peer) do
      :ok ->
        TurnMachine.into_state(
          state,
          TurnMachine.note_session_restart(TurnMachine.from_state(state), detail)
        )

      {:error, reason} ->
        drive_turn(state, {:failed, reason})
    end
  end

  # Close the connection (`Connection.close/3`). An autonomous turn still open
  # is completed first: its updates are real, and ending a turn resolves what
  # the turn holds pending and stamps its row, which is the server's work. The
  # first clause is why a server with no connection skips that finish too.
  defp drop_connection(%{acp_peer: nil, current_command: nil} = state, _why), do: state

  defp drop_connection(state, why) do
    state = close_autonomous_turn(state, "connection_closed")

    _ = why

    Connection.into_state(
      state,
      Connection.close(Connection.from_state(state), state.conversation_id, state.handle)
    )
  end

  # The adapter went away between turns with no turn to fail
  # (`Connection.lost/5`).
  defp connection_lost(state, reason, meta) do
    Connection.into_state(
      state,
      Connection.lost(
        Connection.from_state(state),
        state.conversation_id,
        state.handle,
        reason,
        meta
      )
    )
  end

  # An out-of-turn protocol line opened a background cycle
  # (`Connection.open_autonomous_turn/5`). The row, its span and its tracer are
  # the server's to hold; the quiet timer is armed in this process.
  defp open_autonomous_turn(state) do
    case Connection.open_autonomous_turn(
           state.conversation_id,
           state.user_id,
           state.sandbox_id,
           Fountain.InferenceCredentials.Source.dump(state.inference_source)
         ) do
      {:error, _} ->
        drop_connection(state, "admission_refused")

      {turn, turn_span, tracer} ->
        arm_autonomous_quiet(%{
          touch_activity(state)
          | current_turn: turn,
            current_turn_span: turn_span,
            turn_metrics: nil,
            stream_tracer: tracer
        })
    end
  end

  defp close_autonomous_turn(state, why) do
    if TurnMachine.autonomous_turn?(state) do
      finish_acp_turn(state, "completed", %{"origin" => why}, %{origin: "autonomous", cycle: why})
    else
      state
    end
  end

  defp arm_autonomous_quiet(state) do
    Connection.into_state(
      state,
      Connection.arm_quiet(Connection.from_state(state), state.current_turn)
    )
  end

  defp cancel_autonomous_quiet(state),
    do: Connection.into_state(state, Connection.cancel_quiet(Connection.from_state(state)))

  defp stop_acp_peer(state), do: Connection.stop_peer(Connection.from_state(state))

  # ── output (#331) ─────────────────────────────────────────────────────────

  # One chunk of sandbox output onto the transcript, against the durable
  # budget: `Output.log/4`.
  defp log_output(state, stream, data),
    do:
      Output.into_state(
        state,
        Output.log(Output.from_state(state), Output.ctx(state), stream, data)
      )
end
