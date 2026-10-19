defmodule Fountain.Conversations.Connection do
  @moduledoc """
  The ACP connection, which outlives the turn (#817).

  A value — the peer, its monitor, the sandbox command underneath it, and the
  quiet timer that closes a background cycle — and the functions that reuse
  it, close it, lose it, and open the autonomous turn an out-of-turn protocol
  line starts.

  The distinction the module exists for: a turn ends when the agent answers,
  the connection ends when the sandbox stops being this server's. Between the
  two, an idle adapter stays on the machine. The next turn selects its model
  and sends its prompt without a spawn, handshake or `session/resume`.
  Background tasks and the runtime's per-session grants survive.
  `Fountain.Conversations.TurnMachine` owns the turn itself and
  answers `autonomous_turn?/1`; what a turn ends with is the server's, because
  ending one resolves what is pending and stamps the row.

  `from_state/1` reads the five server fields into a `%Connection{}` and
  `into_state/2` writes them back; the server's state does not change shape.
  Timers are armed in the calling process, which is the server.
  """

  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{CodexApproval, Output, Provisioning, TurnMachine}
  alias Fountain.Machines.Machine

  @type t :: %__MODULE__{
          peer: pid() | nil,
          peer_mon: reference() | nil,
          command: term() | nil,
          command_ref: term() | nil,
          quiet_timer: reference() | nil
        }

  defstruct peer: nil, peer_mon: nil, command: nil, command_ref: nil, quiet_timer: nil

  # An autonomous turn with no `cycle_end` closes after this long a silence.
  @autonomous_quiet_ms :timer.minutes(10)

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "What the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      peer: state.acp_peer,
      peer_mon: state.acp_peer_mon,
      command: state.current_command,
      command_ref: state.current_command_ref,
      quiet_timer: state.autonomous_quiet
    }
  end

  @doc "The value written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = conn) do
    %{
      state
      | acp_peer: conn.peer,
        acp_peer_mon: conn.peer_mon,
        current_command: conn.command,
        current_command_ref: conn.command_ref,
        autonomous_quiet: conn.quiet_timer
    }
  end

  # ── what is open, and what is busy ────────────────────────────────────────

  @doc "Whether an idle peer from an earlier turn is still driving this machine."
  @spec alive?(t()) :: boolean()
  def alive?(%__MODULE__{peer: peer}) when is_pid(peer), do: Process.alive?(peer)
  def alive?(%__MODULE__{}), do: false

  @doc """
  Busy means a turn, not a connection (#817).

  An autonomous turn does not make the conversation busy: a human prompt
  supersedes the background cycle rather than queueing behind it.
  """
  @spec user_turn_running?(map() | nil) :: boolean()
  def user_turn_running?(%{origin: "autonomous"}), do: false
  def user_turn_running?(turn), do: not is_nil(turn)

  # ── riding the open connection ────────────────────────────────────────────

  @doc """
  Why the idle connection must close before this turn, or nil to keep it.

    * `"broker_session_replaced"`: the idle peer holds the broker token that
      `Egress.refresh_before_turn/1` just replaced (#1736).
    * `"model_env_changed"`: the adapter keeps the env it was spawned with,
      and on claude that env decides which Opus its `opus` alias serves
      (`TurnMachine.model_env/3`), so a peer spawned for another answer would
      refuse this turn's model. A peer reattached across a deploy has an
      unknown spawn env (`acp_model_env: nil`), and is kept only by a runtime
      that never varies it.
    * `"permission_policy_changed"`: the peer answers permission requests
      with the policy it was started with, and on codex that policy also
      chose the approval mode the adapter was spawned in (#2708). A changed
      agent policy must reach the next turn, so a peer started under another
      one closes. A reattached peer was handed the current policy, but its
      codex mode is unknown, so it is kept only where the policy adds no mode.
    * `"callback_key_rotated"`: the peer was spawned with a callback key
      other than the one the server holds now (a reattach, whose peer was
      spawned by the previous server: `acp_callback_key_id: nil`). The
      adapter's `MANAGOAT_TOKEN` and any `"auth": "conversation"` MCP
      server's headers (ADR 0086) hold that key, and neither changes in a
      running process, so every runtime closes it (#2835). A fresh spawn
      sends the current key in its env and on `session/new` or
      `session/resume`. A reattached claude peer is closed first as
      `"model_env_changed"`; the reason is one, so it closes once.
  """
  @spec stale_reason(map(), boolean(), Conversations.Conversation.t(), map() | nil) ::
          String.t() | nil
  def stale_reason(_state, true, _conv, _agent), do: "broker_session_replaced"

  def stale_reason(state, false, conv, agent) do
    cond do
      not model_env_matches?(state, conv, agent) -> "model_env_changed"
      not permission_policy_matches?(state, conv, agent) -> "permission_policy_changed"
      not callback_key_matches?(state) -> "callback_key_rotated"
      true -> nil
    end
  end

  defp callback_key_matches?(state),
    do: Map.get(state, :acp_callback_key_id) == Map.get(state, :callback_api_key_id)

  defp permission_policy_matches?(%{acp_permission_policy: nil}, conv, agent),
    do:
      CodexApproval.env(conv.runtime, TurnMachine.effective_permission_policy(conv, agent)) == []

  defp permission_policy_matches?(state, conv, agent),
    do: state.acp_permission_policy == TurnMachine.effective_permission_policy(conv, agent)

  defp model_env_matches?(%{acp_model_env: nil} = state, _conv, _agent),
    do: not Managoat.Runtimes.implements?(state.runtime_module, :model_env, 1)

  defp model_env_matches?(state, conv, agent),
    do: state.acp_model_env == TurnMachine.model_env(state.runtime_module, conv, agent)

  @doc """
  This turn rides the open connection: no spawn, no handshake.

  `Peer.prompt/4` reuses the session already open, so a background task keeps
  running and the runtime's per-session grants survive (#817). Returns the
  turn span, the tracer over it and the monotonic stamp the turn's metrics
  start from; `{:error, reason}` when the idle peer would not take the prompt
  (it died between the check and the call, or is wedged), with the span
  already closed — the caller drops the connection and spawns fresh.
  """
  @spec resume(
          t(),
          String.t(),
          String.t(),
          Conversations.Conversation.t(),
          map(),
          String.t(),
          list()
        ) ::
          {:ok, term(), term(), integer()} | {:error, term()}
  def resume(%__MODULE__{} = conn, conversation_id, user_id, conv, turn, prompt, images) do
    agent = TurnMachine.agent_for(conv)
    model = TurnMachine.acp_model(conv, agent)
    turn_span = TurnMachine.open_span(user_id, conv, turn, :continue, agent)

    previous_span = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Tracer.set_current_span(turn_span)

    started_mono = System.monotonic_time(:millisecond)

    # Every turn names its options, an empty map included: the peer applies
    # exactly what the turn requested (ADR 0062).
    opts = [model: model, config: TurnMachine.acp_session_config(turn)]

    case Managoat.ACP.Peer.prompt(conn.peer, prompt, images, opts) do
      :ok ->
        # Announce only an accepted reuse. On refusal the fresh launch owns
        # this same row's start (#1924). The actor processes queued peer
        # output after this call returns, so the start still precedes it.
        Output.publish_stage(
          conversation_id,
          "turn",
          "started",
          Conversations.Turn.correlate(turn, %{
            turn_id: turn.id,
            turn_number: turn.turn_number,
            mode: "continue",
            connection: "reused"
          })
        )

        OpenTelemetry.Tracer.set_current_span(previous_span)
        {:ok, turn_span, Managoat.ACP.Tracer.new(turn_span, prefix: "fountain"), started_mono}

      {:error, reason} ->
        Logger.warning(
          "conv #{conversation_id}: idle peer refused prompt (#{inspect(reason)}); respawning"
        )

        OpenTelemetry.Tracer.set_current_span(previous_span)
        TurnMachine.end_span(turn_span, :error, %{"error" => "peer_refused_reuse"})
        {:error, reason}
    end
  end

  # A persistent sandbox can predate the deployed adapter pin. Check it when
  # opening a connection, preserving its disk and runtime session. Reused
  # connections keep their process until they close.
  @doc "Check the adapter pin and spawn a fresh command on the existing sandbox."
  @spec spawn_command(map(), String.t(), String.t(), list(), keyword()) ::
          {:ok, Managoat.Sandbox.Command.t()} | {:error, term()}
  def spawn_command(state, runtime, cmd, args, opts) do
    with {:ok, opts} <- Fountain.Conversations.CodexTransport.spawn_opts(state, runtime, opts),
         :ok <- Provisioning.check_acp_adapter(state.handle, runtime, state.sprite_env) do
      {cmd, args} =
        Fountain.Conversations.CodexSandbox.command(state.handle.provider, runtime, cmd, args)

      Managoat.Sandbox.spawn(state.handle, cmd, args, opts)
    end
  end

  # ── letting it go ─────────────────────────────────────────────────────────

  @doc "Stop a verified idle adapter left behind by a previous owner."
  @spec reap_session(Managoat.Sandbox.Handle.t(), String.t()) :: :ok
  def reap_session(handle, session_id) do
    case Managoat.Sandbox.attach(handle, session_id, owner: self(), stdin: true) do
      {:ok, command} ->
        # A detachable adapter survives its WebSocket closing. EOF is what
        # releases its runtime writer before a new owner attempts resume.
        Managoat.Sandbox.close_stdin(command)
        Managoat.Sandbox.stop_command(command)

      _ ->
        :ok
    end
  end

  @doc """
  Close the ACP connection.

  EOF the adapter so it exits — a detachable session outlives its client, so
  closing the socket alone leaves it and any background task running — stop
  the peer, and clear the connection fields. Safe on a value with no peer and
  no command; an autonomous turn still open is the caller's to finish first,
  because ending a turn is the server's.
  """
  @spec close(t()) :: t()
  def close(%__MODULE__{} = conn) do
    conn = cancel_quiet(conn)
    if conn.command, do: Managoat.Sandbox.close_stdin(conn.command)
    stop_peer(conn)
    if conn.command, do: Managoat.Sandbox.stop_command(conn.command)

    cleared(conn)
  end

  @doc """
  The adapter went away between turns with no turn to fail (#817). Record it
  on the transcript and clear the connection; the next prompt spawns fresh.
  """
  @spec lost(t(), String.t(), String.t(), map()) :: t()
  def lost(%__MODULE__{} = conn, conversation_id, reason, meta) do
    Output.publish_stage(
      conversation_id,
      "sandbox",
      "done",
      Map.merge(%{event: "connection_lost", reason: reason}, meta)
    )

    conn = cancel_quiet(conn)

    cleared(conn)
  end

  @doc "Open a fresh session on the same peer (#1667); a peer already gone is unavailable."
  @spec restart_peer_session(pid() | nil) :: :ok | {:error, term()}
  def restart_peer_session(nil), do: {:error, :acp_peer_unavailable}

  def restart_peer_session(peer) do
    Managoat.ACP.Peer.restart_session(peer)
  catch
    :exit, _ -> {:error, :acp_peer_unavailable}
  end

  @doc """
  Stop the peer, if there is one.

  Demonitor before stopping so the peer's own exit does not arrive as a
  `:DOWN` that fails the turn we just finished.
  """
  @spec stop_peer(t()) :: :ok
  def stop_peer(%__MODULE__{peer: nil}), do: :ok

  def stop_peer(%__MODULE__{peer: peer, peer_mon: mon}) do
    if mon, do: Process.demonitor(mon, [:flush])
    if Process.alive?(peer), do: GenServer.stop(peer, :normal, 1_000)
    :ok
  catch
    :exit, _ -> :ok
  end

  defp cleared(%__MODULE__{} = conn),
    do: %{conn | peer: nil, peer_mon: nil, command: nil, command_ref: nil}

  # ── the autonomous turn (#817, #1301) ─────────────────────────────────────

  @doc """
  An out-of-turn protocol line opened a background cycle (#817).

  A real turn row, so the log budget, redaction and stage events all apply;
  `origin: "autonomous"` and a marker prompt tell it from a user turn.
  Returns the row, the span opened over it and the tracer reading it; the
  caller holds them and arms the quiet timer. Its loaded source must match the
  persisted configuration, including an explicitly unbound source.
  """
  @spec open_autonomous_turn(String.t(), String.t(), String.t(), map() | nil) ::
          {map(), term(), term()} | {:error, term()}
  def open_autonomous_turn(conversation_id, user_id, sandbox_id, inference_source) do
    # Ownership: a server's own conversation, established at init. The server
    # passes its sandbox and source so an old connection cannot adopt a
    # binding committed before its peer has been refreshed.
    conv = Conversations._unsafe_get_conversation!(conversation_id)
    turn_number = Conversations._unsafe_next_turn_number(conversation_id)

    attrs = %{
      conversation_id: conv.id,
      turn_number: turn_number,
      prompt: "(background task follow-up)",
      origin: "autonomous",
      inference_source: inference_source,
      status: "running",
      started_at: now()
    }

    # Through the owner (ADR 0058 stage 8a), so a background cycle is admitted
    # under the same lock, lease refusal and per-runtime count as a prompt.
    with {:ok, turn} <- Machine.admit_turn(sandbox_id, attrs) do
      turn_span =
        TurnMachine.open_span(user_id, conv, turn, :autonomous, TurnMachine.agent_for(conv))

      Output.publish_stage(conversation_id, "turn", "started", %{
        turn_id: turn.id,
        turn_number: turn_number,
        origin: "autonomous"
      })

      {turn, turn_span, Managoat.ACP.Tracer.new(turn_span, prefix: "fountain")}
    end
  end

  @doc """
  Arm the timer that closes an autonomous turn gone quiet without a
  `cycle_end` (#1301): an adapter too old to mark its origin must not hold a
  turn open forever. No turn, no timer.
  """
  @spec arm_quiet(t(), map() | nil) :: t()
  def arm_quiet(%__MODULE__{} = conn, turn) do
    conn = cancel_quiet(conn)
    turn_id = turn && turn.id

    timer =
      if turn_id do
        Process.send_after(self(), {:autonomous_quiet, turn_id}, quiet_ms())
      end

    %{conn | quiet_timer: timer}
  end

  @doc "Disarm the quiet timer."
  @spec cancel_quiet(t()) :: t()
  def cancel_quiet(%__MODULE__{quiet_timer: nil} = conn), do: conn

  def cancel_quiet(%__MODULE__{quiet_timer: timer} = conn) do
    Process.cancel_timer(timer)
    %{conn | quiet_timer: nil}
  end

  @doc "How long a silence closes an autonomous turn."
  @spec quiet_ms() :: non_neg_integer()
  def quiet_ms do
    Application.get_env(:fountain, :autonomous_turn_quiet_ms, @autonomous_quiet_ms)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
