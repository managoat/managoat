defmodule Fountain.Machines.Binding do
  @moduledoc """
  One binding protocol for one machine (ADR 0058, stage 8b).

  A conversation is a binding of an agent to a machine (#805), and the owner
  of the machine is the one that makes and unmakes bindings. Since persistent
  homes were removed (#2676) every machine is built for one conversation and
  the binding is made when the launch reserves both rows
  (`Launch.start_conversation/2`), so the protocol here is the other half:
  `detach` ends it. `Fountain.Machines.Machine.detach/2` is the door. The
  record of the skills the disk carries used to be here too; since config
  homes (ADR 0097 step 1) it is the conversation's
  (`Fountain.Conversations.Skills`).

  ## Detach

  `detach/2` ends the conversation's binding. **Whether the machine goes with
  it is the workspace's to decide** (ADR 0097, which brings back 0058's keep
  rule one level up): an implicit workspace is its one conversation's, so its
  machine goes; an explicit one keeps its machine for the conversations still
  on it, or for the next one, until the workspace is deleted. There is no
  refcount: the kind of workspace, fixed at create, is the whole decision.

  On an explicit workspace the detach writes nothing on the machine. It locks
  the ending conversation under the machine's lock, checks it is still bound
  there and that its caller is still waiting, and answers `{:ok, :detached}`;
  the caller stops that conversation's adapter and removes its config home.
  It does not refuse a live lease: another conversation's operation on the
  machine (a wake, a rebuild that runs for minutes) is nothing a conversation
  leaving it has to wait for.

  On an implicit workspace it is `Lifecycle.fence_sandbox_for_teardown/2`
  with a `terminating_conversation_id`, under the lock, with two things a
  plain fence does not do:

    * it **refuses a live lease** (`:machine_busy`, waited out for
      `busy_wait_ms/0` and then `:sandbox_unavailable` at the door). `main`
      fenced a machine underneath a park in flight and then found the destroy
      refused, which terminated the conversation and left a fenced row for
      the hourly sweep to finish. Under the owner, a terminate that meets an
      operation waits for it (in the mailbox, with the gate on) or is told to
      come back (with it off), and nothing is written until it does.
    * it **carries a deadline**: a fence written for a caller that has been
      told 503 closes a machine to admission with a server still serving on
      it.

  `{:ok, :fenced}` is the fence committed and the machine this caller's to finish — a live
  `ConversationServer` closes its adapter and then asks `Machine.destroy/2`
  with `terminating_conversation_id: nil`, exactly as it did on `main`, so a
  rebind landing between the two cannot make the second fence refuse and
  leave the machine fenced and billing (`termination_actor_fence_test.exs`
  pins that order). A
  caller with no adapter to close passes `destroy: true` and the protocol
  runs `Fountain.Machines.Destroy` itself, answering `{:ok, :destroyed}`.

  ## Vocabulary

  `detach/2` answers the fence's words. Beside them are
  `:machine_busy` (a live lease, waited out), `:detach_expired` (a caller that
  left) and `:transaction_open` (the caller's bug), which the door translates.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Conversations
  alias Fountain.Conversations.{Lifecycle, Sandbox}
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  require Logger

  # How long a *detach* waits for a live lease to clear before it is refused.
  # `Destroy`'s number, for `Destroy`'s reason: the caller is a request (a
  # `DELETE` on the dead-server path, a `ConversationServer`'s `handle_call` on
  # the live one) and a wait that outlives it answers nobody.
  #
  # **With the gate on, this wait is the owner's mailbox**, not just the
  # caller's: the detach runs inside `Machine`'s `handle_call`, so everything
  # queued behind it waits too. Against a real operation that is the point —
  # the queue is how two callers on one machine are serialized — but against a
  # lease a crashed operation left behind it once cost five seconds of the
  # owner (round 1, protocol review: `waited ms: 4809`). Since ADR 0072 a lease
  # whose holder has died is not live, so that wait no longer happens.
  @busy_wait_ms 5_000

  # How often the wait re-asks. Each ask is the whole fence transaction.
  @poll_ms 250

  @terminal_statuses ~w(terminated failed)

  @typedoc """
  What a detach did: `:detached`, the binding ended and the machine kept (an
  explicit workspace); `:fenced`, the machine fenced for the caller to
  destroy; `:destroyed`; or `:already_terminal`.
  """
  @type detach_outcome :: :detached | :fenced | :destroyed | :already_terminal

  # ── detach ────────────────────────────────────────────────────────────────

  @doc """
  End `opts[:conversation_id]`'s binding to the machine behind `sandbox_id`.

  Options:

    * `:conversation_id` (required) — the conversation that is ending.
    * `:destroy` — `true` runs `Fountain.Machines.Destroy` in the same call
      once the fence has committed and answers `{:ok, :destroyed}`; `false`
      (the default) answers `{:ok, :fenced}` and leaves the destroy
      to the caller, which is what a live server with an adapter to close
      first needs. Not read on an explicit workspace, whose machine stays.
    * `:actor`, `:reason`, `:fence_reason`, `:destroy_reason`, `:request_ip`,
      `:metadata`, `:audit` — attribution, as `Termination._unsafe_destroy_machine/2`
      takes them. `:reason` is the fence's own event string
      (`"conversation_terminated"` by default); `:destroy_reason` the atom the
      destroy stamps and records (`:terminated` by default).
    * `:deadline` — a `DateTime` on the database clock after which the caller
      is no longer waiting. Set by `Machine.detach/2` on the in-owner path.
    * `:busy_wait_ms` — the bound above. Tests shorten it; no call site does.
  """
  @spec detach(Ecto.UUID.t(), keyword()) :: {:ok, detach_outcome()} | {:error, term()}
  def detach(sandbox_id, opts) when is_binary(sandbox_id) and is_list(opts) do
    conversation_id = Keyword.fetch!(opts, :conversation_id)

    if Repo.in_transaction?() do
      {:error, :transaction_open}
    else
      deadline =
        System.monotonic_time(:millisecond) + Keyword.get(opts, :busy_wait_ms, @busy_wait_ms)

      fence_then_finish(sandbox_id, conversation_id, opts, deadline)
    end
  end

  @doc """
  How long `detach/2` waits for a live lease to clear before refusing.

  Public so `machine_bounds_test.exs` can pin it against the owner's call
  timeout above it.
  """
  @spec busy_wait_ms() :: pos_integer()
  def busy_wait_ms, do: @busy_wait_ms

  # The fence with the ending conversation is the decision; `:machine_busy` is
  # the one refusal waited out, because a park or a resume settles in seconds
  # and the terminate wants its answer rather than a 503.
  defp fence_then_finish(sandbox_id, conversation_id, opts, wait_until) do
    case Conversations._unsafe_get_sandbox(sandbox_id) do
      nil ->
        {:error, :sandbox_unavailable}

      %Sandbox{status: status} when status in @terminal_statuses ->
        {:ok, :already_terminal}

      %Sandbox{} = sandbox ->
        case Fountain.Workspaces.machine_kind(sandbox) do
          :explicit -> keep(sandbox, conversation_id, opts)
          :implicit -> fence_or_wait(sandbox, conversation_id, opts, wait_until)
        end
    end
  end

  # The binding ends and the machine stays (an explicit workspace). The
  # binding is checked under the machine's lock, in the lock order admission
  # takes (advisory, then the conversation), so a conversation already moved
  # to another machine is refused rather than answered for; nothing is
  # written.
  defp keep(%Sandbox{} = sandbox, conversation_id, opts) do
    Conversations.with_sandbox_lock(sandbox.id, fn ->
      bound? =
        Repo.one(
          from(c in Fountain.Conversations.Conversation,
            where:
              c.id == ^conversation_id and c.sandbox_id == ^sandbox.id and
                c.user_id == ^sandbox.user_id,
            select: c.id,
            lock: "FOR UPDATE"
          )
        ) != nil

      cond do
        not bound? -> {:error, :sandbox_unavailable}
        expired?(Keyword.get(opts, :deadline), Machine.db_now()) -> {:error, :detach_expired}
        true -> {:ok, :detached}
      end
    end)
    |> case do
      {:ok, :detached} -> {:ok, :detached}
      {:error, _} = error -> error
    end
  end

  defp fence_or_wait(%Sandbox{} = sandbox, conversation_id, opts, wait_until) do
    sandbox_id = sandbox.id

    case Lifecycle.fence_sandbox_for_teardown(sandbox, fence_opts(conversation_id, opts)) do
      {:ok, %Sandbox{status: status}} when status in @terminal_statuses ->
        {:ok, :already_terminal}

      {:ok, %Sandbox{}} ->
        finish(sandbox_id, opts)

      {:error, :machine_busy} ->
        if System.monotonic_time(:millisecond) + @poll_ms < wait_until do
          Process.sleep(@poll_ms)
          fence_then_finish(sandbox_id, conversation_id, opts, wait_until)
        else
          Logger.warning("machine #{sandbox_id}: detach refused, an owner holds the lease")
          {:error, :machine_busy}
        end

      {:error, _} = error ->
        error
    end
  end

  defp fence_opts(conversation_id, opts) do
    [
      terminating_conversation_id: conversation_id,
      refuse_busy: true,
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :reason, "conversation_terminated"),
      # The row's word, which is the destroy vocabulary and not this event's.
      # The same default `destroy_opts/1` below hands the protocol, so a detach
      # that fences and then destroys stamps once and says one thing — and an
      # abandoned one hands `SandboxReaper`'s driver the reason the caller
      # actually asked for rather than a generic teardown.
      transition_reason: Keyword.get(opts, :destroy_reason, :terminated)
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
    |> put_unless_nil(:deadline, Keyword.get(opts, :deadline))
  end

  # Fenced, and the machine is going. With `destroy: true` this call finishes
  # it, and the protocol does not fence again: the fence above stamped
  # `transition: "destroying"` (stage 9a), so `Destroy.run/2` continues from
  # the stamp. Before 9a it repeated the fence, which wrote no second intent
  # and — with the `terminating_conversation_id: nil` below — could not reopen
  # the decision just made either. The `nil` stays for that reason and for the
  # one `destroy_opts/1` gives.
  defp finish(sandbox_id, opts) do
    if Keyword.get(opts, :destroy, false) do
      case Destroy.run(sandbox_id, destroy_opts(opts)) do
        {:ok, :destroyed} -> {:ok, :destroyed}
        {:ok, :already_terminal} -> {:ok, :already_terminal}
        {:error, :superseded} -> {:ok, :already_terminal}
        {:error, _} = error -> error
      end
    else
      {:ok, :fenced}
    end
  end

  defp destroy_opts(opts) do
    [
      actor: Keyword.get(opts, :actor, "self"),
      reason: Keyword.get(opts, :destroy_reason, :terminated),
      fence_reason: Keyword.get(opts, :reason, "conversation_terminated"),
      terminating_conversation_id: nil,
      audit: Keyword.get(opts, :audit, true)
    ]
    |> put_unless_nil(:request_ip, Keyword.get(opts, :request_ip))
    |> put_unless_nil(:metadata, Keyword.get(opts, :metadata))
  end

  defp put_unless_nil(opts, _key, nil), do: opts
  defp put_unless_nil(opts, key, value), do: Keyword.put(opts, key, value)

  @doc """
  Clear an abandoned stamp on `sandbox_id` for a server about to start on it:
  the write `Conversations.register_server/2` makes, moved here in stage 9b so
  that the owner's namespace is the only code that writes the `sandboxes` row.

  The registration door decides under the machine's advisory lock, on a row
  it read `FOR UPDATE`, whether the machine may be woken at all — a live lease
  refuses, a `destroying` stamp refuses — and calls this inside that
  transaction. It is the door's decision and this is its write.

  Returns the number of rows written: `1`, or `0` for a row that vanished.
  """
  @spec clear_abandoned_transition(Ecto.UUID.t()) :: non_neg_integer()
  def clear_abandoned_transition(sandbox_id) when is_binary(sandbox_id) do
    # On the machine's workspace, and copied onto the sandbox (ADR 0097, step
    # 3b), in the registration's transaction.
    Lease.put_transition!(sandbox_id, nil, nil)
  end

  @doc """
  Whether a conversation other than `conv_id` still holds `sandbox_id` — one
  that is not `terminated` or `failed`. Status only, no clock. No caller in
  `lib/` since #2676; it goes when `Occupancy` is thinned.
  """
  @spec held_by_other?(Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def held_by_other?(sandbox_id, conv_id) when is_binary(sandbox_id) and is_binary(conv_id) do
    sandbox_id |> Occupancy.bindings() |> Occupancy.held_by_other?(conv_id)
  end

  # ── the deadline ──────────────────────────────────────────────────────────

  @doc false
  def expired?(nil, _now), do: false

  def expired?(%DateTime{} = deadline, %DateTime{} = now),
    do: DateTime.compare(now, deadline) == :gt
end
