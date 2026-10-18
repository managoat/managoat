defmodule Fountain.Conversations.Reattachment do
  @moduledoc "ACP peer restoration for a running turn."

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.ActorStatus
  alias Fountain.Conversations.{ConfigHome, Connection, Egress, Output, Pending, Provisioning}
  alias Fountain.Conversations.TurnMachine
  alias Fountain.Machines.Machine

  # How long after it started a turn whose prompt never reached the agent is
  # still run again on reattach. Past it the turn is orphaned: the person has
  # likely moved on, and it bounds a turn that keeps landing on dying servers.
  @relaunch_window_s 600

  @doc """
  Bring a parked machine up before a server reattaches to it: a `suspended`
  row is resumed through its owner (`Machine.ensure_up/2`), with the fleet
  gate and the provider call a wake makes, and read again. Any other row is
  answered as it is.

  A server meets a `suspended` row when a park landed between the wake's own
  resume and the server's start. On an implicit workspace that is only the
  reaper's park, and rare, and the reattach still confirms such a row `ready`
  as it always has (`Provision.confirm_up/2`). On an explicit one a
  co-tenant's idle park makes it ordinary, and confirming it without a
  provider call would leave a paused machine (E2B) behind a row that says it
  is up (review of step 4a), so it is resumed. A refusal is reported on the
  reattach stage, retryable, and the server stops; the next prompt wakes it.
  """
  @spec awake(map(), String.t()) :: {:ok, map()} | {:error, term()}
  def awake(%{status: "suspended"} = sandbox, conv_id) do
    case Fountain.Workspaces.machine_kind(sandbox) do
      :explicit -> resume_before_reattach(sandbox.id, conv_id)
      :implicit -> {:ok, sandbox}
    end
  end

  def awake(sandbox, _conv_id), do: {:ok, sandbox}

  defp resume_before_reattach(sandbox_id, conv_id) do
    case Machine.ensure_up(sandbox_id,
           actor: "system:wake",
           requesting_conversation_id: conv_id
         ) do
      # ownership: the server's own machine, established at its init.
      {:ok, _outcome} ->
        {:ok, Conversations._unsafe_get_sandbox(sandbox_id)}

      {:error, reason} = error ->
        Output.publish_stage(conv_id, "reattach", "failed", %{
          reason: inspect(reason),
          retryable: true
        })

        error
    end
  end

  @doc false
  def prepare_source(handle, state, conv, agent, sprite_env) do
    with :ok <-
           step(state, "reattach_config", fn ->
             write_config(handle, state, agent, conv, sprite_env)
           end) do
      # Deliberately unchecked, and the reattach carries on either way: a
      # reconciliation that fails, or whose record write does, leaves the
      # skills on the disk and the conversation's record as it was until a
      # later reattach writes it. That is a record lagging the disk, not a
      # failed reattach, and refusing the reattach over it would be the worse
      # trade (round 1, protocol review).
      _ =
        step(state, "reattach_skills", fn ->
          Fountain.Conversations.Skills.mount(handle, conv, agent, sprite_env)
        end)

      with :ok <- Fountain.Conversations.InferenceBinding.reserve(conv, state.inference_source) do
        step(state, "reattach_adapter", fn ->
          Provisioning.prepare_runtime_sprite(
            handle,
            conv,
            runtime(conv, agent),
            state.runtime_module,
            agent,
            sprite_env,
            state.inference_source
          )
        end)
      end
    end
  end

  # What a reattach rewrites on the disk: the runtime's config, the agent's
  # instructions, the env file and the broker CA. None reads another, so they
  # go at once, as `FreshProvision`'s config step has since #2499; one after
  # another they were most of a reattach's own time (#2562). The env file and
  # broker readiness decide the answer:
  #
  # - The runtime config rewrite keeps the config home's MCP servers current
  #   with the agent's resolved servers after the callback token rotated
  #   (#2152). Best effort: the turn's own failure says more than a refused
  #   wake would.
  # - Broker trust and transport readiness are required before network work.
  # - The env file is required.
  #
  # Each write is its own `reattach_config_*` span too: the step's p50 was
  # 1.85 s on 2026-10-05 for four writes at once, and its one span cannot say
  # which of them that is.
  defp write_config(handle, state, agent, conv, sprite_env) do
    [
      fn ->
        step(state, "reattach_config_runtime", fn ->
          write_runtime_config(handle, state, agent, conv)
        end)
      end,
      fn ->
        step(state, "reattach_config_instructions", fn ->
          Provisioning.write_instructions(
            handle,
            runtime(conv, agent),
            agent,
            Fountain.Conversations.ConfigHome.home(conv)
          )
        end)
      end,
      fn ->
        step(state, "reattach_config_ca", fn ->
          Egress.install_ca(state.broker, handle, state.conversation_id)
        end)
      end
    ]
    |> Enum.map(&async_step/1)
    |> then(fn tasks ->
      env_file =
        step(state, "reattach_config_env", fn ->
          Provisioning.write_env_file(
            handle,
            Fountain.Conversations.Identity.disk_env(sprite_env)
          )
        end)

      results = Enum.map(tasks, &await_step/1)
      Enum.find([env_file | results], :ok, &(&1 != :ok))
    end)
  end

  defp write_runtime_config(handle, state, agent, conv) do
    Provisioning.write_runtime_config(
      handle,
      state.runtime_module,
      agent,
      Fountain.Conversations.ConfigHome.home(conv)
    )
    |> best_effort("runtime config write on wake")
  end

  # As `FreshProvision`'s: an exception in a task would reach the server as a
  # link exit, past the handling a raise in the server itself gets, so the
  # task catches it and awaiting re-raises it here with its own stacktrace.
  defp async_step(fun) do
    context = :otel_ctx.get_current()

    Task.async(fn ->
      token = :otel_ctx.attach(context)

      try do
        {:ok, fun.()}
      rescue
        exception -> {:raised, exception, __STACKTRACE__}
      after
        :otel_ctx.detach(token)
      end
    end)
  end

  defp await_step(task) do
    case Task.await(task, :infinity) do
      {:ok, result} -> result
      {:raised, exception, stacktrace} -> reraise exception, stacktrace
    end
  end

  defp best_effort(:ok, _what), do: :ok

  defp best_effort({:error, reason}, what) do
    Logger.warning("#{what}: #{inspect(reason)}")
    :ok
  end

  defp runtime(conv, agent), do: conv.runtime || (agent && agent.runtime) || "claude"

  # A reattach step on the `fountain.provision_step` histogram, under a
  # `reattach_` name, so a slow wake says which step it spent its time in the
  # way a slow provision does.
  defp step(state, name, fun) do
    conv_id = state.conversation_id

    Fountain.Telemetry.span([:provision_step], %{conv_id: conv_id, step: name}, fn ->
      {fun.(), %{conv_id: conv_id, step: name}}
    end)
  end

  @doc """
  What a failed reattach publishes: the reason `inspect/1`ed beside whatever
  the caller's arm says of it in `meta`.
  """
  @spec failed_stage(map(), term(), map()) :: map()
  def failed_stage(_state, reason, meta \\ %{}), do: Map.put(meta, :reason, inspect(reason))

  @replay_dedup_ttl_ms 10_000

  # An ACP turn is only alive while something answers the agent: a
  # `session/request_permission` left unanswered blocks it forever, and the
  # `session/prompt` response is the only thing that ends it — the adapter
  # keeps running until stdin closes. Before this, a reattached ACP turn had
  # its stdout logged raw and no peer, so every turn in flight across a deploy
  # hung until the user prompted again (which interrupts it) or the sandbox
  # hit its lifetime ceiling.
  #
  # No tracer: the turn span belongs to a previous BEAM lifetime.
  def acp_peer(state, running_turn, conv) do
    policy = TurnMachine.effective_permission_policy(conv, TurnMachine.agent_for(conv))

    {:ok, peer} =
      Managoat.ACP.Peer.start(
        owner: self(),
        # The transport seam (Managoat.ACP.Transport): the peer writes through
        # this function and never sees the sandbox. `write_stdin/2` is total —
        # a runtime that has already exited answers {:error, :command_exited},
        # which the peer reports as {:failed, {:acp_write_failed, _}}.
        writer: fn iodata -> Managoat.Sandbox.write_stdin(state.current_command, iodata) end,
        ref: state.current_command_ref,
        prompt: running_turn.prompt,
        mode: :continue,
        session_id: conv.runtime_session_id,
        # Unused by an attached peer, which does no session setup; named so
        # its state says where the session runs (ADR 0097).
        cwd: ConfigHome.cwd(conv),
        attach: running_turn.acp_prompt_id,
        # A reattached peer answers `session/request_permission` exactly like a
        # fresh one — the adapter in the sprite is mid-turn and still asking.
        # Resolving from the agent here (rather than reading a policy frozen on
        # the conversation row) is what makes a tightening apply across a
        # deploy.
        permission_policy: policy,
        # Not sent (an attached peer does no handshake), but it is what the
        # peer services (#2492): the adapter may still ask for a form. Read
        # from the policy as it is now, like the policy above; an adapter
        # initialized under a policy that asked, and reattached under one that
        # no longer does, gets its form refused, which it reports to the model
        # as a question it could not present.
        client_capabilities: Managoat.Runtimes.client_capabilities(state.runtime_module, policy),
        auth:
          Fountain.Conversations.CodexChatGPT.peer_auth(
            state.runtime_module,
            state.inference_credentials
          ),
        # Hand back the request the previous peer was holding, if any (#940).
        # The agent minted the JSON-RPC id and is still blocked on it, so the
        # id outlives our process — but only if we wrote it down. This is the
        # same trap `acp_prompt_id` exists for, and the reason the turn row
        # carries `pending_permission` at all.
        pending_permission: running_turn.pending_permission
      )

    # ownership: ConversationServer passes its bound conversation and that
    # conversation's persisted running turn; neither ID comes from a request here.
    dedup =
      Conversations._unsafe_recent_output_lines(state.conversation_id, running_turn.id, "acp")

    Process.send_after(self(), :clear_replay_dedup, @replay_dedup_ttl_ms)

    state =
      Pending.into_state(
        state,
        Pending.restore_permission_timer(Pending.from_state(state), running_turn)
      )

    %{
      state
      | acp_peer: peer,
        acp_peer_mon: Process.monitor(peer),
        # The env this process was spawned with belongs to a previous BEAM
        # lifetime: unknown, so a claude turn after this one respawns.
        acp_model_env: nil,
        # Likewise the approval mode codex was spawned in (#2708).
        acp_permission_policy: nil,
        # And the callback key its `"auth": "conversation"` headers carry: the
        # previous server's, which `rotate_callback_api_key/2` just replaced.
        acp_callback_key_id: nil,
        stream_tracer: nil,
        replay_dedup: dedup
    }
  end

  def fail_transport(state, reason) do
    Logger.error("sprite command error mid-turn: #{inspect(reason)} — failing the turn")
    state = Output.flush_state(state)

    # Stop the failed connection's local peer before committing the turn result.
    # Completion rechecks the actor's binding after this callback can yield.
    Connection.stop_peer(Connection.from_state(state))

    turn =
      TurnMachine.finish(
        TurnMachine.from_state(state),
        "failed",
        %{"error" => inspect(reason)},
        %{reason: "sprite connection lost: #{inspect(reason)}"}
      )

    state = TurnMachine.into_state(state, turn)

    {:noreply,
     %{
       %{state | last_activity_at: DateTime.utc_now()}
       | current_command: nil,
         current_command_ref: nil,
         acp_peer: nil,
         acp_peer_mon: nil
     }}
  end

  # If a turn is marked `running` in the DB and the sprite has an active
  # detachable session, reattach to it: the WebSocket reconnects, stdout
  # continues streaming where it left off, and the eventual `:exit` message
  # closes the turn cleanly. If no active session is found, the command
  # finished while the BEAM was down — we don't know the exit code, so
  # mark the orphaned turn `interrupted` so the user gets a clear signal.
  #
  # Answers the state, or `{:relaunch, state, turn}` when the turn's prompt
  # never reached the agent and the server should run it again.
  def reattach_running_turn(state) do
    running_turn = find_running_turn(state.conversation_id)

    if is_nil(running_turn) do
      # No turn was in flight, but a deploy also killed the idle peer that
      # outlives a turn (#817), leaving its detachable adapter session running
      # with nothing to drive it. Reap it — by this conversation's tag, never
      # the head of the list: a co-tenant's live turn on the same machine must
      # not be touched (ADR 0023, #1058).
      reap_orphan_sessions(state)
    else
      case Managoat.Sandbox.Retry.with_backoff(
             fn -> Managoat.Sandbox.list_sessions(state.handle) end,
             label: "session list on reattach"
           ) do
        {:ok, sessions} ->
          # Don't filter by `is_active`: a detached session reports
          # `is_active: false` while no client is connected, but the
          # underlying exec is alive and `attach_session` resumes its
          # stream (replaying the session buffer + live-tailing).
          #
          # Match on the conversation tag, never the head of the list: with
          # several conversations on one machine, the head is as likely to be
          # someone else's process as ours (`Fountain.Conversations.Identity`).
          case Fountain.Conversations.Identity.reattach_session(
                 state.handle,
                 sessions,
                 state.conversation_id
               ) do
            :none ->
              mark_orphan(state, running_turn, "no_active_session")
              state

            {:ok, session, matched_by, superseded} ->
              # Older adapters can retain a runtime writer even while this
              # conversation has a running turn. Preserve the selected adapter
              # and reap only the other sessions whose ownership was verified.
              Enum.each(superseded, &Connection.reap_session(state.handle, &1.id))
              attempt_session_attach(state, running_turn, session, matched_by)
          end

        {:error, reason} ->
          Logger.warning("list_sessions failed during reattach: #{inspect(reason)}")
          mark_orphan(state, running_turn, "list_sessions_failed")
          state
      end
    end
  end

  # After a restart with no turn in flight, stop this conversation's own
  # leftover adapter sessions (#817). Matched by tag; a session tagged for
  # another conversation, or untagged, is left alone.
  defp reap_orphan_sessions(state) do
    case Managoat.Sandbox.list_sessions(state.handle) do
      {:ok, sessions} ->
        mine =
          Fountain.Conversations.Identity.owned_sessions(
            state.handle,
            sessions,
            state.conversation_id
          )

        Enum.each(mine, &Connection.reap_session(state.handle, &1.id))

        outcome = if mine == [], do: "no_running_turn", else: "orphan_session_reaped"

        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: outcome,
          reaped: length(mine)
        })

        state

      {:error, _reason} ->
        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "no_running_turn"
        })

        state
    end
  end

  defp attempt_session_attach(state, running_turn, session, matched_by) do
    # ownership: the server's bound conversation and the running turn
    # `find_running_turn/1` read for it; no id here came from a request.
    conv = Conversations._unsafe_get_conversation!(state.conversation_id)

    case Managoat.Sandbox.attach(state.handle, session.id, owner: self(), stdin: true) do
      {:ok, idle_command} when is_nil(running_turn.acp_prompt_id) ->
        # The previous peer died before it wrote `session/prompt` (or the turn
        # predates the column). The adapter is sitting idle in its handshake
        # with nothing to answer, and no peer can pick that up: the ids it
        # would need are gone with the process. Stop it — otherwise it lingers
        # as a session the next reattach could bind to.
        #
        # The agent never saw the prompt, so running the turn again from the
        # start is safe, and it is what the person asked for: a deploy that
        # lands between admission and `session/prompt` used to lose it. A turn
        # older than the window is orphaned as before, so a prompt is never
        # run long after it was sent, and a server that keeps dying cannot
        # relaunch the same turn forever.
        Managoat.Sandbox.stop_command(idle_command)

        if relaunchable?(running_turn) do
          Output.publish_stage(state.conversation_id, "reattach", "done", %{
            outcome: "turn_relaunched",
            reason: "acp_prompt_not_sent",
            turn_number: running_turn.turn_number,
            turn_id: running_turn.id
          })

          {:relaunch, state, running_turn}
        else
          mark_orphan(state, running_turn, "acp_prompt_not_sent")
          state
        end

      {:ok, command} ->
        finish_session_attach(state, running_turn, conv, command, session, matched_by)

      {:error, reason} ->
        Logger.warning("attach_session failed: #{inspect(reason)}")
        mark_orphan(state, running_turn, "attach_failed")
        state
    end
  end

  defp finish_session_attach(state, running_turn, conv, command, session, matched_by) do
    case ActorStatus.running(state) do
      :ok ->
        Output.publish_stage(state.conversation_id, "reattach", "done", %{
          outcome: "session_attached",
          matched_by: matched_by,
          session_id: session.id,
          turn_id: running_turn.id,
          turn_number: running_turn.turn_number,
          acp_prompt_id: running_turn.acp_prompt_id
        })

        # turn_metrics stays nil on purpose, so this turn contributes no
        # duration sample (#536). Its start is in a previous BEAM lifetime:
        # monotonic time isn't comparable across a restart, and measuring
        # from the row's started_at would fold the whole deploy gap into the
        # histogram. A missing sample beats a wrong one.
        state = %{
          state
          | current_command: command,
            current_command_ref: command.ref,
            current_turn: running_turn
        }

        acp_peer(state, running_turn, conv)

      :stale ->
        # The attached command belongs to this attempt's old machine. Do not
        # create a peer or announce success against the successor's binding.
        Managoat.Sandbox.stop_command(command)
        state
    end
  end

  # ownership: `running_turn` came from `find_running_turn/1`, scoped to the
  # conversation this server owns — but not to the sandbox this actor is bound
  # to, which is the fence every other lifecycle write in #1767 carries.
  #
  # Every caller above runs inside a live actor on the reattach path, and that
  # path is reached precisely when this actor has been away: an actor on S1
  # restarts and reattaches while the conversation has since been rebound to
  # S2 with a successor actor running a turn on it. `find_running_turn/1` hands
  # back the *successor's* turn, and without a fence this flips it to
  # `interrupted` and the conversation to `idle` — the exact loss #1767 exists
  # to close, in the function that is also the backstop for it.
  #
  # `sandbox_id: state.sandbox_id` is the actor's own binding, set once from
  # init args and never reassigned. The owner's door (`Machine.end_turn/3`, ADR
  # 0058 stage 8a) re-locks the parent and compares under that lock
  # (`Machines.Admission.bound?/2`), so a rebind answers
  # `{:error, :ownership_changed}` and writes nothing. The stale actor then
  # carries on with `current_turn: nil`, which is correct: a turn it no longer
  # owns is not its to finish.
  #
  # `SandboxReaper.sweep_stuck_turns/0` stays unfenced deliberately, and is unaffected by
  # this: it fires only when `ConversationServer.whereis/1` is nil, so there is
  # no actor whose binding it could compare against (#2021 item 1).
  defp mark_orphan(state, running_turn, why) do
    case Machine.end_turn(running_turn, {:orphan, why}, sandbox_id: state.sandbox_id) do
      {:error, :ownership_changed} ->
        Logger.warning(
          "reattach: not orphaning turn #{running_turn.id} (#{why}) — conversation " <>
            "#{state.conversation_id} has been rebound away from sandbox #{state.sandbox_id}"
        )

        :noop

      result ->
        result
    end
  end

  defp relaunchable?(%{started_at: %DateTime{} = started_at}),
    do: DateTime.diff(DateTime.utc_now(), started_at) <= @relaunch_window_s

  defp relaunchable?(_turn), do: false

  def find_running_turn(conv_id) do
    import Ecto.Query

    Fountain.Repo.one(
      from t in Fountain.Conversations.Turn,
        where: t.conversation_id == ^conv_id and t.status == "running",
        order_by: [desc: t.turn_number],
        limit: 1
    )
  end
end
