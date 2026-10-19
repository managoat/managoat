defmodule Fountain.Conversations.MachineLoss do
  @moduledoc """
  A server that finds its machine gone at the provider (#3005; ADR 0097,
  "Sandbox lost").

  A conversation's server stays up between turns, holding its machine's
  handle. When the provider loses the machine in that time, the adapter's
  connection drops (`connection_lost`) and the server stays up, so the next
  prompt reaches it rather than the wake. Its adapter then fails to start at
  the provider (`spawn failed: {:acp_adapter_install, ... 404 ...}`), and
  before this module nothing classified that: the row stayed `ready`, the
  workspace kept reporting it, and every prompt failed the same way until the
  server stopped for another reason. The rebuild of step 4b (#2993) ran only
  from the wake, for a conversation with no live server.

  So a server whose turn could not start asks the provider (`gone?/1`). Only
  `{:error, :not_found}` from `Managoat.Sandbox.get/1` counts, the answer the
  wake's probe and the reattach already treat as definitive; a transient
  error, or a 404 from the exec endpoint while the machine itself still
  answers, fails the turn as before, and the machine is left alone. When the
  machine is gone, `hand_off/3`:

    1. withdraws the turn (`Machines.Machine.end_turn/3`, `:withdraw`). Its
       adapter never started, so its prompt never reached an agent, and it
       runs again under the same turn number, which is the turn a client
       following that number waits for;
    2. retires the machine through its owner (`retire/3`, a destroy with the
       provider step skipped). The owner is the only status writer (ADR
       0058). Every other conversation's server on the machine stops quietly:
       the rebuild writes the one note each conversation it moves gets;
    3. stops this server, with the same quiet notice; and
    4. once the server is down, sends the prompt down the wake road
       (`Wake.wake_conversation/3`), with its images and its
       `client_request_id`, under a new prompt receipt. The wake finds the
       machine retired and rebuilds it in the conversation's workspace, as it
       does for a prompt to a conversation with no server (#2993): every live
       conversation of the workspace follows the new machine with its
       transcript kept and its session cleared, and the prompt runs there.

  **A prompt that does not run again is reported, on its turn.** A client
  saw the withdrawn turn start, so a `wake` `failed` alone does not reach it
  (the SDK and the CLI stop reading those once their turn has started). Until
  a turn takes the prompt, its receipt is watched (`watch/3`): a wake that
  fails, a rebuild that stops before admitting it, or a refusal of it, is
  reported as not run with a `turn` `failed` stage under the withdrawn turn's
  number, reason `machine_lost` (`Wake.report_unrun_prompt/3`, through the
  `:withdrawn_turn` the prompt carries).

  Two limits keep the hand-off honest:

    * **A turn already ended is not run again.** The destroy of a lost machine
      ends every turn still running on it, so a co-tenant's turn admitted in
      the instant before its own server withdraws it is already `interrupted`
      (`machine_destroyed`) when that server gets there. Its client has seen
      the turn end; running the prompt again under the next number would
      answer a turn nobody is waiting on. Such a prompt is reported as not
      run, retryably.
    * **One automatic rebuild per conversation in ten minutes.** A machine
      that is gone again within that time (a provider that keeps losing what
      it builds) is retired and the turn fails as it always did, so the next
      rebuild waits for the next prompt rather than looping on billable
      provisions.

  `requeue/1` is the reattach's half: a server that finds its machine gone
  before it has attached (a workspace launch onto a `ready` machine nobody
  knew was lost) hands the prompt it was started for to the same rebuild.
  """

  require Logger
  require OpenTelemetry.Tracer

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ConversationServer,
    PromptDelivery,
    PromptReceipt,
    Termination,
    TurnMachine,
    Wake
  }

  alias Fountain.Machines.Machine
  alias Fountain.Repo

  # How long the hand-off waits for the stopping server before it wakes the
  # conversation. The server stops on the next message it reads, so this is
  # a bound on a mailbox, not on any provider call.
  @stop_wait_ms 30_000

  # How often the watch re-reads the prompt's receipt while a server holds it.
  @watch_poll_ms 1_000

  # At most one automatic rebuild per conversation in this window.
  @hand_off_window_s 600

  @doc """
  Whether the provider says the machine behind `handle` does not exist. Only
  a definitive not-found counts: every other answer, an error included, is
  `false`.
  """
  @spec gone?(Managoat.Sandbox.Handle.t() | nil) :: boolean()
  def gone?(nil), do: false
  def gone?(handle), do: Managoat.Sandbox.get(handle) == {:error, :not_found}

  @doc """
  Hand the prompt of `turn`, whose adapter did not start on a machine
  `gone?/1` has just found gone, to that machine's rebuild, and stop the
  server `state` is. See the moduledoc. Called in the server's own process,
  as its failed launch's last act, with the failure's `detail`.
  """
  @spec hand_off(map(), Fountain.Conversations.Turn.t(), String.t()) :: :ok
  def hand_off(%{conversation_id: conv_id, sandbox_id: sandbox_id} = state, turn, detail) do
    if handed_off_recently?(state) do
      Logger.warning(
        "conv #{conv_id}: machine #{sandbox_id} is gone at the provider again; " <>
          "retiring it, and leaving the rebuild to the next prompt"
      )

      # One reason for a lost machine, whichever way it is reported (#3001):
      # `machine_lost`, as the withdrawn turn's report says it, with the
      # spawn's words as the detail. Retryable: the next prompt rebuilds.
      TurnMachine.fail_before_start(turn, conv_id, sandbox_id, detail,
        reason: "machine_lost",
        retryable: true
      )

      retire_and_stop(sandbox_id, conv_id)
    else
      Logger.warning(
        "conv #{conv_id}: machine #{sandbox_id} is gone at the provider; " <>
          "rebuilding it for turn #{turn.turn_number}'s prompt"
      )

      withdraw_and_rewake(state, turn)
    end
  end

  defp withdraw_and_rewake(%{conversation_id: conv_id, sandbox_id: sandbox_id}, turn) do
    # Read before the withdrawal, which deletes them with the turn.
    # ownership: the server's own turn.
    images = Conversations._unsafe_list_turn_images(turn.id)

    # The prompt's durable record until a turn takes it again: a restart
    # before then reports it as not run (`PromptReceipt.recover/0`).
    meta =
      PromptReceipt.accept(
        conv_id,
        PromptDelivery.travelling(
          client_request_id: turn.client_request_id,
          withdrawn_turn: turn.turn_number
        )
      )

    withdrawn = Machine.end_turn(turn, :withdraw, sandbox_id: sandbox_id)

    # The turn never started; close the span its launch opened.
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "machine lost"))
    OpenTelemetry.Tracer.end_span()

    retire_and_stop(sandbox_id, conv_id)

    case withdrawn do
      {:ok, _turn} ->
        rewake(self(), conv_id, turn.prompt, meta, images)

      # Ended already (the machine's destroy ended it), or the conversation
      # moved or ended: its client has seen the turn end. Not run again.
      _not_withdrawn ->
        Wake.report_unrun_prompt(conv_id, :machine_lost, Keyword.delete(meta, :withdrawn_turn))
    end

    :ok
  end

  defp retire_and_stop(sandbox_id, conv_id) do
    case retire(sandbox_id, conv_id, "system:conversation_server") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("conv #{conv_id}: lost machine not retired: #{inspect(reason)}")
    end

    GenServer.cast(self(), {:machine_gone, sandbox_id, "reclaimed", "lost", nil})
  end

  # ownership: the server's own conversation, under its owner's id.
  defp handed_off_recently?(%{conversation_id: conv_id, user_id: user_id}) do
    since = DateTime.add(DateTime.utc_now(), -@hand_off_window_s, :second)

    Repo.exists?(
      from(e in Fountain.Audit.Event,
        where:
          e.user_id == ^user_id and e.action == "conversation.turn.withdrawn" and
            e.inserted_at >= ^since and
            fragment("?->>'conversation_id' = ?", e.metadata, ^conv_id)
      )
    )
  end

  @doc """
  Retire a machine the provider has said is gone, through its owner, with
  the provider step skipped, and stop every server still bound to it with
  nothing on its transcript (`MachineEvents.gone/5`). `conv_id` is the
  conversation that found it gone; `actor` is the caller's.
  """
  @spec retire(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: {:ok, term()} | {:error, term()}
  def retire(sandbox_id, conv_id, actor) do
    # ownership: the caller's own conversation's machine, which the provider
    # has just said does not exist.
    Termination._unsafe_destroy_machine(sandbox_id,
      actor: actor,
      destroy_reason: :provider_gone,
      reason: "machine_lost",
      # Forced: a workspace whose disk is gone keeps no machine for anyone.
      terminating_conversation_id: nil,
      provider: :already_gone,
      notify: {conv_id, "reclaimed", "lost", nil}
    )
  end

  @doc """
  Hand the prompts queued for this server, which has just found its machine
  gone before attaching, to the machine's rebuild, as `hand_off/3` does once
  the server is down. Called in the server's own process, before it stops.
  No turn was opened for them, so there is nothing to withdraw. Answers how
  many it handed on.

  Only what is already in the mailbox: the wake and the workspace launch cast
  the prompt as soon as the server is registered, and the reattach's provider
  round trip comes first, so it is there in practice. A cast that lands after
  this is lost with the server, as every cast to a stopping server was.
  """
  @spec requeue(String.t(), non_neg_integer()) :: non_neg_integer()
  def requeue(conv_id, count \\ 0) do
    receive do
      {:"$gen_cast", {:initial_prompt, prompt, images}} ->
        requeue_one(conv_id, prompt, images, [])
        requeue(conv_id, count + 1)

      {:"$gen_cast", {:initial_prompt, prompt, images, meta}} ->
        requeue_one(conv_id, prompt, images, meta)
        requeue(conv_id, count + 1)
    after
      0 -> count
    end
  end

  defp requeue_one(conv_id, prompt, images, meta) do
    rewake(
      self(),
      conv_id,
      prompt,
      PromptReceipt.accept(conv_id, PromptDelivery.travelling(meta)),
      images
    )
  end

  # After the server is down, or the wake would hand the prompt straight back
  # to it. In a task: the server is the process that is stopping.
  defp rewake(server, conv_id, prompt, meta, images) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        if stopped?(server) do
          wake(conv_id, prompt, meta, images)
        else
          Wake.report_unrun_prompt(conv_id, :machine_busy, meta)
        end
      end)

    :ok
  end

  defp stopped?(server) do
    ref = Process.monitor(server)

    receive do
      {:DOWN, ^ref, :process, _pid, _reason} -> true
    after
      @stop_wait_ms ->
        Process.demonitor(ref, [:flush])
        false
    end
  end

  # ownership: the stopped server's own conversation.
  defp wake(conv_id, prompt, meta, images) do
    case Wake.wake_conversation(conv_id, {prompt, meta}, images) do
      {:ok, _conv} ->
        watch(conv_id, meta, System.monotonic_time(:millisecond) + watch_ms())

      {:error, reason} ->
        Logger.warning("conv #{conv_id}: rebuild after a lost machine failed: #{inspect(reason)}")
        Wake.report_unrun_prompt(conv_id, reason, meta)
    end
  end

  # Until a turn takes the prompt (admission resolves its receipt) or it is
  # reported (so does the report). A server that stops still holding it (a
  # rebuild refused, or one that failed before admitting it) reports it here.
  defp watch(conv_id, meta, deadline) do
    receipt = meta[:prompt_receipt_id]

    cond do
      not PromptReceipt.pending?(conv_id, receipt) ->
        :ok

      # Still unadmitted past the longest a rebuild can take: a server up
      # without the prompt (a restart from its child spec carries none).
      System.monotonic_time(:millisecond) > deadline ->
        Wake.report_unrun_prompt(conv_id, :machine_busy, meta)

      server = ConversationServer.whereis(conv_id) ->
        ref = Process.monitor(server)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          @watch_poll_ms -> Process.demonitor(ref, [:flush])
        end

        watch(conv_id, meta, deadline)

      true ->
        Wake.report_unrun_prompt(conv_id, :machine_lost, meta)
    end
  end

  # The longest a rebuild can hold the prompt before admitting it: the
  # provision's deadline, after waiting out a co-tenant's rebuild.
  defp watch_ms,
    do:
      Fountain.Conversations.ProvisionWatchdog.deadline_ms() +
        Fountain.Conversations.Rebuild.follow_wait_ms()
end
