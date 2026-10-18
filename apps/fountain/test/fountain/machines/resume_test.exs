defmodule Fountain.Machines.ResumeTest do
  @moduledoc """
  The one resume protocol (ADR 0058 stage 7a).

  What these pin is the *order* — the lease, the recheck under it, the
  admission, the intent, the provider, the finalize, the trail — and what each
  step does when the world moved under it. `Park`'s suite is the sibling; the
  two differ in exactly one place, and it is the reason this file exists: a
  resume turns a parked disk back into compute, so it has to pass the quota
  gate, and where that gate runs is the whole of 7a.

  The wake path keeps its own suites (`conversations_wake_test.exs`,
  `wake_policy_test.exs`, `wake_race_test.exs`); this file is the protocol on
  its own.

  `async: false`: several cases run the protocol inside an owner process
  alongside cases that share state with it.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Resume
  alias Managoat.Sandbox.Handle

  # The two advisory-lock namespaces a resume touches, spelled out here rather
  # than read from the modules that own them: a probe that imported the number
  # it is checking could not catch one of them changing.
  @quota_lock_namespace 4315
  @sandbox_lock_namespace 4316

  setup do
    stub(Managoat.Sandbox, :exec, fn _handle, "true", [], _opts -> {:ok, "", 0} end)
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "suspended")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp opts(extra \\ []), do: Keyword.merge([actor: "system:wake"], extra)

  defp row(ctx), do: Repo.reload!(ctx.sandbox)

  defp events(ctx, action), do: Audit.list_for_user(ctx.user.id, action_prefix: action)

  # The suite runs at `:warning`, so the `Logger.info` lines the takeover and the
  # refusals write are never captured. Swallowed rather than asserted on:
  # raising the global level to read them would make every other file's
  # `capture_log` noisier, and a log line is not what any of these tests are
  # about.
  defp quietly(fun), do: capture_log(fun)

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

  # The row a resume leaves when its owner dies between the intent and the
  # finalize: `suspended`, stamped `resuming`, lease held by a node that is not
  # coming back. Forged rather than produced, because producing it means killing
  # a process mid-provider-call and the thing under test is what the *next*
  # owner does with what is left.
  defp abandon_mid_resume(ctx, overrides \\ []) do
    put_lease(
      ctx.sandbox.id,
      Keyword.merge(
        [
          lease_epoch: 1,
          lease_node: dead_lease_holder(),
          transition: "resuming",
          transition_reason: nil
        ],
        overrides
      )
    )

    :ok
  end

  describe "exec readiness" do
    test "a probe holds the lease and blocks reads until successful finalization", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
      owner = self()

      expect(Managoat.Sandbox, :exec, fn _, "true", [], probe_opts ->
        mid = row(ctx)
        assert mid.status == "suspended"
        assert mid.transition == "resuming"
        assert Lease.live?(mid)
        refute Repo.in_transaction?()
        assert probe_opts[:timeout] > 0
        assert probe_opts[:timeout] <= 10_000

        assert {:error, {:sandbox_not_ready, "suspended"}} =
                 Fountain.Machines.Reads.run(mid.id, fn _, _ -> flunk("read admitted") end)

        send(owner, :probed)
        {:ok, "", 0}
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert_receive :probed

      assert :read_served =
               Fountain.Machines.Reads.run(ctx.sandbox.id, fn _, _ -> :read_served end)
    end

    test "a timed-out probe leaves the parked disk retryable with no success audit", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
      stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:error, {:unavailable, :timeout}} end)

      quietly(fn ->
        assert {:error, :resume_failed} =
                 Resume.run(ctx.sandbox.id, opts(readiness_timeout_ms: 30, readiness_retry_ms: 1))
      end)

      assert row(ctx).status == "suspended"
      assert is_nil(row(ctx).transition)
      assert is_nil(row(ctx).last_resumed_at)
      assert_lease_released(row(ctx))
      assert events(ctx, "sandbox.resumed") == []
    end

    test "failed implicit wake remains unreadable through reboot and recovers without resetting lifetime",
         ctx do
      original = ~U[2026-01-01 00:00:00Z]
      stamp(ctx, status: "ready", last_resumed_at: original)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
      expect(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 1} end)

      quietly(fn ->
        assert {:error, :resume_failed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))
      end)

      assert row(ctx).status == "ready"
      assert row(ctx).transition == "resuming"
      assert_lease_released(row(ctx))
      Lease.sweep_boot()
      assert row(ctx).transition == "resuming"

      assert {:error, :sandbox_unavailable} =
               Fountain.Machines.Reads.run(ctx.sandbox.id, fn _, _ -> flunk("read admitted") end)

      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{status: :running}} end)
      expect(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)
      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert row(ctx).last_resumed_at == original
      assert events(ctx, "sandbox.resumed") == []
    end

    test "a takeover cannot finalize from provider status alone", ctx do
      abandon_mid_resume(ctx)
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{status: :running}} end)
      expect(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:error, :not_found} end)
      assert {:error, :resume_failed} = Resume.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
      assert is_nil(row(ctx).transition)
      assert events(ctx, "sandbox.resumed") == []
    end

    test "a probe result cannot finalize after its lease is superseded", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      expect(Managoat.Sandbox, :exec, fn _, _, _, _ ->
        stamp(ctx, lease_epoch: row(ctx).lease_epoch + 1, status: "terminated")
        {:ok, "", 0}
      end)

      quietly(fn -> assert {:error, :superseded} = Resume.run(ctx.sandbox.id, opts()) end)
      assert row(ctx).status == "terminated"
      assert events(ctx, "sandbox.resumed") == []
    end
  end

  describe "the happy path" do
    test "stamps the intent, resumes, finalizes, audits, in that order", ctx do
      test = self()
      name = ctx.sandbox.machine_name

      expect(Managoat.Sandbox, :resume, fn %Handle{provider: :sprites, name: ^name} = handle ->
        # Read *during* the provider call: the intent is on the row and the
        # status is not, which is the ordering the whole protocol is about.
        mid = Repo.reload!(ctx.sandbox)
        send(test, {:mid_call, mid.status, mid.transition, mid.lease_node})
        {:ok, handle}
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      assert_receive {:mid_call, "suspended", "resuming", holder}
      assert is_binary(holder), "the provider was called without the lease held"

      up = row(ctx)
      assert up.status == "ready"
      assert %DateTime{} = up.last_resumed_at
      assert is_nil(up.transition)
      assert_lease_released(up)
    end

    test "records one sandbox.resumed, with the requester in its metadata", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} =
               Resume.run(ctx.sandbox.id, opts(requesting_conversation_id: ctx.conv.id))

      assert [event] = events(ctx, "sandbox.resumed")
      assert event.actor == "system:wake"
      assert event.resource_type == "sandbox"
      assert event.resource_id == ctx.sandbox.id
      assert event.metadata["provider"] == "sprites"
      assert event.metadata["sprite_name"] == ctx.sandbox.machine_name
      assert event.metadata["conversation_id"] == ctx.conv.id
    end

    test "the audit is written after the finalize commits, never before", ctx do
      test = self()
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      expect(Fountain.Audit, :record, fn attrs ->
        send(test, {:audited_at, Repo.reload!(ctx.sandbox).status})
        Mimic.call_original(Fountain.Audit, :record, [attrs])
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert_receive {:audited_at, "ready"}
    end
  end

  describe "the recheck under the lease" do
    test "a machine that is already up is not resumed", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "ready"})
      reject(&Managoat.Sandbox.resume/1)

      assert {:ok, :already_up} = Resume.run(ctx.sandbox.id, opts())
      assert events(ctx, "sandbox.resumed") == []
    end

    for terminal <- ~w(terminated failed) do
      test "a machine that has stopped (#{terminal}) is not resumed", ctx do
        {:ok, _} = update_sandbox(ctx.sandbox, %{status: unquote(terminal)})
        reject(&Managoat.Sandbox.resume/1)

        assert {:ok, :already_terminal} = Resume.run(ctx.sandbox.id, opts())
        assert row(ctx).status == unquote(terminal)
      end
    end

    test "a machine whose reset is unconfirmed is fenced, not woken", ctx do
      stamp(ctx, transition: "destroying", transition_reason: "reset")
      reject(&Managoat.Sandbox.resume/1)

      assert {:error, :fenced} = Resume.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
    end

    test "a machine whose teardown has been asked for is fenced, not woken", ctx do
      stamp(ctx, transition: "destroying", transition_reason: "teardown")
      reject(&Managoat.Sandbox.resume/1)

      assert {:error, :fenced} = Resume.run(ctx.sandbox.id, opts())
      assert row(ctx).status == "suspended"
    end

    for status <- ~w(pending starting) do
      test "a machine still being built (#{status}) answers :provisioning", ctx do
        stamp(ctx, status: unquote(status))
        reject(&Managoat.Sandbox.resume/1)

        assert {:error, :provisioning} = Resume.run(ctx.sandbox.id, opts())
      end
    end

    for transition <- ~w(parking retargeting provisioning) do
      test "an abandoned #{transition} stamp is cleared, not treated as a fence", ctx do
        # Round 1, behaviour review, and it is stage 6a's rule from the owner's
        # side: `Lease.claim/4` refuses while a lease is live, so a stamp seen
        # under our own lease belongs to an owner that died. Refusing on it
        # answered 503 to every prompt until an hourly sweep cleared the row —
        # the same withholding 6a round 1 found on the reader's side.
        stamp(ctx, transition: unquote(transition), transition_reason: "whatever")
        stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
        stub(Managoat.Sandbox, :get, fn _handle -> {:ok, %{status: :suspended, raw: %{}}} end)

        quietly(fn -> assert {:ok, _outcome} = Resume.run(ctx.sandbox.id, opts()) end)

        assert is_nil(row(ctx).transition),
               "the stamp outlived the owner that left it and the owner that saw it"
      end

      test "a ready row wearing an abandoned #{transition} stamp answers as main does", ctx do
        # `main`'s answer for a `ready` row is "reuse it", and `ensure_up/2` is
        # asked on every reuse — so this one has to be `:already_up` rather than
        # a refusal.
        stamp(ctx, status: "ready", transition: unquote(transition), transition_reason: "x")
        reject(&Managoat.Sandbox.resume/1)

        quietly(fn -> assert {:ok, :already_up} = Resume.run(ctx.sandbox.id, opts()) end)
        assert is_nil(row(ctx).transition)
      end
    end

    test "a destroying stamp refuses on its own, with no fence column", ctx do
      # The loop above is four transitions rather than five since ADR 0058
      # stage 9a, and this is the fifth. `destroying` is durable intent, not an
      # abandoned operation: somebody asked for this machine to go away, and an
      # owner dying between the fence and the finalize did not withdraw the
      # request. So it is refused whatever the lease says, and by the stamp
      # alone: stage 9b-ii dropped the fence columns that once sat beside it.
      stamp(ctx, transition: "destroying", transition_reason: "terminated")
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn -> assert {:error, :fenced} = Resume.run(ctx.sandbox.id, opts()) end)

      kept = row(ctx)

      assert kept.transition == "destroying",
             "the resume cleared an unfinished destroy off the row"

      assert kept.transition_reason == "terminated"
    end

    test "a ready row wearing a destroying stamp is refused, not reused", ctx do
      # The other half, and the one that inverts `main`. A `ready` row is the
      # shape `ensure_up/2` meets on every reuse, so the loop above answers
      # `:already_up` for the four abandonable stamps. Not this one: the reuse
      # doors refuse such a row ahead of any resume
      # (`Wake.maybe_reuse_sandbox/1`, 409), so what a caller gets is a fresh
      # machine rather than nothing, and reusing the disk here would hand it to
      # a conversation moments before the driver deletes it.
      stamp(ctx, status: "ready", transition: "destroying", transition_reason: "terminated")
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn -> assert {:error, :fenced} = Resume.run(ctx.sandbox.id, opts()) end)
      assert row(ctx).transition == "destroying"
    end

    test "a machine that is not there at all", ctx do
      _ = ctx
      assert {:error, :not_found} = Resume.run(Ecto.UUID.generate(), opts())
    end
  end

  describe "the machine that is already up" do
    test "is answered from one read, with no lease and no write", ctx do
      # Round 1, behaviour review. `ensure_up/2` is asked on every reuse, and a
      # prompt to a running machine is the common case — the first draft claimed
      # and released a lease for it, so `lease_epoch` climbed by two per prompt
      # and two prompts colliding in the five-second wait produced a 503 where
      # `main` wrote nothing at all.
      stamp(ctx, status: "ready")
      before = row(ctx)
      reject(&Managoat.Sandbox.resume/1)

      assert {:ok, :already_up} = Resume.run(ctx.sandbox.id, opts())
      assert {:ok, :already_up} = Resume.run(ctx.sandbox.id, opts())

      after_ = row(ctx)
      assert after_.lease_epoch == before.lease_epoch, "it took a lease it did not need"
      assert after_.updated_at == before.updated_at, "it wrote the row"
      assert_lease_released(after_)
    end

    test "but a machine the caller's probe says is stopped still takes the slow path", ctx do
      stamp(ctx, status: "ready")
      expect(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      quietly(fn ->
        assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))
      end)
    end

    for {label, sets} <- [
          {"a fence", [transition: "destroying", transition_reason: "reset"]},
          {"a teardown fence", [transition: "destroying", transition_reason: "teardown"]},
          {"an abandoned stamp", [transition: "parking"]},
          {"a lease holder", [lease_epoch: 1, lease_node: "somebody@else"]}
        ] do
      test "and #{label} on the row sends it down the slow path", ctx do
        stamp(ctx, [status: "ready"] ++ unquote(Macro.escape(sets)))
        stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

        before = row(ctx)
        quietly(fn -> Resume.run(ctx.sandbox.id, opts(busy_wait_ms: 300)) end)

        assert row(ctx).lease_epoch > before.lease_epoch or row(ctx) != before,
               "the fast path answered for a row that needed the recheck"
      end
    end
  end

  describe "a ready row the provider says is parked" do
    # The other half of the 6b review note: a park whose finalize was lost
    # leaves a `ready` row over a machine E2B calls `paused`. `main` reused it
    # and handed the conversation a handle to a machine that was not running.
    test "is restarted at the provider when the caller's probe saw it suspended", ctx do
      stamp(ctx, status: "ready")
      expect(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      quietly(fn ->
        assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))
      end)

      assert row(ctx).status == "ready"
    end

    test "does not restamp last_resumed_at, so the ceiling's clock does not move", ctx do
      # Round 1, surfaces review, and the reason the two paths part company at
      # the finalize. `Lifecycle.clock_start/1` is `last_resumed_at ||
      # inserted_at`, so restamping here restarts the max-lifetime ceiling on a
      # machine Fountain never parked. On Sprites — the instance default — that
      # is the *ordinary* reading rather than an edge case: its `suspend/1` is a
      # no-op and its `get/1` reports the platform's own scale-to-zero schedule,
      # so every sprite that has scaled to zero by itself arrives here. A
      # ten-hour ceiling would have been pushed ten hours out by a probe.
      stamp(ctx, status: "ready", last_resumed_at: nil)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      quietly(fn ->
        assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))
      end)

      assert is_nil(row(ctx).last_resumed_at),
             "the max-lifetime clock was restarted on a machine that was never parked"
    end

    test "records no sandbox.resumed, because nothing was woken", ctx do
      # A wake in a tenant's trail for a machine that was never suspended
      # describes something that did not happen.
      stamp(ctx, status: "ready")
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      quietly(fn ->
        assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))
      end)

      assert events(ctx, "sandbox.resumed") == []
    end

    test "a machine that really was parked gets both", ctx do
      # The other shape, asserted beside it so the two cannot drift: a row that
      # was `suspended` is a machine Fountain parked, and it gets the stamp and
      # the event.
      stamp(ctx, last_resumed_at: nil)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts(observed: :suspended))

      assert %DateTime{} = row(ctx).last_resumed_at
      assert [_one] = events(ctx, "sandbox.resumed")
    end

    for observed <- [:running, :unknown, nil] do
      test "is left alone when the probe said #{inspect(observed)}", ctx do
        {:ok, _} = update_sandbox(ctx.sandbox, %{status: "ready"})
        reject(&Managoat.Sandbox.resume/1)

        assert {:ok, :already_up} =
                 Resume.run(ctx.sandbox.id, opts(observed: unquote(observed)))
      end
    end
  end

  describe "the provider that will not wake it" do
    test "leaves the row parked, clears the intent, and refuses", ctx do
      expect(Managoat.Sandbox, :resume, fn _handle -> {:error, :boom} end)

      assert capture_log(fn ->
               assert {:error, :resume_failed} = Resume.run(ctx.sandbox.id, opts())
             end) =~ "provider resume failed"

      still = row(ctx)
      assert still.status == "suspended", "the disk is the agent's memory; the row must not lie"
      assert is_nil(still.transition)
      assert_lease_released(still)
      assert events(ctx, "sandbox.resumed") == []
    end

    test "an adapter that raises is the same outcome as one that refuses", ctx do
      expect(Managoat.Sandbox, :resume, fn _handle -> raise "provider exploded" end)

      assert capture_log(fn ->
               assert {:error, :resume_failed} = Resume.run(ctx.sandbox.id, opts())
             end) =~ "provider exploded"

      assert row(ctx).status == "suspended"
      assert_lease_released(row(ctx))
    end

    test "the fleet slot the admission reserved is given back", ctx do
      expect(Managoat.Sandbox, :resume, fn _handle -> {:error, :boom} end)

      capture_log(fn -> assert {:error, :resume_failed} = Resume.run(ctx.sandbox.id, opts()) end)

      # Neither half of the reservation survives — the stamp is cleared and the
      # lease is released — so nothing of this machine counts against the ceiling,
      # which is what lets the retry through. Either one alone would be enough
      # for the count; both are gone because a row that lies about what is
      # happening to it is its own problem (see the test above).
      assert active_sandbox_count(ctx.user.id) == 0
    end
  end

  describe "the fleet ceiling" do
    test "a full fleet cannot wake one more machine", ctx do
      fill_fleet()
      reject(&Managoat.Sandbox.resume/1)

      assert {:error, :fleet_full} = Resume.run(ctx.sandbox.id, opts())

      still = row(ctx)
      assert still.status == "suspended", "refused means still parked, not half-woken"
      assert is_nil(still.transition)
      assert_lease_released(still)
    end

    test "the machine is counted against its own provider's ceiling (#2667)", ctx do
      # The parked machine is a sprite: a full E2B fleet leaves its slot free,
      # and a full Sprites fleet takes it.
      assert row(ctx).provider == "sprites"
      fill_fleet(0, "e2b")
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
    end

    test "the machine being woken is excluded from its own count", ctx do
      # One free slot: the fleet has room for this one. Without the exclusion
      # the `resuming` stamp this writes would count against the check that
      # authorised it and refuse its own resume.
      fill_fleet(1)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
    end

    test "an admitted resume holds a slot before its status says so", ctx do
      # The reservation, observed from the outside: while the provider call is
      # in flight the row still reads `suspended`, and it counts anyway.
      test = self()

      expect(Managoat.Sandbox, :resume, fn handle ->
        mid = Repo.reload!(ctx.sandbox)

        send(
          test,
          {:mid_call, mid.status, active_sandbox_count(ctx.user.id)}
        )

        {:ok, handle}
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert_receive {:mid_call, "suspended", 1}
    end

    test "an abandoned resume stops holding one once its holder is gone", ctx do
      abandon_mid_resume(ctx)
      assert active_sandbox_count(ctx.user.id) == 0

      # …and does hold one while the lease is live, which is the other half of
      # the same rule.
      stamp(ctx, lease_node: live_lease_holder())
      assert active_sandbox_count(ctx.user.id) == 1
    end

    test "the reservation and the stamp commit together", ctx do
      # The design point of 7a, pinned where it can be observed on one
      # connection: the `resuming` stamp is written *inside*
      # `with_sandbox_reservation/2`'s transaction. A stamp that landed in a
      # second transaction would make the ceiling check a read with no record —
      # two wakes of two parked machines would each pass a check the other was
      # invisible to — and a refusal would leave a stamp behind to be swept.
      test = self()
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      expect(Lease, :cas_update, fn id, epoch, attrs, opts ->
        send(test, {:stamp, Repo.in_transaction?(), attrs, opts})
        Mimic.call_original(Lease, :cas_update, [id, epoch, attrs, opts])
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      assert_receive {:stamp, true, [transition: "resuming"], [nest: true]}
    end

    test "the provider is called outside every transaction", ctx do
      # What `main` got wrong, and the reason 7a exists at all: its resume ran
      # inside `with_sandbox_reservation/2`'s transaction, which ADR 0058
      # forbids and #2309 priced. The suite's own sandbox transaction is not
      # reported by `in_transaction?/0`, so `false` here means exactly what it
      # says — nothing the protocol opened is still open.
      test = self()

      expect(Managoat.Sandbox, :resume, fn handle ->
        send(test, {:in_transaction?, Repo.in_transaction?()})
        {:ok, handle}
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert_receive {:in_transaction?, false}
    end

    test "two wakes of two machines cannot overshoot the ceiling", ctx do
      # The case the reservation exists for, and the one a check with no record
      # would let through: two *different* parked machines, one free slot. The
      # first to be admitted holds it; the second is refused rather than both
      # reading "there is room" while both are still `suspended`.
      other = insert_sandbox(user_id: ctx.user.id, status: "suspended")
      on_exit(fn -> stop_machine(other.id) end)
      fill_fleet(1)

      test = self()

      expect(Managoat.Sandbox, :resume, fn handle ->
        # Inside the first resume's provider call — after its admission has
        # committed and before its finalize — the second one runs and must be
        # refused.
        send(test, {:second, Resume.run(other.id, opts())})
        {:ok, handle}
      end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert_receive {:second, {:error, :fleet_full}}

      assert Repo.reload!(other).status == "suspended"
      assert is_nil(Repo.reload!(other).transition)
    end
  end

  describe "takeover" do
    test "a resume that landed is finished by the next owner", ctx do
      abandon_mid_resume(ctx)

      expect(Managoat.Sandbox, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn ->
        assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      end)

      up = row(ctx)
      assert up.status == "ready"
      assert %DateTime{} = up.last_resumed_at
      assert is_nil(up.transition)
      assert [_one] = events(ctx, "sandbox.resumed")
    end

    test "a machine still parked is recovered, not resumed", ctx do
      abandon_mid_resume(ctx)

      expect(Managoat.Sandbox, :get, fn _handle -> {:ok, %{status: :suspended, raw: %{}}} end)
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn ->
        assert {:ok, :recovered} = Resume.run(ctx.sandbox.id, opts())
      end)

      still = row(ctx)
      assert still.status == "suspended"
      assert is_nil(still.transition), "the stamp must not outlive the owner that left it"
      assert events(ctx, "sandbox.resumed") == []
    end

    for {label, answer} <- [
          {"an unknown state", {:ok, %{status: :unknown, raw: %{}}}},
          {"a machine the provider cannot find", {:error, :not_found}},
          {"a provider that is unreachable", {:error, {:unavailable, :timeout}}}
        ] do
      test "#{label} reads as still parked", ctx do
        abandon_mid_resume(ctx)

        expect(Managoat.Sandbox, :get, fn _handle -> unquote(Macro.escape(answer)) end)
        reject(&Managoat.Sandbox.resume/1)

        quietly(fn -> assert {:ok, :recovered} = Resume.run(ctx.sandbox.id, opts()) end)

        assert row(ctx).status == "suspended"
        assert is_nil(row(ctx).transition)
      end
    end

    test "a provider that raises while being probed reads as still parked", ctx do
      abandon_mid_resume(ctx)

      expect(Managoat.Sandbox, :get, fn _handle -> raise "probe exploded" end)
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn -> assert {:ok, :recovered} = Resume.run(ctx.sandbox.id, opts()) end)
      assert row(ctx).status == "suspended"
    end

    test "a takeover re-applies the whole recheck, and leaves the fence when it refuses", ctx do
      # `Park`'s round-1 blocker in this protocol's shape: a fence that landed
      # on the row while the dead owner held it must not be overwritten. The
      # fence is the stamp since stage 9b, written over the abandoned
      # `resuming`, so the `resuming` stamp is already gone and the
      # `destroying` one stays for the driver.
      abandon_mid_resume(ctx)
      stamp(ctx, transition: "destroying", transition_reason: "teardown")

      reject(&Managoat.Sandbox.get/1)
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn ->
        assert {:error, :fenced} = Resume.run(ctx.sandbox.id, opts())
      end)

      assert row(ctx).transition == "destroying"
      assert row(ctx).status == "suspended"
    end

    test "an interrupted implicit wake must prove readiness without restarting the clock", ctx do
      original = ~U[2026-01-01 00:00:00Z]
      abandon_mid_resume(ctx, status: "ready", last_resumed_at: original)
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{status: :running}} end)
      reject(&Managoat.Sandbox.resume/1)
      expect(Managoat.Sandbox, :exec, fn _, "true", [], _ -> {:ok, "", 0} end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())
      assert is_nil(row(ctx).transition)
      assert row(ctx).last_resumed_at == original
      assert events(ctx, "sandbox.resumed") == []
    end

    for terminal <- ~w(terminated failed) do
      test "a #{terminal} row wearing the stamp is not resumed again", ctx do
        abandon_mid_resume(ctx, status: unquote(terminal))

        reject(&Managoat.Sandbox.get/1)
        reject(&Managoat.Sandbox.resume/1)

        assert {:ok, :already_terminal} = Resume.run(ctx.sandbox.id, opts())
        assert is_nil(row(ctx).transition)
      end
    end

    test "a takeover re-runs the admission before it finalizes", ctx do
      # Round 1, behaviour review. The first draft finalized straight from the
      # `:running` branch, reasoning that the dead owner had paid for the slot
      # when it stamped. It had; the slot did not survive it —
      # `Quotas.active_sandboxes/0` counts a `resuming` row only while its lease
      # is live, which is what stops an abandoned resume holding capacity for
      # ever, so by the time a takeover is *possible* the reservation is already
      # gone and somebody else may hold the slot.
      abandon_mid_resume(ctx)
      fill_fleet()

      expect(Managoat.Sandbox, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
      reject(&Managoat.Sandbox.resume/1)

      quietly(fn ->
        assert {:error, :fleet_full} = Resume.run(ctx.sandbox.id, opts())
      end)

      still = row(ctx)
      assert still.status == "suspended", "it finalized past the ceiling"
      assert is_nil(still.transition)
      assert events(ctx, "sandbox.resumed") == []
    end

    test "an implicit wake refused by admission keeps its unreadable guard", ctx do
      abandon_mid_resume(ctx, status: "ready")
      fill_fleet()
      # A ready row already counts; model the ceiling being lowered below
      # the live fleet so there is no slot even after excluding this row.
      insert_sandbox(status: "ready")
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{status: :running}} end)
      reject(&Managoat.Sandbox.exec/4)
      quietly(fn -> assert {:error, :fleet_full} = Resume.run(ctx.sandbox.id, opts()) end)
      assert row(ctx).transition == "resuming"
      assert_lease_released(row(ctx))

      assert {:error, :sandbox_unavailable} =
               Fountain.Machines.Reads.run(ctx.sandbox.id, fn _, _ -> flunk("read admitted") end)
    end

    test "a takeover with room finalizes, and the row is excluded from its own count", ctx do
      # The other side of the same check: re-running the admission costs nothing
      # when there is capacity, because the machine being taken over is left out
      # of the count exactly as on the ordinary path.
      abandon_mid_resume(ctx)
      fill_fleet(1)

      expect(Managoat.Sandbox, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)

      quietly(fn -> assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts()) end)
      assert row(ctx).status == "ready"
      assert [_one] = events(ctx, "sandbox.resumed")
    end
  end

  describe "contention" do
    test "a second resume of a machine that is up calls no provider and writes nothing", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      # The sequential half of "two wakes resume it once". The concurrent half —
      # the second one *waiting* and then reading this — is across connections,
      # in the block below, because two resumes of one machine sharing one
      # connection cannot interleave at all.
      reject(&Managoat.Sandbox.resume/1)
      assert {:ok, :already_up} = Resume.run(ctx.sandbox.id, opts())

      assert [_one] = events(ctx, "sandbox.resumed")
    end

    test "a lease held past the wait is refused with the bound", ctx do
      {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      reject(&Managoat.Sandbox.resume/1)

      started = System.monotonic_time(:millisecond)

      assert capture_log(fn ->
               assert {:error, :machine_busy} =
                        Resume.run(ctx.sandbox.id, opts(busy_wait_ms: 600))
             end) =~ "resume refused"

      waited = System.monotonic_time(:millisecond) - started
      assert waited >= 250, "it did not wait at all"
      assert waited < Resume.busy_wait_ms(), "it waited past the bound it was given"

      :ok = Lease.release(ctx.sandbox.id, epoch)
    end

    test "a park then a resume leaves the machine up, with both trails", ctx do
      stamp(ctx, status: "ready")
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap == :suspend end)
      stub(Managoat.Sandbox, :suspend, fn _handle -> :ok end)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :parked} =
               Fountain.Machines.Park.run(ctx.sandbox.id,
                 actor: "system:sandbox_reaper",
                 reason: :idle
               )

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      assert row(ctx).status == "ready"
      assert [_] = events(ctx, "sandbox.suspended")
      assert [_] = events(ctx, "sandbox.resumed")
    end

    test "a resume then a park leaves the machine parked, with both trails", ctx do
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap == :suspend end)
      stub(Managoat.Sandbox, :suspend, fn _handle -> :ok end)
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      assert {:ok, :parked} =
               Fountain.Machines.Park.run(ctx.sandbox.id,
                 actor: "system:sandbox_reaper",
                 reason: :idle
               )

      assert row(ctx).status == "suspended"
      assert [_] = events(ctx, "sandbox.resumed")
      assert [_] = events(ctx, "sandbox.suspended")
    end

    test "a machine a destroy has finished is not resumed", ctx do
      stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
      reject(&Managoat.Sandbox.resume/1)

      assert {:ok, :destroyed} =
               Fountain.Machines.Destroy.run(ctx.sandbox.id,
                 actor: "system:sandbox_reaper",
                 reason: :expired
               )

      assert {:ok, :already_terminal} = Resume.run(ctx.sandbox.id, opts())
    end

    test "a destroy of a machine a resume just brought up still finishes it", ctx do
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)
      stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

      assert {:ok, :resumed} = Resume.run(ctx.sandbox.id, opts())

      assert {:ok, :destroyed} =
               Fountain.Machines.Destroy.run(ctx.sandbox.id,
                 actor: "system:sandbox_reaper",
                 reason: :expired
               )

      assert row(ctx).status == "terminated"
    end
  end

  describe "the door" do
    test "refuses a caller that is inside a transaction", ctx do
      reject(&Managoat.Sandbox.resume/1)

      Repo.transaction(fn ->
        assert {:error, :provider_transaction_open} = Machine.ensure_up(ctx.sandbox.id, opts())
      end)
    end

    test "the protocol's own guard says the same thing", ctx do
      reject(&Managoat.Sandbox.resume/1)

      Repo.transaction(fn ->
        assert {:error, :transaction_open} = Resume.run(ctx.sandbox.id, opts())
      end)
    end

    test "resumes in the machine's owner", ctx do
      # The owner is another process. It finds this test's connection and its
      # stubs through `$callers`, which `Machine.ensure_started/2` hands it.
      stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

      assert {:ok, :resumed} = Machine.ensure_up(ctx.sandbox.id, opts())
      assert Machine.whereis(ctx.sandbox.id) != nil

      up = row(ctx)
      assert up.status == "ready"
      assert %DateTime{} = up.last_resumed_at
      assert [_one] = events(ctx, "sandbox.resumed")
    end

    test "a superseded resume is a machine that is up, to the caller", ctx do
      expect(Fountain.Machines.Resume, :run, fn _id, _opts -> {:error, :superseded} end)

      quietly(fn ->
        assert {:ok, :already_up} = Machine.ensure_up(ctx.sandbox.id, opts())
      end)
    end

    test "the protocol's :resume_failed becomes the system's word", ctx do
      expect(Fountain.Machines.Resume, :run, fn _id, _opts -> {:error, :resume_failed} end)
      assert {:error, :sandbox_resume_failed} = Machine.ensure_up(ctx.sandbox.id, opts())
    end

    test "contention and database faults read as sandbox_unavailable", ctx do
      for reason <- [:machine_busy, {:database, "57014"}, :lost] do
        expect(Fountain.Machines.Resume, :run, fn _id, _opts -> {:error, reason} end)

        assert capture_log(fn ->
                 assert {:error, :sandbox_unavailable} = Machine.ensure_up(ctx.sandbox.id, opts())
               end) =~ "unavailable"
      end
    end

    test "the words a waking caller has to act on travel unchanged", ctx do
      travelling = [:provisioning, :fleet_full]

      for reason <- travelling do
        expect(Fountain.Machines.Resume, :run, fn _id, _opts -> {:error, reason} end)
        assert {:error, ^reason} = Machine.ensure_up(ctx.sandbox.id, opts())
      end
    end

    test "the protocol's :fenced becomes the system's word, not a bare atom on the wire", ctx do
      # Round 1, surfaces review. `:fenced` is a protocol word with no meaning
      # outside `Fountain.Machines`, and a wake's caller is a prompt — so
      # letting it travel rendered `422 {"error": "fenced"}` through
      # `FallbackController`'s terminal safety net, and put `:fenced` verbatim
      # in a schedule's `last_error`. `Park`'s may travel because both of its
      # callers handle it themselves and neither puts it on the wire.
      expect(Fountain.Machines.Resume, :run, fn _id, _opts -> {:error, :fenced} end)
      assert {:error, :sandbox_reset_pending} = Machine.ensure_up(ctx.sandbox.id, opts())
    end

    test "a fenced machine answers the fence's word end to end", ctx do
      # Through the real protocol rather than a stubbed one, so the translation
      # and the recheck that produces it are pinned together.
      stamp(ctx, transition: "destroying", transition_reason: "teardown")
      reject(&Managoat.Sandbox.resume/1)

      assert {:error, :sandbox_reset_pending} = Machine.ensure_up(ctx.sandbox.id, opts())
    end
  end

  describe "caller bugs" do
    test "an actor is required", ctx do
      assert_raise KeyError, fn -> Resume.run(ctx.sandbox.id, []) end
    end
  end

  # ── across connections ────────────────────────────────────────────────────
  #
  # Everything above runs on the suite's single sandboxed connection, where two
  # operations on one machine cannot interleave and an advisory lock taken in a
  # nested transaction is held until the test rolls back. The two properties 7a
  # is actually about — that two wakes of one machine resume it once, and that
  # the quota lock is not held across the provider call — are therefore only
  # observable with real, committed, concurrent connections. Same machinery as
  # `lease_test.exs`'s own contention block.
  describe "across connections" do
    setup :set_mimic_global

    @tag :capture_log
    test "two wakes of one machine resume it once, and the second is told it is up" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        try do
          stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

          stub(Managoat.Sandbox, :exec, fn _, "true", [], _ ->
            send(owner, :in_provider)
            # Long enough that the second wake is certain to arrive mid-call and
            # short enough to sit well inside its five-second busy wait.
            Process.sleep(700)
            {:ok, "", 0}
          end)

          first = independent(fn -> Resume.run(tenant.sandbox.id, actor: "system:wake") end)
          assert_receive {:backend, _, _}, 5_000
          assert_receive :in_provider, 5_000

          second = independent(fn -> Resume.run(tenant.sandbox.id, actor: "system:wake") end)
          assert_receive {:backend, _, _}, 5_000

          try do
            assert {:ok, :resumed} = Task.await(first, 15_000)

            # The whole of ADR 0023 step 4: the second did not resume the
            # machine and it was not refused either — it waited out the first
            # one's lease and then read what the first one wrote.
            assert {:ok, :already_up} = Task.await(second, 15_000)
          after
            for task <- [first, second], do: Task.shutdown(task, :brutal_kill)
          end

          refute_receive :in_provider, 200
          assert Repo.get!(Sandbox, tenant.sandbox.id).status == "ready"

          assert [_one] = Audit.list_for_user(tenant.user.id, action_prefix: "sandbox.resumed")
        after
          discard(tenant)
        end
      end)
    end

    @tag :capture_log
    test "a resume waiting on the quota lock is holding no sandbox lock" do
      # #2309's deadlock is two lock namespaces taken in opposite orders. This
      # reads the one ordering that exists, from `pg_locks`, at the only moment
      # both could overlap: 4316 is taken and released inside `Lease.claim/4`'s
      # own transaction, and 4315 is taken afterwards by the admission — so a
      # resume stuck on the quota lock is blocking nobody who wants the machine.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        try do
          stub(Managoat.Sandbox, :resume, fn handle -> {:ok, handle} end)

          blocker =
            independent(fn ->
              Repo.transaction(fn ->
                # The fleet key, which `with_sandbox_reservation/2` takes first.
                Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@quota_lock_namespace, 0])
                send(owner, :locked)

                receive do
                  :commit -> :ok
                after
                  15_000 -> raise "quota-lock barrier timed out"
                end
              end)
            end)

          assert_receive {:backend, _, _blocker_backend}, 5_000
          assert_receive :locked, 5_000

          resumer = independent(fn -> Resume.run(tenant.sandbox.id, actor: "system:wake") end)
          assert_receive {:backend, _, resumer_backend}, 5_000

          try do
            await_blocked(resumer_backend, System.monotonic_time(:millisecond) + 5_000)

            assert 0 == advisory_locks_held(resumer_backend, @sandbox_lock_namespace),
                   "the resume is waiting on the quota lock while holding the sandbox lock — " <>
                     "that is the 4316-then-4315 ordering #2309 warned about"

            assert 1 == advisory_locks_held(resumer_backend, @quota_lock_namespace),
                   "the resume is not waiting on the quota lock at all; this probe proves nothing"

            send(blocker.pid, :commit)
            assert {:ok, :resumed} = Task.await(resumer, 15_000)
          after
            for task <- [blocker, resumer], do: Task.shutdown(task, :brutal_kill)
          end
        after
          discard(tenant)
        end
      end)
    end
  end

  # ── unboxed helpers ───────────────────────────────────────────────────────

  # A committed user and machine, kept as small as the foreign keys allow so
  # `discard/1` can take them all back out. Given a cap, because
  # unlike the boxed cases these go through the real admission.
  defp committed_tenant do
    user =
      Repo.insert!(%Fountain.Accounts.User{
        email: "machine-resume-#{Ecto.UUID.generate()}@example.test"
      })

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "resume-#{Ecto.UUID.generate()}",
        status: "suspended",
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

  defp await_blocked(backend, deadline) do
    %{rows: [[blocked]]} = Repo.query!("SELECT cardinality(pg_blocking_pids($1)) > 0", [backend])

    unless blocked do
      assert System.monotonic_time(:millisecond) < deadline,
             "no PostgreSQL advisory-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
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
