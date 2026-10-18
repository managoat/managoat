defmodule Fountain.Conversations.Wake do
  @moduledoc """
  Waking a conversation: deciding what a stored sandbox can still do, and
  bringing a `ConversationServer` up on it, including the fresh-sandbox path
  when the stored machine is dead (#2211).

  `wake_conversation/2` (delegated from `Fountain.Conversations`) is the
  request-facing door for a fresh prompt; `Conversations.wake_for_interrupt/1`
  is the door for an interrupt. Both establish tenant ownership of `conv_id`
  before calling `wake_conversation_for/3` here, and every `sandbox_id` this
  module reads comes from that already-scoped conversation row, so leaves are
  documented as relying on that ownership rather than re-justifying it on
  their own.

  The two purposes diverge on a dead or stranded sandbox — a probe that
  answers `:create_new`, or a `pending`/`starting` row whose server never
  turns up before the registry-settle wait gives up: `:work` still
  provisions a fresh one either way, but `:interrupt` never does (decided
  2026-09-15, #2175 open decision 1) — there is no turn a new sprite could
  continue, so it reconciles the orphaned row instead of paying for compute
  nothing will use (`reconcile_dead_interrupt/1`, fenced to the sandbox this
  wake actually probed).
  """

  require Logger

  alias Fountain.Agents
  alias Fountain.Conversations

  alias Fountain.Conversations.{
    Conversation,
    ConversationServer,
    Launch,
    PromptDelivery,
    Reattachment,
    Sandbox,
    Termination
  }

  alias Fountain.Machines.Machine

  # Where a sandbox stops. A terminal row is never a machine an owner is still
  # working on, whatever its lease or transition says.
  @terminal_statuses ~w(terminated failed)

  # Probe the existing sandbox: if it's `ready` or `suspended` and sprites.dev
  # confirms the sprite still exists, we can reattach without provisioning a
  # new one. Otherwise, fall through to creating a fresh sandbox.
  #
  # The leaf `wake_conversation_for/3` calls first, once ownership is
  # established there; `sandbox_id` is the conversation's own row.
  def maybe_reuse_sandbox(%Conversation{sandbox_id: nil}), do: :create_new

  def maybe_reuse_sandbox(%Conversation{sandbox_id: sandbox_id}) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      # A reset or a teardown has been asked for: the `destroying` stamp, where
      # the intent lives (ADR 0058 stage 9a; stage 9b stopped reading the
      # `reset_requested_at` column that stood beside it). `destroying` is
      # the one durable transition: it is refused here whatever the lease says,
      # because an owner that died between its fence and its finalize has not
      # withdrawn the request — the machine is still on its way out and the
      # sweep that drives it to terminal is what ends the refusal, not the next
      # wake. Every other stamp on a lease-less row reads as abandoned three
      # clauses down, which is the distinction this pair is here to make.
      %Sandbox{transition: "destroying", status: status}
      when status not in @terminal_statuses ->
        {:error, :sandbox_reset_pending}

      # An owner holds a live lease on this machine (ADR 0058 stage 6a).
      # Refused *before* the probe, so a machine somebody is destroying — or,
      # from 6b, parking — gets no provider call from this wake, and refused
      # with the word the whole system already has for "not right now": 503
      # with a `Retry-After: 30`, which is honest because the operation is
      # live and one provider round trip from settling.
      #
      # A stamped `transition` on a lease-less row is *not* refused here, and
      # that is the round-1 correction: such a row is an owner that died
      # mid-operation, and refusing it kept a caller from the fresh machine
      # `main` would have given it for as long as an hour. `Machine.busy?/1`
      # says why. Since stage 9a that holds for every transition **but
      # `destroying`**, which the clause above refuses on its own; a destroy
      # whose owner died is an unfinished destroy, not an abandoned one.
      #
      # After the two fence clauses, deliberately. A reset that the owner
      # refused leaves `transition: "destroying"` on a live row with its lease
      # released (stage 5c), and `:sandbox_reset_pending` is the precise
      # answer there: the fence is in place, the reconciler will finish it,
      # and a retry of the reset is 409 rather than "try again in 30s".
      # The more specific word wins by being asked first.
      #
      # Before the status clauses, and only for a non-terminal row. A finalize
      # writes `terminated` and releases the lease as two statements, so a
      # terminal row with a live lease is a real momentary state and it means
      # the machine is gone — which is `:create_new` below, not a retry.
      # A provision in flight, **before** the mid-operation check and not
      # refused by it (ADR 0058 stage 7b). A `pending` or `starting` row now
      # carries a live lease for the length of the provision — that is what the
      # bracket is — and refusing it here would answer 503 to the ordinary
      # `session/new` followed by a prompt 30ms later, which is the exact shape
      # #800 closed by waiting for the registry instead. The answer a machine
      # being *built* owes a second caller is "wait for the server", not "try
      # again in thirty seconds"; the answer a machine being destroyed or
      # parked owes one is the other way round, and those rows are below.
      %Sandbox{status: status} when status in ["pending", "starting"] ->
        {:provisioning, sandbox_id}

      %Sandbox{status: status} = sandbox when status not in @terminal_statuses ->
        if Machine.busy?(sandbox),
          do: {:error, :sandbox_unavailable},
          else: classify_reusable(sandbox, sandbox_id)

      _ ->
        :create_new
    end
  end

  # The reuse verdict for a machine no owner is working on. Split out of
  # `maybe_reuse_sandbox/1` when the mid-operation check went in front of it,
  # so there is one place that check cannot be skipped.
  #
  # It had a `pending`/`starting` clause until stage 7b, which answered
  # `{:provisioning, sandbox_id}`. That answer moved *above* the busy check in
  # `maybe_reuse_sandbox/1` — a provision holds a lease for its whole length now,
  # and a row being built owes a second caller "wait for the server" rather than
  # "try again in thirty seconds" — so nothing reached the clause any more.
  defp classify_reusable(%{status: status, machine_name: name} = sandbox, sandbox_id)
       when status in ["ready", "suspended"] and is_binary(name),
       do: probe_reusable_sandbox(sandbox, sandbox_id)

  defp classify_reusable(_sandbox, _sandbox_id), do: :create_new

  # The row's provider is sticky: a parked sandbox wakes on the backend that
  # holds its disk, never on whatever the instance default is by now. A row
  # whose (non-default) provider lost its credentials fails retryably — the
  # same protect-the-parked-disk reasoning as :sprite_probe_failed below;
  # falling through to :create_new would retire the row and orphan (or lose)
  # the parked sandbox. Re-adding the credentials restores wakes.
  #
  # A leaf of maybe_reuse_sandbox/1.
  def probe_reusable_sandbox(%{status: status, machine_name: name} = sandbox, sandbox_id) do
    provider = Conversations.sandbox_provider_atom(sandbox)

    if provider != Fountain.SandboxProviders.default_provider() and
         not Fountain.SandboxProviders.enabled?(provider) do
      Logger.warning(
        "sandbox #{sandbox_id} is on disabled provider #{provider}; refusing to wake or retire"
      )

      {:error, {:sandbox_provider_disabled, provider}}
    else
      probe_sandbox(provider, name, status, sandbox_id)
    end
  end

  # A leaf of probe_reusable_sandbox/2.
  #
  # **The probe reports what the machine says about itself, not only that it
  # answered** (ADR 0058 stage 7a). Until 7a any `{:ok, _info}` was a reuse,
  # whatever `info.status` said, and the 6b review named what that cost: a park
  # whose finalize was lost leaves a row saying `ready` over a machine the
  # provider has genuinely stopped, and on E2B (`paused`) the wake then handed
  # a conversation a handle to a machine that was not running. The third element of the verdict is
  # `Managoat.Sandbox`'s own three-value fold — `:running | :suspended |
  # :unknown` — and `Machines.Resume` is what acts on it.
  #
  # Per adapter, so nobody has to go and find out:
  #
  #   * **E2B** reports it faithfully. Its lookup asks for `running,paused`
  #     explicitly and folds `paused` to `:suspended`. This is the provider the
  #     gap was real on.
  #   * **Sprites** cannot, and does not need to. Its `suspend/1` is a
  #     documented no-op — the sprite scales to zero on the platform's schedule —
  #     so `get/1` reports that schedule rather than anything Fountain did, and
  #     its `resume/1` is a probe: a sprite reported `stopped` here is resumed by
  #     the next exec whatever this says. The residual on Sprites is therefore
  #     not a missed wake but a `sandbox.resumed` event and a
  #     `last_resumed_at` stamp on a machine that had scaled to zero by itself,
  #     which is a fair description of what happened.
  #   * `:unknown` — a body without a status this adapter recognises — is
  #     treated as running, i.e. as `main` treated every answer. Resuming on a
  #     guess is the write that claims more, and this is the guess.
  def probe_sandbox(provider, name, status, sandbox_id) do
    case Managoat.Sandbox.get(Managoat.Sandbox.build_handle(provider, name)) do
      {:ok, info} ->
        {:reuse, sandbox_id, Map.get(info, :status, :unknown)}

      {:error, :not_found} ->
        :create_new

      {:error, reason} ->
        # A transient probe failure must not cost the disk: falling to
        # :create_new retires this row, and the reaper then destroys the
        # still-live sprite — with the agent's memory on it. Only a
        # definitive not-found gives up the sandbox; anything else fails the
        # wake retryably (503 + Retry-After at the API).
        #
        # This clause was `suspended`-only until #799: a `ready` row is the
        # same parked disk once its server is gone (a deploy, a crash, a
        # partition), and the 2026-08-18 incident showed the provider going
        # unreachable for 70 s with nine `ready` rows behind it.
        Logger.warning(
          "sprite probe failed for #{status} sandbox #{sandbox_id}: #{inspect(reason)}"
        )

        {:error, :sprite_probe_failed}
    end
  end

  @doc """
  Make sure the conversation's machine is up, through its owner (ADR 0058
  stage 7a).

  One call to `Fountain.Machines.Machine.ensure_up/2`, which does everything
  this function used to do itself and one thing it could not. What it used to
  do: re-read the row, ask the provider to resume a `suspended` one, write
  `ready` and stamp `last_resumed_at`, and re-run the quota gate — because a
  parked sprite is not compute (ADR 0017) and waking one is. What it could not:
  make two prompts arriving on one parked home resume it **once**. Both read
  `suspended`, both called the provider, both wrote `ready`; the only thing
  between them was the per-*user* advisory lock the quota reservation happens to
  hold, which serialized two wakes of two different machines that had no need to
  be serialized and ran a provider round trip inside a database transaction
  doing it.

  The owner's lease is per machine, so the second wake waits for the first and
  then finds the machine already up; and the quota checks now commit before the
  provider is called rather than around it. `Fountain.Machines.Resume` is where
  that ordering is argued.

  Asked unconditionally, on every reuse: `ensure_up/2` answers
  `{:ok, :already_up}` for a `ready` row without calling anybody, which is what
  the status check here used to buy and what makes the name honest.

  The second leaf `wake_conversation_for/3` calls, once ownership is
  established there; `conv` is the caller's own tenant-scoped row and
  `sandbox_id` is that conversation's own machine.
  """
  def wake_suspended_sandbox(%Conversation{} = conv, sandbox_id, observed \\ :unknown)
      when is_binary(sandbox_id) do
    Machine.ensure_up(sandbox_id,
      # ADR 0013: the work is done by this module on an unattended path — the
      # prompt that triggered it is the conversation's, not an operator's, and
      # the conversation is recorded in the event's metadata instead.
      actor: "system:wake",
      requesting_conversation_id: conv.id,
      observed: observed
    )
  end

  # The child spec deliberately carries no prompt.
  #
  # A supervisor restarts a crashed child from its *stored child spec*, and
  # under Horde (before ADR 0072) every deploy did. A prompt baked into that
  # spec is therefore replayed, silently re-running the user's last message
  # against the agent. Production accumulated 38 turns from 2 distinct prompts
  # on one conversation this way, one duplicate per rollout, and the agent on the other end spent several
  # turns pointing out it was being asked the same thing repeatedly.
  #
  # So the prompt is delivered out of band, after the server exists. A cast is
  # queued behind handle_continue(:provision), so it is processed once
  # provisioning finishes; if provisioning fails the server stops and the cast
  # dies with it, which is the right outcome — no turn on a failed provision.
  #
  # The third leaf `wake_conversation_for/4` calls on the reuse path; also
  # called from `create_fresh_sandbox_and_start/5` below on the fresh-sandbox
  # path. `conv` is the caller's own tenant-scoped row, so the re-fetch below
  # reads under that same ownership.
  #
  # `images` travels with the prompt and has no default, because a default is
  # how they were lost: this and the three other handoff sites below each took
  # `queue_initial_prompt/2`'s `[]`, so a prompt sent to a conversation with no
  # live server — parked, or in the gap after a deploy — opened its turn with
  # the text and none of its images. The request answered
  # `200 {"status":"queued"}` and `conversation.prompted` recorded the real
  # `image_count`, so the trail said images were sent and the turn said none
  # arrived, with nothing reporting the loss (#2373).
  def start_conversation_server(conv, sandbox_id, runtime_module, initial_prompt, images) do
    # Through the one registration door (ADR 0058 stage 6a): it starts the
    # server under the machine's lock, so a reaper or a park that takes the
    # lock after it finds the server. It hands the supervisor's answer back
    # verbatim, so the `{:already_started, winner_pid}` both call sites of this
    # function compensate for still arrives unchanged.
    with {:ok, pid} <-
           Conversations.register_server(
             sandbox_id,
             Launch.child_spec(conv.id, sandbox_id, runtime_module)
           ) do
      PromptDelivery.hand_over(pid, initial_prompt, images)

      # ownership: conv is the caller's own tenant-scoped row (see the
      # function doc above); this re-fetch reads under that same ownership.
      {:ok, Conversations._unsafe_get_conversation!(conv.id)}
    end
  end

  @doc """
  Resume a conversation whose ConversationServer is gone (e.g. after a
  BEAM restart, or in the gap between Rehydrator runs).

  Strategy:
  1. If the existing sandbox is `ready` and the sprite is still alive at
     sprites.dev, start a fresh `ConversationServer` pointing at it. The
     server will go through reattach mode and pick up any running
     detachable session.
  2. Otherwise, provision a fresh sprite, mark the old sandbox
     terminated, and start the server pointing at the new sandbox. The
     runtime session does not follow — it lived on the old disk — so the
     server clears `runtime_session_id` once the fresh sprite is up and the
     next turn starts a new one (#778). The Fountain conversation, its
     transcript and its title carry over; the agent's in-context memory
     does not.

  Returns `{:error, :gone}` if the conversation is in a terminal status
  (`terminated`, `failed`) — those don't auto-resume.
  """
  def wake_conversation(conv_id, initial_prompt \\ nil, images \\ []) do
    wake_conversation_for(conv_id, initial_prompt, :work, images)
  end

  @doc """
  Bring a conversation's sandbox and server up without opening a turn, so the
  next prompt does not pay for the wake.

  `{:ok, :awake}` is a conversation whose server is already running: a parked
  conversation has none, so there is nothing to do. `{:ok, :waking}` is one this
  call is waking: on its own sandbox resumed from suspension, or on a fresh one
  when that sandbox is gone, exactly as a prompt would.

  The wake runs behind the answer (#2584), as a prompt's does since #2561. The
  refusals that need no provider (`admit_prompt_wake/1`: the conversation, its
  agent, the account, a reset fence, room for a machine) still answer
  the call; anything after that is a `wake` `failed` stage on the
  conversation's event stream, with the reattach or provision stages before it.

  The same gates as a prompt's wake apply, since a woken machine is billed
  compute whether or not a prompt follows. Only a wake that started a server is
  audited, as `conversation.woken`, when it finishes.

  A door like `wake_conversation/3`: the caller has established tenant
  ownership of `conv_id`.
  """
  @spec wake_without_prompt(binary(), keyword()) :: {:ok, :awake | :waking} | {:error, term()}
  def wake_without_prompt(conv_id, opts \\ []) when is_binary(conv_id) do
    case ConversationServer.whereis(conv_id) do
      pid when is_pid(pid) ->
        {:ok, :awake}

      nil ->
        with :ok <- admit_prompt_wake(conv_id) do
          {:ok, _pid} =
            Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
              result = __MODULE__.wake_conversation_for(conv_id, nil, :work)
              Termination.audit_lifecycle(conv_id, "conversation.woken", ok(result), opts)

              with {:error, reason} <- result, do: report_failed_wake(conv_id, reason, [])
            end)

          {:ok, :waking}
        end
    end
  end

  defp ok({:ok, _}), do: :ok
  defp ok(other), do: other

  # Not a request-facing entry point. `wake_conversation/3` above is the door
  # for a fresh prompt, and `Conversations.wake_for_interrupt/1` (still in
  # `Conversations` until stage 4, #2213) is the door for an interrupt; both
  # establish tenant ownership of `conv_id` before calling here. The
  # `_unsafe_get_conversation` read just below relies on that caller-scoped
  # fetch, not on any check of its own — add no further public entry.
  #
  # `images` defaults for the interrupt door, which carries no prompt for them
  # to belong to; the prompt door always passes what the request decoded.
  def wake_conversation_for(conv_id, initial_prompt, purpose, images \\ []) do
    with {:ok, conv, agent, runtime_module} <- preflight(conv_id) do
      case conv |> reuse_verdict(purpose) |> own_server(conv) do
        {:handed_over, pid} ->
          # A concurrent wake of this conversation got there first and its
          # server holds the machine (a rebuild holds the workspace's lease
          # for minutes, ADR 0097). The prompt is the winner's, as in the
          # start races below.
          PromptDelivery.hand_over(pid, initial_prompt, images)
          # ownership: conv established tenant-scoped above.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        {:reuse, sandbox_id, observed} ->
          # Reuse provisions nothing, so the fresh-path gates below never ran
          # here (#313). Same checks. Reusing a
          # `ready` machine adds no concurrency, so no quota; bringing a parked
          # one back re-adds compute, so `wake_suspended_sandbox/3` runs the
          # quota gate inside the owner's admission. The per-turn gate in
          # ConversationServer is the backstop; this one makes the refusal
          # synchronous at the API door.
          #
          # `observed` is what the probe just heard from the provider, carried
          # in so the owner can wake a machine the row calls `ready` and the
          # provider calls stopped — see `probe_sandbox/4`.
          with :ok <- check_saved_inference(conv, agent),
               {:ok, _} <- wake_suspended_sandbox(conv, sandbox_id, observed) do
            case start_conversation_server(
                   conv,
                   sandbox_id,
                   runtime_module,
                   initial_prompt,
                   images
                 ) do
              {:error, {:already_started, winner_pid}} ->
                # Lost a concurrent wake of the same conversation to another
                # caller reusing the same sandbox. Mirrors the handoff in
                # create_fresh_sandbox_and_start/5 (#330), but reuse provisions
                # no row of its own, so there is nothing here to clean up —
                # just hand the prompt to the winner, which drops it if a turn
                # is already running.
                PromptDelivery.hand_over(winner_pid, initial_prompt, images)

                # ownership: conv established tenant-scoped above; this
                # re-fetch reads under that same ownership.
                {:ok, Conversations._unsafe_get_conversation!(conv.id)}

              other ->
                other
            end
          end

        {:provisioning, sandbox_id} ->
          # The row says a server is (or was) provisioning this sandbox. The
          # launch that wrote it may not have started its server yet —
          # `session/new` and the first prompt arrive ~30 ms apart — so wait
          # for it before concluding it is dead. If it turns up, hand it the prompt exactly
          # as the `already_started` branches do; if it does not, the
          # provision died with its BEAM and a fresh one is right (#800).
          case ConversationServer.await_registered(conv.id) do
            {:ok, pid} ->
              Logger.info(
                "conv #{conv.id}: server for pending sandbox #{sandbox_id} " <>
                  "appeared during the registry settle window; handing off the prompt"
              )

              PromptDelivery.hand_over(pid, initial_prompt, images)

              # ownership: conv established tenant-scoped above; this
              # re-fetch reads under that same ownership.
              {:ok, Conversations._unsafe_get_conversation!(conv.id)}

            :timeout ->
              # The provision died with its BEAM and nothing ever came up on
              # this sandbox either. An interrupt has nothing to provision
              # for here any more than it does on a flat :create_new
              # (immediately below) — same no-provision rule, same reconcile
              # helper, same fence.
              #
              # **Unless an owner is holding the machine right now** (ADR 0058
              # stage 7b). This is the one place the registry's silence used to
              # be taken as proof of absence, and since a provision holds a
              # lease for its whole length there is now a durable answer to ask
              # instead: a live lease means a server *is* building this machine,
              # and replacing it would create a
              # second billable machine over a live one. 6a's rule, at the point
              # that decides rather than at the door — the door still waits for
              # the registry, which is what #800 fixed.
              cond do
                # A co-tenant's prompt is building the shared machine (a
                # rebuild, ADR 0097): this prompt waits for it, then reaches it
                # as any wake would. "Two prompts into a workspace with no
                # sandbox rebuild it once; the second waits."
                purpose == :work and provisioning_owner_live?(sandbox_id) and shared?(conv) ->
                  case Fountain.Conversations.Rebuild.await_settled(sandbox_id) do
                    :settled ->
                      wake_conversation_for(conv.id, initial_prompt, purpose, images)

                    :timeout ->
                      {:error, :sandbox_unavailable}
                  end

                provisioning_owner_live?(sandbox_id) ->
                  Logger.info(
                    "conv #{conv.id}: sandbox #{sandbox_id} is being provisioned by an owner " <>
                      "the registry has not published; refusing rather than replacing it"
                  )

                  {:error, :sandbox_unavailable}

                purpose == :interrupt ->
                  reconcile_dead_interrupt(conv)

                true ->
                  create_fresh_sandbox_and_start(
                    conv,
                    agent,
                    runtime_module,
                    initial_prompt,
                    images
                  )
              end
          end

        # An interrupt with no live server and no sandbox worth reusing has
        # nothing to provision for: there is no turn a fresh sprite could
        # continue, only a row to reconcile (Jake, 2026-09-15, #2175 open
        # decision 1). Provisioning here used to run anyway, and the
        # `:interrupt` call to the new server then queued behind
        # `handle_continue(:provision)` and timed out to `{:error,
        # :provisioning}` — a paying wake for an interrupt that could not
        # reach anything. `purpose: :work` is untouched: a prompt on a dead
        # or stranded sandbox still provisions fresh, here and in the
        # `:timeout` arm above.
        :create_new when purpose == :interrupt ->
          reconcile_dead_interrupt(conv)

        :create_new ->
          create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, images)

        {:error, _} = err ->
          err
      end
    end
  end

  # How long a wake into an explicit workspace waits for another
  # conversation's operation on the shared machine (a resume, a park) before
  # it answers 503: the resume budget, which is what such a wait usually is.
  @co_tenant_wait_ms 60_000
  @co_tenant_poll_ms 500

  # `maybe_reuse_sandbox/1`, waiting out a live lease on an explicit
  # workspace's machine (ADR 0097): there, the lease is usually a co-tenant's
  # wake resuming the machine this prompt wants, so the second of two wakes
  # waits and then finds it up, as two wakes of one machine always have
  # (review of step 4a). An implicit workspace's machine is one
  # conversation's, and a lease on it answers 503 at once, as before.
  # An interrupt is a synchronous request with nothing to wait for.
  defp reuse_verdict(conv, :interrupt), do: maybe_reuse_sandbox(conv)

  defp reuse_verdict(conv, _purpose),
    do: wait_reuse(conv, System.monotonic_time(:millisecond) + @co_tenant_wait_ms)

  defp wait_reuse(conv, deadline) do
    case maybe_reuse_sandbox(conv) do
      {:error, :sandbox_unavailable} = busy ->
        if shared?(conv) and System.monotonic_time(:millisecond) < deadline do
          Process.sleep(@co_tenant_poll_ms)
          wait_reuse(conv, deadline)
        else
          busy
        end

      verdict ->
        verdict
    end
  end

  # ownership: the conversation's own machine.
  defp shared?(%Conversation{sandbox_id: sandbox_id}) do
    case sandbox_id && Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{} = sandbox -> Fountain.Workspaces.machine_kind(sandbox) == :explicit
      nil -> false
    end
  end

  # A machine refused as busy whose owner is this conversation's own server:
  # another wake of this conversation started it, and it is the one to hand
  # the prompt to rather than a 503.
  defp own_server({:error, :sandbox_unavailable} = refused, conv) do
    case ConversationServer.whereis(conv.id) do
      pid when is_pid(pid) -> {:handed_over, pid}
      nil -> refused
    end
  end

  defp own_server(verdict, _conv), do: verdict

  # What every wake checks before it touches a provider: the row, its status,
  # the saved allowance, the agent and the runtime. Database reads only.
  #
  # Ownership is established by callers before reaching this internal wake
  # path. The agent fetched below is the conversation's own agent_id, same
  # tenant by construction.
  defp preflight(conv_id) do
    with :ok <- Conversations.require_provider_commit_boundary(),
         %Conversation{} = conv <-
           Conversations._unsafe_get_conversation(conv_id) || {:error, :not_found},
         :ok <- assert_resumable(conv),
         # Ownership: conv.agent_id belongs to this established-owner conversation.
         %Agents.Agent{} = agent <-
           (conv.agent_id &&
              Conversation.with_model(Agents._unsafe_get_agent(conv.agent_id), conv)) ||
             {:error, :no_agent},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(conv) do
      {:ok, conv, agent, runtime_module}
    else
      nil -> {:error, :not_found}
      {:error, _} = err -> err
    end
  end

  @doc """
  `ConversationServer.send_prompt/4`'s road for a conversation with no server.

  `wake: :background` in `opts` (#2561) is the API's: answer once
  `admit_prompt_wake/1` has run, and wake behind the response, with a failure
  reported on the event stream. Every other caller waits for the wake, because
  it acts on the refusal: a schedule run retries a full fleet, a launch
  reports it.
  """
  @spec for_prompt(binary(), PromptDelivery.wake_prompt(), list(), keyword()) ::
          :ok | {:error, term()}
  def for_prompt(conv_id, wake_prompt, images, opts) do
    result =
      if Keyword.get(opts, :wake) == :background do
        with :ok <- admit_prompt_wake(conv_id),
             do: wake_in_background(conv_id, wake_prompt, images)
      else
        # Remote, so it stays the seam callers' tests stub.
        with {:ok, _conv} <- __MODULE__.wake_conversation(conv_id, wake_prompt, images),
             do: :ok
      end

    case result do
      {:error, :not_found} -> {:error, :not_running}
      other -> other
    end
  end

  @doc """
  The refusals a prompt's wake still owes its caller in the response, run
  without a provider round trip (#2561): the conversation's status, its saved
  allowance, the agent, the saved inference source, a machine being reset, and, when the wake would add a
  machine, room under the fleet ceiling.

  The capacity check is advisory: nothing is reserved here, and the wake
  itself reserves under the locks as before. A slot taken in between is the
  wake's refusal, reported on the event stream like any other.

  A door like `wake_conversation/3`: the caller has established tenant
  ownership of `conv_id`.
  """
  @spec admit_prompt_wake(binary()) :: :ok | {:error, term()}
  def admit_prompt_wake(conv_id) when is_binary(conv_id) do
    with {:ok, conv, agent, _runtime_module} <- preflight(conv_id),
         :ok <- check_saved_inference(conv, agent) do
      check_machine(conv, agent)
    end
  end

  # A machine on its way out is refused as `maybe_reuse_sandbox/1` refuses it.
  # A `ready` machine with no server adds no compute when it is reused; every
  # other wake adds a machine to the count, from parked or from nothing, and
  # it is counted against the ceiling of the provider it will run on (#2667):
  # a parked machine's own, or for a fresh one the agent's, as
  # `create_fresh_sandbox_and_start/5` resolves it.
  defp check_machine(%Conversation{sandbox_id: sandbox_id} = conv, agent) do
    # ownership: the conversation's own machine.
    case sandbox_id && Conversations._unsafe_get_sandbox(sandbox_id) do
      %Sandbox{transition: "destroying", status: status} when status not in @terminal_statuses ->
        {:error, :sandbox_reset_pending}

      %Sandbox{status: "ready"} ->
        :ok

      %Sandbox{status: status, provider: provider} when status not in @terminal_statuses ->
        Fountain.Quotas.check_fleet_ceiling(provider: provider, exclude: sandbox_id)

      _ ->
        case sandbox_id && Fountain.Conversations.Rebuild.wake_target(conv, agent) do
          {:rebuild, sandbox} ->
            Fountain.Quotas.check_fleet_ceiling(provider: sandbox.provider, exclude: sandbox.id)

          _fresh ->
            check_fresh_machine(sandbox_id, agent)
        end
    end
  end

  # A provider the agent can no longer use is the wake's own refusal to make;
  # this advisory check does not answer it early.
  defp check_fresh_machine(sandbox_id, agent) do
    case Conversations.resolve_sandbox_provider(agent) do
      {:ok, provider} ->
        opts = if sandbox_id, do: [exclude: sandbox_id], else: []
        Fountain.Quotas.check_fleet_ceiling([provider: provider] ++ opts)

      {:error, _reason} ->
        :ok
    end
  end

  @doc """
  Wake a conversation for a prompt behind the request that carried it
  (#2561). The caller has run `admit_prompt_wake/1` and answered; this runs
  the wake in a task under `Fountain.TaskSupervisor`, and a wake that fails
  publishes a `wake` `failed` stage with its reason, which is how the caller
  learns the prompt did not run.

  The wake is the same `wake_conversation/3` a synchronous caller gets, so
  concurrent wakes of one conversation still resolve to one server, and a
  prompt that loses the race is handed to the winner.

  A door like `wake_conversation/3`: the caller has established tenant
  ownership of `conv_id`.
  """
  @spec wake_in_background(binary(), PromptDelivery.wake_prompt(), list()) :: :ok
  def wake_in_background(conv_id, initial_prompt, images) when is_binary(conv_id) do
    {prompt, meta} =
      case initial_prompt do
        {text, meta} -> {text, meta}
        text -> {text, []}
      end

    meta = Fountain.Conversations.PromptReceipt.accept(conv_id, meta)
    initial_prompt = {prompt, meta}

    {:ok, _pid} =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        case __MODULE__.wake_conversation(conv_id, initial_prompt, images) do
          {:ok, _conv} -> :ok
          {:error, reason} -> report_failed_wake(conv_id, reason, meta)
        end
      end)

    :ok
  end

  defp report_failed_wake(conv_id, reason, meta) do
    Logger.warning("conv #{conv_id}: background wake failed: #{inspect(reason)}")
    report_unrun_prompt(conv_id, reason, meta)
  end

  @doc """
  Tell the conversation's stream that a prompt its caller was answered
  `queued` for did not run: its wake failed, or the server it was queued
  behind dropped it (a turn was already running) or refused it at admission
  (#2577). The `wake` `failed` stage, with the reason and whether sending the
  prompt again can succeed.
  """
  @spec report_unrun_prompt(binary(), term()) :: term()
  @spec report_unrun_prompt(binary(), term(), keyword()) :: term()
  def report_unrun_prompt(conv_id, reason, meta \\ []) do
    Conversations.publish_stage(conv_id, "wake", "failed", %{
      reason: failed_wake_reason(reason),
      retryable: retryable_wake_failure?(reason),
      client_request_id: meta[:client_request_id],
      prompt_receipt_id: meta[:prompt_receipt_id]
    })

    Fountain.Conversations.PromptReceipt.resolve(conv_id, meta[:prompt_receipt_id])
  end

  defp failed_wake_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp failed_wake_reason({reason, _detail}) when is_atom(reason), do: Atom.to_string(reason)
  defp failed_wake_reason(reason), do: inspect(reason)

  # The ones a retry of the same prompt can succeed on without the caller
  # changing anything: the provider or the fleet was busy.
  @retryable_wake_failures ~w(sandbox_unavailable sprite_probe_failed fleet_full resume_failed machine_busy conversation_busy)a

  defp retryable_wake_failure?(reason) when is_atom(reason),
    do: reason in @retryable_wake_failures

  defp retryable_wake_failure?({reason, _detail}) when is_atom(reason),
    do: reason in @retryable_wake_failures

  defp retryable_wake_failure?(_reason), do: false

  defp check_saved_inference(conv, agent) do
    with {:ok, _source} <- Conversations.resolve_saved_inference(conv, agent), do: :ok
  end

  # No server, no reusable sandbox, and this wake is only for an interrupt:
  # reconcile whatever the dead incarnation left running instead of paying to
  # provision a machine nobody asked to keep working. `find_running_turn/1`
  # and `_unsafe_orphan_turn/2` are the same door the reattach path uses for
  # the same shape of loss (a turn the row still calls `running` with no
  # process left to finish it) — this is that path's decision, reached from a
  # different trigger, not a new writer of the turn or conversation row.
  #
  # The probe that produced :create_new (or the registry timeout on a
  # provisioning row) ran outside any lock, against conv.sandbox_id as read
  # before this wake started. A concurrent :work wake can rebind the
  # conversation to a replacement sandbox and admit a successor turn while
  # that probe is still in flight, so `find_running_turn/1` — reading with no
  # lock of its own — can hand back the successor's turn instead of the dead
  # incarnation's. `sandbox_id: conv.sandbox_id` fences the write to the
  # sandbox this wake actually probed: the owner's door (`Machine.end_turn/3`,
  # ADR 0058 stage 8a) re-locks the parent and rejects a changed binding as
  # `{:error, :ownership_changed}`, writing nothing. Either way this answers
  # :not_running — the interrupt was for the dead incarnation, and a successor
  # found live is somebody else's turn to finish, not this wake's to touch.
  #
  # ownership: conv is the caller's own tenant-scoped row, established by
  # wake_conversation_for/3 above.
  defp reconcile_dead_interrupt(conv) do
    case Reattachment.find_running_turn(conv.id) do
      nil ->
        :ok

      turn ->
        Machine.end_turn(turn, {:orphan, "interrupt_dead_sandbox"}, sandbox_id: conv.sandbox_id)
    end

    {:error, :not_running}
  end

  # A conversation whose machine is gone keeps its workspace (ADR 0097 step 4):
  # its server is started on the lost row and rebuilds the workspace's machine
  # there (`Conversations.Rebuild`). A conversation with no workspace to keep
  # gets a fresh implicit one, as every wake did before.
  defp create_fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, images) do
    case Fountain.Conversations.Rebuild.wake_target(conv, agent) do
      {:rebuild, sandbox} ->
        rebuild_and_start(conv, agent, sandbox, runtime_module, initial_prompt, images)

      :fresh ->
        fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, images)
    end
  end

  # The server is started on the conversation's own row, which names the
  # workspace, and it builds the next machine itself, under the workspace's
  # owner, moving every live conversation of the workspace to it in one commit
  # (`Machine.rebuild/3`). So there is no row of this wake's to reserve, repoint
  # or clean up, and the start race #717 compensated for has nothing to leave
  # behind: a wake that loses it hands its prompt to the winner.
  #
  # A row the probe found gone at the provider is retired first, through its
  # owner, with the provider step skipped, so the server meets a terminal row
  # and rebuilds rather than reattaching to nothing. A row stranded mid-provision
  # (nobody building it, `pending` or `starting`) is provisioned again in place
  # by the server, which discards whatever half-built machine it left.
  #
  # ownership: conv is the caller's own tenant-scoped row, established by
  # wake_conversation_for/3 above; the sandbox is its own.
  defp rebuild_and_start(conv, agent, sandbox, runtime_module, initial_prompt, images) do
    with :ok <- check_saved_inference(conv, agent),
         :ok <- retire_lost(sandbox),
         :ok <- room_for(sandbox) do
      case start_conversation_server(conv, sandbox.id, runtime_module, initial_prompt, images) do
        {:error, {:already_started, winner_pid}} ->
          PromptDelivery.hand_over(winner_pid, initial_prompt, images)
          # ownership: as above.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        other ->
          other
      end
    end
  end

  defp retire_lost(%Sandbox{status: status} = sandbox) when status in ["ready", "suspended"] do
    case mark_old_sandbox_terminated(sandbox.id) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, _} -> {:error, :sandbox_unavailable}
    end
  end

  defp retire_lost(%Sandbox{}), do: :ok

  # The rebuild reserves its slot itself, inside the owner's succession; this
  # is the same check made synchronous, so a full fleet is the wake's answer
  # rather than a stage event after it. A row provisioned again in place
  # already holds its slot.
  defp room_for(%Sandbox{status: status, provider: provider, id: id})
       when status in @terminal_statuses or status in ["ready", "suspended"],
       do: Fountain.Quotas.check_fleet_ceiling(provider: provider, exclude: id)

  defp room_for(%Sandbox{}), do: :ok

  defp fresh_sandbox_and_start(conv, agent, runtime_module, initial_prompt, images) do
    # The sandbox being replaced is excluded: it is retired immediately below,
    # so counting it would block a wake that leaves concurrency unchanged.
    # Waking a dormant conversation provisions a fresh sprite, so it is subject
    # to the same gate as creating one. Without this, prompting an existing
    # conversation was an unmetered way past billing entirely.
    #
    # The machine was this conversation's alone (#2676), so nothing else on
    # the old row needs to be moved or told; the old row is retired once the
    # replacement's server is up.
    #
    # ownership: conv is the caller's own tenant-scoped row, established by
    # wake_conversation_for/3 above.

    with :ok <- check_saved_inference(conv, agent),
         # A fresh sandbox is a fresh placement decision — re-resolve from
         # the agent, so a conversation whose old sandbox died can migrate
         # providers naturally.
         {:ok, provider} <- Conversations.resolve_sandbox_provider(agent),
         {:ok, machine_name} <- Conversations.mint_machine_name(provider, conv.user_id, nil),
         # Same reservation as start_conversation/1 — see the note there (#330).
         {:ok, new_sandbox} <-
           Fountain.Quotas.with_sandbox_reservation(
             [provider: provider, exclude: conv.sandbox_id],
             fn ->
               attrs = %{
                 environment_id: conv.environment_id || agent.environment_id,
                 agent_id: conv.agent_id,
                 vault_id: conv.vault_id,
                 machine_name: machine_name,
                 status: "pending",
                 provider: Atom.to_string(provider),
                 user_id: conv.user_id
               }

               # A fresh implicit workspace for the fresh machine (ADR 0097):
               # this conversation has no workspace to keep (none, or an
               # implicit one whose resolution has moved; see
               # `Conversations.Rebuild`), and the old sandbox is still live
               # until the new server is up (see below), so a shared workspace
               # would trip the live-workspace index. The conversation moves
               # to it with `sandbox_id`. Under the fleet lock, unlike the
               # launch's: one more insert, whose foreign key checks the
               # sandbox insert takes anyway.
               with {:ok, workspace} <- Fountain.Workspaces.insert_implicit(attrs) do
                 Fountain.Machines.Provision.reserve(Map.put(attrs, :workspace_id, workspace.id))
               end
             end
           ) do
      # The row is repointed *after* the server starts, not before (#717).
      #
      # The old order repointed first, so a wake that then lost the start race
      # left the conversation pointing at the sandbox it had just terminated,
      # while the winner ran on a different one — a conversation that reads as
      # terminated in the API and the UI while it is happily serving turns, and
      # an orphan `ready` row nothing references. `managoat acp` reproduced it
      # on every session, because `session/new` and the first prompt arrive a
      # second apart and the prompt takes this path before the registry has the
      # new server.
      #
      # Deferring leaves a much smaller window — between the server starting
      # and the row being updated — in which the row still names the old
      # sandbox. That one is transient and self-correcting; the old one was
      # permanent.
      #
      # #800 closed the other half: a prompt that finds a `pending` row now
      # waits for the registry (`ConversationServer.await_registered/2`)
      # before coming here, so the first server — often on another pod, and
      # so invisible to this node's registry for a beat — is found and
      # handed the prompt instead of being raced by a second provision.
      case start_conversation_server(
             conv,
             new_sandbox.id,
             runtime_module,
             initial_prompt,
             images
           ) do
        {:ok, _} ->
          _ = mark_old_sandbox_terminated(conv.sandbox_id)

          {:ok, conv} =
            Conversations.update_conversation(conv, %{
              sandbox_id: new_sandbox.id,
              workspace_id: new_sandbox.workspace_id,
              status: "pending"
            })

          # ownership: conv established tenant-scoped above; this re-fetch
          # reads under that same ownership.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        {:error, {:already_started, winner_pid}} ->
          # Lost a concurrent wake of the same conversation. The winner's
          # server is running against its own sandbox; this one's just-created
          # row would otherwise sit pending — holding a fleet slot — until the
          # reaper's pass an hour later, so a full fleet could lock a user
          # out after a double-click (#330). Clean up our own row and
          # hand the prompt to the winner, which drops it if a turn is already
          # running — exactly right for a double-click.
          #
          # The conversation is left alone: the winner owns it, and it is the
          # winner's sandbox the row should name.
          _ = mark_old_sandbox_terminated(new_sandbox.id)

          PromptDelivery.hand_over(winner_pid, initial_prompt, images)

          # ownership: conv established tenant-scoped above; this re-fetch
          # reads under that same ownership.
          {:ok, Conversations._unsafe_get_conversation!(conv.id)}

        {:error, _} = err ->
          # Nothing ever ran on this sandbox. Retiring it keeps a failed wake
          # from holding a fleet slot until the reaper's next pass — the same
          # reasoning as the branch above.
          _ = mark_old_sandbox_terminated(new_sandbox.id)
          err
      end
    end
  end

  defp assert_resumable(%Conversation{status: s}) when s in ~w(terminated failed) do
    {:error, :gone}
  end

  defp assert_resumable(_), do: :ok

  # ownership: sandbox_id below is the waking conversation's own sandbox_id,
  # passed down from wake_conversation_for/4 / create_fresh_sandbox_and_start/5
  # above.
  #
  # Through the machine's owner since ADR 0058 stage 7b, with the provider step
  # skipped. Every caller here has already established that there is no machine
  # to destroy: the replaced row's disk is the one `probe_sandbox/4` was just
  # told is gone, and the two cleanup calls name a row this wake created and
  # never built anything on. `provider: :already_gone` says exactly that, so
  # this costs no provider round trip — and going through the door is what buys
  # the rest of it: the retire is serialized against whatever else holds the
  # machine, and it records the `sandbox.destroyed` every other retirement in
  # this tree has recorded since stage 5.
  #
  # The row ends `terminated` as it always did; the owner can refuse the
  # retire, and the reaper's sweep then finishes it.
  defp mark_old_sandbox_terminated(nil), do: :ok

  defp mark_old_sandbox_terminated(sandbox_id) do
    # ownership: `sandbox_id` is the waking conversation's own, passed down from
    # `wake_conversation_for/4` or `create_fresh_sandbox_and_start/5`, which
    # established the conversation's tenant before either reached here.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        :ok

      # A row somebody else already retired: nothing to do.
      sb when sb.status in ["terminated", "failed"] ->
        :ok

      # ownership: as the read above — this is the row it just returned.
      _sb ->
        Termination._unsafe_destroy_machine(sandbox_id,
          actor: "system:wake",
          destroy_reason: :replaced,
          reason: "sandbox_replaced",
          terminating_conversation_id: nil,
          provider: :already_gone
        )
    end
  end

  # Re-read rather than judged from the row `maybe_reuse_sandbox/1` saw: three
  # seconds of `await_registered/2` have passed since, which is long enough for
  # a provision to have finished or for one to have started.
  defp provisioning_owner_live?(sandbox_id) do
    # ownership: `sandbox_id` came from `maybe_reuse_sandbox/1`, which read it
    # off the conversation `wake_conversation_for/3` established the tenant of.
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil -> false
      sandbox -> Machine.busy?(sandbox)
    end
  end
end
