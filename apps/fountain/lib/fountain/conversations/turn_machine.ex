defmodule Fountain.Conversations.TurnMachine do
  @moduledoc """
  A conversation's turn as a state machine (#1374): the running turn row,
  its OTel span, its metrics and its stream tracer as one value, and one
  function per peer report that returns the next value and a list of
  effects for `ConversationServer` to apply.

  ## The shape

  `from_state/1` reads the server's four turn fields (and the reattach
  dedup set the `:lines` report consults) into a `%Turn{}`; `into_state/2`
  writes them back. The server's state does not change shape.

  `handle/3` is the machine. It reads rows and writes the turn row (the
  prompt's JSON-RPC id, the usage), and records what is the turn's own to
  record (the `model` stage, the handshake telemetry and span stamp, the
  permission-denied audit). Everything that is the server's — its other
  state, its processes, its timers, output persistence, the pending
  registries — comes back as an effect, applied in list order:

    * `{:persist_lines, stream, data}` — the log budget, redaction, replay
      skip and tracer feed (the output family, #1377);
    * `:open_autonomous_turn`, `:arm_autonomous_quiet` — the background
      cycle a peer narrates out of turn (#817, the connection family);
    * `{:session_id, id}` — persist the runtime's session id on the row and
      in state;
    * `{:forget_runtime_session, reason, detail}` — clear it again, when the
      runtime says the session it names is not there (#778's remedy, reached
      by the failure rather than by a wake);
    * `{:restart_session, detail}` — open a fresh session on the same peer
      before its original prompt and images are sent (#1667);
    * `{:ask_permission, request_id, tool, options}` — the held request:
      its row, its stage, its timeout (the pending family, #1375);
    * `{:ask_elicitation, request_id, message, schema}` — the same for a
      held form (#2492);
    * `{:finish, status, span_attrs, stage_meta}` — end the turn: the
      server resolves what is pending, cancels the quiet timer, then calls
      `finish/4`;
    * `{:drop_connection, why}` — a failed peer is not reusable.

  `finish/4` and the interrupt pair are the turn's own bookkeeping, called
  by the server at the right point of its sequence so nothing reorders.
  The functions after them are what starting a turn decides before the
  spawn, which stays a server callback because it spawns.
  """

  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.{Agents, Conversations}
  alias Fountain.Agents.SessionConfig
  alias Fountain.Conversations.{Conversation, Interruption, Labels}
  alias Fountain.InferenceCredentials.Source
  alias Fountain.Machines.Machine

  @typedoc "What the peer reports about a turn, with the command ref already matched."
  @type payload :: tuple()

  @typedoc """
  What the machine needs that is not the turn's own: `:autonomous?` (the
  connection family's predicate, read by the server), `:runtime_module`
  (the OAuth clause is Claude-only), `:oauth_switched?` (the server
  swaps the env before the call; the machine words the message), and
  `:inference` (the `Fountain.InferenceCredentials.Source` whose credential
  runs this turn, ADR 0053), stamped on the turn when its prompt goes out.
  """
  @type ctx :: %{
          optional(:autonomous?) => boolean(),
          optional(:runtime_module) => module(),
          optional(:oauth_switched?) => boolean(),
          optional(:inference) => Fountain.InferenceCredentials.Source.t() | nil
        }

  @type effect ::
          {:persist_lines, String.t(), binary()}
          | :open_autonomous_turn
          | :arm_autonomous_quiet
          | {:session_id, String.t()}
          | {:forget_runtime_session, String.t(), String.t()}
          | {:restart_session, String.t()}
          | {:ask_permission, term(), String.t(), list()}
          | {:ask_elicitation, term(), String.t(), map()}
          | {:finish, String.t(), map(), map()}
          | {:drop_connection, String.t()}

  @type t :: %__MODULE__{
          conversation_id: String.t() | nil,
          sandbox_id: String.t() | nil,
          interrupted?: boolean(),
          row: Conversations.Turn.t() | nil,
          span: term() | nil,
          metrics: map() | nil,
          tracer: term() | nil,
          replay_dedup: MapSet.t(),
          session_retry: String.t() | nil,
          provider_failure: %{system_error?: boolean(), detail: String.t() | nil} | nil
        }

  defstruct conversation_id: nil,
            sandbox_id: nil,
            interrupted?: false,
            row: nil,
            span: nil,
            metrics: nil,
            tracer: nil,
            replay_dedup: MapSet.new(),
            # The detail of the `session_gone` this turn has already been
            # restarted for (#1667), or nil. One restart per turn: the machine
            # itself refuses a second, so a fresh session that is also gone
            # fails the turn the way it always did rather than looping.
            session_retry: nil,
            # What the runtime said went wrong with the model call during this
            # turn (#2545), or nil: `system_error?` once it reported its thread
            # in `systemError`, and `detail`, the provider's own words from the
            # last error it relayed. Read when the prompt is answered, which
            # `end_turn` alone would record as a success.
            provider_failure: nil

  # ── the server boundary ───────────────────────────────────────────────────

  @doc "The turn the server holds, as one value."
  @spec from_state(map()) :: t()
  def from_state(state) do
    %__MODULE__{
      conversation_id: state.conversation_id,
      sandbox_id: state.sandbox_id,
      row: state.current_turn,
      span: state.current_turn_span,
      metrics: state.turn_metrics,
      tracer: state.stream_tracer,
      replay_dedup: state.replay_dedup,
      session_retry: state.turn_session_retry,
      provider_failure: state.turn_provider_failure
    }
  end

  @doc "The turn written back into the server's fields."
  @spec into_state(map(), t()) :: map()
  def into_state(state, %__MODULE__{} = turn) do
    %{
      state
      | current_turn: turn.row,
        current_turn_span: turn.span,
        turn_metrics: turn.metrics,
        stream_tracer: turn.tracer,
        replay_dedup: turn.replay_dedup,
        turn_session_retry: turn.session_retry,
        turn_provider_failure: turn.provider_failure
    }
  end

  # ── the machine ───────────────────────────────────────────────────────────

  @doc """
  The `ctx/0` for a report, from the server's state plus whatever the call
  site adds (`:oauth_switched?` is the only one).

  Here rather than at the call site because every key of it is the machine's
  own vocabulary, and the server's job is to hold the state, not to know
  which parts of it the machine reads.
  """
  @spec ctx(map(), keyword()) :: ctx()
  def ctx(state, extra \\ []) do
    Map.new(
      [
        autonomous?: autonomous_turn?(state),
        runtime_module: state.runtime_module,
        inference: state.inference_source
      ] ++ extra
    )
  end

  @doc """
  Whether the running turn is a background cycle the agent narrated out of
  turn (#817) rather than a prompt somebody sent. Over the server's state,
  which is where the running turn lives.
  """
  @spec autonomous_turn?(map()) :: boolean()
  def autonomous_turn?(%{current_turn: %{origin: "autonomous"}}), do: true
  def autonomous_turn?(_state), do: false

  @doc "Apply one peer report, stopping its effects if background admission is refused."
  @spec drive(map(), payload(), keyword(), (map(), effect() -> map())) :: map()
  def drive(state, payload, extra, apply_effect) do
    {turn, effects} = handle(from_state(state), payload, ctx(state, extra))
    state = into_state(state, turn)

    Enum.reduce_while(effects, state, fn effect, state ->
      state = apply_effect.(state, effect)

      # A refused background turn must not persist its output or ask permission.
      if effect == :open_autonomous_turn and is_nil(state.current_turn),
        do: {:halt, state},
        else: {:cont, state}
    end)
  end

  @doc "One peer report: the next turn and the effects the server applies."
  @spec handle(t(), payload(), ctx()) :: {t(), [effect()]}
  def handle(turn, payload, ctx \\ %{})

  # A `session/update` the peer relayed. Under ACP every line here is
  # protocol, so it lands on the "acp" stream with the tracer reading it
  # (`persist_lines`). A line with no turn open (#817) means the agent is
  # narrating a background cycle: that opens an autonomous turn — a real
  # row, so the log budget, redaction and the stage events apply unchanged —
  # and every further line re-arms the quiet timer that closes it if no
  # `cycle_end` ever does.
  #
  # Session *metadata* is the exception (#1300). The claude adapter writes its
  # `session_info_update` (the generated title) about a second after every
  # prompt response — out of turn — and reading that as a background follow-up
  # opened a phantom autonomous turn after nearly every turn, held open for
  # the full quiet window: `running` status, deferred idle park, billed turn
  # time. Metadata is nothing the agent did, so it opens no turn and re-arms
  # no quiet timer; with a turn in flight it still lands on the transcript.
  #
  # `_fountain/labels` is the third exception (#1637). ACP reserves a leading
  # underscore for extensions, and `session/update` is the only notification
  # the peer forwards, so that is where a deterministic run stamps its own
  # outcome. It is a control message and not something the agent said, so it
  # opens no turn, re-arms no quiet timer and never reaches the transcript.
  def handle(%__MODULE__{} = turn, {:lines, stream, data}, ctx) do
    labels = if stream == "acp", do: label_update(data)

    cond do
      stream == "acp" and MapSet.member?(turn.replay_dedup, data) ->
        # A replayed line we already hold (ACP reattach). Each persisted line
        # suppresses at most one arrival, so a legitimate later repeat survives.
        {%{turn | replay_dedup: MapSet.delete(turn.replay_dedup, data)}, []}

      is_map(labels) ->
        # Written here rather than handed back as an effect: nothing about it
        # is the server's — no state, no process, no timer — and this machine
        # already writes what a report means.
        #
        # Ownership: `turn.conversation_id` is the id this machine's own
        # `ConversationServer` was started with, so the unscoped write below
        # cannot name another conversation, of this tenant or any other.
        # Nothing a stamp contains can fail the turn; `_unsafe_stamp/2` logs
        # and drops instead.
        Labels._unsafe_stamp(turn.conversation_id, labels)
        {turn, []}

      stream == "acp" and Managoat.ACP.Protocol.session_metadata?(data) ->
        Conversations.SessionInfo.apply(turn.conversation_id, data)

        if is_nil(turn.row) do
          # Metadata updates the conversation even when there is no transcript
          # turn to attach the protocol line to.
          {turn, []}
        else
          {note_codex_status(turn, data), [{:persist_lines, stream, data}]}
        end

      stream == "acp" and is_nil(turn.row) ->
        {turn, [:open_autonomous_turn, {:persist_lines, stream, data}]}

      stream == "acp" and Map.get(ctx, :autonomous?, false) ->
        {turn, [:arm_autonomous_quiet, {:persist_lines, stream, data}]}

      stream == "acp" ->
        {turn |> maybe_emit_first_update(data) |> maybe_emit_first_text(data),
         [{:persist_lines, stream, data}]}

      true ->
        {turn, [{:persist_lines, stream, data}]}
    end
  end

  # The adapter marked the end of a background cycle (#817). The turn it
  # opened closes here; a `cycle_end` with no autonomous turn open (its
  # updates never reached us) is nothing to close.
  def handle(%__MODULE__{} = turn, {:cycle_end, kind}, ctx) do
    if Map.get(ctx, :autonomous?, false) do
      {turn,
       [
         {:finish, "completed", %{"origin" => kind}, %{origin: "autonomous", cycle: kind}}
       ]}
    else
      {turn, []}
    end
  end

  def handle(%__MODULE__{} = turn, {:model_selected, requested, effective, source}, ctx) do
    stamp_span(turn.span, %{requested_model: requested, effective_model: effective})

    selection = %{
      requested_model: requested,
      effective_model: effective,
      source: source,
      status: "selected"
    }

    # The only report that precedes a prompt going out, so the only one that
    # stamps the turn's inference source (#1685).
    turn = record_model_selection(turn, selection, source_stamp(turn.row, ctx))

    publish_stage(
      turn.conversation_id,
      "model",
      "done",
      Map.put(selection, :turn_id, turn.row && turn.row.id)
    )

    {turn, []}
  end

  def handle(%__MODULE__{} = turn, {:failed, {:model_selection_failed, requested, detail}}, _ctx) do
    message =
      "Could not select model #{requested}: #{detail}. No prompt was sent. " <>
        "Choose a model available in this runtime, or refresh its model catalog and check account access."

    selection = %{
      requested_model: requested,
      effective_model: nil,
      status: "failed",
      error: message
    }

    # No inference stamp: every peer source of this report is in
    # `phase: :setting_model`, strictly before `send_prompt/1`, so the turn
    # spent nothing — as the message above says.
    turn = record_model_selection(turn, selection, %{})

    publish_stage(
      turn.conversation_id,
      "model",
      "failed",
      Map.merge(selection, %{
        turn_id: turn.row && turn.row.id,
        requested: requested,
        detail: detail,
        using: "none, the turn failed"
      })
    )

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.model_selection_failed" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
  end

  # ADR 0062: a requested session config option the adapter took, with the
  # value it confirmed. On the turn (#2538) and on the stream, as the `model`
  # stage is.
  def handle(%__MODULE__{} = turn, {:config_selected, id, requested, confirmed}, _ctx) do
    turn =
      record_config_selection(turn, fn selection ->
        Map.update(selection, "applied", %{id => confirmed}, &Map.put(&1, id, confirmed))
      end)

    publish_stage(turn.conversation_id, "config", "done", %{
      turn_id: turn.row && turn.row.id,
      outcome: "applied",
      id: id,
      requested: requested,
      confirmed: confirmed
    })

    {turn, []}
  end

  # An id the adapter does not advertise for this model. Not a failure:
  # options legitimately vary by model, and the request stays on the
  # conversation for a model that offers it.
  def handle(%__MODULE__{} = turn, {:config_skipped, id, requested}, _ctx) do
    turn =
      record_config_selection(turn, fn selection ->
        Map.update(selection, "skipped", [id], &(&1 ++ [id]))
      end)

    # `done`, because a stage's state is one of a fixed few; the outcome says
    # which kind of done.
    publish_stage(turn.conversation_id, "config", "done", %{
      turn_id: turn.row && turn.row.id,
      outcome: "skipped",
      id: id,
      requested: requested,
      reason: "not advertised by the runtime for this model"
    })

    {turn, []}
  end

  # What the adapter offers, after the model and the options were applied.
  # On the conversation, where a client reads it before choosing the agent's
  # options for its next conversation. The harness mode options are left out: they cannot be
  # requested (`SessionConfig.check/1`).
  def handle(%__MODULE__{} = turn, {:config_options, options}, _ctx) do
    Conversations._unsafe_put_session_config_options(
      turn.conversation_id,
      SessionConfig.offered(options)
    )

    {turn, []}
  end

  # The adapter refused a value for an option it advertises. Its sentence is
  # the check, as for the model (#724): the turn fails before the prompt.
  def handle(
        %__MODULE__{} = turn,
        {:failed, {:config_selection_failed, id, requested, detail}},
        _ctx
      ) do
    message =
      "Could not set #{id} to #{inspect(requested)}: #{detail}. No prompt was sent. " <>
        "Choose a value from the conversation's session_config_options, or remove #{id} " <>
        "from the agent's session_config, and start a new conversation."

    turn =
      record_config_selection(turn, fn selection ->
        Map.merge(selection, %{"status" => "failed", "failed_id" => id, "error" => message})
      end)

    publish_stage(turn.conversation_id, "config", "failed", %{
      turn_id: turn.row && turn.row.id,
      id: id,
      requested: requested,
      detail: detail
    })

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.config_selection_failed" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
  end

  # Persist the id chosen by `session/new` immediately: the next turn resumes
  # by it, and a server restart before this turn ends must not lose it.
  def handle(%__MODULE__{} = turn, {:session, id}, _ctx), do: {turn, [{:session_id, id}]}

  # The peer wrote `session/prompt` under this JSON-RPC id. Persisted at once:
  # it is what a reattach after a restart needs to tell the prompt's answer
  # from the replayed handshake, and a turn without it cannot be resumed at
  # all — see `reattach_acp_peer/3`.
  def handle(%__MODULE__{} = turn, {:prompt_timing, time}, _ctx) do
    metrics = turn.metrics && Map.put_new(turn.metrics, :prompt_sent_mono, time)
    {%{turn | metrics: metrics}, []}
  end

  def handle(%__MODULE__{} = turn, {:prompt_sent, id}, _ctx) do
    {:ok, row} = Conversations._unsafe_update_turn(turn.row, %{acp_prompt_id: id})
    {%{turn | row: row}, []}
  end

  # `ask`: the agent is blocked and a human has to answer (#940). An agent
  # blocked mid-cycle asks out of turn (#817): the request needs a turn row
  # to live on, exactly as an out-of-turn update does. The request itself —
  # persisted on the turn first, then announced, then timed — is the
  # server's `ask_permission` effect.
  def handle(%__MODULE__{} = turn, {:permission_ask, request_id, tool, options}, _ctx) do
    open = if is_nil(turn.row), do: [:open_autonomous_turn], else: []
    {turn, open ++ [{:ask_permission, request_id, tool, options}]}
  end

  # A form the agent is blocked on (#2492): held exactly like an `ask`
  # permission request, out of turn included.
  def handle(%__MODULE__{} = turn, {:elicitation_ask, request_id, message, schema}, _ctx) do
    open = if is_nil(turn.row), do: [:open_autonomous_turn], else: []
    {turn, open ++ [{:ask_elicitation, request_id, message, schema}]}
  end

  # A tool the policy withheld (#939). Recorded in the context, per 0013: the
  # tool and the verdict, never the tool's input. Only refusals reach here —
  # the peer stays silent on `auto_allow`, because a turn makes dozens of tool
  # calls and a row each would turn the trail into a transcript.
  def handle(%__MODULE__{} = turn, {:permission_denied, tool, verdict}, _ctx) do
    Conversations.record_permission_denied(turn.conversation_id, tool, verdict)
    {turn, []}
  end

  # What a turn pays for `initialize` plus resumption. Emitted per turn so
  # the cost of starting an adapter can be measured against the turn total.
  #
  # Also stamped on the turn's OTel span, because the comparison that decides
  # the gate is against *this same turn's* total — a handshake figure in an
  # unrelated metrics stream tells you the cost but not the share.
  def handle(%__MODULE__{} = turn, {:handshake_ms, ms, method}, _ctx) do
    :telemetry.execute([:fountain, :acp, :handshake], %{duration_ms: ms}, %{
      conversation_id: turn.conversation_id,
      turn_id: turn.row && turn.row.id,
      method: method
    })

    stamp_span(turn.span, %{
      "acp.handshake_ms" => ms,
      "acp.session_method" => method
    })

    {turn, []}
  end

  # The turn's first terminator: `session/prompt` answered with a stop reason.
  # Closing stdin here is what makes the adapter exit, and clearing the command
  # ref is what makes that exit a no-op instead of a second ending.
  #
  # `usage` is the turn's end-of-turn token figure (#827), recorded once here
  # — the response is the only place the runtime reports it — before the turn
  # row is closed. nil records nothing.
  #
  #
  # #2545: codex-acp answers `end_turn` even when the model call failed
  # outright (an OpenAI key with no credits left: the stream disconnects, Codex
  # retries, then gives up). What it does say is `threadStatus: systemError`
  # in a `session_info_update`, so a turn that heard that is failed whatever
  # the stop reason, with the provider's own words as the stage's `reason`.
  def handle(
        %__MODULE__{provider_failure: %{system_error?: true} = failure} = turn,
        {:done, stop_reason, usage},
        _ctx
      ) do
    message = system_error_message(failure.detail)
    record_usage(turn, usage)

    {turn,
     [
       {:finish, "failed",
        %{"stop_reason" => stop_reason, "error" => message, "acp.system_error" => true},
        %{stop_reason: stop_reason, reason: message}}
     ]}
  end

  def handle(%__MODULE__{} = turn, {:done, stop_reason, usage}, _ctx) do
    # An answered prompt is not necessarily finished work. Token/request limits
    # and unknown future stop reasons must not become success for API consumers,
    # as 8a05804c made it. That includes `waiting`, which once let a request
    # outlive its turn (#1635, removed in #2676): it is now one more stop reason
    # Fountain does not know, and the turn's end denies whatever was held.
    status = if stop_reason == "end_turn", do: "completed", else: "failed"
    record_usage(turn, usage)
    {turn, [{:finish, status, %{"stop_reason" => stop_reason}, %{stop_reason: stop_reason}}]}
  end

  # #655: the org has refused this account's Claude OAuth token. Left alone,
  # every further turn on this conversation would fail the exact same way —
  # nothing about the token changes between attempts — while the Anthropic
  # API key sitting in the same `inference_credentials` row would work. Swap
  # it in for the rest of this server's life (not just a silent retry of this
  # one turn, so the failure and the fix are both visible in the transcript)
  # rather than leave the tenant to rediscover the swap by hand. Scoped to
  # this running conversation on purpose: a fresh conversation tries OAuth
  # again, so a policy that later reverts self-heals instead of staying
  # pinned to a credential this fix disabled.
  #
  # The swap itself is the server's (it logs the refusal and rewrites the
  # sprite env and the broker session before this is called);
  # `:oauth_switched?` says whether a key was there to swap in, which is what
  # the message turns on.
  def handle(
        %__MODULE__{} = turn,
        {:failed, {:oauth_org_not_allowed, _detail}},
        %{runtime_module: Managoat.Runtimes.Claude} = ctx
      ) do
    message =
      cond do
        match?(%Source{identity: identity} when is_binary(identity), Map.get(ctx, :inference)) ->
          "Your organization has disabled Claude subscription (OAuth) access for Claude Code. " <>
            "This conversation remains bound to its selected credential. Start a new conversation " <>
            "with an Anthropic API key as its credential, or restore subscription access."

        Map.get(ctx, :oauth_switched?, false) ->
          "Your organization has disabled Claude subscription (OAuth) access for Claude Code. " <>
            "Switched to the Anthropic API key on this account for the rest of this " <>
            "conversation — send your prompt again."

        true ->
          "Your organization has disabled Claude subscription (OAuth) access for Claude Code, " <>
            "and no Anthropic API key is on file for this account. Add one in Settings, then " <>
            "try again."
      end

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.oauth_org_not_allowed" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
  end

  # #970: the provider refused the model, so this turn and every later one on
  # this agent fail the same way until someone changes the field. The peer
  # already read the kind out of the provider's sentence; what is left is to
  # deliver it as a sentence rather than as an inspected tuple, and to publish
  # the `model` stage so a client has the requested id as a field and can point
  # at the agent that carries it.
  #
  # Nothing is swapped in, unlike the OAuth clause above. There is no second
  # model to fall back to that the tenant did not choose, and picking one would
  # answer their prompt with a model they never asked for.
  def handle(%__MODULE__{} = turn, {:failed, {:model_unavailable, requested, detail}}, _ctx) do
    Logger.warning(
      "conv #{turn.conversation_id}: provider refused model #{requested || "(unset)"}: #{detail}"
    )

    publish_stage(turn.conversation_id, "model", "failed", %{
      requested: requested,
      detail: detail,
      using: "none, the turn failed"
    })

    message = model_unavailable_message(requested, detail)

    {turn,
     [
       {:finish, "failed", %{"error" => message, "acp.model_unavailable" => true},
        %{reason: message}},
       {:drop_connection, "failed"}
     ]}
  end

  # The runtime session this conversation names is not on the disk, so
  # `session/resume` (or `session/load`) can never succeed and every later
  # prompt fails exactly like this one — the shape #778 fixed for a sandbox
  # that was replaced, reached here by the error instead of by a wake.
  #
  # The trigger that prompted this: a first turn whose ACP `initialize` fails
  # transiently. `session_plan/2` has already generated and persisted an id by
  # then — a persisted id is how the next turn knows a turn has happened — but
  # no session was ever opened under it, so `mode` is `:continue` forever
  # against a rollout that was never written:
  #
  #     {:acp_error, :resume_session,
  #      %{"code" => -32603, "data" => %{"details" => "no rollout found for
  #        thread id be412434-…"}}}
  #
  # Observed on codex, and confirmed to still fail identically twenty-two
  # minutes and two prompts later. The conversation stays `idle` between them,
  # so nothing upstream reads as broken: the turns fail, the client is told a
  # turn ended, and the track looks merely quiet.
  #
  # Clearing the id makes the turn `:run` → `session/new`: the same
  # conversation, transcript and title, a new runtime session. The agent's
  # in-context memory is lost — but it was already unreachable, which is the
  # same trade #778 made and for the same reason.
  #
  # #1667: recover once before the model receives the prompt. The peer
  # retains the original input and initializes a new session on the same
  # remote command. The turn's span and measurements stay open; `note_session_restart/2` records the lost context.
  # `session_retry` prevents another recovery within this turn.
  #
  # Read out of the error's sentence rather than off a field, as the two
  # clauses above are and for the same reason: no runtime marks this kind.
  # Both halves are required — the call has to be a resumption *and* the
  # runtime has to have said the session is missing — so that a peer that
  # died mid-handshake is never read as a session that is gone, and a
  # still-good session is never thrown away over a transient failure.
  def handle(%__MODULE__{} = turn, {:failed, {:acp_error, tag, error}}, _ctx)
      when tag in [:resume_session, :load_session] do
    if session_gone?(error) do
      session_gone(turn, tag, acp_detail(error))
    else
      handle_failed(turn, {:acp_error, tag, error})
    end
  end

  # A failed peer is not reusable: end the turn it was driving (if any) and
  # drop the connection, so the next prompt spawns a fresh adapter.
  def handle(%__MODULE__{} = turn, {:failed, reason}, _ctx), do: handle_failed(turn, reason)

  defp session_gone(%__MODULE__{} = turn, tag, detail) do
    forget = {:forget_runtime_session, "session_gone", detail}

    cond do
      is_nil(turn.row) ->
        # A peer that failed to resume with no turn open: nothing was asked,
        # so there is nothing to replay and nothing to fail.
        log_session_gone(turn, tag, detail, "clearing it so the next turn starts a new one")
        {turn, [forget, {:drop_connection, "failed"}]}

      is_nil(turn.session_retry) ->
        log_session_gone(turn, tag, detail, "clearing it and running this turn on a new one")

        {%{turn | session_retry: detail}, [{:restart_session, detail}]}

      true ->
        # The fresh session is gone too. Something is wrong that a third
        # attempt will not fix, so this is the failure #1657 shipped, said in
        # full, once.
        log_session_gone(turn, tag, detail, "already restarted once; failing the turn")
        message = session_gone_message(detail)

        {turn,
         [
           forget,
           {:finish, "failed", %{"error" => message, "acp.session_gone" => true},
            %{reason: message}},
           {:drop_connection, "failed"}
         ]}
    end
  end

  defp log_session_gone(turn, tag, detail, what_next) do
    Logger.warning(
      "conv #{turn.conversation_id}: runtime session is gone (#{tag}): #{detail}; #{what_next}"
    )
  end

  defp handle_failed(%__MODULE__{} = turn, reason) do
    Logger.error("conv #{turn.conversation_id}: acp peer failed: #{inspect(reason)}")

    finish =
      if turn.row do
        [{:finish, "failed", %{"error" => inspect(reason)}, %{reason: "acp: #{inspect(reason)}"}}]
      else
        []
      end

    {turn, finish ++ [{:drop_connection, "failed"}]}
  end

  # The extension update a run stamps its own outcome with (#1637):
  #
  #     {"jsonrpc":"2.0","method":"session/update","params":{
  #       "sessionId":"...",
  #       "update":{"sessionUpdate":"_fountain/labels",
  #                 "labels":{"drift":"true","env":"prod"}}}}
  #
  # ACP reserves a leading `_` for extensions, and `Managoat.ACP.Peer`
  # forwards `session/update` and drops every other notification method, so
  # this rides there rather than on a method of its own.
  #
  # A cheap substring test before the decode: this runs on every protocol line
  # of every turn, and all but a handful of them are agent output.
  @label_kind "_fountain/labels"

  defp label_update(data) do
    if String.contains?(data, @label_kind), do: decode_label_update(data)
  end

  defp decode_label_update(data) do
    case Managoat.ACP.Protocol.classify_line(data) do
      {:notification, "session/update", %{"update" => %{"sessionUpdate" => @label_kind} = update}} ->
        # An `update` carrying no `labels` object is read as an empty merge,
        # which writes nothing. Raising on it would cost the run its turn for
        # a stamp, which is the wrong trade.
        case Map.get(update, "labels") do
          labels when is_map(labels) -> labels
          _ -> %{}
        end

      _ ->
        nil
    end
  end

  # What codex-acp says about its thread (#2545). It has no ACP vocabulary for
  # "the model call failed", so it relays Codex's own events as
  # `session_info_update`s under `_meta.codex`:
  #
  #     {"sessionUpdate":"session_info_update","_meta":{"codex":{"error":{
  #       "message":"Reconnecting... 1/5","additionalDetails":"stream
  #       disconnected before completion: You have no credits remaining. …",
  #       "codexErrorInfo":…,"turnId":"…","willRetry":true}}}}
  #
  #     {"sessionUpdate":"session_info_update",
  #      "_meta":{"codex":{"threadStatus":{"type":"systemError"}}}}
  #
  # The errors come first and carry the provider's words; the status says
  # Codex gave up. `active` means the thread is working again, which clears the
  # verdict but keeps the words. A cheap substring test first: every metadata
  # line of every runtime passes through here.
  defp note_codex_status(%__MODULE__{} = turn, data) do
    if String.contains?(data, ~s("codex")) do
      case Managoat.ACP.Protocol.classify_line(data) do
        {:notification, "session/update", %{"update" => %{"_meta" => %{"codex" => %{} = codex}}}} ->
          note_codex(turn, codex)

        _ ->
          turn
      end
    else
      turn
    end
  end

  defp note_codex(turn, %{"threadStatus" => %{"type" => "systemError"}}),
    do: put_provider_failure(turn, :system_error?, true)

  defp note_codex(%{provider_failure: %{} = failure} = turn, %{
         "threadStatus" => %{"type" => "active"}
       }),
       do: %{turn | provider_failure: %{failure | system_error?: false}}

  defp note_codex(turn, %{"error" => %{} = error}) do
    case error_detail_text(error) do
      nil -> turn
      detail -> put_provider_failure(turn, :detail, detail)
    end
  end

  defp note_codex(turn, _codex), do: turn

  defp error_detail_text(%{"additionalDetails" => detail})
       when is_binary(detail) and detail != "",
       do: detail

  defp error_detail_text(%{"message" => message}) when is_binary(message) and message != "",
    do: message

  defp error_detail_text(_error), do: nil

  defp put_provider_failure(turn, key, value) do
    failure = turn.provider_failure || %{system_error?: false, detail: nil}
    %{turn | provider_failure: Map.put(failure, key, value)}
  end

  # The provider's text can run long (Codex appends the request id and a help
  # link); the stage event is a status line, and the transcript keeps the rest.
  @provider_detail_max 1_000

  defp system_error_message(nil),
    do: "The runtime ended this turn on a system error and gave no detail."

  defp system_error_message(detail),
    do:
      "The runtime ended this turn on a system error: #{String.slice(detail, 0, @provider_detail_max)}"

  # ── ending a turn ─────────────────────────────────────────────────────────

  @doc """
  End a turn, and only a turn (#817): the row, the `turn` stage, the span,
  the completion metric and the conversation back to idle. What the server
  resolves first (a held permission, parked caller tools, the quiet timer)
  is the server's; what it clears after (activity) is too. Returns the turn
  with its bookkeeping cleared. A stale completion clears local bookkeeping
  without overwriting the persisted result or emitting another completion.
  """
  @spec finish(t(), String.t(), map(), map()) :: t()
  def finish(%__MODULE__{} = turn, status, span_attrs, stage_meta) do
    # Before the turn span ends: totals land on it, abandoned tool spans close.
    finalize_tracer(turn.tracer)

    # Ownership: the server supplies its binding, and the context locks and
    # rechecks it under the parent lock (`Machines.Admission.bound?/2`).
    case Machine.end_turn(turn.row, {:finish, status, []}, sandbox_id: turn.sandbox_id) do
      {:ok, row} ->
        stage_meta = Map.merge(stage_meta, %{turn_id: row.id, turn_number: row.turn_number})

        publish_stage(
          turn.conversation_id,
          "turn",
          if(row.status == "completed", do: "done", else: "failed"),
          stage_meta
        )

        end_span(turn.span, if(row.status == "completed", do: :ok, else: :error), span_attrs)
        emit_completed(turn, row.status)

      :noop ->
        end_span(turn.span, :error, %{"outcome" => "completion_ignored"})

      {:error, reason} ->
        Logger.warning("turn #{turn.row.id}: completion refused (#{inspect(reason)})")
        end_span(turn.span, :error, %{"outcome" => "completion_refused"})
    end

    %{
      turn
      | row: nil,
        span: nil,
        metrics: nil,
        tracer: nil,
        session_retry: nil,
        provider_failure: nil
    }
  end

  @doc """
  The interrupt's first half: the row `interrupted`, the stage, the tracer
  closed. The server stops the peer between the halves, as it always did,
  then `close_interrupted/1` ends the span, emits the metric and conditionally
  idles the conversation. A stale mark emits neither a stage nor a metric, and
  closing it writes nothing.

  This half leaves the parent `running` on purpose, so the peer stops under a
  conversation that still says it is working. Turn recovery skips retired
  turns, so this pair must finish its own parent cleanup. The second half
  rechecks the generation rather than this actor's binding
  (`Interruption._unsafe_idle_interrupted_turn/1`). A successor admitted
  while the peer was stopping is what keeps the conversation running.
  """
  #
  # `stage_meta` is merged into the `turn` stage event: a reclaim that cuts a
  # turn passes its `reason` there, so a client reading the stream sees why
  # the turn ended rather than a bare interruption (#2529).
  @spec mark_interrupted(t(), map()) :: t()
  def mark_interrupted(%__MODULE__{} = turn, stage_meta \\ %{}) do
    # Ownership: the actor's binding is checked with the parent and turn locked.
    applied? =
      case Machine.end_turn(turn.row, :mark_interrupted, sandbox_id: turn.sandbox_id) do
        {:ok, _} ->
          publish_stage(
            turn.conversation_id,
            "turn",
            "interrupted",
            Map.merge(stage_meta, %{turn_id: turn.row.id, turn_number: turn.row.turn_number})
          )

          true

        :noop ->
          false
      end

    # Finalize local spans even when another actor owns the persisted result.
    finalize_tracer(turn.tracer)
    %{turn | interrupted?: applied?}
  end

  @spec close_interrupted(t()) :: t()
  def close_interrupted(%__MODULE__{} = turn) do
    end_span(turn.span, :error, %{"outcome" => "interrupted"})

    if turn.interrupted? do
      emit_completed(turn, "interrupted")
      # Ownership: mark_interrupted verified this actor's binding and retired
      # the turn under it. This half releases the parent that half left
      # running. See its docstring for the caller requirement and why it
      # rechecks the generation rather than the binding.
      Interruption._unsafe_idle_interrupted_turn(turn.row)
    end

    %{
      turn
      | row: nil,
        span: nil,
        metrics: nil,
        tracer: nil,
        session_retry: nil,
        provider_failure: nil,
        interrupted?: false
    }
  end

  @doc "Release local measurements for a fenced worker without changing its persisted turn."
  @spec abandon_fenced(t()) :: t()
  def abandon_fenced(%__MODULE__{} = turn) do
    finalize_tracer(turn.tracer)
    end_span(turn.span, :error, %{"outcome" => "execution_fenced"})

    %{
      turn
      | row: nil,
        span: nil,
        metrics: nil,
        tracer: nil,
        session_retry: nil,
        provider_failure: nil
    }
  end

  @doc "Records session recovery while preserving the admitted turn's measurements."
  @spec note_session_restart(t(), String.t()) :: t()
  def note_session_restart(%__MODULE__{} = turn, detail) do
    publish_stage(turn.conversation_id, "session", "done", %{
      event: "restarted",
      reason: "session_gone",
      detail: detail,
      turn_id: turn.row && turn.row.id,
      message: session_restarted_message(detail)
    })

    stamp_span(turn.span, %{
      "acp.session_gone" => true,
      "acp.session_restarted" => true
    })

    turn
  end

  @doc "Start one turn's measurements with the provider of the computer it runs on."
  @spec start_metrics(String.t(), atom(), integer(), integer() | nil) :: map()
  def start_metrics(runtime, provider, started_mono, turn_number \\ nil) do
    %{
      started_mono: started_mono,
      runtime: runtime,
      provider: to_string(provider),
      turn_class: if(turn_number == 1, do: "first", else: "followup"),
      first_text?: false,
      first_output?: false,
      first_update?: false
    }
  end

  # Emit the aggregate turn-duration event (#536). Called from every path
  # that ends a turn which actually ran: the :exit handler, the mid-turn
  # {:error, ...} handler (#413) and :interrupt.
  #
  # The `fountain.turn` OTel span and the turn row's started_at/ended_at
  # both already describe one turn each; neither trends. This is the
  # dashboard/alert signal.
  #
  # Tags are `runtime` (four values, gated by Runtimes.for_runtime/1 on the
  # only path that starts a server), the sandbox `provider`, and terminal `status`
  # (completed/failed/interrupted). conv_id rides along as metadata — it is
  # what makes the JSON log line actionable, and as a tag it would mint a
  # time series per conversation.
  @spec emit_completed(t(), String.t()) :: :ok
  def emit_completed(%__MODULE__{metrics: nil}, _status), do: :ok

  def emit_completed(%__MODULE__{metrics: metrics} = turn, status) do
    Fountain.Telemetry.event(
      [:turn, :completed],
      %{
        runtime: metrics.runtime,
        provider: metrics.provider,
        turn_class: metrics.turn_class,
        status: status,
        conv_id: turn.conversation_id,
        # For `ResponseTiming`'s `[:fountain, :response, :completed]`.
        response_path: get_in(metrics, [:response_timing, :path]),
        text: Map.get(metrics, :first_text?, false)
      },
      %{duration_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )
  end

  # Time to first token (#535): the gap a user actually feels between
  # hitting enter and seeing the agent do something. Provision time and
  # turn duration are both trended; a regression that delays *first
  # output* — slow runtime startup inside the sprite, model latency,
  # stdin plumbing — sat between them, visible only per-trace in
  # Honeycomb, only for Claude, and only with OTLP export configured.
  #
  # One-shot per turn: the first stdout chunk wins and the flag is set,
  # so the whole rest of a streaming turn costs one map update.
  #
  # First bytes, not first parsed token. Measuring bytes keeps this identical
  # across runtimes, including the ACP handshake before a model is called.
  @spec maybe_emit_first_output(t()) :: t()
  def maybe_emit_first_output(%__MODULE__{metrics: %{first_output?: false} = metrics} = turn) do
    Fountain.Telemetry.event(
      [:turn, :first_output],
      metric_metadata(turn),
      %{elapsed_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
    )

    %{turn | metrics: %{metrics | first_output?: true}}
  end

  # No turn running, or this turn already reported. Also the reattach case:
  # turn_metrics is nil there, so the replayed output a resumed session
  # opens with can't be mistaken for a first token (its real one arrived in
  # a previous BEAM lifetime).
  def maybe_emit_first_output(%__MODULE__{} = turn), do: turn

  # The `session/update` kinds that are the agent doing something a user sees:
  # text, thinking, a tool, a plan. Mode, command and usage updates are the
  # adapter's bookkeeping and arrive before the model has answered.
  @agent_update_kinds ~w(agent_message_chunk agent_thought_chunk tool_call tool_call_update plan)

  @doc """
  Time to the agent's first visible update (#2564): the wait a user actually
  feels. `first_output` times the first stdout bytes, which under ACP include
  the handshake, so half of claude turns reported under 250 ms while the user
  still saw nothing. This reports once per turn, on the first `session/update`
  whose kind is in `@agent_update_kinds`, and parses lines only until it has.
  A turn with no metrics (a reattach, a test) reports nothing, as above.
  """
  @spec maybe_emit_first_update(t(), String.t()) :: t()
  def maybe_emit_first_update(%__MODULE__{metrics: %{} = metrics} = turn, line) do
    with false <- Map.get(metrics, :first_update?, false),
         {:notification, "session/update", %{"update" => %{"sessionUpdate" => kind}}}
         when kind in @agent_update_kinds <- Managoat.ACP.Protocol.classify_line(line) do
      Fountain.Telemetry.event(
        [:turn, :first_update],
        Map.put(metric_metadata(turn), :kind, kind),
        %{elapsed_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
      )

      %{turn | metrics: Map.put(metrics, :first_update?, true)}
    else
      _ -> turn
    end
  end

  def maybe_emit_first_update(%__MODULE__{} = turn, _line), do: turn

  @doc "Attach the request clock only to a turn that actually started."
  def with_response_timing(nil, _timing), do: nil
  def with_response_timing(metrics, nil), do: metrics
  def with_response_timing(metrics, timing), do: Map.put(metrics, :response_timing, timing)

  # The turn's span rides along for `ResponseTiming`, the handler that stamps
  # these timings on it; this module only emits them.
  defp metric_metadata(turn) do
    Map.merge(Map.take(turn.metrics, [:runtime, :provider, :turn_class]), %{
      conv_id: turn.conversation_id,
      turn_id: turn.row && turn.row.id,
      span: turn.span
    })
  end

  @doc "First nonempty assistant text, excluding reasoning, tools and protocol traffic."
  def maybe_emit_first_text(%__MODULE__{metrics: %{first_text?: false} = metrics} = turn, line) do
    with {:notification, "session/update",
          %{
            "update" => %{
              "sessionUpdate" => "agent_message_chunk",
              "content" => content
            }
          }} <- Managoat.ACP.Protocol.classify_line(line),
         true <- text_content?(content) do
      # The request clock and the prompt write split the wait into phases;
      # `ResponseTiming` does that from this one event.
      Fountain.Telemetry.event(
        [:turn, :first_text],
        Map.merge(metric_metadata(turn), %{
          turn_started_mono: metrics.started_mono,
          prompt_sent_mono: Map.get(metrics, :prompt_sent_mono),
          response_timing: Map.get(metrics, :response_timing)
        }),
        %{elapsed_ms: System.monotonic_time(:millisecond) - metrics.started_mono}
      )

      %{turn | metrics: %{metrics | first_text?: true}}
    else
      _ -> turn
    end
  end

  def maybe_emit_first_text(turn, _line), do: turn

  defp text_content?(%{"type" => "text", "text" => text}) when is_binary(text), do: text != ""
  defp text_content?(contents) when is_list(contents), do: Enum.any?(contents, &text_content?/1)
  defp text_content?(_), do: false

  # `extra` is whatever else belongs in the same write — the inference source,
  # and nothing else so far. One update, so a turn cannot carry the source
  # without the selection that earned it.
  defp record_config_selection(%__MODULE__{row: nil} = turn, _fun), do: turn

  defp record_config_selection(turn, fun) do
    selection = fun.(turn.row.config_selection || %{})
    {:ok, row} = Conversations._unsafe_update_turn(turn.row, %{config_selection: selection})
    %{turn | row: row}
  end

  defp record_model_selection(%__MODULE__{row: nil} = turn, _selection, _extra), do: turn

  defp record_model_selection(turn, selection, extra) do
    attrs = Map.put(extra, :model_selection, selection)
    {:ok, row} = Conversations._unsafe_update_turn(turn.row, attrs)
    %{turn | row: row}
  end

  # The turn's inference source, written at turn start (#1685, ADR 0060
  # decision 6) from the `:model_selected` report: `Managoat.ACP.Peer` sends
  # that one immediately before it writes `session/prompt`, so it is the one
  # report that means "tokens are about to be spent". Written once; a turn
  # that already carries a source keeps it.
  defp source_stamp(%{inference_source: source}, _) when is_map(source), do: %{}

  defp source_stamp(_, %{inference: %Source{} = source}),
    do: %{inference_source: Source.dump(source)}

  defp source_stamp(_, _), do: %{}

  @spec record_usage(t(), map() | nil) :: :ok
  def record_usage(%__MODULE__{row: %{} = row}, %{} = usage) do
    case Conversations._unsafe_record_turn_usage(row, usage) do
      {:ok, _} ->
        :ok

      other ->
        Logger.warning(
          "conv #{row.conversation_id}: turn #{row.id} usage not recorded: #{inspect(other)}"
        )
    end
  end

  def record_usage(_turn, _usage), do: :ok

  # ── the span and the tracer ───────────────────────────────────────────────

  # The turn's OTel span. Opened explicitly (not via Telemetry.span) because a
  # turn finishes asynchronously, in a later handler; the context is carried in
  # state and closed there. `mode` is `:run` | `:continue` | `:autonomous`.
  @spec open_span(String.t() | nil, Conversation.t(), Conversations.Turn.t(), atom(), map() | nil) ::
          term()
  def open_span(user_id, conv, turn, mode, agent) do
    OpenTelemetry.Tracer.start_span("fountain.turn", %{
      attributes: %{
        "conv_id" => conv.id,
        "turn_id" => turn.id,
        "turn_number" => turn.turn_number,
        "turn_class" => if(turn.turn_number == 1, do: "first", else: "followup"),
        "mode" => Atom.to_string(mode),
        "runtime" => to_string(conv.runtime),
        "model" => agent && agent.model,
        "agent_id" => agent && agent.id,
        "user_id" => user_id,
        "prompt_length" => byte_size(turn.prompt),
        "image_count" => 0
      }
    })
  end

  # Attributes on a turn's span from outside `kick_turn`, which restores the
  # caller's current span in its `after` block — so by the time a peer report
  # arrives the turn span is no longer current and a bare `set_attribute` would
  # land on whatever is.
  @spec stamp_span(term() | nil, map()) :: :ok
  def stamp_span(nil, _attrs), do: :ok

  def stamp_span(span_ctx, attrs) do
    previous = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Tracer.set_current_span(span_ctx)
    Enum.each(attrs, fn {k, v} -> OpenTelemetry.Tracer.set_attribute(to_string(k), v) end)
    OpenTelemetry.Tracer.set_current_span(previous)
    :ok
  end

  # End the OTel turn span (if any) with a status reflecting the
  # outcome. Called from the :exit and :interrupt handlers.
  @spec end_span(term() | nil, :ok | :error, map()) :: :ok | term()
  def end_span(nil, _outcome, _attrs), do: :ok

  def end_span(span_ctx, outcome, attrs) do
    previous = OpenTelemetry.Tracer.current_span_ctx()
    OpenTelemetry.Tracer.set_current_span(span_ctx)

    Enum.each(attrs, fn {k, v} -> OpenTelemetry.Tracer.set_attribute(to_string(k), v) end)

    case outcome do
      :error ->
        OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, inspect(attrs)))

      _ ->
        :ok
    end

    # No-arg: end_span/1 takes a timestamp, not a span. span_ctx was just
    # made current above, which is what no-arg ends.
    OpenTelemetry.Tracer.end_span()
    OpenTelemetry.Tracer.set_current_span(previous)
  end

  # Called on every way a turn can end; a reattached turn may have no tracer.
  @spec finalize_tracer(term() | nil) :: :ok | term()
  def finalize_tracer(nil), do: :ok
  def finalize_tracer(tracer), do: Managoat.ACP.Tracer.finalize(tracer)

  # ── starting a turn ───────────────────────────────────────────────────────

  # Every turn passes through here, whichever door it came in by — the
  # controller/LiveView call above, or the queued initial prompt a wake
  # delivers as a cast. A live server outlives the inference credential it
  # was started under, so each turn checks it again.
  #
  # `inference` is the conversation's inference source (#1388).
  @spec gate(String.t(), Source.t() | nil) :: :ok | {:error, term()}
  def gate(user_id, inference \\ nil), do: validate_inference(user_id, inference)

  @doc """
  The log line for a prompt the server could not turn into a turn.
  """
  @spec log_refusal(String.t(), String.t(), term()) :: :ok
  def log_refusal(conversation_id, what, reason) do
    Logger.info("conv #{conversation_id}: #{what} (#{inspect(reason)})")
  end

  defp validate_inference(user_id, %Source{identity: identity} = source) when is_binary(identity),
    do: Fountain.InferenceCredentials.validate_source(user_id, source)

  defp validate_inference(_, _), do: :ok

  @doc """
  The turn row, or the refusal. The machine may be shared (ADR 0023). For a
  runtime that takes one turn at a time the insert is checked under the
  sandbox's lock, so two conversations prompting the same machine at once
  cannot both start. Refused, not queued: nothing is written, the
  conversation stays idle and the caller sends again when the other turn
  ends.

  `:no_command` is the other refusal, and it belongs to the acp runtime alone
  (#1634). The argv there is the agent's own `runtime_command`, and a
  conversation outlives its agent, so a live server can be asked for a turn
  it has nothing to spawn for. Refused here, before a turn row exists, for the
  same reason capacity is: there is no run to record, and the stage event says
  what happened.
  """
  @spec open(
          String.t(),
          String.t(),
          String.t(),
          map() | nil,
          Source.t() | nil | :unspecified,
          keyword()
        ) ::
          {:ok, Conversation.t(), Conversations.Turn.t()}
          | :no_command
          | {:error, term()}
  def open(
        conversation_id,
        sandbox_id,
        prompt,
        agent \\ nil,
        source \\ :unspecified,
        opts \\ []
      ) do
    conv = Conversations._unsafe_get_conversation!(conversation_id)

    with :ok <- matching_model(source, agent, conv.runtime) do
      if runnable?(conv, agent),
        do: open_turn(conv, sandbox_id, prompt, source, opts),
        else: refuse_no_command(conv)
    end
  end

  defp matching_model(%Source{identity: identity} = source, agent, runtime)
       when is_binary(identity) do
    if source.model == (agent && agent.model) and source.runtime == runtime,
      do: :ok,
      else: {:error, :inference_source_changed}
  end

  defp matching_model(_, _, _), do: :ok

  # `RuntimeDispatch.command/2` is total for every other runtime, so the only
  # question is whether the acp runtime's agent still carries one.
  defp runnable?(conv, agent) do
    not Fountain.RuntimeDispatch.command_required?(conv.runtime) or
      match?({:ok, _}, Fountain.CommandRuntime.argv(agent))
  end

  defp refuse_no_command(conv) do
    publish_stage(conv.id, "turn", "failed", %{
      reason: "no_runtime_command",
      runtime: conv.runtime,
      message:
        "This conversation runs the acp runtime, and the agent that carried its " <>
          "command is gone. Create an agent with a runtime_command and start a " <>
          "conversation on it."
    })

    :no_command
  end

  defp open_turn(conv, sandbox_id, prompt, source, opts) do
    conversation_id = conv.id
    turn_number = Conversations._unsafe_next_turn_number(conversation_id)

    attrs = %{
      conversation_id: conv.id,
      turn_number: turn_number,
      prompt: prompt,
      status: "running",
      started_at: now(),
      prompt_receipt_id: opts[:prompt_receipt_id]
    }

    attrs =
      if source == :unspecified,
        do: attrs,
        else: Map.put(attrs, :inference_source, Source.dump(source))

    # The caller's name for this prompt (#1406), stored on the row it opens.
    attrs =
      case opts[:client_request_id] do
        id when is_binary(id) -> Map.put(attrs, :client_request_id, id)
        _ -> attrs
      end

    # The session config options this turn asks for (ADR 0062): the agent's
    # as the conversation launched with them. Not the live agent's: an edit to
    # it reaches new conversations only (#2664). Fixed here, on the row, so
    # both connection paths send the same request and a client can label the
    # turn with it.
    attrs =
      case SessionConfig.effective(conv) do
        requested when map_size(requested) == 0 -> attrs
        requested -> Map.put(attrs, :config_selection, %{"requested" => requested})
      end

    # The owner admits the turn (ADR 0058 stage 8a): under the machine's lock
    # it re-reads the row and refuses a live lease or a fence.
    case Machine.admit_turn(sandbox_id, attrs) do
      {:ok, turn} ->
        {:ok, conv, turn}

      {:error, reason} = error ->
        publish_stage(conversation_id, "sandbox", "done", %{
          event: "admission_refused",
          reason: if(is_atom(reason), do: Atom.to_string(reason), else: "invalid_turn"),
          message: "This connection could not start another turn."
        })

        error
    end
  end

  # Store images. A rejected image must not take the turn down with it: this
  # used to hard-match {:ok, _}, which is why validation could not be added to
  # the insert path without crashing the server mid-turn.
  @spec store_images(Conversations.Turn.t(), list()) :: :ok
  def store_images(turn, images) do
    case Conversations._unsafe_insert_turn_images(turn.id, images) do
      {:ok, _count} ->
        :ok

      {:error, changeset} ->
        # Log only. A `turn`/`started` stage event is what the LiveView uses to
        # create a turn row, so publishing one here would invent a second turn.
        Logger.warning(
          "turn #{turn.id}: image rejected, continuing without it: " <>
            inspect(changeset.errors)
        )

        :ok
    end
  end

  @doc """
  The mode and the runtime session id a fresh turn runs with. A persisted id
  means "a turn has happened", which is what picks `session/resume` or
  `session/load` over `session/new`; with none, one is generated and
  persisted immediately so a server restart can resume.
  """
  @spec session_plan(Conversations.Turn.t(), String.t() | nil) ::
          {:ok, {:run | :continue, String.t()}} | {:error, term()}
  def session_plan(turn, runtime_session_id) do
    mode = if is_nil(runtime_session_id), do: :run, else: :continue
    fenced_plan(turn, mode, runtime_session_id || Ecto.UUID.generate(), [])
  end

  @doc """
  A plan already chosen for this turn, fenced again: a relaunched adapter
  (#2402) runs the plan its first launch had, since the session that launch
  named was never created.

  `sandbox_id` is the actor's own binding: the check that the conversation
  has not moved to a replacement sandbox since the first launch:
  `{:error, :ownership_changed}` when it has.
  """
  @spec session_plan(Conversations.Turn.t(), :run | :continue, String.t(), String.t() | nil) ::
          {:ok, {:run | :continue, String.t()}} | {:error, term()}
  def session_plan(turn, mode, id, sandbox_id),
    do: fenced_plan(turn, mode, id, sandbox_id: sandbox_id)

  defp fenced_plan(turn, mode, id, opts) do
    # A placeholder chooses run/resume, not ACP identity. Preparing even that
    # placeholder must remain tied to the admitted turn across cancellation.
    case Conversations._unsafe_set_turn_session(turn, id, opts) do
      {:ok, %{applied: true}} -> {:ok, {mode, id}}
      {:ok, %{applied: false}} -> {:error, :plan_refused}
      {:error, _} = error -> error
    end
  end

  @doc """
  The ACP adapter command and its working directory inside the sandbox.

  Prompts, images and runtime session control travel over ACP. For a custom
  ACP runtime, `open/4` has already required the agent's `runtime_command`.
  """
  @spec command(Conversation.t(), map() | nil, Managoat.Sandbox.Handle.t()) ::
          {String.t(), [String.t()], String.t()}
  def command(conv, agent, handle) do
    {cmd, args} = Fountain.RuntimeDispatch.command(conv.runtime, agent)

    # The agent validates ACP cwd against the filesystem inside the sandbox,
    # so it is the sandbox's own path for it: the launch's `cwd`, or the
    # runtime's default (ADR 0097).
    cwd = Managoat.Sandbox.host_path(handle, Fountain.Conversations.ConfigHome.cwd(conv))
    {cmd, args, cwd}
  end

  @doc "Start the peer for a fresh ACP turn, owned by the caller; returns it with its monitor."
  @spec start_acp_peer(Managoat.Sandbox.Command.t(), String.t(), atom(), String.t(), keyword()) ::
          {pid(), reference()}
  def start_acp_peer(command, prompt, mode, runtime_session_id, opts) do
    {:ok, peer} =
      Managoat.ACP.Peer.start(
        owner: self(),
        # See reattach_acp_peer/3 for the writer's contract.
        writer: fn data -> Managoat.Sandbox.write_stdin(command, data) end,
        ref: command.ref,
        prompt: prompt,
        mode: mode,
        session_id: runtime_session_id,
        cwd: Keyword.get(opts, :cwd) || "/home/sprite",
        images: Keyword.get(opts, :images, []),
        mcp_servers: Keyword.get(opts, :mcp_servers, []),
        additional_directories: Keyword.get(opts, :additional_directories, []),
        model: Keyword.get(opts, :model),
        config: Keyword.get(opts, :config, %{}),
        permission_policy: Keyword.get(opts, :permission_policy),
        # What `initialize` declares, per runtime: claude's adds form
        # elicitation, which is what offers its `AskUserQuestion` (#2492).
        client_capabilities: Keyword.get(opts, :client_capabilities),
        # A codex spawn on a ChatGPT subscription must not be authenticated
        # with codex-acp's api-key method (`CodexChatGPT.peer_auth/2`).
        auth: Keyword.get(opts, :auth, :api_key)
      )

    {peer, Process.monitor(peer)}
  end

  @doc """
  The session config options the peer applies before this turn's prompt
  (ADR 0062): what the turn recorded as requested when it opened, less any
  harness mode id a turn opened before those were refused still carries.
  """
  @spec acp_session_config(Conversations.Turn.t() | nil) :: map()
  def acp_session_config(%{config_selection: %{"requested" => requested}}) when is_map(requested),
    do: SessionConfig.without_harness_modes(requested)

  def acp_session_config(_turn), do: %{}

  @doc "The ACP model id to pin for this turn: the agent's model in the runtime's dialect, or nil without an agent."
  @spec acp_model(Conversation.t(), map() | nil) :: String.t() | nil
  def acp_model(_conv, nil), do: nil

  def acp_model(conv, agent),
    do: Fountain.RuntimeDispatch.acp_model(conv.runtime || agent.runtime, agent.model)

  @doc """
  The env the adapter process needs for the model `acp_model/2` pins, from
  `Managoat.Runtimes.model_env/2`: on claude, `claude-opus-5` needs the CLI's
  `opus` alias pointed at it; every other model needs nothing.

  It belongs to the spawn, not the sandbox, so `TurnLaunch` adds it to the
  adapter's env and records it with the peer, and `ConversationServer` does
  not reuse an idle peer spawned with a different answer.
  """
  @spec model_env(module(), Conversation.t(), map() | nil) :: [{String.t(), String.t()}]
  def model_env(runtime_module, conv, agent),
    do: Managoat.Runtimes.model_env(runtime_module, acp_model(conv, agent))

  # The permission policy in force for this turn (#939): the agent's own,
  # clamped by whatever narrowing the launch asked for. Resolved per turn from
  # the agent rather than read off a policy frozen on the conversation row, so
  # tightening an agent tightens the conversations already running under it.
  @spec effective_permission_policy(Conversation.t(), map() | nil) :: term()
  def effective_permission_policy(conv, agent) do
    Managoat.ACP.Permissions.effective(agent && agent.permission_policy, conv.permission_policy)
  end

  # Ownership is already established: this server exists for this conversation.
  # See the `_unsafe_` rules in CLAUDE.md — a GenServer holding the conversation
  # is one of the legitimate callers. The agent as this conversation runs it,
  # its model overridden when the conversation has one (ADR 0061).
  @spec agent_for(Conversation.t()) :: map() | nil
  def agent_for(conv),
    do: conv.agent_id && Conversation.with_model(Agents._unsafe_get_agent(conv.agent_id), conv)

  @doc "`agent_for/1` for a conversation whose agent has to exist: raises when it is gone."
  @spec agent_for!(Conversation.t()) :: map()
  def agent_for!(conv),
    do: Conversation.with_model(Agents._unsafe_get_agent!(conv.agent_id), conv)

  @doc """
  A turn whose adapter failed to spawn ends `failed` with
  the reason, a `turn`/`failed` stage event, and the conversation back to
  "idle". A reassigned or terminal conversation, or an already-ended turn,
  preserves its persisted result and emits no failure stage.

  There is no exit code because no process started. `detail` is the failure
  sentence the server logs before calling this.

  Called only from inside the server's spawn `try` block, which restores the
  caller's previous current-span in its `after`; the span this ends is the
  turn span opened a few lines above the call.
  """
  @spec fail_before_start(
          Conversations.Turn.t(),
          String.t(),
          String.t() | nil,
          String.t(),
          keyword()
        ) :: :ok
  def fail_before_start(turn, conversation_id, sandbox_id, detail, opts \\ []) do
    # The server owns this turn and supplies its captured sandbox binding.
    case Machine.end_turn(turn, {:finish, "failed", [exit_code: nil]}, sandbox_id: sandbox_id) do
      {:ok, _} ->
        publish_stage(conversation_id, "turn", "failed", failed_stage(turn, detail, opts))

      # The conversation was set to "running" just before the spawn attempt;
      # `_unsafe_complete_turn/4` idles it in the same transaction as the
      # turn's result. A refused write leaves both alone: the conversation
      # belongs to whichever actor the parent now points at.
      :noop ->
        :ok
    end

    # The turn never started; close the span we just opened so it doesn't leak.
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "spawn failed: #{detail}"))

    # No-arg: end_span/1 takes a timestamp, not a span. turn_span is the
    # current span here (kick_turn made it current), which is what no-arg ends.
    OpenTelemetry.Tracer.end_span()
    :ok
  end

  # The spawn's own words are the reason, unless the caller knows a better
  # one: `reason: "machine_lost"` for a machine the provider says is gone
  # (`MachineLoss`, #3001), with the spawn's words kept as `detail`, and the
  # fields the withdrawn turn's report carries (`Wake.report_unrun_prompt/3`:
  # `turn_number`, `retryable`, `client_request_id`) beside the turn's id.
  defp failed_stage(turn, detail, opts) do
    case Keyword.get(opts, :reason) do
      nil ->
        %{turn_id: turn.id, reason: detail, exit_code: nil}

      reason ->
        %{
          turn_id: turn.id,
          turn_number: turn.turn_number,
          reason: reason,
          detail: detail,
          retryable: Keyword.get(opts, :retryable, false),
          exit_code: nil,
          client_request_id: turn.client_request_id
        }
    end
  end

  @fresh_sandbox_detail "the previous runtime session lived on a sandbox that no longer exists"

  # A runtime session lives in the sandbox filesystem, so it cannot follow the
  # conversation onto a freshly provisioned one. Until #778 a wake that took
  # the `:create_new` arm kept the old id, the next turn ran in `:continue`
  # mode, and the ACP peer's `session/resume` failed `-32002 Resource not
  # found` against a disk that had never seen the session — on every prompt,
  # until the conversation was terminated. Clearing it here makes the next
  # turn `:run` → `session/new`: the same conversation, transcript and title,
  # a new runtime session on the new disk. The agent's in-context memory is
  # lost either way; the difference is a working turn instead of a failing
  # one, and a stage event that says so.
  #
  # Applied from the server's own callback rather than by the wake caller:
  # the caller's row update races the server's own read of the row in
  # handle_continue.
  @spec reset_runtime_session(Conversation.t(), String.t()) :: :ok
  def reset_runtime_session(conv, conversation_id),
    do: reset_runtime_session(conv, conversation_id, "fresh_sandbox", @fresh_sandbox_detail)

  @doc """
  The same clearing, for a caller that knows a different reason for it. The
  wake path above is one way to learn the session is gone; the runtime saying
  so when asked to resume it (`session_gone?/1`) is the other, and both leave
  the row in the state that makes the next turn `session/new`. The stage
  event carries which one it was, so a conversation that resets can be told
  from one that reset for the other reason without reading the turn that
  failed.
  """
  @spec reset_runtime_session(Conversation.t(), String.t(), String.t(), String.t()) :: :ok
  def reset_runtime_session(conv, conversation_id, reason, detail) do
    {:ok, _} = Conversations.update_conversation(conv, %{runtime_session_id: nil})

    publish_stage(conversation_id, "session", "done", %{
      event: "reset",
      reason: reason,
      detail: detail
    })

    :ok
  end

  @doc "Persist a worker session report only while its exact turn remains current."
  def accept_runtime_session(%{current_turn: %{} = turn} = state, id) do
    case Conversations._unsafe_set_turn_session(turn, id) do
      {:ok, %{applied: true}} -> %{state | runtime_session_id: id}
      _ -> state
    end
  end

  def accept_runtime_session(state, _id), do: state

  @doc "Clear a worker's lost session through the same generation fence as session reports."
  def forget_turn_session(%{current_turn: %{}} = state, reason, detail) do
    {_result, state} = try_forget_turn_session(state, reason, detail)
    state
  end

  def forget_turn_session(%{runtime_session_id: nil} = state, _reason, _detail), do: state

  def forget_turn_session(state, reason, detail) do
    case Conversations._unsafe_clear_idle_session(state.conversation_id, state.runtime_session_id) do
      {:ok, %{applied: true}} ->
        publish_stage(state.conversation_id, "session", "done", %{
          event: "reset",
          reason: reason,
          detail: detail
        })

        %{state | runtime_session_id: nil}

      _ ->
        state
    end
  end

  @doc "Clear a current turn's session, retaining the fence result for recovery."
  def try_forget_turn_session(%{current_turn: %{} = turn} = state, reason, detail) do
    case Conversations._unsafe_set_turn_session(turn, nil) do
      {:ok, %{applied: true}} ->
        publish_stage(state.conversation_id, "session", "done", %{
          turn_id: turn.id,
          event: "reset",
          reason: reason,
          detail: detail
        })

        {:ok, %{state | runtime_session_id: nil}}

      _ ->
        {:error, state}
    end
  end

  @doc """
  The conversation's server state with the runtime session forgotten, and the
  row and the stage event to match. Here rather than in `ConversationServer`
  because #1369 only lets that module shrink, and because the two callers
  are the two ways to learn the same fact: a wake that provisioned a fresh
  sandbox (#778), and a resume the runtime refused because the session is not
  there (`session_gone?/1`).

  Guarded on the id this server holds. Nothing to forget is not an event, and
  publishing a reset for one would tell a client a session was discarded on
  every wake of a conversation that never had one.
  """
  @spec forget_runtime_session(map(), Conversation.t()) :: map()
  def forget_runtime_session(state, conv),
    do: forget_runtime_session(state, conv, "fresh_sandbox", @fresh_sandbox_detail)

  @doc "The same, for a caller that knows a different reason for it."
  @spec forget_runtime_session(map(), Conversation.t(), String.t(), String.t()) :: map()
  def forget_runtime_session(%{runtime_session_id: nil} = state, _conv, _reason, _detail),
    do: state

  def forget_runtime_session(state, conv, reason, detail) do
    reset_runtime_session(conv, state.conversation_id, reason, detail)
    %{state | runtime_session_id: nil}
  end

  # The runtime's way of saying the session it was handed does not exist.
  # There is no field for it: codex answers `session/resume` with a generic
  # -32603 and puts the fact in `data.details` ("no rollout found for thread
  # id …"), and the -32002 in the second clause is the JSON-RPC "Resource not
  # found" the #778 comment recorded from a disk that had never seen the
  # session. Both are read off the whole error, so a runtime that nests its
  # message somewhere new is still matched.
  @session_gone_phrases [
    "no rollout found",
    "no conversation found",
    "no session found",
    "session not found",
    "resource not found",
    "no such session",
    "unknown session"
  ]

  defp session_gone?(%{"code" => -32_002}), do: true

  defp session_gone?(error) do
    text = error |> inspect() |> String.downcase()
    Enum.any?(@session_gone_phrases, &String.contains?(text, &1))
  end

  # The runtime's own sentence, which is the half that names the session and
  # the half a reader can match against their own logs. `data.details` first
  # because a runtime that fills it has put the specific thing there and left
  # `message` generic — "Internal error" is not worth reporting.
  defp acp_detail(%{"data" => %{"details" => details}}) when is_binary(details), do: details
  defp acp_detail(%{"message" => message}) when is_binary(message), do: message
  defp acp_detail(other), do: inspect(other)

  @doc """
  What a tenant is told when the runtime session underneath a conversation is
  gone. Said rather than inspected, and said in full: the next prompt works,
  which is the one thing the failure itself gives no way to guess, and the
  agent's memory of the conversation does not, which is the one thing they
  would otherwise discover by watching it answer as though the turns before
  it had not happened.
  """
  @spec session_gone_message(String.t()) :: String.t()
  def session_gone_message(detail) do
    "The runtime session for this conversation is no longer on its sandbox: #{String.trim(detail)} " <>
      "Send your prompt again — the next turn starts a fresh session on this same conversation. " <>
      "Its history is kept, but the agent will not remember the turns before this one."
  end

  @doc """
  What a tenant is told when the session went and the turn was restarted on
  a fresh one (#1667).

  The prompt needs no mention: it is running. What is left is the one thing
  they would otherwise discover by watching the agent answer as though the
  turns before it had not happened.
  """
  @spec session_restarted_message(String.t()) :: String.t()
  def session_restarted_message(detail) do
    "The agent's memory was lost. Your prompt is running on a fresh session on this same " <>
      "conversation. Its history is kept, but the agent does not remember the turns " <>
      "before this one. The runtime reported: #{String.trim(detail)}"
  end

  # The provider's own sentence is the useful half, and it usually names the
  # replacement, so it is quoted rather than summarised. Fountain adds only
  # what the provider cannot know: which field holds the model, and that no
  # retry helps until that field changes.
  @spec model_unavailable_message(String.t() | nil, String.t()) :: String.t()
  def model_unavailable_message(requested, detail) do
    named = if is_binary(requested) and requested != "", do: " (#{requested})", else: ""

    "The provider refused this agent's model#{named}: #{String.trim(detail)} " <>
      "Change the agent's model, then send your prompt again. " <>
      "Every turn fails the same way until it changes."
  end

  defp publish_stage(conv_id, stage, status, meta) do
    Conversations.publish_stage(conv_id, stage, status, meta)
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  @doc """
  Close a turn that a normally-stopping server leaves behind.

  A normal stop is not restarted and its quiet timer dies with it, so a turn
  still marked `running` would never be closed by anything else. Supervisor
  shutdowns and crashes are left alone, because those servers come back and
  reattach. Best-effort by design: the caller runs this on the way out of
  `terminate/2`, and a raise here must not take the rest of that callback
  with it.

  The stopping server is an actor, so it passes the sandbox it was bound to
  as `opts[:sandbox_id]`: a parent rebound underneath it belongs to a
  successor and this recovery writes nothing. `opts` is required rather than
  defaulted, because a caller that forgets it silently recovers a turn it no
  longer owns.
  """
  @spec orphan_on_normal_stop(term(), Conversations.Turn.t() | nil, String.t() | nil, keyword()) ::
          :ok
  def orphan_on_normal_stop(:normal, turn, conversation_id, opts) when not is_nil(turn) do
    _ = Machine.end_turn(turn, {:orphan, "server_terminated_normally"}, opts)
    :ok
  rescue
    error ->
      Logger.error(
        "terminate/2: orphaning turn for conv #{inspect(conversation_id)} raised: " <>
          Exception.format(:error, error, __STACKTRACE__)
      )

      :ok
  end

  def orphan_on_normal_stop(_reason, _turn, _conversation_id, _opts), do: :ok
end
