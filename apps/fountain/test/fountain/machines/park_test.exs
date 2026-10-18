defmodule Fountain.Machines.ParkTest do
  @moduledoc """
  The one park protocol (ADR 0058 stage 6b; closes #2307).

  What these pin is the *order* — the lease, the recheck under it, the intent,
  the checkpoint, the provider, the finalize, the trail — and what each step
  does when the world moved under it. The two call sites keep their own suites
  (`lifecycle_actions_test.exs`, `conversation_server_lifetime_test.exs`,
  `sandbox_reaper_test.exs`, `sandbox_reaper_park_test.exs`); this file is the
  protocol on its own.

  `async: false`: several cases run the protocol inside an owner process
  alongside cases that share state with it.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Park
  alias Managoat.Sandbox.Handle

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp opts(extra \\ []) do
    Keyword.merge([actor: "system:sandbox_reaper", reason: :idle], extra)
  end

  defp row(ctx), do: Repo.reload!(ctx.sandbox)

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)

  # Released, with the epoch kept: epochs are monotonic and never reused.
  defp assert_lease_released(sandbox) do
    assert is_nil(sandbox.lease_node),
           "the lease was not released; this machine is unclaimable until it expires"
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

  # The idle window off, so a case about the running-turn rule is not answered
  # by `busy_elsewhere?/4` before it gets there.
  defp without_idle_bound(fun) do
    previous = Application.get_env(:fountain, :sandbox_idle_timeout_minutes)
    Application.put_env(:fountain, :sandbox_idle_timeout_minutes, 0)

    try do
      fun.()
    after
      Application.put_env(:fountain, :sandbox_idle_timeout_minutes, previous)
    end
  end

  defp with_lock_timeout(ms, fun) do
    previous = Application.fetch_env(:fountain, :sandbox_lock_timeout_ms)
    Application.put_env(:fountain, :sandbox_lock_timeout_ms, ms)

    try do
      fun.()
    after
      case previous do
        {:ok, was} -> Application.put_env(:fountain, :sandbox_lock_timeout_ms, was)
        :error -> Application.delete_env(:fountain, :sandbox_lock_timeout_ms)
      end
    end
  end

  # The row a park leaves when its owner dies between the intent and the
  # finalize: live, stamped `parking`, lease held by a node that is not coming
  # back. Forged rather than produced, because producing it means killing a
  # process mid-provider-call and the thing under test is what the *next* owner
  # does with what is left.
  defp abandon_mid_park(ctx, overrides \\ []) do
    put_lease(
      ctx.sandbox.id,
      Keyword.merge(
        [
          lease_epoch: 1,
          lease_node: dead_lease_holder(),
          transition: "parking",
          transition_reason: "idle"
        ],
        overrides
      )
    )

    :ok
  end

  # A co-tenant that has been quiet longer than the idle bound. A conversation
  # with no turns is judged by its own `updated_at`, which is *now* for a row a
  # test just inserted, so without this every co-tenant would read as active
  # and the cases below would be about the clock rather than about who is
  # watching the machine.
  defp quiet_cotenant(ctx) do
    other = insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "idle")

    long_ago =
      DateTime.utc_now() |> DateTime.add(-2 * 60 * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(
      from(c in Fountain.Conversations.Conversation, where: c.id == ^other.id),
      set: [updated_at: long_ago, inserted_at: long_ago]
    )

    other
  end

  # What "somebody is using this machine" looks like on the row, one shape per
  # arm of the recheck. Inside the test body rather than in the comprehension
  # that names them: these call the helpers below, which do not exist yet when
  # the module body is evaluated.
  defp use_the_machine(ctx, :driven_turn) do
    stand_in_server(ctx.conv.id)
    insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
  end

  # A wake starts its server under the sandbox lock (ADR 0072), so what it
  # leaves on the machine is a registered server.
  defp use_the_machine(ctx, :woken), do: stand_in_server(ctx.conv.id)

  defp use_the_machine(ctx, :teardown),
    do: stamp(ctx, transition: "destroying", transition_reason: "teardown")

  defp use_the_machine(ctx, :reset),
    do: stamp(ctx, transition: "destroying", transition_reason: "reset")

  defp stamp(ctx, sets) do
    put_lease(ctx.sandbox.id, sets)
  end

  # A plain process standing in for a co-tenant's server: `whereis/1` only asks
  # the registry, and a cast is a message. Same shape as `destroy_test.exs`.
  defp flush_test_mailbox do
    receive do
      _ -> flush_test_mailbox()
    after
      0 -> :ok
    end
  end

  defp stand_in_server(conversation_id) do
    test = self()

    pid =
      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Fountain.ConversationRegistry, conversation_id, nil)
           receive do: (msg -> send(test, {:cotenant, msg}))
         end},
        id: {:stand_in, conversation_id}
      )

    assert {:ok, ^pid} = ConversationServer.await_registered(conversation_id, 2_000)
    pid
  end

  describe "the happy path" do
    test "stamps the intent, suspends, finalizes, audits, in that order", ctx do
      home = ctx.sandbox
      test = self()
      machine_name = home.machine_name

      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap == :suspend end)

      expect(Managoat.Sandbox, :suspend, fn %Handle{provider: :sprites, name: ^machine_name} ->
        # Everything before step 6, read from the row the way another node
        # would read it: no transaction, no lock, no struct we brought.
        refute Repo.in_transaction?()
        send(test, {:mid_park, Repo.reload!(home)})
        :ok
      end)

      assert {:ok, :parked} =
               Park.run(home.id, opts(actor: "system:conversation_server", reason: :idle))

      assert_received {:mid_park, mid}
      assert mid.transition == "parking", "the intent was not on the row before the suspend"
      assert mid.transition_reason == "idle"
      assert mid.status == "ready", "the row said suspended before the machine was"
      assert Lease.live?(mid)
      assert mid.lease_epoch == 1

      final = row(ctx)
      assert final.status == "suspended"
      refute final.terminated_at
      assert is_nil(final.transition)
      assert is_nil(final.transition_reason)
      assert final.lease_epoch == 1
      assert_lease_released(final)

      assert [suspended] = events(ctx, "sandbox.suspended")
      assert suspended.actor == "system:conversation_server"
      assert suspended.resource_type == "sandbox"
      assert suspended.resource_id == home.id

      assert suspended.metadata == %{
               "reason" => "idle",
               "provider" => "sprites",
               "machine_name" => machine_name,
               "sprite_name" => machine_name
             }
    end

    test "the ceiling's park records the bound it was", ctx do
      explicit_workspace!(ctx.sandbox)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts(reason: :max_lifetime))
      assert [event] = events(ctx, "sandbox.suspended")
      assert event.metadata["reason"] == "max_lifetime"
      assert event.actor == "system:sandbox_reaper"
    end

    test "the audit is written after the finalize commits, never before", ctx do
      test = self()
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      stub(Audit, :record, fn attrs ->
        if attrs[:action] == "sandbox.suspended" do
          refute Repo.in_transaction?()
          send(test, {:at_audit, Repo.reload!(ctx.sandbox)})
        end

        Mimic.call_original(Audit, :record, [attrs])
      end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())

      assert_received {:at_audit, at_audit}
      assert at_audit.status == "suspended"
      assert is_nil(at_audit.transition)
    end

    test "a machine is parked without a checkpoint", ctx do
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap == :suspend end)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).provider_meta == %{}
    end
  end

  describe "HTTPS broker transport" do
    test "stops the local relay before the provider suspend", ctx do
      stub(Fountain.Broker, :proxy_url, fn -> "https://broker.example:443" end)
      test = self()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", command], _opts ->
        assert command =~ "transport-relay.cjs stop"
        send(test, :relay_stopped)
        {:ok, "", 0}
      end)

      stub(Managoat.Sandbox, :suspend, fn _ ->
        assert_received :relay_stopped
        :ok
      end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
    end

    test "a relay that cannot stop refuses suspension", ctx do
      stub(Fountain.Broker, :proxy_url, fn -> "https://broker.example:443" end)
      stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 1} end)
      reject(&Managoat.Sandbox.suspend/1)
      assert {:error, :suspend_failed} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "ready"
      assert_lease_released(row(ctx))
    end
  end

  describe "the co-tenant notice" do
    test "reaches every other live server on the machine when the caller supplies one", ctx do
      other = quiet_cotenant(ctx)
      stand_in_server(other.id)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(
                 ctx.sandbox.id,
                 opts(
                   requesting_conversation_id: ctx.conv.id,
                   notify: {ctx.conv.id, "suspended", "idle", "why"}
                 )
               )

      sandbox_id = ctx.sandbox.id

      assert_receive {:cotenant,
                      {:"$gen_cast", {:machine_gone, ^sandbox_id, "suspended", "idle", "why"}}}
    end

    test "the requester's own server is told too, for a park it stopped waiting for", ctx do
      # A server whose call to the owner timed out while its park went on is
      # still running, on a machine now parked; the notice stops it (review
      # of step 4a). One whose park returned stops first and never reads it.
      stand_in_server(ctx.conv.id)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(
                 ctx.sandbox.id,
                 opts(
                   requesting_conversation_id: ctx.conv.id,
                   notify: {ctx.conv.id, "suspended", "idle", "why"}
                 )
               )

      sandbox_id = ctx.sandbox.id

      assert_receive {:cotenant,
                      {:"$gen_cast", {:machine_gone, ^sandbox_id, "suspended", "idle", "why"}}}
    end

    test "a co-tenant with no live server is not an error", ctx do
      _other = quiet_cotenant(ctx)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(
                 ctx.sandbox.id,
                 opts(notify: {ctx.conv.id, "suspended", "idle", "why"})
               )
    end

    test "a caller with nothing to say still tells every co-tenant, in the park's words",
         ctx do
      # ADR 0097: `machine_gone` tells every conversation bound to the
      # machine, not only the ones a caller thought to name. The requester is
      # not told about its own park.
      other = quiet_cotenant(ctx)
      stand_in_server(other.id)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))

      sandbox_id = ctx.sandbox.id

      assert_receive {:cotenant,
                      {:"$gen_cast", {:machine_gone, ^sandbox_id, "suspended", "idle", message}}}

      assert message == Fountain.Conversations.Lifecycle.explain(:idle, :suspend)
    end
  end

  # Each refusal below rejects the provider call as well as asserting the
  # answer: the point of the recheck is that it happens before any machine is
  # touched.
  describe "the recheck under the lease" do
    test "a machine that is already parked", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})

      assert {:ok, :already_parked} = Park.run(ctx.sandbox.id, opts())
      assert_lease_released(row(ctx))
    end

    for terminal <- ["terminated", "failed"] do
      test "a machine that has stopped (#{terminal})", ctx do
        reject(&Managoat.Sandbox.suspend/1)
        {:ok, _} = update_sandbox(ctx.sandbox, %{status: unquote(terminal)})

        assert {:ok, :already_terminal} = Park.run(ctx.sandbox.id, opts())
        assert row(ctx).status == unquote(terminal)
        assert_lease_released(row(ctx))
      end
    end

    test "a machine whose reset is unconfirmed", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      # `main`'s `park_row/1` checked this one, and it is the reason it did:
      # the disk is meant to be gone, and parking would re-reserve it.
      put_lease(ctx.sandbox.id, transition: "destroying", transition_reason: "reset")

      assert {:error, :fenced} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "ready"
      assert_lease_released(row(ctx))
    end

    test "a machine whose teardown has been asked for", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      # `main`'s `park_row/1` did **not** check this one, and would have parked
      # a machine somebody had asked to be destroyed — writing a live status
      # over a row `sweep_fenced_teardowns/0` is about to finish, and
      # re-reserving the machine at the provider.
      put_lease(ctx.sandbox.id, transition: "destroying", transition_reason: "teardown")

      assert {:error, :fenced} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "ready"
      # The fence is the stamp, and a refusal leaves it for the driver.
      assert row(ctx).transition == "destroying"
    end

    test "a provider that cannot park", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)

      assert {:error, :cannot_park} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "ready"
      assert_lease_released(row(ctx))
    end

    test "a turn running anywhere on the machine, with a server driving it", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      stand_in_server(ctx.conv.id)
      insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())

      assert {:error, :machine_occupied} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "ready"
      assert_lease_released(row(ctx))
    end

    test "a running turn nothing is driving is not occupancy", ctx do
      # The regression this rule exists for. A turn parked on a human's
      # permission decision whose server then died stays `running` for ever —
      # `SandboxReaper.sweep_stuck_turns/0` skips those by design, because a person may
      # still answer — so counting it refused the park for ever and the machine
      # went on billing with nothing able to reclaim it. `main` had no turn
      # check and its reaper parked this machine.
      insert_turn(ctx.conv,
        status: "running",
        started_at: DateTime.utc_now(),
        pending_permission: %{"id" => "perm-1"}
      )

      assert ConversationServer.whereis(ctx.conv.id) == nil
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
    end

    test "a turn running on the requester's own conversation refuses an idle park", ctx do
      # The idle verdict's premise is that nothing is running, so a turn found
      # here — the requester's included — means the verdict was wrong.
      reject(&Managoat.Sandbox.suspend/1)
      insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())

      assert {:error, :machine_occupied} =
               Park.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))
    end

    test "and does not refuse a max-lifetime one: that turn is what the ceiling cuts", ctx do
      # `Lifecycle.check/4` lets `{:expired, :max_lifetime}` through with
      # `busy?` true on purpose, so a server reaching the protocol with its own
      # turn in flight is the normal way the ceiling fires. Treating it as a
      # veto made the ceiling unable to park a home at all — the server had
      # already dropped its adapter, so the turn it left `running` had nothing
      # to end it, and the machine went on billing.
      explicit_workspace!(ctx.sandbox)
      insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(
                 ctx.sandbox.id,
                 opts(reason: :max_lifetime, requesting_conversation_id: ctx.conv.id)
               )

      assert row(ctx).status == "suspended"
    end

    test "the ceiling parks only an explicit workspace's machine", ctx do
      # ADR 0097: an implicit workspace's machine is destroyed at the ceiling,
      # so a park asked for there is refused in the word the callers already
      # degrade to a destroy on, before anything is touched.
      reject(&Managoat.Sandbox.suspend/1)
      insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())

      assert {:error, :cannot_park} =
               Park.run(
                 ctx.sandbox.id,
                 opts(reason: :max_lifetime, requesting_conversation_id: ctx.conv.id)
               )

      assert row(ctx).status == "ready"
      assert [%{status: "running"}] = Repo.all(Fountain.Conversations.Turn)
    end

    test "a co-tenant's running turn is cut by an explicit workspace's ceiling, not a veto",
         ctx do
      # ADR 0097: the ceiling interrupts every running turn on the workspace
      # and then parks, without waiting for them. The co-tenant's turn is
      # marked interrupted with its transcript kept, and its server is told
      # *before* the provider is asked to suspend, so it cancels its adapter
      # rather than leaving it running on a parked machine. The idle bound is
      # off so the co-tenant's activity is not what is being judged.
      explicit_workspace!(ctx.sandbox)
      other = quiet_cotenant(ctx)
      stand_in_server(other.id)
      turn = insert_turn(other, status: "running", started_at: DateTime.utc_now())
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        :ok
      end)

      without_idle_bound(fn ->
        assert {:ok, :parked} =
                 Park.run(
                   ctx.sandbox.id,
                   opts(
                     reason: :max_lifetime,
                     actor: "system:conversation_server",
                     requesting_conversation_id: ctx.conv.id,
                     notify: {ctx.conv.id, "suspended", "max_lifetime", "the ceiling"}
                   )
                 )
      end)

      sandbox_id = ctx.sandbox.id

      # The notice was sent before the suspend: it is first in the mailbox,
      # and it is the only one (the finalize does not tell them again).
      assert {:messages,
              [
                {:cotenant,
                 {:"$gen_cast",
                  {:machine_gone, ^sandbox_id, "suspended", "max_lifetime", "the ceiling"}}},
                :suspending
              ]} = Process.info(self(), :messages)

      flush_test_mailbox()

      assert Repo.reload!(turn).status == "interrupted"
      assert row(ctx).status == "suspended"
      refute_receive {:cotenant, _}, 100
    end

    test "a sweep is refused by the server before its turn is ever counted", ctx do
      # Named for what it pins rather than for what it looks like. A turn only
      # counts as occupancy when something is driving it, and for a sweep
      # "something is driving it" means a live server — which `any_live?`
      # has already refused on. So the requester exception cannot reach a
      # sweep, and neither can the turn check: the liveness rule subsumes it.
      explicit_workspace!(ctx.sandbox)
      reject(&Managoat.Sandbox.suspend/1)
      stand_in_server(ctx.conv.id)
      insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())

      without_idle_bound(fn ->
        assert {:error, :machine_occupied} = Park.run(ctx.sandbox.id, opts(reason: :max_lifetime))
      end)
    end

    test "a sweep is refused by any live server on the machine", ctx do
      # The reaper's rule, unchanged: its idle pass exists for machines with
      # nothing watching them, and a machine with a server has one enforcing
      # its own bounds.
      reject(&Managoat.Sandbox.suspend/1)
      stand_in_server(ctx.conv.id)

      assert {:error, :machine_occupied} = Park.run(ctx.sandbox.id, opts())
    end

    test "a server's park is not refused by an idle co-tenant's live server", ctx do
      # ADR 0023 step 5, and the reason `notify` exists. Refusing here would
      # mean two idle conversations on one home could never park it, each
      # vetoing the other, until both servers died.
      other = quiet_cotenant(ctx)
      stand_in_server(other.id)
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))
    end

    test "a server's park is refused by a co-tenant active inside the idle window", ctx do
      reject(&Managoat.Sandbox.suspend/1)
      other = quiet_cotenant(ctx)
      insert_turn(other, status: "completed", ended_at: DateTime.utc_now())

      assert {:error, :machine_occupied} =
               Park.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))
    end

    test "the requester's own live server does not refuse its own park", ctx do
      stand_in_server(ctx.conv.id)
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))
    end
  end

  describe "the caller's verdict, re-run under the lease" do
    test "a machine that is no longer past any bound is refused", ctx do
      # The #2286 reproduction, in the shape stage 6b leaves it: the reaper
      # scanned a page of rows, and by the time this one's park claimed its
      # lease a turn had landed on the machine. Nothing is running *now* — the
      # occupancy check would let this through — and the machine is simply not
      # idle any more.
      insert_turn(ctx.conv, status: "completed", ended_at: DateTime.utc_now())
      reject(&Managoat.Sandbox.suspend/1)

      assert {:error, :not_expired} =
               Park.run(ctx.sandbox.id, opts(verdict: {:expired, :idle}))

      assert row(ctx).status == "ready"
      assert_lease_released(row(ctx))
    end

    test "the same row parks when the caller brings no verdict", ctx do
      # The conversation server does not supply one: it decides on its own tick
      # and asks in the same breath, and its `last_activity_at` is its own, not
      # the machine-wide fold. See `Park.still_expired?/3`.
      insert_turn(ctx.conv, status: "completed", ended_at: DateTime.utc_now())
      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
    end

    test "a machine still past its bound parks", ctx do
      old = DateTime.add(DateTime.utc_now(), -60 * 60 * 24, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [inserted_at: old, updated_at: old]
      )

      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(ctx.sandbox.id, opts(verdict: {:expired, :idle}))
    end

    test "a verdict that named the other bound is not re-litigated", ctx do
      # The recheck asks whether the machine is past *some* bound, not the same
      # one: a reaper that decided `:max_lifetime` on a row now merely idle
      # still parks it, and `transition_reason` records what it decided.
      old = DateTime.add(DateTime.utc_now(), -60 * 60 * 24, :second) |> DateTime.truncate(:second)

      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [inserted_at: old, updated_at: old]
      )

      expect(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} =
               Park.run(ctx.sandbox.id, opts(verdict: {:expired, :max_lifetime}))
    end

    test "a verdict that is not one is a caller bug", ctx do
      assert_raise ArgumentError, ~r/bad :verdict/, fn ->
        Park.run(ctx.sandbox.id, opts(verdict: :idle))
      end
    end
  end

  describe "the suspend that does not land" do
    test "an error clears the intent and leaves the machine exactly as it was", ctx do
      expect(Managoat.Sandbox, :suspend, fn _ -> {:error, {:unavailable, :timeout}} end)

      log =
        capture_log(fn ->
          assert {:error, :suspend_failed} = Park.run(ctx.sandbox.id, opts())
        end)

      assert log =~ "provider suspend failed"

      final = row(ctx)
      assert final.status == "ready", "a machine that was not parked was written down as parked"
      assert is_nil(final.transition), "a stale parking stamp was left on a live row"
      assert is_nil(final.transition_reason)
      assert_lease_released(final)

      assert events(ctx, "sandbox.suspended") == [],
             "a park that did not happen was recorded in the tenant's trail"
    end

    test "an adapter that raises is the same outcome", ctx do
      # 5a's rule: an adapter that raises rather than answering did not reach
      # the machine either way. The difference from a destroy is what follows —
      # a destroy finalizes anyway so a fenced row is not stranded, a park must
      # not write down something that did not happen.
      expect(Managoat.Sandbox, :suspend, fn _ -> raise "sprites client exploded" end)

      log =
        capture_log(fn ->
          assert {:error, :suspend_failed} = Park.run(ctx.sandbox.id, opts())
        end)

      assert log =~ "sprites client exploded"

      final = row(ctx)
      assert final.status == "ready"
      assert is_nil(final.transition)
      assert_lease_released(final)
    end
  end

  describe "takeover" do
    test "a suspend that landed is finished by the next owner", ctx do
      :ok = abandon_mid_park(ctx)
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :suspended, raw: %{}}} end)
      # The compensation is the finalize, not a second suspend.
      reject(&Managoat.Sandbox.suspend/1)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())

      final = row(ctx)
      assert final.status == "suspended"
      assert is_nil(final.transition)
      assert final.lease_epoch == 2, "the taker did not take a new epoch"
      assert_lease_released(final)

      assert [event] = events(ctx, "sandbox.suspended")
      assert event.actor == "system:sandbox_reaper"
    end

    test "a machine still running is recovered, not parked", ctx do
      :ok = abandon_mid_park(ctx)
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :running, raw: %{}}} end)
      # Never resume-and-finalize both: nothing is asked of the machine.
      reject(&Managoat.Sandbox.suspend/1)
      reject(&Managoat.Sandbox.resume/1)

      assert {:ok, :recovered} = Park.run(ctx.sandbox.id, opts())

      final = row(ctx)
      assert final.status == "ready", "a machine that is up was written down as parked"
      assert is_nil(final.transition), "a stale parking stamp survived a whole pass"
      assert is_nil(final.transition_reason)
      assert_lease_released(final)
      assert events(ctx, "sandbox.suspended") == []
    end

    for {name, answer} <- [
          {"an unknown state", {:ok, %{status: :unknown, raw: %{}}}},
          {"a machine the provider does not have", {:error, :not_found}},
          {"a provider that cannot be reached", {:error, {:unavailable, :timeout}}}
        ] do
      test "#{name} reads as running", ctx do
        :ok = abandon_mid_park(ctx)
        stub(Managoat.Sandbox, :get, fn %Handle{} -> unquote(Macro.escape(answer)) end)
        reject(&Managoat.Sandbox.suspend/1)

        capture_log(fn -> assert {:ok, :recovered} = Park.run(ctx.sandbox.id, opts()) end)
        assert row(ctx).status == "ready"
        assert is_nil(row(ctx).transition)
      end
    end

    test "a provider that raises while being probed reads as running", ctx do
      :ok = abandon_mid_park(ctx)
      stub(Managoat.Sandbox, :get, fn %Handle{} -> raise "probe exploded" end)

      assert capture_log(fn -> assert {:ok, :recovered} = Park.run(ctx.sandbox.id, opts()) end) =~
               "probe exploded"

      assert is_nil(row(ctx).transition)
    end

    test "a mid-park row that somebody else already finished is not re-parked", ctx do
      :ok = abandon_mid_park(ctx)
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})
      reject(&Managoat.Sandbox.get/1)
      reject(&Managoat.Sandbox.suspend/1)

      assert {:ok, :already_terminal} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "terminated"

      assert is_nil(row(ctx).transition),
             "the stale stamp was left, so the row can no longer answer " <>
               "'is this machine mid-park?'"
    end

    test "a mid-park row that reached suspended is not parked twice", ctx do
      :ok = abandon_mid_park(ctx)
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      reject(&Managoat.Sandbox.get/1)
      reject(&Managoat.Sandbox.suspend/1)

      assert {:ok, :already_parked} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
      assert is_nil(row(ctx).transition)
      assert events(ctx, "sandbox.suspended") == []
    end

    # B1, from the protocol review. Nothing clears a `parking` stamp off a
    # lease-less row except an owner, so an abandoned park can sit on a machine
    # that is then woken and used. A takeover that revalidated nothing would
    # write `suspended` over it and answer `{:ok, :parked}` where the ordinary
    # path answers a refusal.
    for {label, shape, refusal} <- [
          {"a turn somebody is driving", :driven_turn, :machine_occupied},
          {"a server a wake has just started", :woken, :machine_occupied},
          {"a teardown somebody has asked for", :teardown, :fenced},
          {"a reset that is unconfirmed", :reset, :fenced}
        ] do
      test "a takeover refuses #{label}, and clears its own stamp", ctx do
        :ok = abandon_mid_park(ctx)
        use_the_machine(ctx, unquote(shape))

        # Neither asked nor acted on: the machine is not this park's to finish.
        reject(&Managoat.Sandbox.get/1)
        reject(&Managoat.Sandbox.suspend/1)

        assert {:error, unquote(refusal)} = Park.run(ctx.sandbox.id, opts())

        final = row(ctx)
        assert final.status == "ready", "a machine in use was written down as parked"

        # The abandoned `parking` stamp does not survive, so the next owner does
        # not read it as its own interrupted work. A fence *replaced* it: the
        # teardown and reset fences write `destroying` over whatever was there
        # (since stage 9b the fence is the stamp alone), and that one is the
        # driver's to finish, so it stays.
        if unquote(refusal) == :fenced do
          assert final.transition == "destroying"
        else
          assert is_nil(final.transition),
                 "the stamp was left, so the next owner reads the same lie"

          assert is_nil(final.transition_reason)
        end

        assert events(ctx, "sandbox.suspended") == []
      end
    end

    test "a takeover refuses a provider that can no longer park, and clears the stamp", ctx do
      :ok = abandon_mid_park(ctx)
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
      reject(&Managoat.Sandbox.get/1)

      assert {:error, :cannot_park} = Park.run(ctx.sandbox.id, opts())
      assert is_nil(row(ctx).transition)
    end

    test "a takeover still compensates a machine the provider reports suspended", ctx do
      # The revalidation is a gate on the compensation, not a replacement for
      # it: an abandoned park on a machine nobody has touched still finishes.
      :ok = abandon_mid_park(ctx)
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :suspended, raw: %{}}} end)

      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
      assert [_one] = events(ctx, "sandbox.suspended")
    end

    test "somebody else's abandoned operation is left to its own protocol", ctx do
      :ok = abandon_mid_park(ctx, transition: "destroying", transition_reason: "terminated")
      reject(&Managoat.Sandbox.get/1)
      reject(&Managoat.Sandbox.suspend/1)

      assert {:error, :fenced} = Park.run(ctx.sandbox.id, opts())

      assert row(ctx).transition == "destroying",
             "a park cleared a destroy's intent, so its takeover has nothing to read"
    end
  end

  describe "contention" do
    test "a lease somebody else holds is waited out, then refused", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      reject(&Managoat.Sandbox.suspend/1)

      started = System.monotonic_time(:millisecond)

      log =
        capture_log(fn ->
          assert {:error, :machine_busy} = Park.run(ctx.sandbox.id, opts(busy_wait_ms: 600))
        end)

      waited = System.monotonic_time(:millisecond) - started

      assert log =~ "park refused"
      assert waited >= 250, "the wait gave up without waiting at all"
      assert waited < 5_000, "the wait ran past the bound it was given"
    end

    test "a park and a destroy of one machine queue behind each other, both orders", ctx do
      # Whichever holds the lease, the other waits its bound and then refuses;
      # neither runs while the other is at the provider. The lease is held by a
      # third party here so the same claim stands in for both orders.
      {:ok, epoch} = Lease.claim(ctx.sandbox.id)

      capture_log(fn ->
        assert {:error, :machine_busy} = Park.run(ctx.sandbox.id, opts(busy_wait_ms: 300))

        assert {:error, :machine_busy} =
                 Destroy.run(ctx.sandbox.id,
                   actor: "self",
                   reason: :terminated,
                   busy_wait_ms: 300
                 )
      end)

      # And with the machine free again, each runs.
      :ok = Lease.release(ctx.sandbox.id, epoch)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)
      assert {:ok, :parked} = Park.run(ctx.sandbox.id, opts())
    end

    test "a park that loses its lease between the suspend and the finalize is superseded", ctx do
      test = self()

      expect(Managoat.Sandbox, :suspend, fn _ ->
        # A takeover lands while this park is at the provider: the only way to
        # take a live holder's lease is `supersede:`, as the provision watchdog
        # does.
        {:ok, _taker} = Lease.claim(ctx.sandbox.id, supersede: self())
        send(test, :taken_over)
        :ok
      end)

      log =
        capture_log(fn ->
          assert {:error, :superseded} = Park.run(ctx.sandbox.id, opts())
        end)

      assert_received :taken_over
      assert log =~ "superseded before its finalize"

      # The taker owns the row and says what happened to it; this park wrote
      # nothing, including no audit event for a park it cannot vouch for.
      assert row(ctx).status == "ready"
      assert events(ctx, "sandbox.suspended") == []
    end

    test "two parks of one machine make one provider call", ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspended)
        Process.sleep(150)
        :ok
      end)

      tasks =
        for _ <- 1..2 do
          Task.async(fn ->
            Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
            capture_log(fn -> send(test, {:result, Park.run(ctx.sandbox.id, opts())}) end)
          end)
        end

      Enum.each(tasks, &Task.await(&1, 10_000))

      results = for _ <- 1..2, do: receive(do: ({:result, r} -> r))
      assert Enum.sort(results) == Enum.sort([{:ok, :parked}, {:ok, :already_parked}])

      assert_received :suspended
      refute_received :suspended, "the machine was suspended twice for one park"
      assert [_one] = events(ctx, "sandbox.suspended")
    end

    test "an advisory lock held past its timeout is contention, not a crash", ctx do
      # 6a's locks review §6, closed here. `with_sandbox_lock/2` sets a
      # `lock_timeout`, so a claim that would once have blocked for as long as
      # the holder lasted comes back as a refusal the busy wait already
      # understands — and not as a `Postgrex.Error` unwinding through a park.
      #
      # The holder needs a connection of its own: inside the Ecto sandbox every
      # process shares one, and a lock cannot block the connection that holds
      # it. `Postgrex.start_link/1` gives a real one, and the only thing it
      # does with it is take the lock, so it commits nothing (#2178).
      {:ok, holder} =
        Fountain.Repo.config()
        |> Keyword.drop([
          :pool,
          :pool_size,
          :migration_lock,
          :telemetry_prefix,
          :otp_app,
          :scheme
        ])
        |> Postgrex.start_link()

      # Killed rather than stopped: a `DBConnection` whose transaction has just
      # ended answers a `:normal` stop with a shutdown exit, and the point of
      # this cleanup is only that the connection does not outlive the test.
      on_exit(fn -> if Process.alive?(holder), do: Process.exit(holder, :kill) end)

      {:ok, _} =
        Postgrex.transaction(
          holder,
          fn conn ->
            Postgrex.query!(conn, "SELECT pg_advisory_xact_lock($1, $2)", [
              4316,
              Fountain.Conversations.sandbox_lock_key(ctx.sandbox.id)
            ])

            with_lock_timeout(200, fn ->
              reject(&Managoat.Sandbox.suspend/1)

              log =
                capture_log(fn ->
                  assert {:error, :machine_busy} =
                           Park.run(ctx.sandbox.id, opts(busy_wait_ms: 700))
                end)

              assert log =~ "lock_timeout", "something other than the lock_timeout gave up"
            end)
          end,
          timeout: 30_000
        )

      # Nothing was written, and the machine is claimable the moment the lock
      # goes: a refused claim is not a half-done park.
      assert row(ctx).status == "ready"
      assert is_nil(row(ctx).transition)
    end
  end

  describe "the door" do
    test "refuses an enclosing transaction", ctx do
      Repo.transaction(fn ->
        assert {:error, :transaction_open} = Park.run(ctx.sandbox.id, opts())
        assert {:error, :provider_transaction_open} = Machine.park(ctx.sandbox.id, opts())
      end)
    end

    test "a machine with no row", ctx do
      _ = ctx
      assert {:error, :not_found} = Park.run(Ecto.UUID.generate(), opts())
      assert {:error, :not_found} = Machine.park(Ecto.UUID.generate(), opts())
    end

    test "parks in the machine's owner", ctx do
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      assert {:ok, :parked} = Machine.park(ctx.sandbox.id, opts())
      assert Machine.whereis(ctx.sandbox.id) != nil
      assert row(ctx).status == "suspended"
      assert [_one] = events(ctx, "sandbox.suspended")
    end

    test "the protocol's words become the system's", ctx do
      # `:machine_busy` and a database fault are both "come back shortly"; the
      # three that change what a caller does travel intact.
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} =
                 Machine.park(ctx.sandbox.id, opts(busy_wait_ms: 100))
      end)

      :ok = Lease.release(ctx.sandbox.id, 1)
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
      assert {:error, :cannot_park} = Machine.park(ctx.sandbox.id, opts())
    end

    test "a superseded park reads as already parked at the door", ctx do
      expect(Managoat.Sandbox, :suspend, fn _ ->
        {:ok, _taker} = Lease.claim(ctx.sandbox.id, supersede: self())
        :ok
      end)

      capture_log(fn ->
        assert {:ok, :already_parked} = Machine.park(ctx.sandbox.id, opts())
      end)
    end
  end

  describe "caller bugs" do
    test "a missing actor or a reason that is not a bound raises", ctx do
      assert_raise KeyError, fn -> Park.run(ctx.sandbox.id, reason: :idle) end

      assert_raise ArgumentError, ~r/:reason must be :idle or :max_lifetime/, fn ->
        Park.run(ctx.sandbox.id, actor: "self", reason: :terminated)
      end
    end
  end
end
