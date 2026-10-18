defmodule Fountain.Conversations.Termination do
  @moduledoc """
  The client half of terminate: what a caller does to end a conversation,
  whether or not its `ConversationServer` is alive.

  Moved out of `Fountain.Conversations.ConversationServer` and
  `Fountain.Conversations.Lifecycle` in #2209 (one owner per lifecycle verb,
  #2175). The server keeps the actor halves — `handle_call({:terminate_conv, ..})`,
  `terminate_machine`, `finish_termination` and OTP `terminate/2` — because
  each needs `state.handle` or orders a row write against the reply.
  Everything here is a function over a conversation id, the registry and rows.

  This module also owns the terminated row itself
  (`_unsafe_finish_conversation_termination/2`, moved from
  `Fountain.Conversations` in #2268), the same way
  `Fountain.Conversations.Interruption` owns the interrupted turn row
  (#2244). The machine fence a forced teardown refuses or commits against is
  `Fountain.Conversations.Lifecycle`'s (#2258) — a rule about the sandbox,
  not a conversation verb; this module calls it, it does not own it.

  Tenant scoping is the caller's job: every public function here is reached
  after a tenant-scoped fetch established ownership at the controller,
  `Fountain.Accounts.Deletion` or a system sweep, exactly as
  when these lived on the server.
  """

  import Ecto.Query
  import Fountain.Conversations.ConversationServer, only: [whereis: 1, call_server: 2]

  require Logger

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Lifecycle, Sandbox}
  alias Fountain.Machines.Machine
  alias Fountain.Repo

  @doc """
  Terminate the conversation. If the GenServer is alive, it tears down the
  sprite. If not, just mark the DB rows terminated so the user can still
  clean up dead conversations after a server restart.

  An enclosing database transaction is refused before contacting the actor or
  updating rows, so teardown cannot escape a caller's rollback.

  Named `terminate_conversation` rather than `terminate`: taking `opts` for
  audit attribution (#545) would have made this `terminate/2`, which is the
  OTP callback on `ConversationServer`. Two different meanings under one name in one module was
  already a readability trap — `ConversationServer.terminate/1` (stop this
  tenant's conversation) and `terminate/2` (OTP teardown) are unrelated — so
  the client half gets the unambiguous name.
  """
  def terminate_conversation(conv_id, opts \\ []) do
    if Fountain.Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # ownership: callers established this conversation's tenant.
      do_terminate_conversation(conv_id, opts)
    end
  end

  defp do_terminate_conversation(conv_id, opts) do
    result =
      case whereis(conv_id) do
        nil ->
          # ownership: established by the caller before terminate_conversation/2.
          case Conversations._unsafe_get_conversation(conv_id) do
            nil ->
              {:error, :not_running}

            conv ->
              with {:ok, terminated} <-
                     Conversations.update_conversation(conv, %{status: "terminated"}) do
                retire_terminated_sandbox(terminated, opts)
              end
          end

        pid ->
          # `:audit_destroy` travels with the attribution (ADR 0058 stage 5b
          # review): the server forwards its whole opts list to
          # `_unsafe_destroy_machine/2`, so this narrowing was the only thing
          # keeping account deletion's suppression off the live-server path —
          # a machine whose conversation still had a server left one
          # `sandbox.destroyed` behind, and the delete then nilified its
          # `user_id`, which is the orphaned row this module refuses to write.
          call_server(
            pid,
            {:terminate_conv, Keyword.take(opts, [:actor, :request_ip, :audit_destroy, :destroy])}
          )
      end

    audit_lifecycle(conv_id, "conversation.terminated", result, opts)
    result
  end

  @doc """
  What a live server's terminate does to its machine once the detach has
  answered (ADR 0097): an explicit workspace's machine (`:detached`) stays for
  the conversations still on it, so nothing more is done to it; any other is
  destroyed (`destroy_after_terminate/2`). The conversation's own adapter has
  stopped and its config home is being removed either way.
  """
  @spec end_machine(String.t() | nil, :detached | :fenced | :already_terminal, keyword()) :: :ok
  def end_machine(_sandbox_id, :detached, _opts), do: :ok
  def end_machine(sandbox_id, _outcome, opts), do: destroy_after_terminate(sandbox_id, opts)

  @doc """
  Remove an ending conversation's config home from its machine, once its
  adapter has stopped (ADR 0097): `Fountain.Conversations.ConfigHome.remove/2`,
  best effort, from the live server's terminate path.

  Only on a machine that is awake (`ready`): an exec on a parked one would
  resume it to delete a directory. On an implicit workspace the destroy that
  follows removes the directory regardless; on an explicit one, whose machine
  stays, this is what keeps it from being left behind. A conversation ended
  while its explicit workspace's machine is parked leaves its home on the
  disk (the dead-server path, `release_kept/2`, has the same rule).

  `state` is the server's: its `handle`, `sandbox_id` and `conversation_id`.

  Run off the terminate path, in a supervised task, so a slow or idle
  machine never holds the terminate up; `remove_config_home_now/1` is the
  work itself.
  """
  @spec remove_config_home(map()) :: :ok
  def remove_config_home(%{handle: nil}), do: :ok
  def remove_config_home(%{sandbox_id: nil}), do: :ok

  def remove_config_home(%{handle: _, sandbox_id: _, conversation_id: _} = state) do
    target = Map.take(state, [:handle, :sandbox_id, :conversation_id])

    case Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
           remove_config_home_now(target)
         end) do
      {:ok, _pid} -> :ok
      _ -> :ok
    end
  end

  @doc false
  @spec remove_config_home_now(map()) :: :ok
  def remove_config_home_now(%{handle: nil}), do: :ok
  def remove_config_home_now(%{sandbox_id: nil}), do: :ok

  def remove_config_home_now(%{handle: handle, sandbox_id: sandbox_id, conversation_id: conv_id}) do
    # ownership: the conversation's own server, which established both rows
    # at init.
    with %Sandbox{status: "ready"} = sandbox <- Conversations._unsafe_get_sandbox(sandbox_id),
         true <- at_rest?(sandbox),
         # ownership: as above.
         %Conversation{} = conv <- Conversations._unsafe_get_conversation(conv_id) do
      Fountain.Conversations.ConfigHome.remove(handle, conv)
    else
      _ -> :ok
    end
  end

  @doc """
  Destroy the machine of a conversation that is ending, through its owner
  (ADR 0058 stage 5).

  `_unsafe_`: a bare `sandbox_id` and no tenant scoping here. Every caller
  established the conversation this machine belongs to first.

  One door for every destroy this tree asks for — both halves of terminate,
  and since stage 5b the forced teardowns (`reap_sandbox/2`,
  `Accounts.Deletion` and `Workers.SandboxReaper`'s expiry) — so the fence, the
  provider destroy, the terminal write and the `sandbox.destroyed` event are
  the same five steps whichever caller ran.

  **`:terminating_conversation_id` says whose binding the fence checks**, and
  it is required rather than defaulted, so every caller states it:

    * **the conversation's id**, from the dead-server path, where this fence is
      the first and only look at the machine. The fence locks that
      conversation and verifies it is still bound to this machine before
      fencing.
    * **`nil`**, from a live server that already ran `Machine.detach/2` and
      acted on its verdict. The protocol still fences — a repeat, which writes
      no second intent — but it does not check the binding a second time.
    * **`nil` again**, from every forced teardown. A tenant's machines during
      account deletion, an abandoned machine past its ceiling, a machine the
      provider has lost and an admin reap are all operations *on the machine*,
      not on one conversation, so an idle conversation still bound to the row
      does not stop them.

  The two reasons are deliberately different words, and different options.
  `:destroy_reason` is the machine's transition and what the
  `sandbox.destroyed` event says happened (`:terminated` unless the caller
  names another); `:reason` is what the fence's `sandbox.teardown_requested`
  event has always said, and changing that would rewrite a trail operators
  already read.

  `:provider` steers the protocol rather than describing the operation, and is
  forwarded untouched: it is `:already_gone` when the caller has already probed
  and been told the machine does not exist, which `ConversationServer`'s
  reattach and `Wake`'s retire of a replaced row both pass.
  `Fountain.Machines.Destroy` documents what it skips. Every other caller takes
  the default, `:destroy`.

  `:notify` is forwarded as the protocol takes it (ADR 0058 stage 8b).

  `:audit_destroy` is the machine event's own switch and is spelled apart from
  `:audit` on purpose. `terminate_conversation/2`'s `:audit` means the
  *conversation* event, and it arrives here in the same opts list on the
  dead-server path (`retire_terminated_sandbox/2` forwards its caller's opts
  whole); letting it silence the machine event too would mean every
  `delete_conversation/2` quietly stopped recording `sandbox.destroyed`.
  """
  @spec _unsafe_destroy_machine(String.t(), keyword()) ::
          {:ok, Fountain.Machines.Destroy.outcome()} | {:error, term()}
  def _unsafe_destroy_machine(sandbox_id, opts) do
    Machine.destroy(sandbox_id,
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :destroy_reason, :terminated),
      fence_reason: Keyword.get(opts, :reason, "conversation_terminated"),
      terminating_conversation_id: Keyword.fetch!(opts, :terminating_conversation_id),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Keyword.get(opts, :metadata),
      audit: Keyword.get(opts, :audit_destroy, true),
      provider: Keyword.get(opts, :provider, :destroy),
      notify: Keyword.get(opts, :notify)
    )
  end

  @doc """
  Retire the machine of an authorized, terminated conversation with no actor.

  The detach's fence checks that the conversation is still bound to the
  machine and closes it to admission; past it, the machine is destroyed at the
  provider and the row retired, through the owner's destroy protocol. **This is where it used to stop.**
  Before ADR 0058 stage 5 this path fenced the row, wrote it terminal and left
  the sprite standing for `Workers.SandboxReaper`'s next pass to notice and
  collect — up to an hour of a machine nobody could reach still billing. The
  reaper's terminal-row pass is still the safety net; it is no longer the
  mechanism.

  The caller owns the conversation lifecycle audit; the two machine events —
  the fence's intent and the destroy — carry the supplied attribution.
  """
  def retire_terminated_sandbox(%{sandbox_id: nil}, _opts), do: :ok

  def retire_terminated_sandbox(conv, opts) do
    # ownership: this sandbox belongs to the conversation authorized by the
    # caller; the detach rechecks the binding under its lock.
    #
    # The detach and the destroy, in one call to the owner (ADR 0058 stage
    # 8b): nothing has fenced this machine yet, so the detach's fence is the
    # first look at it, and with no adapter to close in between,
    # `destroy: true` lets the protocol finish it.
    #
    # `destroy: :background` (#2561) splits that call at the fence: the
    # decision commits here, and a machine that is going is destroyed in a task
    # after the caller has its answer. `destroy_after_terminate/2` says why
    # that is safe.
    background? = Keyword.get(opts, :destroy) == :background

    case Machine.detach(conv.sandbox_id,
           conversation_id: conv.id,
           destroy: not background?,
           actor: Keyword.get(opts, :actor, "self"),
           reason: Keyword.get(opts, :reason, "conversation_terminated"),
           destroy_reason: Keyword.get(opts, :destroy_reason, :terminated),
           request_ip: Keyword.get(opts, :request_ip),
           metadata: Keyword.get(opts, :metadata),
           audit: Keyword.get(opts, :audit_destroy, true)
         ) do
      {:ok, :fenced} when background? ->
        destroy_after_terminate(
          conv.sandbox_id,
          Keyword.put(opts, :terminating_conversation_id, nil)
        )

      # An explicit workspace keeps its machine (ADR 0097); what is left is
      # this conversation's own: its adapter and its config home.
      {:ok, :detached} ->
        release_kept(conv, conv.sandbox_id)

      {:ok, _outcome} ->
        Fountain.Workspaces.release_ended(conv.sandbox_id)

      {:error, _} = error ->
        error
    end
  end

  @doc """
  Destroy a fenced machine at the end of a conversation's termination: in the
  caller, or with `destroy: :background` in `opts` (#2561), in a task under
  `Fountain.TaskSupervisor`, so the request that ended the conversation does
  not wait on the provider (up to 16 s in prod).

  Safe to leave behind because the decision is already durable. The fence has
  stamped the row `destroying` before this runs, so no wake, attach or read
  reaches the machine (`Wake.maybe_reuse_sandbox/1` refuses it), the destroy
  continues from that stamp, and a destroy that fails or never runs, because
  its node went down, is finished by the reaper's sweep of fenced rows as any
  interrupted destroy is. A provider error is logged either way, as the server
  has always done; the conversation is terminated regardless.

  Account deletion and the other internal callers keep the default: they act
  on the machine being gone.
  """
  @spec destroy_after_terminate(String.t(), keyword()) :: :ok
  def destroy_after_terminate(sandbox_id, opts) do
    destroy = fn ->
      case _unsafe_destroy_machine(sandbox_id, opts) do
        # The machine is gone, so an implicit workspace whose conversation
        # has ended goes with it (ADR 0097). If the conversation's own
        # terminal write has not landed yet, that write releases it instead.
        {:ok, _outcome} -> Fountain.Workspaces.release_ended(sandbox_id)
        {:error, reason} -> Logger.warning("sandbox #{sandbox_id}: destroy: #{inspect(reason)}")
      end
    end

    if Keyword.get(opts, :destroy) == :background do
      {:ok, _pid} = Task.Supervisor.start_child(Fountain.TaskSupervisor, destroy)
    else
      destroy.()
    end

    :ok
  end

  @doc """
  What ending a conversation leaves to do on an explicit workspace's machine,
  which stays (ADR 0097), when no server of the conversation is alive to do
  it: stop the conversation's own adapter sessions (a detachable adapter
  outlives the server that started it; matched by its tag,
  `Fountain.Conversations.Identity.owned_sessions/3`) and remove its config
  home. In a supervised task, best effort, and only on an awake machine, for
  `remove_config_home/1`'s reason. Never another conversation's session: one
  that is untagged or tagged for someone else is left alone.
  """
  @spec release_kept(Conversation.t(), String.t() | nil) :: :ok
  def release_kept(_conv, nil), do: :ok

  def release_kept(%Conversation{} = conv, sandbox_id) do
    _ =
      Task.Supervisor.start_child(Fountain.TaskSupervisor, fn ->
        release_kept_now(conv, sandbox_id)
      end)

    :ok
  end

  @doc false
  @spec release_kept_now(Conversation.t(), String.t()) :: :ok
  def release_kept_now(%Conversation{} = conv, sandbox_id) do
    # ownership: the conversation the caller established; its own machine.
    with %Sandbox{status: "ready"} = sandbox <- Conversations._unsafe_get_sandbox(sandbox_id),
         true <- at_rest?(sandbox) do
      handle =
        Managoat.Sandbox.build_handle(
          Conversations.sandbox_provider_atom(sandbox),
          sandbox.machine_name
        )

      with {:ok, sessions} <- Managoat.Sandbox.list_sessions(handle) do
        handle
        |> Fountain.Conversations.Identity.owned_sessions(sessions, conv.id)
        |> Enum.each(&Fountain.Conversations.Connection.reap_session(handle, &1.id))
      end

      Fountain.Conversations.ConfigHome.remove(handle, conv)
    end

    :ok
  rescue
    error ->
      Logger.info("conv #{conv.id}: kept machine not tidied: #{Exception.message(error)}")
      :ok
  end

  # Awake and nobody operating on it: an exec under a co-tenant's park could
  # bring a paused machine back up behind a row that says `suspended` (E2B),
  # and under a destroy it has nothing to tidy (review of step 4a). Best
  # effort: a check, not a lock, and a home left behind is only disk.
  defp at_rest?(%Sandbox{} = sandbox),
    do: is_nil(sandbox.transition) and not Machine.busy?(sandbox)

  @doc """
  Support teardown of any tenant's sandbox, from the admin panel. Moved from
  `Fountain.Conversations._unsafe_reap_sandbox/1` in #2257 (#2255, tranche 2).

  A conversation with a live `ConversationServer` is terminated through the
  server, which destroys the sprite and ends the conversation — that is what
  stopping a runaway agent means. A sandbox with no live server (including a
  `suspended` one) is destroyed through the machine's owner
  (`_unsafe_destroy_machine/2`): the conversation stays resumable (next prompt
  gets a fresh sandbox, with the agent's memory lost — decisions/0017), and
  since ADR 0058 stage 5b the sprite goes in this call rather than on the
  reaper's next pass. The reaper's terminal-row pass is still the safety net
  for a destroy that could not finish.

  With `admin_user_id:` in `opts`, a successful reap records
  `admin.sandbox.reaped` here, outside any transaction (this function opens
  none) — folded in from the admin controller and `AdminLive.Sandboxes`,
  which used to record the identical event themselves (#2255 decision 4).
  A caller that passes no admin id records nothing here.
  """
  def reap_sandbox(sandbox_id, opts \\ []) do
    # ownership: sandbox_id is given by an admin surface behind require_admin
    # (AdminController.reap_sandbox/2, AdminLive.Sandboxes).
    result =
      case Conversations._unsafe_get_sandbox(sandbox_id) do
        nil ->
          {:error, :not_found}

        %Sandbox{status: s} when s in ["terminated", "failed"] ->
          {:ok, :already_terminal}

        sandbox ->
          sandbox = Fountain.Repo.preload(sandbox, :conversations)
          live_ids = Lifecycle.live_conversation_ids(sandbox)

          if live_ids == [] do
            release_machine(sandbox, opts)
          else
            # A reclaimed sandbox took the tenant's conversations down with it,
            # which is worth a row each — this is the one termination they did
            # not ask for. #551 covers the reaper that calls this.
            Enum.each(
              live_ids,
              &terminate_conversation(&1, actor: "system:sandbox_reaper")
            )

            {:ok, :terminated}
          end
      end

    audit_reap(sandbox_id, result, opts)
    result
  end

  # The arm with nobody home: no live `ConversationServer` anywhere in the
  # cluster, so there is no actor to ask and this is a machine operation with
  # no conversation behind it.
  #
  # It used to write the row `terminated` and stop, leaving the sprite for
  # `Workers.SandboxReaper`'s pass over terminal rows — the same up-to-an-hour
  # gap stage 5a closed on the dead-server terminate. Now it goes through the
  # machine's owner, so the provider machine dies in this call and
  # `sandbox.destroyed` records it (ADR 0058 stage 5b).
  #
  # `terminating_conversation_id: nil`, and that is the point of the reap: an
  # admin stopping a runaway machine is an operation on the machine, and an
  # idle conversation still bound to the row does not stop it.
  #
  # The outcome word stays `:released` whatever the protocol answers. It is the
  # admin surfaces' vocabulary and it lands in
  # `admin.sandbox.reaped`'s metadata; a machine somebody else had already
  # stopped was reported as released before this stage too, because the old
  # write was an unconditional `update_sandbox/2`.
  #
  # ownership: `sandbox` came from the scoped read in `reap_sandbox/2` above,
  # whose own caller is an admin surface.
  defp release_machine(%Sandbox{} = sandbox, opts) do
    case _unsafe_destroy_machine(sandbox.id,
           actor: reap_actor(opts),
           destroy_reason: :admin_reap,
           reason: "reaped",
           request_ip: Keyword.get(opts, :request_ip),
           terminating_conversation_id: nil
         ) do
      {:ok, _outcome} -> {:ok, :released}
      {:error, _} = error -> error
    end
  end

  # `admin:<id>` so both machine events fold it to the plain `admin` ADR 0013
  # allows (`Lifecycle.teardown_actor/1`); the id itself is reserved for
  # `account.deleted`, and `admin.sandbox.reaped` already carries it.
  # A caller that identifies no admin is the reaper's own work.
  defp reap_actor(opts) do
    case Keyword.get(opts, :admin_user_id) do
      nil -> "system:sandbox_reaper"
      admin_user_id -> "admin:#{admin_user_id}"
    end
  end

  # Only on success, and only when the caller identified an admin. A failed
  # reap changed nothing, per #2255 decision 4.
  defp audit_reap(sandbox_id, {:ok, outcome}, opts) do
    case Keyword.get(opts, :admin_user_id) do
      nil ->
        :ok

      admin_user_id ->
        Fountain.Audit.record_admin(%{
          actor_user_id: admin_user_id,
          resource_type: "sandbox",
          resource_id: sandbox_id,
          event_type: "admin.sandbox.reaped",
          metadata: %{"sandbox_id" => sandbox_id, "outcome" => to_string(outcome)}
        })

        :ok
    end
  end

  defp audit_reap(_sandbox_id, _result, _opts), do: :ok

  @doc """
  Finish an actor's termination only while the conversation is still bound to
  its sandbox. The binding check and status write are one database statement,
  so a reassignment during provider cleanup cannot terminate the new binding.

  The actor owns both IDs. This is internal lifecycle bookkeeping; the public
  `terminate_conversation/2` above records the action's audit once after a
  successful reply. A missing or moved conversation returns a refusal.
  """
  def _unsafe_finish_conversation_termination(conversation_id, sandbox_id) do
    query =
      from(c in Conversation,
        where: c.id == ^conversation_id and c.sandbox_id == ^sandbox_id,
        select: c
      )

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(query, set: [status: "terminated", updated_at: now]) do
      {1, [conv]} ->
        Conversations.broadcast_sidebar_update(conv.user_id)
        # An implicit workspace ends with its conversation (ADR 0097), once
        # its machine has gone too; a destroy still running releases it when
        # it finishes (`destroy_after_terminate/2`).
        Fountain.Workspaces.release_ended(sandbox_id)
        {:ok, conv}

      {0, _} ->
        {:error, :sandbox_unavailable}
    end
  end

  # Records a lifecycle action against the conversation's owner.
  #
  # Only on success: an attempt against a conversation that is not running
  # changed nothing, and a trail that logged it would show terminations that
  # never happened.
  #
  # `audit: false` suppresses the row where a caller's own higher-level event
  # already describes the action — `delete_conversation/2` and account
  # deletion both cascade through `terminate/2`, and neither is a second thing
  # the user asked for.
  #
  # The `_unsafe_` read is legitimate here under the rule in CLAUDE.md: these
  # are GenServer client functions, reached only after a tenant-scoped fetch
  # established ownership at the controller or LiveView, and the read exists
  # solely to attribute the event to that same owner.
  def audit_lifecycle(conv_id, action, result, opts, metadata \\ %{}) do
    if Keyword.get(opts, :audit, true) and result == :ok do
      case Conversations._unsafe_get_conversation(conv_id) do
        nil ->
          :ok

        conv ->
          Fountain.Audit.record(%{
            user_id: conv.user_id,
            action: action,
            resource_type: "conversation",
            resource_id: conv_id,
            actor: Keyword.get(opts, :actor, "self"),
            request_ip: Keyword.get(opts, :request_ip),
            metadata: metadata
          })
      end
    end

    :ok
  end
end
