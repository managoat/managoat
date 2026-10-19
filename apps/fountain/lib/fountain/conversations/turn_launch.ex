defmodule Fountain.Conversations.TurnLaunch do
  @moduledoc """
  Launch a fresh command for a turn the actor has already admitted.

  Extracted from `ConversationServer.run_fresh_turn/6`: the actor is
  the largest module in the system and its line count only ratchets down
  (`conversation_server_size_test.exs`). This is the natural seam — a pure
  launch, given a state it does not own and returning it.

  `fail_before_start` is the actor's own pre-start failure path, passed in
  rather than duplicated: it logs the failure, which is the actor's business.

  `relaunch_crashed/3` says why at its definition: an adapter that a native
  crash killed before it wrote a byte is launched once more under the same
  turn (#2402).
  """
  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.Connection
  alias Fountain.Conversations.{CodexApproval, ConversationKey, McpServers, Output, TurnMachine}

  def run(state, conv, turn, prompt, agent, images, fail_before_start) do
    case TurnMachine.session_plan(turn, state.runtime_session_id) do
      {:ok, plan} ->
        spec = %{
          conv: conv,
          agent: agent,
          prompt: prompt,
          images: images,
          relaunched?: false
        }

        launch(state, turn, spec, fail_before_start, plan)

      {:error, _} ->
        session_plan_refused(state, turn)
    end
  end

  defp session_plan_refused(state, turn) do
    # ownership: the conversation actor supplied its already admitted turn.
    Logger.warning("conv #{state.conversation_id}: runtime session preparation refused")
    {:ok, _} = Conversations._unsafe_update_turn(turn, %{status: "failed"})
    {:ok, _} = Conversations._unsafe_idle_after_turn(turn)
    state
  end

  # `spec` is what the launch runs, kept on the turn's metrics so a relaunch
  # (`relaunch_crashed/3`) runs the same thing.
  defp launch(state, turn, spec, fail_before_start, {mode, runtime_session_id}) do
    %{conv: conv, agent: agent, prompt: prompt, images: images, relaunched?: relaunch?} = spec
    turn_number = turn.turn_number

    {cmd, args, cwd} = TurnMachine.command(conv, agent, state.handle)

    # A relaunch continues the turn the first launch announced and timed.
    unless relaunch?, do: publish_started(state, turn, turn_number, mode)

    # Open an OTel span for the turn. We can't use Telemetry.span here
    # because the turn finishes asynchronously (in the :exit handler);
    # so we open it explicitly and store the span context in state to
    # close it later. While this span is current, build_sprite_env
    # picks up the trace context as TRACEPARENT for the runtime CLI.
    turn_span =
      if relaunch?,
        do: state.current_turn_span,
        else: TurnMachine.open_span(state.user_id, conv, turn, mode, agent)

    previous_span = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Tracer.set_current_span(turn_span)

    # Tag the detachable session with this conversation, on its own command
    # line, so a reattach after a deploy can tell it from another
    # conversation's process on the same machine (ADR 0023 gate 1).
    {cmd, args} = Fountain.Conversations.Identity.tag_command(state.conversation_id, cmd, args)

    # Stamped before the spawn so the duration covers the round trip to
    # sprites.dev — that latency is part of what the user waits through.
    # Kept local until the spawn succeeds: a spawn that never starts has no
    # run to time, and a stamp left in state would attach itself to the
    # next turn. A relaunch keeps the first launch's stamp: the user has
    # been waiting since then.
    turn_started_mono =
      if relaunch?,
        do: state.turn_metrics.started_mono,
        else: System.monotonic_time(:millisecond)

    # What this turn's model needs in the adapter's own env, on top of the
    # sandbox's. Recorded with the peer, so a reuse can tell it apart.
    model_env = TurnMachine.model_env(state.runtime_module, conv, agent)

    # The policy the peer answers with, and the codex approval mode it needs
    # in the adapter's env (#2708). Recorded with the peer too: a reuse under
    # another policy would answer with the old one, in the old mode.
    policy = TurnMachine.effective_permission_policy(conv, agent)
    approval_env = CodexApproval.env(conv.runtime, policy)

    # The narrow key this turn's `"auth": "conversation"` MCP servers get,
    # minted from the current callback key the first time one is needed
    # (#2934). Never the sandbox's own `sprite` key.
    state = ConversationKey.ensure(state, agent)

    try do
      spawn_opts =
        [
          env: CodexApproval.put_env(state.sprite_env, approval_env) ++ model_env,
          owner: self(),
          # The peer writes protocol requests and permission answers over
          # this channel throughout the adapter's lifetime.
          stdin: true,
          tty: false,
          dir: cwd,
          # Detachable: the sprite-side session survives a WebSocket
          # disconnect, so a BEAM restart can list_sessions + reattach.
          detachable: true
        ]

      case Connection.spawn_command(state, conv.runtime, cmd, args, spawn_opts) do
        {:ok, command} ->
          stream_tracer = Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")

          {peer, peer_mon} =
            TurnMachine.start_acp_peer(command, prompt, mode, runtime_session_id,
              cwd: cwd,
              images: images,
              mcp_servers:
                McpServers.for_session(agent,
                  resolved: state.resolved_mcp_servers,
                  conversation: %{
                    id: state.conversation_id,
                    token: ConversationKey.token(state)
                  }
                ),
              additional_directories:
                Enum.uniq(repository_directories(state) ++ cwd_git_directory(conv, state.handle)),
              model: TurnMachine.acp_model(conv, agent),
              config: TurnMachine.acp_session_config(turn),
              permission_policy: policy,
              client_capabilities:
                Managoat.Runtimes.client_capabilities(state.runtime_module, policy),
              auth:
                Fountain.Conversations.CodexChatGPT.peer_auth(
                  state.runtime_module,
                  state.inference_credentials
                )
            )

          %{
            state
            | current_command: command,
              current_command_ref: command.ref,
              current_turn: turn,
              runtime_session_id: runtime_session_id,
              current_turn_span: turn_span,
              turn_metrics:
                if(relaunch?,
                  do: state.turn_metrics,
                  else:
                    TurnMachine.start_metrics(
                      conv.runtime,
                      state.handle.provider,
                      turn_started_mono,
                      turn.turn_number
                    )
                )
                |> Map.put(:launch, Map.put(spec, :plan, {mode, runtime_session_id})),
              stream_tracer: stream_tracer,
              acp_peer: peer,
              acp_peer_mon: peer_mon,
              acp_model_env: model_env,
              acp_permission_policy: policy,
              acp_callback_key_id: state.callback_api_key_id
          }

        {:error, reason} ->
          fail_before_start.(state, turn, reason)
      end
    after
      # The successful path keeps the span open until :exit; the error
      # path above closes it explicitly. In both cases we restore the
      # caller's previous current-span here.
      OpenTelemetry.Tracer.set_current_span(previous_span)
    end
  end

  defp publish_started(state, turn, turn_number, mode) do
    Output.publish_stage(
      state.conversation_id,
      "turn",
      "started",
      Conversations.Turn.correlate(turn, %{
        turn_id: turn.id,
        turn_number: turn_number,
        mode: Atom.to_string(mode)
      })
    )
  end

  # Exit statuses Sprites reports for a process a native crash killed:
  # 128 + the signal (#2402). SIGKILL and SIGTERM are not here: something
  # outside the process sent those, and it would send them again.
  @native_crashes %{
    132 => "SIGILL",
    133 => "SIGTRAP",
    134 => "SIGABRT",
    135 => "SIGBUS",
    136 => "SIGFPE",
    139 => "SIGSEGV"
  }

  @doc """
  Launch a turn's adapter once more after a native crash killed it
  before it wrote a byte (#2402).

  Node 24 on Sprites guests has been seen to die of SIGSEGV during startup
  under concurrent launches, and one of six concurrent Claude turns failed
  that way in production. Such a turn failed with nothing sent to the model.

  Retrying is safe only because of what the conditions prove. The command
  wrote nothing to stdout, and its stdout and its exit reach this actor from
  the same command process, in order. So the adapter never answered
  `initialize`, the peer never sent `session/new`, and no `session/prompt`
  existed to be answered twice. The launch must also be this turn's own
  fresh launch (`:launch` is set only here): an idle peer carried across
  turns may already have been prompted. Only the first launch retries, so a
  crash that recurs fails the turn as it always did.

  A turn whose conversation has moved to another sandbox since this actor
  launched it, including while its peer was stopping, is not relaunched: the
  plan write carries the actor's binding and refuses.

  `finish` is the server's exit path, `(state, code) -> {:noreply, state}`.
  Every exit goes through here; the ones that do not qualify, and any retry
  that is refused or cannot start, end through `finish` exactly as an exit
  always did.
  """
  def relaunch_crashed(
        %{
          current_turn: %{} = turn,
          turn_metrics: %{first_output?: false, launch: %{relaunched?: false} = launch}
        } = state,
        code,
        finish
      )
      when is_map_key(@native_crashes, code) do
    # Stop the dead command's peer before the fence, as the exit path does:
    # the stop waits, and a check made before it would be stale after it.
    Connection.stop_peer(Connection.from_state(state))
    state = %{state | acp_peer: nil, acp_peer_mon: nil}
    {mode, id} = launch.plan

    # The plan write carrying this actor's binding is the check that Wake has not moved
    # the conversation to a replacement. Nothing is announced or spawned
    # before it passes. On any refusal the exit ends the turn as it always
    # did: `finish` is the server's exit path, whose `Machine.end_turn/3`
    # applies the same binding.
    case TurnMachine.session_plan(turn, mode, id, state.sandbox_id) do
      {:ok, plan} ->
        spec = %{Map.delete(launch, :plan) | relaunched?: true}
        relaunch(state, turn, spec, plan, code, finish)

      {:error, reason} ->
        Logger.info(
          "conv #{state.conversation_id}: adapter crashed before any output; " <>
            "not relaunched (#{inspect(reason)})"
        )

        finish.(state, code)
    end
  end

  def relaunch_crashed(state, code, finish), do: finish.(state, code)

  @doc """
  The exit a `turn`/`done` stage reports: the code, and for a native crash the
  signal it stands for (#2402). A bare 139 reads as the runtime's own error;
  `SIGSEGV` says the process died, which is what the reader needs to know.
  """
  @spec exit_meta(integer()) :: %{
          required(:exit_code) => integer(),
          optional(:signal) => String.t()
        }
  def exit_meta(code) do
    case @native_crashes do
      %{^code => signal} -> %{exit_code: code, signal: signal}
      _ -> %{exit_code: code}
    end
  end

  defp relaunch(state, turn, spec, plan, code, finish) do
    signal = Map.fetch!(@native_crashes, code)

    Logger.warning(
      "conv #{state.conversation_id}: adapter died on #{signal} before any output; " <>
        "launching it once more (#2402)"
    )

    Output.publish_stage(state.conversation_id, "session", "done", %{
      event: "restarted",
      reason: "adapter_crashed",
      detail: signal,
      turn_id: turn.id,
      message:
        "The agent's runtime crashed while starting (#{signal}), before your prompt " <>
          "was sent. It is being started again."
    })

    TurnMachine.stamp_span(state.current_turn_span, %{"acp.adapter_relaunched" => signal})

    # A relaunch that cannot start ends the turn as the crash would have:
    # through the exit path, with the crash's code, the first launch's
    # measurements and its completion metric. The turn already ran, so the
    # never-started path's silence would drop it from the failure rate.
    cannot_start = fn state, _turn, reason ->
      Logger.warning(
        "conv #{state.conversation_id}: adapter relaunch did not start: #{inspect(reason)}"
      )

      {:noreply, state} = finish.(state, code)
      state
    end

    state = %{state | current_command: nil, current_command_ref: nil}
    {:noreply, launch(state, turn, spec, cannot_start, plan)}
  end

  # The environment's clones, which codex adds to its sandbox's writable roots
  # (#1684): without them a clone outside its cwd is read-only, and a worktree
  # cut from it fails. Each clone's `.git` goes too, as a root of its own:
  # codex keeps `.git` read-only inside every writable root, so a branch or a
  # commit still failed with the clone alone. A path that does not exist is
  # ignored by codex. Read the way `Egress.refresh_before_turn/1` reads it,
  # tenant-scoped on the provisioned environment; a row that is gone gives
  # nothing. Mapped like `cwd`, since the adapter checks them in band.
  defp repository_directories(%{secret_sources: %{environment_id: env_id}} = state)
       when is_binary(env_id) do
    env_id
    |> Fountain.Environments.get_environment(state.user_id)
    |> Fountain.Environments.Environment.repository_mounts()
    |> Enum.flat_map(&[&1, Path.join(&1, ".git")])
    |> Enum.map(&Managoat.Sandbox.host_path(state.handle, &1))
  end

  defp repository_directories(_state), do: []

  # A launch's own cwd (ADR 0097) is codex's workspace, so it is writable
  # already; its `.git` is not, for the same reason a clone's is not above.
  # A cwd that is a checkout the setup script made would otherwise refuse
  # every commit. A cwd that is a repository mount (#2999) gets the same
  # `.git` from both lists, once. Nothing for the runtime's default cwd,
  # which is as before.
  # Codex only, whose sandbox is the reason; a `.git` that is not there (a
  # cwd that is no checkout) is ignored by codex, as a missing clone is.
  defp cwd_git_directory(%{runtime: "codex", cwd: cwd}, handle)
       when is_binary(cwd) and cwd != "",
       do: [Managoat.Sandbox.host_path(handle, Path.join(cwd, ".git"))]

  defp cwd_git_directory(_conv, _handle), do: []
end
