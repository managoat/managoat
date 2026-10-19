defmodule Fountain.Conversations.MachineLoss do
  @moduledoc """
  A live server that finds its machine gone at the provider (#3005; ADR 0097,
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
  machine is gone, `hand_off/2`:

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
       transcript kept and its session cleared, and the prompt runs there. A
       wake that fails reports the prompt as not run, as a background wake
       does.

  The turn is withdrawn before the machine is retired, because the destroy
  ends every turn still running on the machine. A co-tenant's turn admitted
  in between is ended that way, as `interrupted`; its own server then finds
  nothing to withdraw, and its prompt runs as the next turn instead. Either
  way the prompt runs, because its adapter never started.
  """

  require Logger
  require OpenTelemetry.Tracer

  alias Fountain.Conversations
  alias Fountain.Conversations.{PromptDelivery, PromptReceipt, Termination, Wake}
  alias Fountain.Machines.Machine

  # How long the hand-off waits for the stopping server before it wakes the
  # conversation. The server stops on the next message it reads, so this is
  # a bound on a mailbox, not on any provider call.
  @stop_wait_ms 30_000

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
  as its failed launch's last act.
  """
  @spec hand_off(map(), Fountain.Conversations.Turn.t()) :: :ok
  def hand_off(%{conversation_id: conv_id, sandbox_id: sandbox_id}, turn) do
    Logger.warning(
      "conv #{conv_id}: machine #{sandbox_id} is gone at the provider; " <>
        "rebuilding it for turn #{turn.turn_number}'s prompt"
    )

    # Read before the withdrawal, which deletes them with the turn.
    # ownership: the server's own turn.
    images = Conversations._unsafe_list_turn_images(turn.id)

    # The prompt's durable record until a turn takes it again: a restart
    # before then reports it as not run (`PromptReceipt.recover/0`).
    meta =
      PromptReceipt.accept(
        conv_id,
        PromptDelivery.travelling(client_request_id: turn.client_request_id)
      )

    _ = Machine.end_turn(turn, :withdraw, sandbox_id: sandbox_id)

    # The turn never started; close the span its launch opened.
    OpenTelemetry.Tracer.set_status(OpenTelemetry.status(:error, "machine lost"))
    OpenTelemetry.Tracer.end_span()

    case retire(sandbox_id, conv_id, "system:conversation_server") do
      {:ok, _} ->
        :ok

      {:error, reason} ->
        Logger.warning("conv #{conv_id}: lost machine not retired: #{inspect(reason)}")
    end

    rewake(self(), conv_id, turn.prompt, meta, images)
    GenServer.cast(self(), {:machine_gone, sandbox_id, "reclaimed", "lost", nil})
    :ok
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

  # After the server is down, or the wake would hand the prompt straight back
  # to it. In a task: the server is the process that is stopping.
  defp rewake(server, conv_id, prompt, meta, images) do
    {:ok, _pid} =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        ref = Process.monitor(server)

        receive do
          {:DOWN, ^ref, :process, _pid, _reason} -> :ok
        after
          @stop_wait_ms -> Process.demonitor(ref, [:flush])
        end

        # ownership: the stopping server's own conversation.
        case Wake.wake_conversation(conv_id, {prompt, meta}, images) do
          {:ok, _conv} ->
            :ok

          {:error, reason} ->
            Logger.warning(
              "conv #{conv_id}: rebuild after a lost machine failed: #{inspect(reason)}"
            )

            Wake.report_unrun_prompt(conv_id, reason, meta)
        end
      end)

    :ok
  end
end
