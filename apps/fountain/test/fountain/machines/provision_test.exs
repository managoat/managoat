defmodule Fountain.Machines.ProvisionTest do
  @moduledoc """
  The one provision protocol (ADR 0058 stage 7b).

  What these pin is the *order* — the lease, the recheck under it, the intent,
  the discard, the create, `starting`, the caller's pipeline, the finalize, the
  trail — and what each step does when the world moved under it. `Destroy`,
  `Park` and `Resume` are the siblings; this one differs in the shape that made
  it a bracket rather than a move: the work in the middle is the *caller's*, and
  the protocol is what happens on either side of it.

  Three doors come through here, because they are three verbs of one module:
  `run/3` builds a machine, `confirm_up/2` takes possession of one that already
  exists, and `fail/2` retires one whose provisioning is not going to happen.

  The call sites keep their own suites — `conversation_server_provision_*`,
  `conversation_server_reprovision_test.exs`, `conversation_server_broker_test.exs`,
  `initial_start_failure_test.exs`, `conversations_wake_test.exs` — and this file
  is the protocol on its own.

  `async: false`: the across-connections cases need committed rows and real
  connections.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Provision
  alias Managoat.Sandbox.Handle

  @sandbox_lock_namespace 4316
  @quota_lock_namespace 4315

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "pending")

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "pending")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp opts(extra \\ []),
    do: Keyword.merge([actor: "system:conversation_server", environment: nil], extra)

  defp row(ctx), do: Repo.reload!(ctx.sandbox)

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)

  # The suite runs at `:warning`, and this protocol logs a great deal at both
  # levels on its refusal paths. Swallowed rather than asserted on: a log line is
  # not what any of these tests are about, and raising the global level to read
  # them would make every other file noisier. The answer is what is wanted, so
  # it comes back out.
  defp answer(fun) do
    key = :erlang.make_ref()
    Process.put(key, nil)
    capture_log(fn -> Process.put(key, fun.()) end)
    Process.get(key)
  end

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

  defp stamp(ctx, sets) do
    put_lease(ctx.sandbox.id, sets)
  end

  # The row a provision leaves when its owner dies between the intent and the
  # finalize: stamped `provisioning`, lease held by a node that is not coming
  # back. Forged rather than produced, because producing it means killing a
  # process mid-provider-call and the thing under test is what the *next* owner
  # does with what is left.
  defp abandon_mid_provision(ctx, overrides \\ []) do
    stamp(
      ctx,
      Keyword.merge(
        [
          lease_epoch: 1,
          lease_node: dead_lease_holder(),
          transition: "provisioning",
          transition_reason: nil
        ],
        overrides
      )
    )

    :ok
  end

  defp handle(ctx), do: %Handle{provider: :sprites, name: Repo.reload!(ctx.sandbox).machine_name}

  # A machine that is created without complaint. Returns the handle the protocol
  # will hand the pipeline.
  defp stub_create(ctx) do
    built = handle(ctx)
    stub(Managoat.Sandbox, :create, fn :sprites, _name -> {:ok, built} end)
    built
  end

  # A pipeline that records the order of what happened around it and succeeds.
  defp recording_pipeline(test \\ self()) do
    fn handle, epoch ->
      send(test, {:pipeline, handle, epoch, Repo.one(from s in Sandbox, select: s.status)})
      {:ok, :built}
    end
  end

  # ── the happy path ─────────────────────────────────────────────────────────

  describe "the happy path" do
    test "stamps the intent, creates, says starting, runs the pipeline, then ready", ctx do
      built = stub_create(ctx)
      test = self()

      # The transition is on the row *before* the create — that is what makes a
      # reader see an owner rather than race one, and what lets the next attempt
      # tell that a machine may exist.
      expect(Managoat.Sandbox, :create, fn :sprites, name ->
        current = row(ctx)
        send(test, {:created, name, current.status, current.transition})
        {:ok, built}
      end)

      assert {:ok, :provisioned, :built} =
               Provision.run(
                 ctx.sandbox.id,
                 recording_pipeline(),
                 opts(ready_attrs: [provider_meta: %{"n" => 1}])
               )

      assert_received {:created, name, "pending", "provisioning"}
      assert name == ctx.sandbox.machine_name

      # And `starting` is on the row before the pipeline runs: the machine
      # exists by then.
      assert_received {:pipeline, ^built, epoch, "starting"}
      assert epoch >= 1

      ready = row(ctx)
      assert ready.status == "ready"
      assert ready.transition == nil
      assert ready.provider_meta == %{"n" => 1}
      assert_lease_released(ready)
    end

    test "records one sandbox.provisioned, with the actor and the conversation", ctx do
      stub_create(ctx)

      assert {:ok, :provisioned, :built} =
               Provision.run(
                 ctx.sandbox.id,
                 recording_pipeline(),
                 opts(conversation_id: ctx.conv.id)
               )

      assert [event] = events(ctx, "sandbox.provisioned")
      assert event.actor == "system:conversation_server"
      assert event.resource_id == ctx.sandbox.id
      assert event.metadata["provider"] == "sprites"
      assert event.metadata["sprite_name"] == ctx.sandbox.machine_name
      assert event.metadata["conversation_id"] == ctx.conv.id
    end

    test "discards nothing on a first attempt", ctx do
      stub_create(ctx)
      test = self()
      stub(Managoat.Sandbox, :destroy, fn _handle -> send(test, :destroyed) && :ok end)

      assert {:ok, :provisioned, :built} =
               Provision.run(ctx.sandbox.id, recording_pipeline(), opts())

      refute_received :destroyed
    end

    test "runs :on_claim once the row is stamped and before anything is created", ctx do
      stub_create(ctx)
      test = self()

      on_claim = fn interrupted? ->
        current = row(ctx)
        send(test, {:claimed, interrupted?, current.status, current.transition})
        :ok
      end

      assert {:ok, :provisioned, :built} =
               Provision.run(ctx.sandbox.id, recording_pipeline(), opts(on_claim: on_claim))

      assert_received {:claimed, false, "pending", "provisioning"}
    end

    test "a refusing :on_claim fails the row and creates nothing", ctx do
      reject(&Managoat.Sandbox.create/2)
      reject(&Managoat.Sandbox.destroy/1)

      assert {:error, :no_network_policy} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   recording_pipeline(),
                   opts(on_claim: fn _ -> {:error, :no_network_policy} end)
                 )
               end)

      failed = row(ctx)
      assert failed.status == "failed"
      assert failed.transition == nil
      assert_lease_released(failed)

      # The caller's own reason, not a generic word for "refused" — this is the
      # column an operator reads when #935's pairing check says no.
      assert failed.transition_reason == "no_network_policy"
      assert [event] = events(ctx, "sandbox.provision_failed")
      assert event.metadata["reason"] == "no_network_policy"
    end
  end

  # ── the recheck under the lease ────────────────────────────────────────────

  describe "the recheck under the lease" do
    for terminal <- ["terminated", "failed"] do
      test "a #{terminal} row is not provisioned", ctx do
        stamp(ctx, status: unquote(terminal))
        reject(&Managoat.Sandbox.create/2)

        assert {:ok, :already_terminal} =
                 Provision.run(ctx.sandbox.id, recording_pipeline(), opts())

        assert row(ctx).status == unquote(terminal)
      end
    end

    for {reason, label} <- [{"reset", "a reset"}, {"teardown", "a teardown"}] do
      test "#{label} fence refuses before the machine exists", ctx do
        stamp(ctx, transition: "destroying", transition_reason: unquote(reason))
        reject(&Managoat.Sandbox.create/2)

        assert {:error, :fenced} = Provision.run(ctx.sandbox.id, recording_pipeline(), opts())

        current = row(ctx)
        assert current.status == "pending"
        # The fence is the stamp, and a refusal leaves it for the driver.
        assert current.transition == "destroying"
        assert_lease_released(current)
      end
    end

    for live <- ["ready", "suspended"] do
      test "a #{live} row is refused rather than provisioned over", ctx do
        # `dispatch_provision/7` sends these to the reattach arm and never here.
        # Refusing matters because `Managoat.Sandbox.create/2` adopts by name: a
        # provision onto a live machine would re-run the pipeline over a working
        # disk.
        stamp(ctx, status: unquote(live))
        reject(&Managoat.Sandbox.create/2)

        assert {:error, {:not_provisionable, unquote(live)}} =
                 Provision.run(ctx.sandbox.id, recording_pipeline(), opts())
      end
    end

    test "a row that is gone answers :not_found", ctx do
      Repo.delete_all(from c in Fountain.Conversations.Conversation, where: c.id == ^ctx.conv.id)
      Repo.delete!(ctx.sandbox)
      reject(&Managoat.Sandbox.create/2)

      assert {:error, :not_found} = Provision.run(ctx.sandbox.id, recording_pipeline(), opts())
    end

    test "an abandoned stamp left by another verb is cleared on the way past", ctx do
      # Stage 6a's rule from the owner's side: a transition whose lease has
      # expired is an owner that died, not one at work. `Resume` does the same.
      stamp(ctx,
        transition: "parking",
        transition_reason: "idle",
        lease_epoch: 1,
        lease_node: nil
      )

      stub_create(ctx)

      assert {:ok, :provisioned, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, recording_pipeline(), opts()) end)

      assert row(ctx).status == "ready"
    end

    test "refuses an enclosing transaction", ctx do
      Repo.transaction(fn ->
        assert {:error, :transaction_open} =
                 Provision.run(ctx.sandbox.id, recording_pipeline(), opts())
      end)
    end
  end

  # ── an interrupted attempt ─────────────────────────────────────────────────

  describe "an interrupted attempt" do
    test "a starting row is discarded before it is created again", ctx do
      stamp(ctx, status: "starting")
      built = stub_create(ctx)
      test = self()

      expect(Managoat.Sandbox, :destroy, fn %Handle{name: name} ->
        send(test, {:discarded, name})
        :ok
      end)

      expect(Managoat.Sandbox, :create, fn :sprites, name ->
        send(test, {:created, name})
        {:ok, built}
      end)

      assert {:ok, :provisioned, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, recording_pipeline(), opts()) end)

      # The order is the point: the remnant goes first, because
      # `Managoat.Sandbox.create/2` adopts an existing machine by name and the
      # pipeline's steps are not idempotent.
      assert_received {:discarded, name}
      assert_received {:created, ^name}
    end

    test "a pending row wearing an abandoned provisioning stamp is discarded too", ctx do
      # The shape `main` could not see and this stage introduces: the stamp goes
      # on before the create, so a `pending` row wearing one is an attempt that
      # may have created a machine and died before it could say so.
      abandon_mid_provision(ctx)
      built = stub_create(ctx)
      test = self()

      expect(Managoat.Sandbox, :destroy, fn _handle ->
        send(test, :discarded)
        :ok
      end)

      expect(Managoat.Sandbox, :create, fn :sprites, _name -> {:ok, built} end)

      assert {:ok, :provisioned, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, recording_pipeline(), opts()) end)

      assert_received :discarded
      assert row(ctx).status == "ready"
    end

    test "a discard the provider refuses does not stop the rebuild", ctx do
      stamp(ctx, status: "starting")
      built = stub_create(ctx)
      stub(Managoat.Sandbox, :destroy, fn _handle -> {:error, :not_found} end)
      expect(Managoat.Sandbox, :create, fn :sprites, _name -> {:ok, built} end)

      assert {:ok, :provisioned, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, recording_pipeline(), opts()) end)

      assert row(ctx).status == "ready"
    end

    test "a takeover re-reads every condition under its own lease", ctx do
      # There is no separate takeover clause, and this is why that is safe: the
      # abandoned row goes through `admissible/1` like any other.
      abandon_mid_provision(ctx,
        status: "starting",
        transition: "destroying",
        transition_reason: "reset"
      )

      reject(&Managoat.Sandbox.create/2)
      reject(&Managoat.Sandbox.destroy/1)

      assert {:error, :fenced} = Provision.run(ctx.sandbox.id, recording_pipeline(), opts())
      assert row(ctx).status == "starting"
    end
  end

  # ── the create ─────────────────────────────────────────────────────────────

  describe "the machine that could not be created" do
    test "fails the row and answers the provider's reason", ctx do
      stub(Managoat.Sandbox, :create, fn :sprites, _name -> {:error, :quota_exhausted} end)
      reject(&Managoat.Sandbox.destroy/1)

      assert {:error, :quota_exhausted} =
               answer(fn -> Provision.run(ctx.sandbox.id, recording_pipeline(), opts()) end)

      failed = row(ctx)
      assert failed.status == "failed"
      assert failed.transition == nil
      refute is_nil(failed.terminated_at)
      assert_lease_released(failed)

      assert [event] = events(ctx, "sandbox.provision_failed")
      assert event.metadata["reason"] == "create_failed"
    end

    test "the pipeline never runs", ctx do
      stub(Managoat.Sandbox, :create, fn :sprites, _name -> {:error, :quota_exhausted} end)

      answer(fn ->
        Provision.run(
          ctx.sandbox.id,
          fn _handle, _epoch -> flunk("the pipeline ran without a machine") end,
          opts()
        )
      end)
    end
  end

  # ── the window between the create and `starting` ───────────────────────────

  describe "the row that was settled between the create and the status" do
    test "a retirement destroys the machine and writes nothing", ctx do
      # A window `main` did not have: it wrote `starting` *before* the create.
      # The first draft answered `:create_failed` for every refusal of the
      # post-create write, which dropped the handle on the floor and then wrote
      # `failed` over the terminal row — `Lease.refuse_revival/2` permits
      # terminal-to-terminal, so the write landed and a spurious
      # `sandbox.provision_failed` went with it (round 1, protocol review).
      test = self()
      built = handle(ctx)

      expect(Managoat.Sandbox, :create, fn :sprites, _name ->
        stamp(ctx, status: "terminated", terminated_at: DateTime.utc_now())
        {:ok, built}
      end)

      expect(Managoat.Sandbox, :destroy, fn ^built ->
        send(test, :destroyed)
        :ok
      end)

      assert {:ok, :already_terminal} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> flunk("the pipeline ran on a machine the row had lost") end,
                   opts()
                 )
               end)

      assert_received :destroyed

      # Another actor's write, untouched — status, reason and trail.
      settled = row(ctx)
      assert settled.status == "terminated"
      assert settled.transition_reason == nil
      assert events(ctx, "sandbox.provision_failed") == []
    end

    test "a takeover leaves the machine alone, because its name is the row's", ctx do
      # The other half of the same window, and the opposite answer: the taker is
      # building under this row's name, so a destroy here would take theirs.
      test = self()
      built = handle(ctx)

      expect(Managoat.Sandbox, :create, fn :sprites, _name ->
        stamp(ctx, lease_epoch: 99, lease_node: "taker@node")
        {:ok, built}
      end)

      stub(Managoat.Sandbox, :destroy, fn _handle ->
        send(test, :destroyed)
        :ok
      end)

      assert {:error, :superseded} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> flunk("the pipeline ran on a machine the row had lost") end,
                   opts()
                 )
               end)

      refute_received :destroyed
      assert row(ctx).status == "pending"
      assert events(ctx, "sandbox.provision_failed") == []
    end

    test "a database fault leaves the machine for the next attempt to discard", ctx do
      # The lease is still this attempt's and the stamp is still on a live row,
      # so `interrupted?/1` reads it next time. Destroying here would be right
      # too, but the row cannot say the machine exists, and a destroy that also
      # failed would leave nothing to find it by.
      test = self()
      built = handle(ctx)
      stub(Managoat.Sandbox, :create, fn :sprites, _name -> {:ok, built} end)

      stub(Managoat.Sandbox, :destroy, fn _handle ->
        send(test, :destroyed)
        :ok
      end)

      expect(Lease, :cas_update, 2, fn id, epoch, attrs, lopts ->
        if attrs[:status] == "starting" do
          {:error, {:database, :some_sqlstate}}
        else
          Mimic.call_original(Lease, :cas_update, [id, epoch, attrs, lopts])
        end
      end)

      assert {:error, {:database, :some_sqlstate}} =
               answer(fn ->
                 Provision.run(ctx.sandbox.id, fn _h, _e -> flunk("unreachable") end, opts())
               end)

      refute_received :destroyed
      current = row(ctx)
      assert current.status == "pending"
      assert current.transition == "provisioning", "the stamp the next attempt reads is gone"
    end
  end

  # ── the three failure arms ─────────────────────────────────────────────────

  describe "the pipeline that failed" do
    test "a plain error destroys this attempt's machine and fails the row", ctx do
      built = stub_create(ctx)
      test = self()

      expect(Managoat.Sandbox, :destroy, fn ^built ->
        send(test, :destroyed)
        :ok
      end)

      assert {:error, :apt_failed, :reached} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> {:error, :apt_failed, :reached} end,
                   opts()
                 )
               end)

      assert_received :destroyed

      failed = row(ctx)
      assert failed.status == "failed"
      assert failed.transition_reason == "apt_failed"
      assert_lease_released(failed)

      assert [event] = events(ctx, "sandbox.provision_failed")
      assert event.metadata["reason"] == "apt_failed"
    end

    test "a tuple reason reaches the column and the trail without raising", ctx do
      # `transition_reason` is a string column and the metadata is JSON, so a
      # step that answers `{:broker, :session, :timeout}` used to raise
      # `Protocol.UndefinedError` from inside the failure handler — the worst
      # place in this protocol to raise from.
      built = stub_create(ctx)
      stub(Managoat.Sandbox, :destroy, fn ^built -> :ok end)

      assert {:error, {:broker, :session, :timeout}, nil} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> {:error, {:broker, :session, :timeout}, nil} end,
                   opts()
                 )
               end)

      assert row(ctx).transition_reason == "{:broker, :session, :timeout}"
    end

    for reason <- [:configuration_changed, :sandbox_reset_pending, :retired] do
      test "#{reason} destroys this attempt's machine and writes nothing", ctx do
        # Another actor owns this row. `main` was explicit about it in two
        # comments — "Retire only its own resources"; "a replacement may own it"
        # — and writing `failed` here would fail a conversation a successor has
        # already taken over.
        built = stub_create(ctx)
        test = self()

        expect(Managoat.Sandbox, :destroy, fn ^built ->
          send(test, :destroyed)
          :ok
        end)

        assert {:error, unquote(reason), :reached} =
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> {:error, unquote(reason), :reached} end,
                   opts()
                 )

        assert_received :destroyed

        untouched = row(ctx)
        assert untouched.status == "starting"
        assert untouched.transition == "provisioning"
        assert_lease_released(untouched)
        assert events(ctx, "sandbox.provision_failed") == []
      end
    end

    test "a destroy the provider refuses is not fatal", ctx do
      stub_create(ctx)
      stub(Managoat.Sandbox, :destroy, fn _handle -> {:error, :gone} end)

      assert {:error, :apt_failed, nil} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> {:error, :apt_failed, nil} end,
                   opts()
                 )
               end)

      assert row(ctx).status == "failed"
    end
  end

  # ── the finalize that lost the row ─────────────────────────────────────────

  describe "the row that was settled while the machine was being built" do
    test "a retirement destroys the machine and writes nothing", ctx do
      built = stub_create(ctx)
      test = self()

      expect(Managoat.Sandbox, :destroy, fn ^built ->
        send(test, :destroyed)
        :ok
      end)

      pipeline = fn _handle, _epoch ->
        stamp(ctx, status: "terminated", terminated_at: DateTime.utc_now())
        {:ok, :built}
      end

      assert {:ok, :already_terminal, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, pipeline, opts()) end)

      assert_received :destroyed
      assert row(ctx).status == "terminated"
      assert events(ctx, "sandbox.provisioned") == []
    end

    test "a reset fence landing mid-build refuses the ready write", ctx do
      # The hole `refuse_fenced:` closes. `Lease.cas_update/4` does not consult
      # the fence columns by default, and `update_sandbox/2` was the only thing
      # refusing a live status over a reset — so without it this would have
      # handed a conversation a machine the reconciler was about to delete.
      built = stub_create(ctx)
      test = self()

      expect(Managoat.Sandbox, :destroy, fn ^built ->
        send(test, :destroyed)
        :ok
      end)

      pipeline = fn _handle, _epoch ->
        stamp(ctx, transition: "destroying", transition_reason: "reset")
        {:ok, :built}
      end

      assert {:error, :fenced, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, pipeline, opts()) end)

      assert_received :destroyed

      fenced = row(ctx)
      assert fenced.status == "starting"
      assert events(ctx, "sandbox.provisioned") == []
    end

    test "a takeover leaves the machine alone, because its name is the row's", ctx do
      # `:superseded` is the one arm that destroys *nothing*. A machine's name is
      # its row's, so the owner that took this row over is building under the
      # same name — a destroy here would tear down theirs. Their own
      # `interrupted?` collects it.
      stub_create(ctx)
      test = self()

      # Observed rather than `reject`ed: `destroy_attempt/3` rescues anything the
      # adapter raises, Mimic's rejection included, so a rejected call would be
      # swallowed and this test would pass with the bug in it. Found by
      # reverting.
      stub(Managoat.Sandbox, :destroy, fn _handle ->
        send(test, :destroyed)
        :ok
      end)

      pipeline = fn _handle, _epoch ->
        # Somebody else takes the lease, which is what a superseded finalize is.
        stamp(ctx, lease_epoch: 99, lease_node: "other@node")
        {:ok, :built}
      end

      assert {:error, :superseded, :built} =
               answer(fn -> Provision.run(ctx.sandbox.id, pipeline, opts()) end)

      refute_received :destroyed, "the taker's machine was destroyed by the owner it superseded"
      assert row(ctx).status == "starting"
      assert events(ctx, "sandbox.provisioned") == []
    end
  end

  # ── the deadline ───────────────────────────────────────────────────────────

  describe "the lease holder (ADR 0072)" do
    test "a superseded provision with nothing to unwind answers two elements", ctx do
      # `:orphaned` means the `starting` compare-and-set was refused, and a
      # superseding claim is what refuses it. It must answer two elements, not
      # three-with-`nil`: `Machine.provision/3` maps a three-tuple to
      # `{:ok, :claimed_elsewhere, result}`, and `FreshProvision` reads the
      # third element as "there is state of yours to release".
      built = handle(ctx)

      expect(Managoat.Sandbox, :create, fn :sprites, _name ->
        {:ok, _taker} = Lease.claim(ctx.sandbox.id, supersede: self())
        {:ok, built}
      end)

      assert {:error, :superseded} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> flunk("the pipeline ran on a machine the row had lost") end,
                   opts()
                 )
               end)
    end

    test "a slow pipeline keeps the machine for as long as its server lives", ctx do
      stub_create(ctx)
      test = self()

      pipeline = fn _handle, _epoch ->
        Process.sleep(200)
        send(test, {:taken, Task.async(fn -> Lease.claim(ctx.sandbox.id) end) |> Task.await()})
        {:ok, :built}
      end

      assert {:ok, :provisioned, :built} = Provision.run(ctx.sandbox.id, pipeline, opts())

      assert_received {:taken, {:error, {:held, _holder}}},
                      "another claimant took a machine its operation was still working on"

      assert row(ctx).status == "ready"
    end
  end

  # ── contention ─────────────────────────────────────────────────────────────

  describe "contention" do
    test "a second provision of one row is refused, and touches nothing", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      reject(&Managoat.Sandbox.create/2)
      reject(&Managoat.Sandbox.destroy/1)

      assert {:error, :machine_busy} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   recording_pipeline(),
                   opts(busy_wait_ms: 10)
                 )
               end)

      current = row(ctx)
      assert current.status == "pending"
      assert current.transition == nil
      assert current.lease_node == Lease.holder(self()), "the waiter took a lease it was refused"
    end

    test "the wait is bounded by :busy_wait_ms", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      started = System.monotonic_time(:millisecond)

      answer(fn ->
        assert {:error, :machine_busy} =
                 Provision.run(ctx.sandbox.id, recording_pipeline(), opts(busy_wait_ms: 400))
      end)

      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 250, "the wait gave up immediately"
      assert elapsed < 4_000, "the wait outlived its bound"
    end
  end

  # ── confirm_up ─────────────────────────────────────────────────────────────

  describe "confirm_up/2" do
    test "a ready row is confirmed, with no provider call and no event", ctx do
      stamp(ctx, status: "ready")
      reject(&Managoat.Sandbox.get/1)
      reject(&Managoat.Sandbox.resume/1)
      before = row(ctx).updated_at

      assert {:ok, :confirmed} = Provision.confirm_up(ctx.sandbox.id, opts())

      current = row(ctx)
      assert current.status == "ready"
      assert is_nil(current.last_resumed_at)
      assert_lease_released(current)

      # `updated_at` moves, which is what `release_stuck_sandboxes/0` reads as a
      # sign of life and the reason this write is not a no-op.
      assert DateTime.compare(current.updated_at, before) in [:gt, :eq]
      assert events(ctx, "sandbox.resumed") == []
    end

    test "a suspended row is a wake: last_resumed_at and the event", ctx do
      stamp(ctx, status: "suspended")
      reject(&Managoat.Sandbox.resume/1)

      assert {:ok, :confirmed} =
               Provision.confirm_up(ctx.sandbox.id, opts(conversation_id: ctx.conv.id))

      up = row(ctx)
      assert up.status == "ready"
      assert %DateTime{} = up.last_resumed_at

      assert [event] = events(ctx, "sandbox.resumed")
      assert event.actor == "system:conversation_server"
      assert event.metadata["conversation_id"] == ctx.conv.id
    end

    for terminal <- ["terminated", "failed"] do
      test "a #{terminal} row is not confirmed", ctx do
        stamp(ctx, status: unquote(terminal))

        assert {:ok, :already_terminal} = Provision.confirm_up(ctx.sandbox.id, opts())
        assert row(ctx).status == unquote(terminal)
      end
    end

    test "a fenced row is refused", ctx do
      stamp(ctx, status: "ready", transition: "destroying", transition_reason: "reset")

      assert {:error, :fenced} = Provision.confirm_up(ctx.sandbox.id, opts())
    end

    test "a row that is still being built is not one to attach to", ctx do
      assert {:error, {:not_confirmable, "pending"}} =
               Provision.confirm_up(ctx.sandbox.id, opts())
    end
  end

  # ── fail/2 ─────────────────────────────────────────────────────────────────

  describe "fail/2" do
    for status <- ["pending", "starting"] do
      test "retires a #{status} row, with the effects and one event", ctx do
        stamp(ctx, status: unquote(status))

        assert {:ok, :failed} =
                 Provision.fail(ctx.sandbox.id, opts(reason: :server_start_failed))

        failed = row(ctx)
        assert failed.status == "failed"
        assert failed.transition_reason == "server_start_failed"
        refute is_nil(failed.terminated_at)
        assert_lease_released(failed)

        assert [event] = events(ctx, "sandbox.provision_failed")
        assert event.metadata["reason"] == "server_start_failed"
      end
    end

    for status <- ["ready", "suspended", "terminated"] do
      test "leaves a #{status} row alone", ctx do
        stamp(ctx, status: unquote(status))

        assert {:ok, settled} = Provision.fail(ctx.sandbox.id, opts(reason: :deadline))
        assert settled in [:not_provisioning, :already_terminal]
        assert row(ctx).status == unquote(status)
        assert events(ctx, "sandbox.provision_failed") == []
      end
    end

    test ":before_write runs under the lease and can stand the retire down", ctx do
      test = self()

      guard = fn %Sandbox{} = machine ->
        send(test, {:guarded, machine.status, machine.lease_node})
        :stale
      end

      assert {:ok, :not_provisioning} =
               Provision.fail(ctx.sandbox.id, opts(reason: :deadline, before_write: guard))

      assert_received {:guarded, "pending", holder}
      assert is_binary(holder), "the guard ran without the lease it is supposed to run under"
      assert row(ctx).status == "pending"
    end

    test "a lease somebody else holds refuses the retire", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)

      assert {:error, :machine_busy} =
               answer(fn ->
                 Provision.fail(ctx.sandbox.id, opts(reason: :deadline, busy_wait_ms: 10))
               end)

      assert row(ctx).status == "pending"
    end
  end

  # ── the door ───────────────────────────────────────────────────────────────

  describe "the door" do
    test "a busy machine reads as another owner's, not as a failure", ctx do
      expect(Provision, :run, fn _id, _fun, _opts -> {:error, :machine_busy} end)

      assert {:ok, :claimed_elsewhere} =
               answer(fn -> Machine.provision(ctx.sandbox.id, recording_pipeline(), opts()) end)
    end

    test "a supersession carries the state the pipeline reached", ctx do
      expect(Provision, :run, fn _id, _fun, _opts -> {:error, :superseded, :reached} end)

      assert {:ok, :claimed_elsewhere, :reached} =
               answer(fn -> Machine.provision(ctx.sandbox.id, recording_pipeline(), opts()) end)
    end

    test ":fenced becomes the word the server's own arms match on", ctx do
      expect(Provision, :run, fn _id, _fun, _opts -> {:error, :fenced} end)

      assert {:error, :sandbox_reset_pending} =
               Machine.provision(ctx.sandbox.id, recording_pipeline(), opts())
    end

    test "the pipeline's own reason travels", ctx do
      expect(Provision, :run, fn _id, _fun, _opts -> {:error, :apt_failed, :reached} end)

      assert {:error, :apt_failed, :reached} =
               Machine.provision(ctx.sandbox.id, recording_pipeline(), opts())
    end

    test "an enclosing transaction is the caller's bug", ctx do
      Repo.transaction(fn ->
        assert {:error, :provider_transaction_open} =
                 Machine.provision(ctx.sandbox.id, recording_pipeline(), opts())

        assert {:error, :provider_transaction_open} = Machine.confirm_up(ctx.sandbox.id, opts())

        assert {:error, :provider_transaction_open} =
                 Machine.fail_provision(ctx.sandbox.id, opts(reason: :x))
      end)
    end

    test "provisions through the door", ctx do
      stub_create(ctx)

      assert {:ok, :provisioned, :built} =
               Machine.provision(ctx.sandbox.id, recording_pipeline(), opts())

      assert row(ctx).status == "ready"
      assert [_one] = events(ctx, "sandbox.provisioned")
    end

    test "the bracket runs on the caller, not in the owner", ctx do
      # Deliberate, and the one place the provision family differs from the
      # other three: the callback is the caller's pipeline, so it must not be
      # moved into another process. `Fountain.Machines.Provision`'s moduledoc
      # argues it; this pins it.
      stub_create(ctx)
      test = self()

      pipeline = fn _handle, _epoch ->
        send(test, {:ran_in, self()})
        {:ok, :built}
      end

      assert {:ok, :provisioned, :built} =
               Machine.provision(ctx.sandbox.id, pipeline, opts())

      assert_received {:ran_in, pid}
      assert pid == self(), "the pipeline was moved out of its caller"
    end
  end

  # ── across connections ─────────────────────────────────────────────────────
  #
  # Everything above runs on the suite's single sandboxed connection, where two
  # operations on one machine cannot interleave. The two properties the bracket
  # is actually about — that two servers never provision one row, and that
  # neither advisory lock is held across the provider — are therefore only
  # observable with real, committed, concurrent connections. Same machinery as
  # `resume_test.exs`'s block of the same name.
  describe "across connections" do
    setup :set_mimic_global

    @tag :capture_log
    test "two servers never provision one row" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        try do
          stub(Managoat.Sandbox, :create, fn :sprites, name ->
            send(owner, {:created, name})
            # Long enough that the second server is certain to arrive while the
            # first still holds the lease.
            Process.sleep(700)
            {:ok, %Handle{provider: :sprites, name: name}}
          end)

          pipeline = fn _handle, _epoch -> {:ok, :built} end

          first =
            independent(fn ->
              Provision.run(tenant.sandbox.id, pipeline, opts())
            end)

          assert_receive {:backend, _, _}, 5_000
          assert_receive {:created, _name}, 5_000

          # Its busy wait is shortened so this test does not spend the
          # protocol's full five seconds proving a refusal.
          second =
            independent(fn ->
              Provision.run(tenant.sandbox.id, pipeline, opts(busy_wait_ms: 100))
            end)

          assert_receive {:backend, _, _}, 5_000

          try do
            assert {:ok, :provisioned, :built} = Task.await(first, 15_000)
            assert {:error, :machine_busy} = Task.await(second, 15_000)
          after
            for task <- [first, second], do: Task.shutdown(task, :brutal_kill)
          end

          # One machine, and the row is the winner's.
          refute_receive {:created, _name}, 200
          assert Repo.get!(Sandbox, tenant.sandbox.id).status == "ready"
        after
          discard(tenant)
        end
      end)
    end

    @tag :capture_log
    test "the bracket holds neither advisory lock across the provider" do
      # The lock-order rule, proved the way `resume_test.exs` proves it: 4316
      # lives and dies inside `Lease.claim/4`'s own short transaction, and the
      # provision takes 4315 not at all — its reservation was the row's insert.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        try do
          stub(Managoat.Sandbox, :create, fn :sprites, name ->
            {:ok, %Handle{provider: :sprites, name: name}}
          end)

          pipeline = fn _handle, _epoch ->
            %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")

            send(
              owner,
              {:locks, advisory_locks_held(backend, @sandbox_lock_namespace),
               advisory_locks_held(backend, @quota_lock_namespace)}
            )

            {:ok, :built}
          end

          task =
            independent(fn ->
              Provision.run(tenant.sandbox.id, pipeline, opts())
            end)

          assert_receive {:backend, _, _}, 5_000
          assert {:ok, :provisioned, :built} = Task.await(task, 15_000)
          assert_received {:locks, 0, 0}
        after
          discard(tenant)
        end
      end)
    end
  end

  # A committed user and machine, kept as small as the foreign keys allow so
  # `discard/1` can take them all back out.
  defp committed_tenant do
    user =
      Repo.insert!(%Fountain.Accounts.User{
        email: "machine-provision-#{Ecto.UUID.generate()}@example.test"
      })

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "provision-#{Ecto.UUID.generate()}",
        status: "pending",
        user_id: user.id,
        workspace_id: Fountain.Factory.insert_workspace(user_id: user.id).id
      })
      |> Repo.insert!()

    %{user: user, sandbox: sandbox}
  end

  defp discard(%{user: user, sandbox: sandbox}) do
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
    Repo.delete!(sandbox)
    Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
    Repo.delete!(user)
  end

  # ── the implicit workspace (ADR 0097, step 2) ──────────────────────────────

  describe "the sandbox's implicit workspace" do
    setup ctx do
      ws = insert_workspace(user_id: ctx.user.id)
      stamp(ctx, workspace_id: ws.id)
      {:ok, ws: ws}
    end

    test "takes ready when the provision finalizes", ctx do
      stub_create(ctx)

      assert {:ok, :provisioned, :built} =
               Provision.run(ctx.sandbox.id, recording_pipeline(), opts())

      assert Repo.reload!(ctx.ws).status == "ready"
    end

    test "takes failed when the pipeline fails", ctx do
      stub_create(ctx)
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      assert {:error, :apt_failed, :reached} =
               answer(fn ->
                 Provision.run(
                   ctx.sandbox.id,
                   fn _h, _e -> {:error, :apt_failed, :reached} end,
                   opts()
                 )
               end)

      assert Repo.reload!(ctx.ws).status == "failed"
    end

    test "takes failed when fail/2 retires the row, with or without :before_write", ctx do
      assert {:ok, :failed} =
               Provision.fail(ctx.sandbox.id,
                 actor: "system:launch",
                 reason: :server_start_failed,
                 before_write: fn _ -> :ok end
               )

      assert Repo.reload!(ctx.ws).status == "failed"
    end

    test "stays provisioning when a before_write stands the retire down", ctx do
      assert {:ok, :not_provisioning} =
               Provision.fail(ctx.sandbox.id,
                 actor: "system:launch",
                 reason: :server_start_failed,
                 before_write: fn _ -> :stale end
               )

      assert Repo.reload!(ctx.ws).status == "provisioning"
    end
  end

  # One task on a connection of its own, announcing its backend pid so the test
  # can watch what it holds.
  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
        send(owner, {:backend, self(), backend})
        fun.()
      end)
    end)
  end

  # How many advisory locks in `namespace` that backend is holding or waiting
  # for. Postgres stores a two-int advisory key as `classid`/`objid`.
  defp advisory_locks_held(backend, namespace) do
    %{rows: [[count]]} =
      Repo.query!(
        "SELECT count(*) FROM pg_locks " <>
          "WHERE locktype = 'advisory' AND pid = $1 AND classid = $2",
        [backend, namespace]
      )

    count
  end
end
