defmodule Fountain.Machines.BindingTest do
  @moduledoc """
  The binding protocol (ADR 0058 stage 8b): attach, detach, the skills record, the
  turns the owner ends, the owner-only `machine_gone`, the early takeover of a
  lease whose node is gone, and the deadline a late resume now carries.

  `async: false`: the protocol runs inside an owner process, and the race cases
  use `unboxed_run`.

  **What `reject(&Managoat.Sandbox.destroy/1)` is worth here, and what it is
  not** (round 1). `Destroy.destroy_at_provider/2` rescues a raising adapter
  and finalizes the row, and Mimic's `UnexpectedCallError` is a raise — so a
  provider call this file rejects is swallowed into a logged failure rather
  than failing the test. Every `reject` below is therefore belt to an
  assertion's braces: the outcome (`{:ok, :kept}`) or the row (`status ==
  "ready"`) is what actually catches a provider call that should not have
  happened. Where "no round trip" is the whole claim, the pin is a stub that
  reports and a `refute_received`, not a `reject`. Same shape inside a `stub`:
  an assertion that fails there surfaces as the protocol's own error tuple, so
  the outer assertion is the one doing the work.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{LogEvent, Sandbox, Turn}
  alias Fountain.Machines.Admission
  alias Fountain.Machines.Binding
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park

  setup do
    stub(Managoat.Sandbox.Sprites, :exec, fn _, "true", [], _ -> {:ok, "", 0} end)
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude", environment_id: env.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: env.id,
        mode: "ephemeral",
        status: "ready"
      )

    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, env: env, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp detach_opts(ctx, overrides \\ []) do
    Keyword.merge([conversation_id: ctx.conv.id, actor: "self", destroy: true], overrides)
  end

  defp stamp(ctx, sets) do
    put_lease(ctx.sandbox.id, sets)
  end

  defp quietly(fun), do: capture_log(fun)

  defp stage_reasons(stage, state, reason) do
    Repo.all(from e in LogEvent, where: e.stage == ^stage and e.state == ^state)
    |> Enum.filter(fn e -> Jason.decode!(e.data)["reason"] == reason end)
  end

  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end

  # ── detach ────────────────────────────────────────────────────────────────

  describe "detach" do
    test "the last detach on an ephemeral machine destroys it", ctx do
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert [_] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.destroyed")
    end

    test "without destroy: true the fence commits and the machine is the caller's to finish",
         ctx do
      reject(&Managoat.Sandbox.destroy/1)

      assert {:ok, :fenced} = Machine.detach(ctx.sandbox.id, detach_opts(ctx, destroy: false))

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
    end

    test "the fence carries the caller's destroy reason as the row's word", ctx do
      # ADR 0058 stage 9a: an owner that dies between this fence and its own
      # stamp leaves the fence's `transition_reason` for `SandboxReaper`'s
      # driver to record. A `fence_opts/2` that dropped `:destroy_reason` would
      # have the fence fall back to `teardown`. `:replaced`, not the default
      # `:terminated`, so a hardcoded default fails too. Recorded inside the
      # stub, asserted outside it (the protocol rescues a raise).
      test = self()

      expect(Fountain.Conversations.Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
        send(test, {:fence_opts, opts})

        Mimic.call_original(Fountain.Conversations.Lifecycle, :fence_sandbox_for_teardown, [
          sandbox,
          opts
        ])
      end)

      reject(&Managoat.Sandbox.destroy/1)

      assert {:ok, :fenced} =
               Machine.detach(
                 ctx.sandbox.id,
                 detach_opts(ctx, destroy: false, destroy_reason: :replaced)
               )

      assert_received {:fence_opts, opts}
      assert opts[:transition_reason] == :replaced
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition_reason == "replaced"
    end

    test "refuses a live lease after waiting, and writes no fence", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      started = System.monotonic_time(:millisecond)

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.detach(ctx.sandbox.id, detach_opts(ctx, busy_wait_ms: 600))
      end)

      waited = System.monotonic_time(:millisecond) - started
      assert waited >= 250, "the wait gave up without waiting at all"
      assert waited < 5_000
      refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "the fence's own deadline refuses on its own, and writes no fence", ctx do
      # The detach's half of the pair above, reached through the protocol so
      # the owner's pre-check is not in the way. `refuse_busy_or_expired/2`
      # reads one clock after the locked row and rolls the fence back.
      past = DateTime.add(DateTime.utc_now(), -5, :second)

      assert {:error, :detach_expired} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, deadline: past)

      fenced = Fountain.Machines.Lease.get(ctx.sandbox.id)
      refute fenced.transition == "destroying", "an expired detach fenced the machine"
      assert fenced.status == "ready"

      # The positive control: the same detach inside its deadline decides.
      future = DateTime.add(DateTime.utc_now(), 60, :second)

      assert {:ok, :fenced} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, deadline: future)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
    end

    test "a detach whose caller has given up is refused, not run late", ctx do
      # A fence written for a caller told 503 would close the machine to
      # admission with this server still serving on it.
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      reject(&Managoat.Sandbox.destroy/1)

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)
      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            send(
              test,
              {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
            )
          end)
        end)

      assert_receive :suspending, 2_000

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.detach(ctx.sandbox.id, detach_opts(ctx, detach_timeout_ms: 200))
      end)

      assert_receive {:park, {:ok, :parked}}, 5_000
      Task.await(park)
      assert %Fountain.Machines.Occupancy{} = Machine.who_is_here(ctx.sandbox.id)

      refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying",
             "the owner fenced a machine for nobody"

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"
    end

    test "detach and park, in both orders", ctx do
      # Park first: the park holds the lease at the provider, the detach
      # waits it out and is refused, nothing is fenced.
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            Park.run(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)
          end)
        end)

      assert_receive :suspending, 2_000

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.detach(ctx.sandbox.id, detach_opts(ctx, busy_wait_ms: 300))
      end)

      Task.await(park)
      refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"

      # Detach first: the machine is gone, and the park that follows finds it.
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} = Machine.detach(ctx.sandbox.id, detach_opts(ctx))
      end)

      quietly(fn ->
        assert {:ok, :already_terminal} =
                 Park.run(ctx.sandbox.id, actor: "system:sandbox_reaper", reason: :idle)
      end)
    end
  end

  # ── attach and detach on real connections (the lock) ──────────────────────

  # The turn's status as the `parking` stamp's own statement completes — read
  # on the same connection, right behind it.
  def report_stamp(_event, _measurements, %{query: query, params: params}, {test, turn_id}) do
    if String.contains?(query, "UPDATE \"workspaces\"") and "parking" in params do
      send(test, {:stamped, Repo.get!(Turn, turn_id).status})
    end
  end

  # ── the Codex auth binding ────────────────────────────────────────────────

  # ── the owner ends the turns it operates over ─────────────────────────────

  describe "the turns the owner ends" do
    setup ctx do
      running = fn conv ->
        conv = conv |> Ecto.Changeset.change(status: "running") |> Repo.update!()

        {conv,
         insert_turn(conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})}
      end

      {conv, turn} = running.(ctx.conv)
      cotenant = insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: ctx.sandbox)
      {cotenant, cotenant_turn} = running.(cotenant)
      %{conv: conv, turn: turn, cotenant: cotenant, cotenant_turn: cotenant_turn}
    end

    test "a destroy ends every running turn bound to the machine, and leaves a rebound one",
         ctx do
      replacement = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      rebound =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: replacement,
          status: "running"
        )

      rebound_turn =
        insert_turn(rebound, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      quietly(fn ->
        assert {:ok, :destroyed} =
                 Machine.destroy(ctx.sandbox.id,
                   actor: "system:sandbox_reaper",
                   reason: :reclaimed
                 )
      end)

      for turn <- [ctx.turn, ctx.cotenant_turn] do
        assert %Turn{status: "interrupted", orphaned_at: %DateTime{}} = Repo.reload!(turn)
      end

      assert Repo.reload!(ctx.conv).status == "idle"
      assert Repo.reload!(ctx.cotenant).status == "idle"
      assert Repo.reload!(rebound_turn).status == "running"

      assert [_, _] = stage_reasons("reattach", "interrupted", "machine_destroyed")

      assert [_, _] =
               Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")

      # And the recovering actor's later write finds the turn already ended.
      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: ctx.sandbox.id)
    end

    # #3001: the ceiling ends every running turn on an explicit workspace's
    # machine at once, the co-tenant's included, and each gets its own
    # `conversation.turn.orphaned` row naming the operation's actor (an admin
    # reduced to "admin", as a teardown's actor is) and the reason.
    test "a ceiling park audits every turn it ends, with the operation's actor", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      explicit_workspace!(ctx.sandbox)

      quietly(fn ->
        assert {:ok, :parked} =
                 Park.run(ctx.sandbox.id,
                   reason: :max_lifetime,
                   actor: "admin:#{ctx.user.id}",
                   requesting_conversation_id: ctx.conv.id
                 )
      end)

      for turn <- [ctx.turn, ctx.cotenant_turn] do
        assert %Turn{status: "interrupted"} = Repo.reload!(turn)
      end

      rows = Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")

      assert rows |> Enum.map(& &1.resource_id) |> Enum.sort() ==
               Enum.sort([ctx.turn.id, ctx.cotenant_turn.id])

      for row <- rows do
        assert row.actor == "admin"
        assert row.metadata["reason"] == "machine_parked"
        assert row.metadata["conversation_id"] in [ctx.conv.id, ctx.cotenant.id]
      end
    end

    test "the replacement's destroy ends the predecessor's turn; the successor's write finds it ended",
         ctx do
      # Counterexample 3's real path: a wake builds a fresh machine and
      # retires the old row through the owner with `provider: :already_gone`.
      replacement = insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "ready")

      # `provider: :already_gone` must cost no provider round trip, and that is
      # the whole claim here — so it is pinned by a stub that reports rather
      # than by `reject/1`, which this protocol rescues (see the moduledoc).
      test_pid = self()

      stub(Managoat.Sandbox, :destroy, fn _handle ->
        send(test_pid, :destroyed_at_provider)
        :ok
      end)

      quietly(fn ->
        assert {:ok, :destroyed} =
                 Fountain.Conversations.Termination._unsafe_destroy_machine(ctx.sandbox.id,
                   actor: "system:wake",
                   destroy_reason: :replaced,
                   reason: "sandbox_replaced",
                   terminating_conversation_id: nil,
                   provider: :already_gone
                 )
      end)

      refute_received :destroyed_at_provider

      assert Repo.reload!(ctx.turn).status == "interrupted"
      {:ok, _} = Conversations.update_conversation(ctx.conv, %{sandbox_id: replacement.id})

      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "attach_failed"}, sandbox_id: replacement.id)
    end

    test "a ceiling park ends the requester's own turn before the stamp; an idle park refuses on it",
         ctx do
      # Alone on the machine: a co-tenant active inside the idle window is a
      # different veto (`busy_elsewhere?`), and not the one under test.
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)
      Repo.delete!(ctx.cotenant)
      # The ceiling parks only an explicit workspace's machine (ADR 0097).
      explicit_workspace!(ctx.sandbox)
      opts = [actor: "system:conversation_server", requesting_conversation_id: ctx.conv.id]
      turn_id = ctx.turn.id

      # The instant the `parking` stamp lands, the turn is already terminal:
      # no reader ever sees `running` on a `parking` row. Observed on the
      # stamp's own statement — a plant that cuts the turn right *after* the
      # stamp still has it ended by the time the provider is asked, which is
      # why the suspend stub below is not enough on its own.
      stub(Managoat.Sandbox, :suspend, fn _ ->
        assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "parking"
        assert Repo.get!(Turn, turn_id).status == "interrupted"
        :ok
      end)

      test = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:fountain, :repo, :query],
        &__MODULE__.report_stamp/4,
        {test, turn_id}
      )

      try do
        quietly(fn ->
          assert {:error, :machine_occupied} = Park.run(ctx.sandbox.id, [reason: :idle] ++ opts)
          assert Repo.reload!(ctx.turn).status == "running"
          assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
        end)
      after
        :telemetry.detach(handler)
      end

      assert_received {:stamped, "interrupted"}

      assert %Turn{status: "interrupted", orphaned_at: %DateTime{}} = Repo.reload!(ctx.turn)
      assert Repo.reload!(ctx.conv).status == "idle"
      assert [_] = stage_reasons("reattach", "interrupted", "machine_parked")
    end

    test "the server ending the same turn is a :noop in either order, with one event", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)
      Repo.delete!(ctx.cotenant)
      explicit_workspace!(ctx.sandbox)
      opts = [actor: "system:conversation_server", requesting_conversation_id: ctx.conv.id]

      orphaned = fn ->
        Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")
      end

      # Owner first: the park ended it; the server's own ending on its way out
      # writes nothing and records nothing.
      quietly(fn ->
        assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
      end)

      assert [_] = orphaned.()

      assert :noop = Machine.end_turn(ctx.turn, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      assert :noop =
               Machine.end_turn(ctx.turn, {:orphan, "server_terminated_normally"},
                 sandbox_id: ctx.sandbox.id
               )

      assert [_] = orphaned.()
      assert Repo.reload!(ctx.turn).status == "interrupted"

      # Server first: the turn is already terminal when the park cuts, and the
      # park's ending is not this owner's — nothing written, nothing recorded.
      stamp(ctx, status: "ready")
      {:ok, _} = Conversations.update_conversation(Repo.reload!(ctx.conv), %{status: "running"})

      second =
        insert_turn(ctx.conv, %{status: "running", prompt: "go", started_at: DateTime.utc_now()})

      assert {:ok, %Turn{status: "interrupted"}} =
               Machine.end_turn(second, :mark_interrupted, sandbox_id: ctx.sandbox.id)

      quietly(fn ->
        assert {:ok, :parked} = Park.run(ctx.sandbox.id, [reason: :max_lifetime] ++ opts)
      end)

      assert Repo.reload!(second).status == "interrupted"
      assert is_nil(Repo.reload!(second).orphaned_at)
      assert [_] = orphaned.()
    end

    test "a park over a turn nothing is driving leaves it standing (stage 6b's rule)", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      Repo.delete_all(from t in Turn, where: t.conversation_id == ^ctx.cotenant.id)

      quietly(fn ->
        assert {:ok, :parked} =
                 Park.run(ctx.sandbox.id, actor: "system:sandbox_reaper", reason: :idle)
      end)

      assert Repo.reload!(ctx.turn).status == "running"
      assert Repo.reload!(ctx.conv).status == "running"
    end

    test "end_turns_on/3 is best effort per turn, and narrows to one conversation", ctx do
      # A turn already ended by its actor is not this owner's to end, and the
      # next one is still ended; `:only` leaves every other conversation alone.
      assert {:ok, _} =
               Machine.end_turn(ctx.cotenant_turn, {:finish, "completed", []},
                 sandbox_id: ctx.sandbox.id
               )

      quietly(fn ->
        assert :ok =
                 Admission.end_turns_on(ctx.sandbox.id, "machine_destroyed",
                   only: ctx.cotenant.id,
                   actor: "system:sandbox_reaper"
                 )
      end)

      assert Repo.reload!(ctx.turn).status == "running"

      quietly(fn ->
        assert :ok =
                 Admission.end_turns_on(ctx.sandbox.id, "machine_destroyed",
                   actor: "system:sandbox_reaper"
                 )
      end)

      assert Repo.reload!(ctx.turn).status == "interrupted"
      assert Repo.reload!(ctx.cotenant_turn).status == "completed"
    end
  end

  # ── a message shape this release has no clause for ────────────────────────

  describe "an owner asked something it has no clause for" do
    test "refuses the caller and keeps its mailbox, on all three callbacks", ctx do
      # ADR 0058 rule 4, from the other side. An old owner meeting a new
      # release's message dies with everything queued behind it — which is what
      # 8b's own three new shapes do to an owner on the previous release, and
      # why the mixed-version note says so. From here on, the cost of that
      # rollout is one 503 to one caller.
      #
      # All three callbacks, because all three had the hole: a missing call
      # clause raises, a missing cast clause is `{:bad_cast, ..}` from
      # `GenServer`'s generated one, and defining any `handle_info/2` replaces
      # the default that would have logged and ignored — so a stray `:DOWN` or
      # a late reply took the owner down too.
      # A payload that would be unmistakable in a log line if the redaction
      # leaked: empty values prove nothing (round 3, behaviour review drove the
      # refutation with a string of its own for the same reason).
      secret = "sk-live-do-not-log-me-9f3c"

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      sandbox_id = ctx.sandbox.id

      call_log =
        capture_log(fn ->
          assert {:error, :sandbox_unavailable} =
                   GenServer.call(owner, {:a_verb_from_a_later_release, %{token: secret}, nil})
        end)

      # The log has to name what arrived and on which machine, or this
      # clause is silence with a return value (the lead's condition). The
      # call returning at all is the proof the owner survived, so there is no
      # `Process.alive?` here; the barrier calls below are the same proof for
      # the two asynchronous cases.
      assert call_log =~ "no handle_call clause for :a_verb_from_a_later_release/3"
      assert call_log =~ Machine.owner_key(sandbox_id)

      cast_log =
        capture_log(fn ->
          GenServer.cast(owner, {:a_cast_from_a_later_release, %{token: secret}})
          # The cast is asynchronous; this call is the barrier that forces
          # the owner to have handled it.
          assert %Fountain.Machines.Occupancy{} =
                   GenServer.call(owner, {:who_is_here, ctx.sandbox.id})
        end)

      assert cast_log =~ "no handle_cast clause for :a_cast_from_a_later_release/2"
      assert cast_log =~ Machine.owner_key(sandbox_id)

      info_log =
        capture_log(fn ->
          send(owner, {:DOWN, make_ref(), :process, self(), :normal})

          assert %Fountain.Machines.Occupancy{} =
                   GenServer.call(owner, {:who_is_here, ctx.sandbox.id})
        end)

      assert info_log =~ "unexpected message :DOWN/5"
      assert info_log =~ Machine.owner_key(sandbox_id)

      # **And a message that is not a tuple**, which is where the redaction
      # claim used to be false: the fallback inspected the whole term, so a
      # map or a binary went into the log entire. The type, and nothing else.
      map_log =
        capture_log(fn ->
          send(owner, %{token: secret})

          assert %Fountain.Machines.Occupancy{} =
                   GenServer.call(owner, {:who_is_here, ctx.sandbox.id})
        end)

      assert map_log =~ "unexpected message a map"

      # The payload never reaches the log, whatever its shape: a tuple is a
      # tag and an arity, anything else is a type.
      for log <- [call_log, cast_log, info_log, map_log] do
        refute log =~ secret
      end

      # And it still answers the verbs it does know.
      assert %Fountain.Machines.Occupancy{} =
               GenServer.call(owner, {:who_is_here, ctx.sandbox.id})
    end
  end

  # ── a lease whose holder is gone (ADR 0072) ───────────────────────────────

  describe "a lease whose holder is gone" do
    test "is taken at once", ctx do
      stamp(ctx, lease_epoch: 4, lease_node: dead_lease_holder())

      assert {:ok, 5} = Lease.claim(ctx.sandbox.id)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).lease_node == Lease.holder(self())
    end

    test "a holder that is alive keeps it", ctx do
      holder = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(holder, :stop) end)
      named = Lease.holder(holder)
      stamp(ctx, lease_epoch: 4, lease_node: named)

      assert {:error, {:held, ^named}} = Lease.claim(ctx.sandbox.id)
    end

    test "the protocol that takes it re-checks under its new lease", ctx do
      # A destroy that lands on such a lease and finds a fence already there
      # and the row terminal answers for the row, not the dead holder.
      stamp(ctx,
        lease_epoch: 4,
        lease_node: dead_lease_holder(),
        transition: "destroying",
        status: "terminated"
      )

      quietly(fn ->
        assert {:ok, :already_terminal} =
                 Machine.destroy(ctx.sandbox.id,
                   actor: "system:sandbox_reaper",
                   reason: :reclaimed
                 )
      end)

      assert is_nil(Fountain.Machines.Lease.get(ctx.sandbox.id).transition)
    end
  end

  # ── a late resume ─────────────────────────────────────────────────────────

  describe "ensure_up carries the caller's deadline" do
    test "a resume whose caller has given up is refused, not run late", ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(700)
        :ok
      end)

      # A stub that answers, not a `reject`: a rejected call raises inside the
      # protocol, which rescues it as a failed resume and leaves the row
      # `suspended` — the very state this test asserts — so a plant that turns
      # the deadline off stayed green against it. The provider's own word is
      # what the assertion has to see.
      stub(Managoat.Sandbox, :resume, fn handle ->
        send(test, :resumed_at_provider)
        {:ok, handle}
      end)

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)
      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            send(
              test,
              {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
            )
          end)
        end)

      assert_receive :suspending, 2_000

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.ensure_up(ctx.sandbox.id, actor: "system:wake", resume_timeout_ms: 200)
      end)

      assert_receive {:park, {:ok, :parked}}, 5_000
      Task.await(park)
      assert %Fountain.Machines.Occupancy{} = Machine.who_is_here(ctx.sandbox.id)

      refute_received :resumed_at_provider, "the owner resumed a machine for nobody"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"
    end

    test "and a caller still waiting when the park finishes is answered (the positive control)",
         ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(300)
        :ok
      end)

      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)
      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            send(
              test,
              {:park, Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)}
            )
          end)
        end)

      assert_receive :suspending, 2_000

      quietly(fn ->
        assert {:ok, :resumed} =
                 Machine.ensure_up(ctx.sandbox.id,
                   actor: "system:wake",
                   resume_timeout_ms: 5_000
                 )
      end)

      assert_receive {:park, {:ok, :parked}}, 5_000
      Task.await(park)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
    end

    test "a message in a shape an earlier release sent is refused, not run", ctx do
      # Since ADR 0097 step 3b every message names its sandbox, because the
      # owner is the workspace's. One without (the two- and three-tuples every
      # caller before sent) is refused by the rollout clause rather than run
      # against a machine the owner cannot name; with one node and a Recreate
      # deploy (ADR 0072) no such caller exists.
      stamp(ctx, status: "suspended")
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)

      quietly(fn ->
        assert {:error, :sandbox_unavailable} =
                 GenServer.call(owner, {:ensure_up, [actor: "system:wake"]})
      end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"
    end
  end

  # ── the reaper's stuck pass ───────────────────────────────────────────────

  describe "release_stuck_sandboxes/0" do
    test "one refused write does not stop the pass", ctx do
      cutoff = DateTime.add(DateTime.utc_now(), -120 * 60, :second)

      stuck =
        for _ <- 1..2 do
          sandbox =
            insert_sandbox(user_id: ctx.user.id, agent_id: ctx.agent.id, status: "pending")

          Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
            set: [updated_at: cutoff]
          )

          sandbox
        end

      [refused, released] = stuck
      refused_id = refused.id

      # Refused at the owner's door since stage 9b, which is the write this
      # pass makes now.
      stub(Machine, :fail_provision, fn
        ^refused_id, _opts -> {:error, :boom}
        id, opts -> Mimic.call_original(Machine, :fail_provision, [id, opts])
      end)

      log =
        capture_log(fn ->
          assert Fountain.Workers.SandboxReaper.release_stuck_sandboxes() == 1
        end)

      assert log =~ "could not release stuck sandbox #{refused.id}"
      assert Repo.reload!(refused).status == "pending"
      assert Repo.reload!(released).status == "failed"
    end
  end
end
