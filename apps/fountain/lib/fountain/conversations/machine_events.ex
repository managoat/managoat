defmodule Fountain.Conversations.MachineEvents do
  @moduledoc false

  alias Fountain.Conversations
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Output

  # Handle a notification for this actor's sandbox; ignore another sandbox's.
  # The server supplies its connection/turn teardown callbacks. Keeping the
  # transcript handling here leaves the actor's mailbox clauses small.
  #
  # Cleanup runs before the guarded context transition, outside its
  # transaction. A moved or terminal conversation, or a newer running turn,
  # emits no sandbox event. A moved one can still be released: this is the
  # backstop `_unsafe_idle_interrupted_turn/1` names, so the write that idles a
  # parent stranded `running` with no running turn survives the rebind, while
  # the transcript event does not. The obsolete actor still stops after
  # cleanup, because its handle is already gone with the machine.
  def gone(
        %{sandbox_id: sandbox_id} = state,
        sandbox_id,
        {event, reason, message},
        interrupt,
        drop
      )
      when is_binary(sandbox_id) do
    state = if state.current_turn, do: interrupt.(state), else: state
    state = drop.(state, event)

    # Ownership: the actor supplies the sandbox whose local handle it closed.
    case Conversations._unsafe_finish_machine_gone(state.conversation_id, sandbox_id) do
      :ok ->
        Output.publish_stage(state.conversation_id, "sandbox", "done", %{
          event: event,
          reason: reason,
          # The machine's owner sent it, for whoever asked (a co-tenant's
          # park, a reclaim, an admin reap): ADR 0097.
          by: "machine_owner",
          message: message
        })

      :noop ->
        :ok
    end

    {:stop, :normal, %{state | handle: nil}}
  end

  def gone(state, _sandbox_id, _notification, _interrupt, _drop), do: {:noreply, state}

  @doc """
  The one sender of the `{:machine_gone, ..}` cast that `gone/5` above
  receives. A park, a destroy or a replaced machine is a machine
  operation: every other conversation on the sandbox loses its handle with
  it. Tell their servers, so each records what happened on its own transcript
  and stops — the next prompt then takes the wake path, the only path that
  brings the machine back. A cast: a co-tenant whose server is already gone
  (including a cross-pod registry miss) is not an error here.
  """
  @spec tell_cotenants([String.t()], String.t() | nil, String.t(), String.t(), String.t()) ::
          :ok
  def tell_cotenants(ids, sandbox_id, event, reason, message) do
    Enum.each(ids, fn id ->
      case ConversationServer.whereis(id) do
        nil -> :ok
        pid -> GenServer.cast(pid, {:machine_gone, sandbox_id, event, reason, message})
      end
    end)
  end
end
