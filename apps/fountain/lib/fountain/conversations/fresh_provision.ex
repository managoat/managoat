defmodule Fountain.Conversations.FreshProvision do
  @moduledoc """
  Building a machine for a conversation that has none: the fresh arm of
  `ConversationServer`'s `handle_continue(:provision)`.

  Lifted out of that server in ADR 0058 stage 7b, which is the move #1369 asks
  for and the stage that made it worth making. The arm had two halves tangled
  together — *who owns the machine* (the status writes, the create, the
  destroys on the failure paths) and *what goes on the disk* (skills, a runtime
  config, an env file, a broker CA, packages, a clone, a setup script, an
  inference reservation, an adapter) — and stage 7b separates them. The first
  half is `Fountain.Machines.Provision`, the owner's bracket. The second is
  `pipeline/3` below, which the bracket runs as a callback, and which is the
  same sequence of steps it has always been.

  So this module is the seam between them: it assembles what the pipeline
  needs from the server's state, hands the bracket a closure over it, and
  turns the bracket's answer back into the `handle_continue` reply the server
  owes OTP. The state it builds and the adapter it ends at are still the
  server's (ADR 0037) — every function here takes that state and gives it
  back.

  `ConversationServer.reattach/6` is the other arm and stays where it is: it
  works on a machine that already exists, so it has no bracket around it, only
  the two owner calls at its end.
  """

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.ActorStatus
  alias Fountain.Conversations.{CallbackKey, ConfigHome, ConversationServer, Egress}
  alias Fountain.Conversations.{Lifecycle, Output}
  alias Fountain.Conversations.{Provisioning, TurnMachine}
  alias Fountain.Machines.Machine

  # The two answers from a provision's pipeline that mean another actor already
  # owns this row: a reassignment that committed while the provider
  # was working, and a reset fence that landed in the same window. The machine
  # this attempt built is destroyed by the protocol; the conversation is left
  # alone, because a successor owns it. `Fountain.Machines.Provision` keeps the
  # same list for the row's half of the decision.
  @foreign_provision_owner [:configuration_changed, :sandbox_reset_pending]

  @doc """
  Rebuild the lost machine of `conv`'s workspace, and answer
  `handle_continue(:provision)` (ADR 0097, "Sandbox lost"; step 4).

  `sandbox` is the conversation's machine, and it is terminal: the wake that
  started this server found it gone and retired it, or somebody else retired
  it while the conversation slept. Its workspace is kept, so the next machine
  is built there, under the workspace's one owner and lease
  (`Machine.rebuild/3`), by this server's own pipeline, and every live
  conversation of the workspace follows it in the succession's commit.

  `{:follow, state, sandbox}` is the answer for a conversation whose
  workspace already has a live machine, because another conversation's
  prompt rebuilt it first (or is rebuilding it, which is waited out): the
  server reattaches to that machine instead, as a wake onto it would. A
  conversation with no workspace to rebuild in stops, as a server started on
  a terminal row always has.
  """
  @spec rebuild(map(), map(), map(), map() | nil, map() | nil, map()) ::
          {:noreply, map()} | {:stop, :normal, map()} | {:follow, map(), map()}
  def rebuild(state, conv, sandbox, agent, env, secrets) do
    case Fountain.Conversations.Rebuild.target(conv, sandbox, agent) do
      :rebuild ->
        run(state, conv, sandbox, agent, env, secrets, rebuild: true)

      :follow ->
        Fountain.Conversations.Rebuild.follow(state, conv)

      :none ->
        Logger.warning(
          "ConversationServer started for terminal conv #{conv.id} (#{sandbox.status})"
        )

        Fountain.Conversations.Rebuild.not_rebuilt(state, conv)
    end
  end

  @doc """
  Provision a machine for `conv` and answer `handle_continue(:provision)`.
  """
  @spec run(map(), map(), map(), map() | nil, map() | nil, map(), keyword()) ::
          {:noreply, map()} | {:stop, :normal, map()} | {:follow, map(), map()}
  def run(state, conv, sandbox, agent, env, secrets, opts \\ []) do
    Fountain.Telemetry.span(
      [:fresh_provision],
      %{
        conv_id: state.conversation_id,
        sandbox_id: sandbox.id,
        env_id: env && env.id,
        provider: Conversations.sandbox_provider_atom(sandbox),
        runtime: conv.runtime || (agent && agent.runtime) || "claude"
      },
      fn -> {do_run(state, conv, sandbox, agent, env, secrets, opts), %{}} end
    )
  end

  defp do_run(state, conv, sandbox, agent, env, secrets, opts) do
    try do
      do_run_inner(state, conv, sandbox, agent, env, secrets, opts)
    rescue
      exception ->
        stack = __STACKTRACE__
        msg = Exception.format(:error, exception, stack)
        Logger.error("provision raised an unhandled exception:\n#{msg}")

        metadata = %{
          reason: Exception.message(exception),
          stack: Exception.format_stacktrace(stack) |> String.slice(0, 2000)
        }

        if Keyword.get(opts, :rebuild, false) do
          # The succession may have moved the conversation to a new row:
          # the failure lands there (`Rebuild.failed/4`, review of step 4b).
          Fountain.Conversations.Rebuild.failed(state, conv, :provision_raised, metadata)
        else
          ConversationServer.fail_machine(sandbox.id, :provision_raised, conv.id)
          ActorStatus.fail(state, metadata)
          {:stop, :normal, state}
        end
    end
  end

  defp do_run_inner(state, conv, sandbox, agent, env, secrets, opts) do
    skills = (agent && agent.skills) || []
    # conv.runtime is validated-required and outlives the agent; the agent
    # fallback covers rows predating it. The mount logs what it skipped.
    runtime = conv.runtime || (agent && agent.runtime) || "claude"

    ctx = %{
      state: state,
      conv: conv,
      sandbox: sandbox,
      agent: agent,
      env: env,
      secrets: secrets,
      skills: skills,
      runtime: runtime,
      rebuild?: Keyword.get(opts, :rebuild, false)
    }

    provision_machine(ctx)
  end

  # What this server does once the machine is its own and the intent is on the
  # row, and before anything is created. `Machines.Provision` runs it for that
  # reason: a row retirement won while this server was starting never reaches
  # here, so it announces nothing.
  #
  # `interrupted?` is the protocol's reading, not a guess from the snapshot this
  # server read before it claimed anything — an earlier attempt that died
  # between stamping its intent and creating its machine is a rebuild too, and
  # only the row under the lease knows.
  defp announce_and_check(state, sandbox, interrupted?) do
    Output.publish_stage(
      state.conversation_id,
      "provision",
      "started",
      if(interrupted?,
        do: %{retry: "an earlier attempt was interrupted; rebuilding the sandbox"},
        else: %{}
      )
    )

    Provisioning.check_broker_support(
      Conversations.sandbox_provider_atom(sandbox),
      state.conversation_id
    )
  end

  # The bracket (ADR 0058 stage 7b). The owner claims the machine's lease,
  # stamps the intent, creates the machine, runs `provision_pipeline/3` under the
  # lease and writes `ready` or `failed` from what it answers. Every
  # step of the pipeline, and the adapter it ends at, stay in this server
  # (ADR 0037, #1369).
  defp provision_machine(ctx) do
    %{state: state, conv: conv, sandbox: sandbox, skills: skills} =
      ctx

    result =
      if ctx.rebuild? do
        Fountain.Conversations.Rebuild.machine(ctx, &pipeline/3)
      else
        Machine.provision(
          sandbox.id,
          &pipeline(ctx, &1, &2),
          actor: "system:conversation_server",
          conversation_id: conv.id,
          environment: ctx.env,
          on_claim: &announce_and_check(state, sandbox, &1)
        )
      end

    case result do
      # The rebuild's own answers: the workspace's machine is somebody
      # else's to build or already built, or there is no room for one
      # (`Fountain.Conversations.Rebuild`).
      {:rebuild, answer} ->
        answer

      {:ok, :provisioned, %{state: provisioned, conv: conv}} ->
        # What the config home was built with, known from the agent rather
        # than from anything the build discovered. Recorded once the machine
        # is `ready`, so a superseded provision, which never gets here,
        # leaves no record of a disk another owner threw away. Best effort:
        # with no record a wake falls back to the agent version's skills.
        _ = Fountain.Conversations.Skills.record(conv, skills)
        Output.publish_stage(state.conversation_id, "provision", "done")

        # Any prompt this conversation was started for arrives as a cast,
        # already queued behind this handle_continue. See
        # queue_initial_prompt/3.
        {:noreply, TurnMachine.forget_runtime_session(provisioned, conv)}

      # Retirement won, or another server holds this machine, and this attempt
      # never got as far as preparing anything — the protocol says so by
      # answering without a result. Leave the winner and any replacement
      # conversation alone, and announce nothing.
      #
      # **Which outcomes reach here is the protocol's statement, not a guess**
      # (round 1, behaviour review). The first draft read this arm as "before
      # the pipeline ran" and the sibling below as "after", and one outcome
      # broke that reading: a supersession the *renewer* detected returned a
      # bare two-tuple although `fun` had run to completion, so the broker
      # session and the callback key the pipeline had just minted were left
      # live. The protocol carries its result now, so the shape of the answer
      # and the existence of a state to unwind are the same fact.
      {:ok, settled} when settled in [:already_terminal, :claimed_elsewhere] ->
        report_queued_unrun(state, settled)
        {:stop, :normal, state}

      # The same two, carrying what the pipeline reached — the row was retired,
      # or the lease taken over, while the provider was working. The machine is
      # the protocol's to destroy and has been; what is left for this server is
      # the session and the key its pipeline minted, which belong to the attempt
      # rather than to the machine.
      {:ok, settled, %{state: reached}} when settled in [:already_terminal, :claimed_elsewhere] ->
        Egress.release_prepared({:ok, reached})
        report_queued_unrun(state, settled)
        {:stop, :normal, reached}

      # Another actor owns the row: a reassignment that committed, or a reset fence,
      # either detected by a pipeline step or by the finalize. Same treatment —
      # the conversation is a successor's, and this attempt unwinds its own.
      {:error, reason, %{state: reached}} when reason in @foreign_provision_owner ->
        Egress.release_prepared({:ok, reached})
        report_queued_unrun(state, :sandbox_unavailable)
        {:stop, :normal, reached}

      {:error, reason, %{state: reached}} ->
        Egress.release_prepared({:ok, reached})
        announce_failed_provision(reached, conv, reason)

      {:error, :sandbox_reset_pending} ->
        report_queued_unrun(state, :sandbox_unavailable)
        {:stop, :normal, state}

      {:error, reason} ->
        provision_could_not_start(state, conv, sandbox, reason)
    end
  end

  # The stops above announce nothing about the machine, which is another
  # owner's, but a prompt already queued for this server (a launch's first, a
  # wake's) dies with its mailbox. It is reported as not run, with its receipt
  # (#3001), and nothing is said when none is queued. The words are
  # `Reattachment.untaken/2`'s, the same stand-down on the reattach's road: a
  # row retired under it is `machine_lost`, one another holder has is
  # `machine_busy`, and a reassignment or a reset fence is
  # `sandbox_unavailable`; all retryable. An ended conversation's is `gone`.
  # A reset fence that is a teardown ending this conversation may not have
  # written it `terminated` yet, so its prompt can read as retryable, and the
  # retry is then refused as gone.
  defp report_queued_unrun(state, word) do
    # ownership: the server's own conversation.
    case Conversations._unsafe_get_conversation(state.conversation_id) do
      %{status: status} when status in ["terminated", "failed"] ->
        Fountain.Conversations.Wake.report_queued_unrun(state.conversation_id, :gone, bare: false)

      nil ->
        Fountain.Conversations.Wake.report_queued_unrun(state.conversation_id, :gone, bare: false)

      _live ->
        Fountain.Conversations.Reattachment.untaken(state.conversation_id, word)
    end
  end

  # The machine never existed: the pairing check refused it, or the provider
  # would not create it. The row is the protocol's to fail where it claimed
  # one, and this server's where it never got that far.
  defp provision_could_not_start(state, conv, sandbox, reason) do
    Logger.error(
      "provision could not start: #{inspect(Fountain.Machines.Provision.without_output(reason))}"
    )

    ConversationServer.fail_machine(sandbox.id, :provision_could_not_start, conv.id)
    announce_failed_provision(state, conv, reason)
  end

  defp announce_failed_provision(state, _conv, reason) do
    ActorStatus.fail(state, %{reason: inspect(Fountain.Machines.Provision.without_output(reason))})

    {:stop, :normal, state}
  end

  # Every step between the machine existing and the row saying `ready`:
  # unchanged from `main` but for its two ends. It is handed a machine rather
  # than creating one, and it answers rather than writing the row — so the
  # `ready` claim that used to sit inside this `with` is the protocol's
  # finalize, and the three `Managoat.Sandbox.destroy/1` calls that used to sit
  # in its `else` are the protocol's failure arms.
  #
  # `epoch` is the lease this provision holds. One step records something on the
  # row mid-provision — the machine's public URL — and writes it by
  # compare-and-set on that epoch, so a superseded attempt leaves no URL behind.
  defp pipeline(ctx, handle, epoch) do
    # Skills are files the first turn reads, and nothing between here and
    # there depends on them, so they are written alongside the rest and
    # awaited at the end rather than first. A GitHub skill is the exception:
    # its install reaches npm and GitHub through the proxy, so it waits for
    # the CA and the floor and starts beside the packages
    # (`run_provisioning_pipeline/6`). Raced against them it lost, and spent
    # 72 s failing to resolve the registry (2026-10-15).
    skills_task =
      if Fountain.SandboxSkills.remote?(ctx.skills),
        do: nil,
        else: async_step(fn -> mount_skills(handle, ctx, []) end)

    # The adapter goes on beside the CA install too, from a bundle this host
    # streams, since nothing in that install dials out
    # (`Managoat.Runtimes.ACP.preload/2`). Downloading it waited for the CA and
    # the floor and ended every cold provision (2.2 s at p50 on prod,
    # 2026-10-17); `adapter_after_floor/4` streams it once more if this did
    # not.
    preload_task = async_step(fn -> Provisioning.preload_acp_adapter(handle, ctx.runtime) end)

    try do
      result = run_pipeline(Map.put(ctx, :adapter_preload, preload_task), handle, epoch)
      if skills_task && match?({:ok, _}, result), do: await_step(skills_task)
      seed_config_home(ctx, handle, result)
    after
      skills_task && Task.shutdown(skills_task, :brutal_kill)
      Task.shutdown(preload_task, :brutal_kill)
    end
  end

  # The runtime template the setup script filled, copied into the config home
  # Managoat has just written (#2998): last, once the setup script has run and
  # every file Managoat writes into the home is there, because those are the
  # files that win. Only an environment with a setup script has a template:
  # the template's directories are made in the setup script's own exec.
  defp seed_config_home(ctx, handle, {:ok, reached} = result) do
    if has_setup_script?(ctx.env) do
      # A step of an explicit workspace's setup log, on a rebuild after a
      # loss that this conversation runs (#3009).
      :ok = Fountain.Workspaces.SetupOutput.step(:runtime_template)

      case step(ctx.state.conversation_id, "runtime_template", fn ->
             ConfigHome.seed(handle, reached.conv, ctx.agent, :into)
           end) do
        :ok -> result
        {:error, reason} -> {:error, reason, %{state: reached.state}}
      end
    else
      result
    end
  end

  defp seed_config_home(_ctx, _handle, result), do: result

  defp has_setup_script?(%{setup_script: script}) when is_binary(script), do: script != ""
  defp has_setup_script?(_env), do: false

  defp mount_skills(handle, ctx, sprite_env) do
    step(ctx.state.conversation_id, "skills", fn ->
      Fountain.SandboxSkills.mount_fresh(handle, ctx.runtime, ctx.skills,
        config_home: ConfigHome.home(ctx.conv),
        env: Fountain.Broker.egress_env(sprite_env)
      )
    end)
  end

  # A step run beside the pipeline. `do_run/6` rescues any exception a step
  # raises and fails the provision rather than stranding the conversation in
  # `pending`; an exception inside a Task would reach this process as an exit
  # instead, past that rescue. So the task catches it, and awaiting re-raises
  # it here, with its own stacktrace.
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

  defp run_pipeline(ctx, handle, epoch) do
    %{state: state, conv: conv, sandbox: sandbox, agent: agent, env: env} = ctx
    %{secrets: secrets, runtime: runtime} = ctx
    conv_id = state.conversation_id

    {state, conv} =
      step(conv_id, "callback_key", fn ->
        # A key a predecessor handed over to its running turn (#2835) has no
        # adapter left to serve on a fresh machine.
        CallbackKey.release_handover(conv_id, conv.handover_callback_api_key_id)
        ConversationServer.rotate_callback_api_key(state, conv)
      end)

    # Looked up once, here, because it is stable for the sandbox's life and
    # the agent needs it in its environment before the first turn runs.
    sandbox_url =
      step(conv_id, "sandbox_url", fn ->
        Provisioning.record_sandbox_url(sandbox, handle, epoch)
      end)

    # The broker session is minted before the env is built, because the
    # env carries it; the CA is installed before anything dials out,
    # because nothing dials out without it (ADR 0019 gate 1a).
    # Keep the result outside `with`: its else cannot see the minted state.
    prepared = step(conv_id, "broker_session", fn -> Egress.prepare_state(state) end)

    with {:ok, state} <- prepared,
         {:ok, ca_files} <-
           step(conv_id, "broker_ca_files", fn -> Egress.ca_files(state.broker, handle) end),
         sprite_env =
           ConversationServer.build_sprite_env(state, agent, env, secrets, sandbox_url, ca_files),
         # The env file and the CA are written in tasks of their own, which
         # report to no setup log: an explicit workspace's (#3009) is told here.
         :ok <- Fountain.Workspaces.SetupOutput.step(:environment),
         :ok <-
           step(conv_id, "sandbox_config", fn ->
             write_sandbox_config(handle, state, agent, runtime, sprite_env, conv)
           end),
         :ok <-
           run_provisioning_pipeline(handle, env, sprite_env, secrets, conv_id, fn ->
             %{
               adapter: adapter_after_floor(ctx, handle, runtime, sprite_env),
               skills:
                 if(Fountain.SandboxSkills.remote?(ctx.skills),
                   do: async_step(fn -> mount_skills(handle, ctx, sprite_env) end)
                 )
             }
           end),
         :ok <-
           step(conv_id, "inference_reserve", fn ->
             Fountain.Conversations.InferenceBinding.reserve(conv, state.inference_source)
           end),
         :ok <-
           step(conv_id, "runtime_prepare", fn ->
             Provisioning.prepare_runtime_sandbox(
               handle,
               conv,
               runtime,
               state.runtime_module,
               agent,
               sprite_env,
               state.inference_source
             )
           end) do
      {:ok,
       %{
         conv: conv,
         handle: handle,
         state: %{
           state
           | handle: handle,
             sprite_env: sprite_env,
             # Dated from the sandbox row, not from now, so the absolute
             # lifetime ceiling survives a restart and a reattach rather than
             # resetting.
             sandbox_started_at: Lifecycle.clock_start(sandbox)
         }
       }}
    else
      {:error, reason} ->
        # The state this attempt reached travels with the error; releasing it is
        # `run/6`'s, because the row may also be lost *after* this returns —
        # retired or taken over at the finalize — and one place that unwinds an
        # attempt is better than two that have to agree.
        {:error, reason, %{state: reached_state(prepared, state)}}
    end
  end

  # What the sandbox needs on disk before anything runs in it: the runtime's
  # config, the agent's instructions, the env file and the broker CA. None
  # reads another, so they go at once: they were ~2.8 s one after another on
  # a sprite, most of it the CA install (measured 2026-09-26). Each answers as
  # it did in sequence, and the first error in that order is the answer.
  #
  # - The runtime config is a real step, not best effort: an agent whose MCP
  #   servers could not be written would otherwise run without them and report
  #   `provision/done`. The runtimes retry the write themselves.
  # - The env file is the machine's; the conversation's identity travels as
  #   process env on every spawn (`Fountain.Conversations.Identity`).
  # - The CA is installed before anything dials out, which the pipeline still
  #   guarantees: every step after this one waits for it.
  defp write_sandbox_config(handle, state, agent, runtime, sprite_env, conv) do
    home = ConfigHome.home(conv)
    # ownership: the server's own machine, established at its init.
    relay_owner = Fountain.Workspaces.relay_owner(state.sandbox_id, state.conversation_id)

    [
      {"runtime_config",
       fn ->
         Provisioning.write_runtime_config(handle, state.runtime_module, agent, home)
       end},
      {"instructions",
       fn ->
         _ = Provisioning.write_instructions(handle, runtime, agent, home)
         :ok
       end},
      {"env_file",
       fn ->
         Provisioning.write_env_file(handle, Fountain.Conversations.Identity.disk_env(sprite_env))
       end},
      {"broker_ca_install",
       fn -> Egress.install_ca(state.broker, handle, state.conversation_id, relay_owner) end}
    ]
    |> Enum.map(fn {name, fun} ->
      async_step(fn -> step(state.conversation_id, name, fun) end)
    end)
    |> Enum.map(&await_step/1)
    |> Enum.find(:ok, &(&1 != :ok))
  end

  # One named provisioning step as a span: the `fountain.provision_step`
  # histogram, tagged by step, says which step a slow provision spent its time
  # in. `step` and `conv_id` ride the stop event because `:telemetry.span`
  # reports only what the work returns there.
  # How long the floor waits for the preload before installing again.
  # The preload normally finishes inside the CA install. One still running is
  # left to finish, and the install then finds the pin installed under the
  # lock they share.
  @preload_wait 2_000

  # The `adapter` step once the floor is up: nothing if the preload installed
  # the pin, `install/3` (the pin check, then the same streamed bundle) otherwise.
  defp adapter_after_floor(ctx, handle, runtime, sprite_env) do
    case Task.yield(ctx.adapter_preload, @preload_wait) do
      {:ok, {:ok, :ok}} ->
        nil

      _skipped_failed_or_late ->
        async_step(fn ->
          step(ctx.state.conversation_id, "adapter", fn ->
            Provisioning.prepare_acp_adapter(handle, runtime, sprite_env)
          end)
        end)
    end
  end

  defp step(conv_id, name, fun) do
    Fountain.Telemetry.span([:provision_step], %{conv_id: conv_id, step: name}, fn ->
      result = fun.()
      outcome = if match?({:error, _}, result), do: :failed, else: :ok
      {result, %{conv_id: conv_id, step: name, outcome: outcome}}
    end)
  end

  # The state a failed pipeline stops with: the one carrying the broker session
  # if it got that far, so `terminate/2` sees what this attempt actually held.
  defp reached_state({:ok, prepared_state}, _state), do: prepared_state
  defp reached_state(_unprepared, state), do: state

  # The network policy is the *first* step, before the packages (#2597). The
  # package commands run under the conversation's full process env, broker
  # session token included, and apt and npm hooks are code the tenant chose
  # rather than wrote; with the floor not yet applied they ran on the
  # provider's open network. The ordering the old comment defended ("apt
  # needs unrestricted network") predates the broker: `write_sandbox_config`
  # has already installed the CA and the sudoers `env_keep` by now, which is
  # what lets `sudo apt-get` reach a mirror through the proxy at all.
  #
  # `after_floor` starts what needs the floor and the CA but not the packages,
  # as tasks awaited once the setup script has run:
  #
  # - The runtime's ACP adapter (`adapter`), when the preload did not install
  #   it. It used to start only after the setup script had finished, adding
  #   all of it to every cold start that had packages, a clone, a setup
  #   script or a GitHub skill (measured on prod 2026-10-15: +apt jq 5.7 s,
  #   one GitHub skill 7.2 s, each serial before the adapter). It reads
  #   nothing those steps write: it installs the bundle the host streams
  #   (ADR 0092) into its own versioned directory, under the process env
  #   rather than the env file. The one thing a setup script could change under it is which Node
  #   the adapter's launcher records. The install resolves it in its first
  #   moments, so that is now the image's Node, the one each pinned adapter
  #   is tested against, rather than one a setup script installs and
  #   switches to. A failed install fails the
  #   provision, once the steps beside it have finished. Where a pushed
  #   bundle already installed the pin before the floor (`pipeline/3`),
  #   there is no `adapter` step at all.
  # - A GitHub skill (`skills`), whose failure is logged by the mount and is
  #   not the provision's, as before.
  #
  # What the runtime writes for itself (`Provisioning.prepare_runtime_sandbox/7`)
  # stays after the setup script, so Fountain's files still win over one the
  # setup script wrote.
  defp run_provisioning_pipeline(handle, env, sprite_env, secrets, conv_id, after_floor) do
    with :ok <- Egress.apply_policy(handle, conv_id) do
      %{adapter: adapter, skills: skills} = after_floor.()

      try do
        setup = %Fountain.Machines.Setup{
          environment: env,
          sprite_env: sprite_env,
          secrets: secrets,
          conversation_id: conv_id
        }

        with :ok <- Fountain.Machines.Setup.run(handle, setup),
             :ok <- if(adapter, do: await_step(adapter), else: :ok) do
          if skills, do: _ = await_step(skills)
          :ok
        end
      after
        for task <- [adapter, skills], task, do: Task.shutdown(task, :brutal_kill)
      end
    end
  end
end
