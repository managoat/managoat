defmodule Fountain.Workers.SandboxReaperParkTest do
  @moduledoc """
  The reaper's idle park, against the race it lost on `main` (#2307; ADR 0058
  stage 6b).

  Lifted from the salvage branch `follow/2255-reaper-liveness-lock`
  (`sandbox_reaper_lock_order_test.exs`, `sandbox_park_claim_test.exs`) and
  rewritten onto the lease. What that branch proved with an advisory lock held
  on a second connection — that a verdict taken before the lock is stale, and
  that the write must be decided *after* it — is proved here at the seam the
  lease actually creates: the reaper folds a page of rows, and the park then
  claims a lease and re-reads everything under it. So the admission is
  committed from inside `Lease.claim/4`, which is precisely the moment the
  scan's verdict becomes old news, and no second database connection is
  needed to place it there.

  The salvage branch's two remaining halves live elsewhere: the wake and
  attach doors are `machines/mid_operation_readers_test.exs` (stage 6a), and
  the protocol's own arms are `machines/park_test.exs`.

  ## What is deliberately not here

  "Admission wins" for the **max-lifetime expiry**. That path goes through
  `Machines.Destroy` with `terminating_conversation_id: nil`, whose fence is
  unconditional by design (stage 5b: an abandoned machine past its ceiling
  usually still has conversations bound to it, and a fence that could answer
  `:sandbox_kept` would bill forever). It therefore has no liveness recheck
  under its lease, exactly as it had none on `main`. Closing that is stage 8's
  `attach`/`admit_turn`, when admission itself comes through the owner.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Workers.SandboxReaper
  alias Managoat.Sandbox.Handle

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    insert_turn(conv, %{status: "completed"})

    # Idle by a wide margin, and far enough under the ceiling that the idle
    # bound is the one that fires.
    age(sandbox, conv, 60 * 5)

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, sandbox: sandbox, conv: conv}
  end

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  defp age(sandbox, conv, minutes) do
    ts = minutes_ago(minutes)

    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: ts, updated_at: ts]
    )

    Repo.update_all(
      from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
      set: [inserted_at: ts, ended_at: ts]
    )

    Repo.reload!(sandbox)
  end

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp sweep do
    with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
      capture_log(fn -> send(self(), {:swept, SandboxReaper.sweep_abandoned_sandboxes()}) end)
      receive do: ({:swept, result} -> result)
    end)
  end

  defp row(ctx), do: Fountain.Machines.Lease.get(ctx.sandbox.id)

  defp suspended_events(ctx),
    do: Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.suspended")

  # Commit `fun` at the instant the park takes its lease: after the sweep has
  # scanned, folded and decided, and before anything is re-read. That is the
  # window #2307 constraint 1 is about, and stubbing the claim is the only way
  # to put a writer in it deterministically.
  defp admission_at_the_claim(fun) do
    admission_at_the_claim_of(nil, fun)
  end

  # The same, for one machine only: a sweep over several claims each in turn,
  # and a test about the budget needs to know which one it interfered with.
  defp admission_at_the_claim_of(target, fun) do
    # `Park` calls `claim/1`, so this is the arity to stand in front of;
    # stubbing `claim/2` alone would let every call through and prove nothing.
    stub(Lease, :claim, fn sandbox_id ->
      result = Mimic.call_original(Lease, :claim, [sandbox_id])
      if is_nil(target) or target == sandbox_id, do: fun.()
      result
    end)
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

  describe "the durable park claim" do
    test "the row carries the intent and a live lease while the provider call is in flight",
         ctx do
      test = self()

      expect(Managoat.Sandbox, :suspend, fn %Handle{} ->
        send(test, {:mid_park, Fountain.Machines.Lease.get(ctx.sandbox.id)})
        :ok
      end)

      assert {1, 0, 0, _} = sweep()

      assert_received {:mid_park, mid}
      assert mid.transition == "parking"
      assert mid.status == "ready"

      assert Machine.busy?(mid),
             "a wake arriving mid-park would not have been refused — which is the whole " <>
               "of #2307: it would resume the machine this suspend is about to park"

      final = row(ctx)
      assert final.status == "suspended"
      assert is_nil(final.transition)
      assert is_nil(final.lease_node)
      assert [_one] = suspended_events(ctx)
    end
  end

  describe "admission wins the claim" do
    test "a turn that starts between the scan and the claim is not parked over", ctx do
      # The #2286 reproduction. The sweep decided this machine was idle; a
      # prompt landed while it was claiming. `main` suspended the machine
      # anyway and wrote `suspended` over a row a turn was running on.
      reject(&Managoat.Sandbox.suspend/1)

      admission_at_the_claim(fn ->
        insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
      end)

      # `skipped`, not `refused`: the sweep was wrong and the owner said so,
      # which is constraint 1 working rather than a machine left behind.
      assert {0, 0, 0, 1} = sweep()
      assert row(ctx).status == "ready"
      assert is_nil(row(ctx).transition)
      assert suspended_events(ctx) == []
    end

    test "a refused park leaves the run's provider-destroy budget alone", ctx do
      # Stage 5b's rule, still true with parks in the mix: the budget bounds
      # calls to the *provider*, and a refusal makes none — so a machine
      # refused here must not cost the machine behind it its reclamation.
      # Driven with two: the first park is refused, the second still runs.
      second = insert_sandbox(user_id: ctx.user.id, status: "ready")
      second_conv = insert_conversation(user_id: ctx.user.id, sandbox: second, status: "idle")
      insert_turn(second_conv, %{status: "completed"})
      age(second, second_conv, 60 * 5)
      on_exit(fn -> stop_machine(second.id) end)

      stub(Managoat.Sandbox, :suspend, fn %Handle{} -> :ok end)

      # Only this machine gets an admission under its claim; the other is left
      # to park, which is the half that says the refusal cost it nothing.
      admission_at_the_claim_of(ctx.sandbox.id, fn ->
        insert_turn(ctx.conv, status: "running", started_at: DateTime.utc_now())
      end)

      assert {parked, 0, 0, 1} = sweep()
      assert parked == 1, "the refused machine took the other one's turn with it"
      assert row(ctx).status == "ready"
      assert Repo.reload!(second).status == "suspended"
    end

    test "a wake that starts a server between the scan and the claim is not parked over",
         ctx do
      # `Conversations.register_server/2` starts the server under the sandbox
      # lock (ADR 0072), so by the time the park's claim holds that lock the
      # server is registered, and the park's recheck finds it. Registered from
      # the claiming process, which lives for the whole park.
      reject(&Managoat.Sandbox.suspend/1)

      admission_at_the_claim(fn ->
        {:ok, _} = Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)
      end)

      assert {0, 0, 0, 1} = sweep()
      assert row(ctx).status == "ready"
    end

    test "a wake that restarts the clock between the scan and the claim is not parked over",
         ctx do
      # No turn, no server, nothing running: the machine was simply resumed,
      # which restarts the idle clock (`last_resumed_at`). Only the recheck of
      # the *verdict* catches this one — the liveness half sees nobody.
      reject(&Managoat.Sandbox.suspend/1)

      admission_at_the_claim(fn ->
        Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.sandbox.id),
          set: [last_resumed_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )
      end)

      assert {0, 0, 0, 1} = sweep()
      assert row(ctx).status == "ready"
    end
  end

  describe "recovery is a serialized takeover" do
    setup ctx do
      put_lease(ctx.sandbox.id,
        lease_epoch: 1,
        lease_node: dead_lease_holder(),
        transition: "parking",
        transition_reason: "idle"
      )

      :ok
    end

    test "an abandoned park whose suspend landed is finished on the next pass", ctx do
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :suspended, raw: %{}}} end)
      reject(&Managoat.Sandbox.suspend/1)

      assert {1, 0, 0, _} = sweep()

      final = row(ctx)
      assert final.status == "suspended"
      assert is_nil(final.transition)
      assert [_one] = suspended_events(ctx)
    end

    test "an abandoned park whose machine is still up is cleared on the next pass", ctx do
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :running, raw: %{}}} end)
      reject(&Managoat.Sandbox.suspend/1)
      reject(&Managoat.Sandbox.resume/1)

      # Neither parked nor reclaimed: the machine is up and the row now says so.
      assert {0, 0, 0, _} = sweep()

      final = row(ctx)
      assert final.status == "ready"

      assert is_nil(final.transition),
             "a stale parking stamp survived a whole reaper pass, so every wake and " <>
               "attach onto this machine keeps meeting an owner that is not there"

      assert suspended_events(ctx) == []
    end

    test "and the pass after that parks it again", ctx do
      stub(Managoat.Sandbox, :get, fn %Handle{} -> {:ok, %{status: :running, raw: %{}}} end)
      assert {0, 0, 0, _} = sweep()

      # The recovery wrote the row, so `updated_at` is fresh and the sweep's
      # grace window now excludes it — the machine is not abandoned, it was
      # touched a moment ago. Ageing it is what the next hour does.
      age(ctx.sandbox, ctx.conv, 60 * 5)

      stub(Managoat.Sandbox, :suspend, fn %Handle{} -> :ok end)
      assert {1, 0, 0, _} = sweep()
      assert row(ctx).status == "suspended"
    end
  end

  describe "a park superseded mid-suspend" do
    test "writes nothing, and the taker decides what happened to the machine", ctx do
      # The salvage branch compensated here by *resuming* the machine its own
      # suspend had just parked, because its claim was not a lease and a late
      # success could still land. The compare-and-set makes that unnecessary:
      # the superseded park's finalize matches zero rows, so it changed
      # nothing, and the owner that took the machine over is the one that reads
      # the machine and writes the answer.
      expect(Managoat.Sandbox, :suspend, fn %Handle{} ->
        {:ok, _taker} = Lease.claim(ctx.sandbox.id, supersede: self())
        :ok
      end)

      # Counted as parked, because that is what `:superseded` means at the door
      # (`Machine.park/2`): another owner holds this machine and it is parked
      # or parking. `Machine.destroy/2` has answered `:already_terminal` the
      # same way since stage 5a. What the sweep must not do is report having
      # done it — and it did not: nothing below was written by this pass.
      assert {1, 0, 0, _} = sweep()

      # The taker holds a live lease and a stamped row; every reader refuses it
      # until the taker finishes or its own lease lapses.
      mid = row(ctx)
      assert mid.status == "ready"
      assert mid.transition == "parking"
      assert Machine.busy?(mid)
      assert suspended_events(ctx) == []
    end
  end

  describe "the run's bounds" do
    test "contention cannot stack two reaper jobs", ctx do
      _ = ctx
      assert {:ok, job} = Oban.insert(SandboxReaper.new(%{}))
      assert {:ok, same} = Oban.insert(SandboxReaper.new(%{}))

      assert same.id == job.id,
             "a second reaper was enqueued; two sweeps of one fleet spend their time " <>
               "queueing behind each other's leases (ADR 0058 stage 6b)"
    end

    test "a machine its owner is already holding is left alone, and counted", ctx do
      # The pre-filter. Asking would mean waiting out the busy wait for an
      # answer the row already gives, and a machine that lands in no counter at
      # all is one an operator reading the hourly summary cannot account for.
      put_lease(ctx.sandbox.id,
        lease_epoch: 1,
        lease_node: live_lease_holder()
      )

      reject(&Managoat.Sandbox.suspend/1)

      assert {0, 0, 0, 1} = sweep()
      assert row(ctx).status == "ready"
    end

    test "a job orphaned in `executing` would otherwise stop reclamation for good", ctx do
      # The hazard `unique:` creates, from the surfaces review. Oban's shutdown
      # grace is 15 seconds and a contended run is budgeted at minutes, so a
      # pod that loses a rolling deploy mid-sweep is the ordinary case — and a
      # unique worker's corpse is not one lost run, it is every future one:
      # each cron insert matches the `executing` row and is deduplicated
      # against it.
      _ = ctx
      assert {:ok, job} = Oban.insert(SandboxReaper.new(%{}))

      {1, _} =
        Repo.update_all(
          from(j in Oban.Job, where: j.id == ^job.id),
          set: [state: "executing", attempted_at: DateTime.add(DateTime.utc_now(), -2, :hour)]
        )

      assert {:ok, deduped} = Oban.insert(SandboxReaper.new(%{}))

      assert deduped.id == job.id and deduped.conflict?,
             "the corpse did not deduplicate the next run, so this test is not about " <>
               "the hazard it claims to be about"

      # What answers it. The plugin is Oban's and is not executed here —
      # `testing: :manual` strips the supervision tree that would run it — so
      # what this pins is that it is configured, that Oban accepts the options
      # given, and that the two numbers are the right way round: a rescue must
      # be slower than the slowest legitimate run and faster than the gap
      # between crons, or it either kills a live sweep or never arrives.
      plugins = Application.fetch_env!(:fountain, Oban)[:plugins]

      assert {Oban.Plugins.Lifeline, lifeline} =
               Enum.find(plugins, &match?({Oban.Plugins.Lifeline, _}, &1)),
             "no Lifeline plugin: an orphaned `executing` reaper is permanent " <>
               "(ADR 0058 stage 6b)"

      assert :ok = Oban.Plugins.Lifeline.validate(lifeline)
      assert lifeline[:rescue_after] > :timer.minutes(8), "a live sweep would be rescued"
      assert lifeline[:rescue_after] < :timer.hours(1), "the next cron would find the corpse"
    end

    test "a run stops asking owners once it has spent its attempts", ctx do
      # The 5b round-3 note, closed. Refusals cost no provider call and so
      # spend no destroy budget, which leaves the *attempt* count unbounded —
      # and every contended attempt costs `Park.busy_wait_ms/0`. Driven with a
      # cap of one and two eligible machines rather than with a hundred and
      # one rows.
      second = insert_sandbox(user_id: ctx.user.id, status: "ready")
      second_conv = insert_conversation(user_id: ctx.user.id, sandbox: second, status: "idle")
      insert_turn(second_conv, %{status: "completed"})
      age(second, second_conv, 60 * 5)
      on_exit(fn -> stop_machine(second.id) end)

      stub(Managoat.Sandbox, :suspend, fn %Handle{} -> :ok end)
      Application.put_env(:fountain, :reaper_owner_attempt_limit, 1)
      on_exit(fn -> Application.delete_env(:fountain, :reaper_owner_attempt_limit) end)

      assert {1, 0, 0, _} = sweep()

      parked = Enum.count([row(ctx), Repo.reload!(second)], &(&1.status == "suspended"))

      assert parked == 1,
             "both machines were parked, so the cap bounded nothing and a contended fleet " <>
               "can still hold a maintenance slot for as long as it likes"

      # Deferred, not refused: nothing was written and nothing went wrong, and
      # the next run picks the other one up.
      Application.delete_env(:fountain, :reaper_owner_attempt_limit)
      assert {1, 0, 0, _} = sweep()
      assert Enum.all?([row(ctx), Repo.reload!(second)], &(&1.status == "suspended"))
    end
  end
end
