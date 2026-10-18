defmodule Fountain.Conversations.Rehydrator do
  @moduledoc """
  On app boot, find conversations whose ConversationServer would have been
  alive at the time of a clean BEAM stop and start servers for them. Each
  server enters reattach mode: get a sprite handle without recreating,
  verify the sprite is still alive at sprites.dev, mark the sandbox failed
  if it isn't.

  Scoped to **fully-provisioned** conversations (sandbox.status == "ready"
  and conversation.status in ["idle", "running"]). Pending/starting
  sandboxes from a crashed mid-provision are left as-is — the user's next
  action lazily resolves them via `wake_conversation`. `PromptReceipt` reports
  accepted but unadmitted prompts as `deployment_interrupted` before the
  endpoint starts; this sweep never resubmits their text.

  Fountain runs as one node (ADR 0072), so the boot that runs this sweep is
  the only one there is: it sweeps at once, and `start_child` answering
  `{:already_started, _}` means a prompt woke the conversation first.
  """

  require Logger

  alias Fountain.{Agents, Conversations}
  alias Fountain.Conversations.{Launch, Sandbox}
  alias Fountain.Machines.Machine

  # Where a machine stops. A terminal row's `destroying` stamp is leftovers
  # rather than intent (`Machines.Destroy`'s takeover clause), and a server
  # started on a retired row discovers that for itself.
  @terminal_statuses ~w(terminated failed)

  def run, do: sweep()

  # ── sweep ─────────────────────────────────────────────────────────────────

  defp sweep do
    Fountain.Telemetry.span([:rehydrate], %{}, fn ->
      convs = Conversations._unsafe_list_resumable_conversations()
      Logger.info("rehydrator: scanning #{length(convs)} resumable conversation(s)")

      started =
        Enum.reduce(convs, 0, fn conv, count ->
          case spawn_server(conv) do
            {:ok, _pid} -> count + 1
            _ -> count
          end
        end)

      Logger.info("rehydrator: ensured #{started} ConversationServer(s)")
      {started, %{candidates: length(convs), started: started}}
    end)
  end

  defp spawn_server(conv) do
    # Ownership: internal boot sweep; each conversation supplies its own agent_id.
    with :ok <- check_machine_free(conv),
         %Agents.Agent{} = _agent <-
           (conv.agent_id && Agents._unsafe_get_agent(conv.agent_id)) || {:skip, :no_agent},
         {:ok, runtime_module} <- Fountain.RuntimeDispatch.for_agent(conv) do
      conv.sandbox_id
      |> Conversations.register_server(
        Launch.child_spec(conv.id, conv.sandbox_id, runtime_module, initial_prompt: nil)
      )
      |> case do
        {:ok, pid} ->
          {:ok, pid}

        # A prompt woke the conversation between our list read and the
        # start. Treat as success — it's running.
        {:error, {:already_started, pid}} ->
          {:ok, pid}

        # The door made the same refusal `check_machine_free/1` does, on the
        # row it re-read under the lock: a lease claimed in the gap between our
        # check and the registration. The same outcome as our own skip, and it
        # must say so — this `case` is the `with`'s *body*, so nothing here
        # reaches the `else` below, and before ADR 0058 stage 6a round 2 this
        # refusal left the sweep silently (round 1, locks review).
        {:error, :sandbox_unavailable} ->
          skipped(conv, {:skip, :machine_busy})

        # The door's other refusal, and `check_machine_free/2`'s below: a
        # machine somebody has asked to be destroyed (ADR 0058 stage 9a). Named
        # rather than left to the catch-all so the log says which of the two
        # this was — a busy machine comes back, this one does not.
        {:error, :sandbox_reset_pending} ->
          skipped(conv, {:skip, :machine_destroying})

        other ->
          skipped(conv, other)
      end
    else
      outcome ->
        skipped(conv, outcome)
    end
  end

  # One logging path for every way this sweep declines a conversation, reached
  # from the `with`'s `else` and from its body alike.
  defp skipped(conv, {:skip, why}) do
    Logger.warning("rehydrator: skipping conv #{conv.id} (#{why})")
    :skipped
  end

  defp skipped(conv, {:error, reason}) do
    Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(reason)}")
    :skipped
  end

  # `start_child` may also answer `:ignore`, which the `with` body used to
  # return untouched. Logged rather than matched on: a sweep that raises on one
  # odd row stops starting servers for the whole fleet.
  defp skipped(conv, other) do
    Logger.warning("rehydrator: skipping conv #{conv.id}: #{inspect(other)}")
    :skipped
  end

  # A machine whose owner holds a live lease is not a machine to start a server
  # on (ADR 0058 stage 6a). The sweep reads `ready` rows, and a `ready` row can
  # be one a destroy, a reset or — from stage 6b — a park is holding between
  # its intent and its finalize; the row it will write is not the row this
  # preloaded struct shows. Starting a server there gives the machine a second
  # writer during the one window the owner exists to prevent.
  #
  # A row whose holder has died is started, stamped `transition` or not: that
  # is an owner that died, not one working, and a boot sweep that skipped it
  # would leave the conversation with no server until something else gave up on
  # the row (round 1).
  #
  # **Except `destroying`** (ADR 0058 stage 9a). That stamp is durable intent
  # rather than an operation in flight, so it is refused whatever the lease
  # says, and this is the one place stage 6a round 1's reasoning genuinely
  # inverts.
  #
  # Round 1 restored a server here because refusing withheld a machine that
  # `main` would have handed over at once. That is true of an abandoned *park*
  # or *resume* and false of an abandoned destroy, and the difference is the
  # fence rather than anything this stage invents: `main` answers
  # `:sandbox_reset_pending` — 409 — to a prompt on a fenced row already, so
  # such a conversation is **blocked either way** until the machine is gone,
  # and then gets a fresh one. Skipping the boot sweep costs it nothing it
  # would have had.
  #
  # What starting a server there does cost is real: a second writer on a disk
  # that is about to be deleted, and the intent itself, since
  # `Conversations.register_server/2` would clear the stamp on the way in.
  #
  # Skipping, not failing: the next boot sweep or the conversation's own next
  # prompt comes back, and by then the operation has finished or its lease has
  # expired. `{:skip, _}` is the sweep's own "not now" shape.
  defp check_machine_free(%{sandbox: %Sandbox{} = preloaded}) do
    # The preload is the sandbox row; its lease and transition are its
    # workspace's (ADR 0097, step 3b), so the row is read again through
    # `Machines.Lease`.
    sandbox = Fountain.Machines.Lease.get(preloaded.id) || preloaded

    cond do
      sandbox.transition == "destroying" and sandbox.status not in @terminal_statuses ->
        {:skip, :machine_destroying}

      sandbox.transition == "resuming" and sandbox.status not in @terminal_statuses ->
        {:skip, :machine_resuming}

      Machine.busy?(sandbox) ->
        {:skip, :machine_busy}

      true ->
        :ok
    end
  end

  # `_unsafe_list_resumable_conversations/0` joins the sandbox and preloads it,
  # so the clause above is the one that runs. A conversation without one has no
  # machine to be busy.
  defp check_machine_free(_conv), do: :ok
end
