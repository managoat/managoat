defmodule Fountain.Workers.SandboxReaperTest do
  @moduledoc """
  Reconciliation between the `sandboxes` table and sprites.dev.

  The risk here is asymmetric and points in one direction: failing to reap a
  sprite costs money and quota, while reaping the wrong one destroys someone's
  running work and cannot be undone. So most of these tests are about what the
  reaper refuses to touch.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workers.SandboxReaper

  setup :set_mimic_global

  defp minutes_ago(n),
    do: DateTime.utc_now() |> DateTime.add(-n * 60, :second) |> DateTime.truncate(:second)

  # updated_at is managed by Ecto, so age has to be forced with a raw update.
  defp age_sandbox(sandbox, minutes) do
    ts = minutes_ago(minutes)
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [updated_at: ts])
    %{sandbox | updated_at: ts}
  end

  defp stub_sprites(names) do
    stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:ok, MapSet.new(names)} end)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)
  end

  defp capture_destroys do
    test = self()

    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)

    stub(Sprites, :destroy, fn {:handle, name} ->
      send(test, {:destroyed, name})
      :ok
    end)
  end

  # A provider that answers listings from what is actually still there.
  # `stub_sprites/1` plus `capture_destroys/0` model one that keeps naming a
  # machine after it has been deleted, which is fine for a test about what the
  # reaper refuses to touch and useless for one about how many times it calls
  # the provider — pass 2 filters on the listing, so a static listing hides a
  # second destroy of a machine pass 1 already took. The two share an agent so
  # the destroy and the listing cannot disagree.
  defp live_provider(names) do
    test = self()
    {:ok, live} = Agent.start_link(fn -> MapSet.new(names) end)

    stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn ->
      {:ok, Agent.get(live, & &1)}
    end)

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)
    stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)

    stub(Sprites, :destroy, fn {:handle, name} ->
      Agent.update(live, &MapSet.delete(&1, name))
      send(test, {:destroyed, name})
      :ok
    end)

    live
  end

  defp destroyed_names do
    receive do
      {:destroyed, name} -> [name | destroyed_names()]
    after
      0 -> []
    end
  end

  describe "stuck sandboxes" do
    test "a row stuck in pending past the grace period is released" do
      # This is the quota half: Quotas counts pending/starting toward the
      # concurrent cap, so a row left behind by a BEAM that died mid-provision
      # consumes a tenant's allowance forever, with no self-serve way out.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)

      assert %{status: "failed", terminated_at: %DateTime{}} = Repo.reload(sandbox)
    end

    test "starting is released too" do
      sandbox = insert_sandbox(status: "starting") |> age_sandbox(120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)

      assert Repo.reload(sandbox).status == "failed"
    end

    test "a recent row is left alone" do
      # A slow provision is not a stuck one. Package installs get 300s per
      # command and a clone gets 600s, and they run in sequence.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(5)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "pending"
    end

    test "a ready sandbox is never released, however old" do
      # An idle sandbox is a lifetime question (#167), not a stuck one. Marking
      # it failed here would kill live conversations.
      sandbox = insert_sandbox(status: "ready") |> age_sandbox(60 * 24 * 90)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "ready"
    end

    test "a row with a live ConversationServer is left alone" do
      # Whatever the clock says, a running server means provisioning is still
      # in flight somewhere in the cluster.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "pending") |> age_sandbox(600)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      assert 0 = SandboxReaper.release_stuck_sandboxes()
      assert Repo.reload(sandbox).status == "pending"
    end

    test "a row whose owner still holds its lease is left alone" do
      # Stage 9b: the pass asks the owner (`Machine.fail_provision/2`), which
      # claims the machine's lease first. A provision that is still renewing its
      # lease past this pass's cutoff answers `:claimed_elsewhere`, where the bare
      # write this replaced would have failed the row underneath it.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(120)
      {:ok, _epoch} = Fountain.Machines.Lease.claim(sandbox.id)

      capture_log(fn -> assert 0 = SandboxReaper.release_stuck_sandboxes() end)

      assert Repo.reload(sandbox).status == "pending"
      assert Fountain.Audit.list_for_user(sandbox.user_id, action_prefix: "sandbox.") == []
    end

    test "a released row is recorded as the owner's failed provision, with the reaper's reason" do
      sandbox = insert_sandbox(status: "starting") |> age_sandbox(120)

      capture_log(fn -> assert 1 = SandboxReaper.release_stuck_sandboxes() end)

      actions =
        sandbox.user_id
        |> Fountain.Audit.list_for_user(action_prefix: "sandbox.")
        |> Enum.map(&{&1.action, &1.actor})
        |> Enum.sort()

      assert actions == [
               {"sandbox.provision_failed", "system:sandbox_reaper"},
               {"sandbox.released_stuck", "system:sandbox_reaper"}
             ]
    end
  end

  describe "abandoned ready sandboxes" do
    defp with_bounds(pairs, fun) do
      previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
      Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

      try do
        fun.()
      after
        Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
      end
    end

    defp age_rows(sandbox, conv, minutes) do
      ts = minutes_ago(minutes)

      # updated_at ages too: the sweep's grace window keys on it, and a row
      # this old that was genuinely abandoned has not been touched either.
      Repo.update_all(
        from(s in Sandbox, where: s.id == ^sandbox.id),
        set: [inserted_at: ts, updated_at: ts]
      )

      if conv do
        Repo.update_all(
          from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
          set: [inserted_at: ts]
        )
      end

      Repo.reload(sandbox)
    end

    test "past the ceiling with no server, a ready sandbox is expired" do
      # The 83-day production sandbox. Its ConversationServer is long gone, so
      # nothing was watching it. Both bounds are crossed at that age and the
      # ceiling wins: an unattended row this old only exists if the reaper
      # itself was down past the idle window that would have parked it, and
      # the ceiling is the backstop that still bounds it.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 24 * 83)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "terminated"

      # The conversation must survive — reclaiming is a cost control, not a
      # delete. assert_resumable/1 refuses terminated/failed/completed, so
      # marking it here would lock the user out of their own history forever.
      assert Repo.reload(conv).status == "idle"
      refute Repo.reload(conv).status in ~w(terminated failed completed)
    end

    test "past the idle bound but under the ceiling, a ready sandbox is parked" do
      # The common case after a crash or deploy gap: the server that would
      # have suspended it is gone. Parking is the reaper doing the server's
      # idle-suspend on its behalf — the sprite stays (decisions/0017).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 5)

      capture_destroys()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "suspended"
      refute reloaded.terminated_at
      assert destroyed_names() == []
      assert Repo.reload(conv).status == "idle"
    end

    test "an ephemeral sandbox parks without a checkpoint" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 5)

      capture_destroys()
      stub(Managoat.Sandbox, :supports?, fn :sprites, cap -> cap == :suspend end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
      refute Repo.reload(sandbox).provider_meta["checkpoint_id"]
    end

    test "a suspended sandbox matches no pass, however old" do
      # The durable resting state: never released, never expired, never
      # destroyed — its sprite is the agent's memory (decisions/0017).
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})
      sandbox = age_rows(sandbox, conv, 60 * 24 * 83)

      stub_sprites([sandbox.machine_name])
      capture_destroys()

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
      assert destroyed_names() == []
    end

    test "a recently touched ready row is inside the grace window" do
      # The wake path flips suspended → ready (touching updated_at) before a
      # server that dies mid-wake is gone, so a mid-wake row can look
      # server-less. The grace window keeps the reaper from parking it back
      # out from under the reattach.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      insert_turn(conv, %{status: "completed"})

      # Old activity and an old creation date, but updated_at is fresh.
      ts = minutes_ago(60 * 5)
      Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [inserted_at: ts])

      Repo.update_all(
        from(t in Fountain.Conversations.Turn, where: t.conversation_id == ^conv.id),
        set: [inserted_at: ts]
      )

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    for field <- [:started_at, :ended_at] do
      test "recent turn #{field} keeps an old machine out of the idle sweep" do
        user = insert_verified_user()
        sandbox = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: sandbox)
        turn = insert_turn(conv, %{status: "completed"})
        sandbox = age_rows(sandbox, conv, 300)
        turn |> change([{unquote(field), minutes_ago(20)}]) |> Repo.update!()

        with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
          assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
        end)

        assert Repo.reload(sandbox).status == "ready"
      end
    end

    test "a recent wake restarts the idle clock even without a new turn" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      sandbox = age_rows(sandbox, nil, 48 * 60)
      # Outside the 15-minute grace window, but inside the 60-minute idle limit.
      sandbox |> change(last_resumed_at: minutes_ago(20)) |> Repo.update!()
      sandbox = age_sandbox(sandbox, 20)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "recent turn activity keeps a sandbox alive" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      insert_turn(conv, %{status: "completed"})

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "a live ConversationServer is left to enforce its own timeout" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "with both bounds disabled nothing is expired" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 0], fn ->
        assert {0, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "a sandbox that never took a turn is dated from its own creation" do
      # Otherwise a sandbox with no turns has no activity timestamp at all and
      # would either never expire or expire immediately. Five hours old crosses
      # the idle bound but not the ceiling, so the verdict is a park.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      sandbox = age_rows(sandbox, conv, 60 * 5)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert {1, 0, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)
      end)

      assert Repo.reload(sandbox).status == "suspended"
    end

    test "expiring a sandbox destroys its sprite in pass 1, and pass 2 does not repeat it" do
      # This used to assert that pass 1 made the sprite *eligible* for pass 2.
      # Since ADR 0058 stage 5b the expiry destroys the machine itself, through
      # the owner, and pass 2 is the safety net rather than the mechanism. The
      # thing worth pinning is therefore that it happens exactly once: `perform/1`
      # lists the provider *after* the abandoned sweep, so a machine pass 1 has
      # already destroyed is not in the listing pass 2 filters on.
      #
      # The listing is read through `live_names/0` rather than a fixed set, so
      # the stub models a provider that stops naming a machine somebody
      # destroyed. A static list cannot see a double destroy at all — it reports
      # the sprite as present however many times it has been deleted, which is
      # what made the old assertion pass either way.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox)
      age_rows(sandbox, conv, 60 * 24 * 83)
      live_provider([sandbox.machine_name])

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "a terminal row whose sprite outlived its destroy is still collected by pass 2" do
      # The other half of the pair above, and the reason pass 2 stays: a machine
      # the expiry could not reach is still named by the provider on the next
      # run, and pass 2 destroys it then. Modelled by a row that is already
      # terminal — the state a failed destroy leaves — so pass 1 has no verdict
      # on it at all.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "terminated")
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
    end
  end

  describe "abandoned teardown fences" do
    # Every row here is fenced through the real `Lifecycle` door, because the
    # thing under test is precisely what that door leaves behind — and since
    # ADR 0058 stage 9a that includes the `destroying` stamp it writes beside
    # the two columns.
    defp fence(sandbox, opts \\ []) do
      {:ok, fenced} =
        Lifecycle.fence_sandbox_for_teardown(sandbox, Keyword.put_new(opts, :reason, "test"))

      fenced
    end

    # The grace window runs from the stamp, which is the row's last write.
    defp age_fence(sandbox, minutes), do: age_sandbox(sandbox, minutes) |> Repo.reload()

    defp fenced_sandbox(status \\ "ready") do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: status)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      {user, fence(sandbox), conv}
    end

    test "a teardown that died before its terminal write is driven to completion" do
      # The hole this pass exists for. The fence commits, then the destroy
      # raises or the pod dies, and the row is left `ready` with the fence set:
      # invisible to both sweeps above (they require no `destroying` stamp,
      # which the fence sets), to the dead-sprite
      # pass (it wants a terminal status) and to the untracked count (the sprite
      # has a row). Quotas keeps charging for it and nothing else can clear it.
      #
      # Since stage 9a "finished" means driven through the machine's owner, so
      # every one of these is asserted: the row is terminal, the sprite is gone
      # in *this* call rather than on pass 2, the stamp came off because the
      # finalize carried an epoch, and the trail has both events.
      {user, sandbox, _conv} = fenced_sandbox()
      assert active_sandbox_count(user.id) == 1
      sandbox = age_fence(sandbox, 60)
      assert Repo.reload(sandbox).transition == "destroying"
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      reloaded = Repo.reload(sandbox)
      assert %{status: "terminated", terminated_at: %DateTime{}} = reloaded
      assert is_nil(reloaded.transition)
      assert is_nil(reloaded.transition_reason)
      assert destroyed_names() == [sandbox.machine_name]
      assert active_sandbox_count(user.id) == 0
    end

    test "the destroy is recorded against the reaper, beside the reaper's own reason" do
      # Two events, as `expire/3` has two. `sandbox.destroyed` is the
      # protocol's record that the machine went, and it is the one the old
      # `update_sandbox/2` write never made at all — a machine destroyed by this
      # pass left no trail of the destroy, only of the reconciliation.
      {user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      assert [destroyed] =
               Fountain.Audit.list_for_user(user.id, action_prefix: "sandbox.destroyed")

      assert destroyed.actor == "system:sandbox_reaper"
      assert destroyed.resource_id == sandbox.id

      assert [reconciled] =
               Fountain.Audit.list_for_user(user.id,
                 action_prefix: "sandbox.teardown_reconciled"
               )

      assert reconciled.actor == "system:sandbox_reaper"
      assert reconciled.metadata["previous_status"] == "ready"
      assert reconciled.metadata["sprite_name"] == sandbox.machine_name
    end

    test "the reason the fence recorded is the reason the destroy records" do
      # The driver does not invent a word for a decision it did not make: the
      # fence stamped `transition_reason`, and that is what reaches the row's
      # transition and the audit metadata. `:reclaimed` rather than the
      # default, so a fallback would be visible.
      {user, sandbox, _conv} = fenced_sandbox()

      put_lease(sandbox.id, transition_reason: "reclaimed")

      age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      assert [destroyed] =
               Fountain.Audit.list_for_user(user.id, action_prefix: "sandbox.destroyed")

      assert destroyed.metadata["reason"] == "reclaimed"
    end

    test "a row carrying the stamp alone is driven" do
      # Forged rather than fenced, to show the stamp is all the pass reads:
      # stage 9b stopped reading the two columns a fence once wrote beside it.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      put_lease(sandbox.id,
        transition: "destroying",
        transition_reason: "teardown",
        updated_at: minutes_ago(60)
      )

      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      assert Repo.reload(sandbox).status == "terminated"
      assert destroyed_names() == [sandbox.machine_name]
    end

    test "the conversation survives its machine being reclaimed" do
      # Same rule as expire/3: reclaiming a machine is not deleting the thread
      # that ran on it. assert_resumable/1 refuses a terminated conversation.
      {_user, sandbox, conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      assert Repo.reload(conv).status == "idle"
    end

    test "a teardown still in flight is inside the grace window" do
      # A fence is minutes old on every ordinary teardown, and an account
      # deletion walks a whole tenant's machines between the fence and the
      # destroy. Sweeping those would race a caller that is still working.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 5)
      live_provider([sandbox.machine_name])

      assert {0, 0} = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
      assert destroyed_names() == []
    end

    test "a fenced row whose machine owner still holds the lease is left alone" do
      # Since ADR 0058 a destroy in flight looks exactly like an abandoned
      # teardown to everything else here: fenced, live status, no server. The
      # lease is what tells them apart, and it is read before any owner is
      # asked — a live holder means this pass would be waiting out
      # `Destroy.busy_wait_ms/0` for an answer already on the row. Reporting
      # `reconciled` for it would be worse still: `perform/1` documents that
      # gauge as a defect upstream, and a destroy that merely took longer than
      # the grace window is not one.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      {:ok, 1} = Fountain.Machines.Lease.claim(sandbox.id)

      assert {0, 0} = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
      assert destroyed_names() == []
    end

    test "a fenced row whose owner's lease has expired is swept as before" do
      # The other half, and the reason the skip is a *live* lease rather than
      # "has a lease at all": a holder that died mid-destroy leaves the lease
      # behind, and that row is exactly the abandonment this pass is for.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      {:ok, 1} = Fountain.Machines.Lease.claim(sandbox.id)

      put_lease(sandbox.id, lease_node: dead_lease_holder())

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "a fenced row a server still holds is left alone" do
      {_user, sandbox, conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      stub(Fountain.Conversations.ConversationServer, :whereis, fn id ->
        if id == conv.id, do: self(), else: nil
      end)

      assert {0, 0} = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "ready"
      assert destroyed_names() == []
    end

    test "the idle and ceiling sweep leaves a machine that is being destroyed alone" do
      # Pass 1b's prefilter, in the words that outlive the column beside them
      # (ADR 0058 stage 9a). Parking or expiring a fenced machine would be this
      # sweep deciding the end of a machine whose end somebody else already
      # decided — and the destroy it would write over is the driver's, one pass
      # down. Stamped with no column, which is what stage 9b leaves.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
      age_rows(sandbox, conv, 60 * 24 * 83)

      put_lease(sandbox.id, transition: "destroying", transition_reason: "terminated")

      reject(Managoat.Sandbox, :suspend, 1)
      reject(Managoat.Sandbox, :destroy, 1)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        assert {0, 0, 0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
      end)

      assert Repo.reload(sandbox).status == "ready"
    end

    test "a persistent home whose forced teardown was abandoned is finished too" do
      # Rule 16 for the deleted reconciler's other half. A forced teardown of a
      # persistent home stamps a reason that is not `"reset"`, so it is finished
      # as a teardown, after the grace window, on the five-minute run.
      user = insert_verified_user()
      home = insert_sandbox(user_id: user.id, status: "ready", mode: "persistent")

      fenced =
        fence(home, actor: "admin", reason: "reaped", transition_reason: :admin_reap)

      assert fenced.transition_reason == "admin_reap"
      age_fence(fenced, 20)
      live_provider([home.machine_name])

      capture_log(fn ->
        assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
      end)

      assert Repo.reload(home).status == "terminated"
      assert destroyed_names() == [home.machine_name]
    end

    test "a machine nobody has asked to destroy is left alone" do
      user = insert_verified_user()
      home = insert_sandbox(user_id: user.id, status: "ready", mode: "persistent")
      age_sandbox(home, 60)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)

      assert {0, 0} = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(home).status == "ready"
    end

    test "an already terminal row needs no work, however long it has been fenced" do
      {_user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      sandbox = sandbox |> Ecto.Changeset.change(status: "terminated") |> Repo.update!()
      live_provider([sandbox.machine_name])

      assert {0, 0} = SandboxReaper.sweep_fenced_teardowns()
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "a row somebody else finished under the sweep counts on neither gauge" do
      # `{:ok, :already_terminal}` from the owner. Nothing was reclaimed by this
      # pass, so `reconciled` must not move; nothing went wrong, so `refused`
      # must not either — a defect gauge that counts a machine somebody else
      # cleaned up reports an outage on a healthy fleet.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      stub(Fountain.Conversations.Termination, :_unsafe_destroy_machine, fn _id, _opts ->
        {:ok, :already_terminal}
      end)

      capture_log(fn -> assert {0, 0} = SandboxReaper.sweep_fenced_teardowns() end)
    end

    test "a suspended row carrying a teardown fence is finished too" do
      # A parked machine is still a leaked sprite once a teardown was
      # requested for it, and Quotas counts a fenced row whatever its status.
      {user, sandbox, _conv} = fenced_sandbox("suspended")
      assert active_sandbox_count(user.id) == 1
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)

      assert Repo.reload(sandbox).status == "terminated"
      assert active_sandbox_count(user.id) == 0
    end

    test "the sprite dies in this pass rather than on pass 2" do
      # What the driver bought, asserted through both runs. The old write left
      # the sprite for the leaked-sprite pass, which worked only because that
      # pass reads a listing taken afterwards. Now the destroy happens here — so
      # the machine is *not* in the listing pass 2 filters on, and it is
      # destroyed exactly once.
      {_user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      capture_log(fn ->
        assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        assert :ok = perform_job(SandboxReaper, %{})
      end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "a fence left behind by a deleted account is finished, and cleanup still runs" do
      # Account deletion carries on past a destroy that raised, then deleting
      # the user nilifies `sandboxes.user_id` and cascades the conversations
      # away. The row still needs its terminal write, and a refused one used to
      # raise out of perform/1 before the provider listing — so one departed
      # account blocked machine cleanup for the whole fleet, every run.
      {user, orphan, _conv} = fenced_sandbox()
      Repo.delete!(user)
      orphan = age_fence(orphan, 60)
      assert is_nil(orphan.user_id)

      other = insert_sandbox(status: "terminated")
      live_provider([orphan.machine_name, other.machine_name])

      capture_log(fn ->
        assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
        assert :ok = perform_job(SandboxReaper, %{})
      end)

      assert Enum.sort(destroyed_names()) == Enum.sort([orphan.machine_name, other.machine_name])
      assert %{status: "terminated", terminated_at: %DateTime{}} = Repo.reload(orphan)
    end

    test "a row the owner refuses is counted, logged, and does not stop the rest" do
      # The refused row stays for the next run or an operator; its neighbour is
      # still finished, and nothing raises out of the pass. `refused` is the
      # gauge that says the machine is still there, which is why it moves.
      {_user, refused, _conv} = fenced_sandbox()
      {_user, finished, _conv} = fenced_sandbox()
      refused = age_fence(refused, 60)
      finished = age_fence(finished, 60)
      live_provider([refused.machine_name, finished.machine_name])

      stub(Fountain.Conversations.Termination, :_unsafe_destroy_machine, fn id, opts ->
        if id == refused.id,
          do: {:error, :machine_busy},
          else:
            Mimic.call_original(
              Fountain.Conversations.Termination,
              :_unsafe_destroy_machine,
              [id, opts]
            )
      end)

      log = capture_log(fn -> assert {1, 1} = SandboxReaper.sweep_fenced_teardowns() end)

      assert log =~ "could not finish abandoned teardown of sandbox #{refused.id}"
      assert Repo.reload(refused).status == "ready"
      assert Repo.reload(finished).status == "terminated"
    end

    test "a row past the run's attempt cap is deferred, not refused" do
      # Nothing was attempted and nothing went wrong, so it goes on neither
      # gauge — `defer/2`'s reading one pass up. The row keeps its stamp, so the
      # next run sees it unchanged, and the older stamp goes first.
      {_user, first, _conv} = fenced_sandbox()
      {_user, second, _conv} = fenced_sandbox()
      age_fence(first, 90)
      age_fence(second, 60)
      live_provider([first.machine_name, second.machine_name])

      capture_log(fn ->
        with_bounds([reaper_sweep_attempt_limit: 1], fn ->
          assert {1, 0} = SandboxReaper.sweep_fenced_teardowns()
        end)
      end)

      assert destroyed_names() == [first.machine_name]
      assert Repo.reload(first).status == "terminated"

      deferred = Repo.reload(second)
      assert deferred.status == "ready"
      assert deferred.transition == "destroying"
    end

    test "a destroy another run is finishing counts on neither gauge" do
      # Two runs overlapping is ordinary. The one that loses the lease answers
      # `sandbox_unavailable`, and the machine is being reclaimed — by the other
      # run — so `refused`, which means "still standing and billing", must not
      # move (round 1, protocol review).
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      # The owner reports back, so `{0, 0}` cannot come from a row the pass
      # never reached.
      test = self()

      expect(Fountain.Conversations.Termination, :_unsafe_destroy_machine, 1, fn id, _opts ->
        send(test, {:destroy_asked, id})
        {:ok, _epoch} = Fountain.Machines.Lease.claim(id)
        {:error, :sandbox_unavailable}
      end)

      capture_log(fn -> assert {0, 0} = SandboxReaper.sweep_fenced_teardowns() end)
      sandbox_id = sandbox.id
      assert_received {:destroy_asked, ^sandbox_id}
      refute_received {:destroy_asked, _}
    end

    test "a teardown whose provider delete fails is still reconciled, and the row retires" do
      # The protocol retires a fenced row whatever the provider answers, so the
      # machine is left to the hourly pass for rows already finished. That is
      # a reclamation, and the sandbox-lifetime guide says it counts as one.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])
      stub(Sprites, :destroy, fn _ -> {:error, :provider_down} end)

      capture_log(fn -> assert {1, 0} = SandboxReaper.sweep_fenced_teardowns() end)
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "sandbox_unavailable with nobody holding the machine is still a refusal" do
      # The symmetric case: a database fault or an unreachable owner answers the
      # same word, and that machine is still standing.
      {_user, sandbox, _conv} = fenced_sandbox()
      sandbox = age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      stub(Fountain.Conversations.Termination, :_unsafe_destroy_machine, fn _id, _opts ->
        {:error, :sandbox_unavailable}
      end)

      capture_log(fn -> assert {0, 1} = SandboxReaper.sweep_fenced_teardowns() end)
    end

    test "the teardown run reports on its own event" do
      # Its own, not the hourly run's: the two are different jobs on different
      # clocks, and a refusal here is a machine still standing.
      {_user, sandbox, _conv} = fenced_sandbox()
      age_fence(sandbox, 60)
      live_provider([sandbox.machine_name])

      stub(Fountain.Conversations.Termination, :_unsafe_destroy_machine, fn _id, _opts ->
        {:error, :machine_busy}
      end)

      handler = "reaper-teardowns-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler) end)

      :telemetry.attach(
        handler,
        [:fountain, :reaper, :teardowns],
        fn _event, measurements, _meta, pid -> send(pid, {:teardowns, measurements}) end,
        self()
      )

      capture_log(fn ->
        assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
      end)

      assert_received {:teardowns, %{reconciled: 0, refused: 1}}
    end

    test "one sweep asks a bounded number of owners, whatever the backlog" do
      # `@owner_attempts_per_sweep`. It bounds the *waiting* — every refusal
      # costs `Destroy.busy_wait_ms/0` — and, with no destroy budget since stage
      # 9b, the provider calls one run can make.
      fences =
        for _ <- 1..3 do
          {_user, fenced, _conv} = fenced_sandbox()
          age_fence(fenced, 60)
          fenced
        end

      live_provider(Enum.map(fences, & &1.machine_name))

      capture_log(fn ->
        with_bounds([reaper_sweep_attempt_limit: 2], fn ->
          assert {2, 0} = SandboxReaper.sweep_fenced_teardowns()
        end)
      end)

      assert Enum.count(fences, &(Repo.reload(&1).status == "terminated")) == 2
    end

    test "the hourly run drives no teardowns; the five-minute run does" do
      # Stage 9b. The hourly run used to share its destroy budget with this
      # pass and needed a floor so an expiry backlog could not starve it. The
      # pass has a run of its own now, so an expiry spending the whole hourly
      # budget costs it nothing.
      {_user, fenced, _conv} = fenced_sandbox()
      age_fence(fenced, 60)

      user = insert_verified_user()
      expirable = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: expirable)
      age_rows(expirable, conv, 60 * 24 * 83)

      live_provider([fenced.machine_name, expirable.machine_name])

      bounds = [
        sandbox_idle_timeout_minutes: 60,
        sandbox_max_lifetime_hours: 24,
        reaper_destroy_limit: 1
      ]

      capture_log(fn ->
        with_bounds(bounds, fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      assert Repo.reload(expirable).status == "terminated"
      assert Repo.reload(fenced).status == "ready"

      capture_log(fn ->
        assert :ok = perform_job(SandboxReaper, %{"pass" => "teardowns"})
      end)

      assert Repo.reload(fenced).status == "terminated"
    end

    test "the teardown run has a five-minute cron entry of its own" do
      # The cadence is the point of the run: an abandoned reset or forced
      # teardown held its tenant's slot for at most five minutes under
      # `SandboxResetReconciler`, and folding it into the hourly run would
      # have made that up to an hour and a quarter.
      crontab =
        :fountain
        |> Application.fetch_env!(Oban)
        |> Keyword.fetch!(:plugins)
        |> Enum.find_value(fn
          {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
          _ -> nil
        end)

      assert {"*/5 * * * *", SandboxReaper, args: %{"pass" => "teardowns"}} in crontab
      assert {"7 * * * *", SandboxReaper} in crontab

      refute Enum.any?(
               crontab,
               &match?({_, SandboxReaper, args: %{"pass" => "detached_requests"}}, &1)
             )
    end
  end

  describe "leaked sprites" do
    test "destroys a sprite whose sandbox row is terminal" do
      # The ordinary leak: both destroy call sites in ConversationServer discard
      # the result and mark the row terminal regardless, so a transient failure
      # at sprites.dev strands the sprite permanently.
      sandbox = insert_sandbox(status: "terminated")
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
    end

    test "destroys for failed sandboxes as well as terminated" do
      sandbox = insert_sandbox(status: "failed")
      stub_sprites([sandbox.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [sandbox.machine_name]
    end

    test "never destroys a sprite whose sandbox is still live" do
      ready = insert_sandbox(status: "ready")
      pending = insert_sandbox(status: "pending")
      stub_sprites([ready.machine_name, pending.machine_name])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "never destroys a sprite with no sandbox row" do
      # The rule that keeps this safe. A sprite created seconds ago may not
      # have committed its row yet, and an organization an operator shared
      # anyway (unsupported, ADR 0005's 2026-10-15 addendum) holds sprites this
      # instance never made. Absence of a row is not evidence of a leak, and
      # this mistake is the one that cannot be undone.
      stub_sprites(["someone-elses-sprite", "aod-conv-legacy"])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "untracked sprites are counted so the drift is visible" do
      # Inert is not the same as ignored — an operator still has to be able to
      # see that 102 sprites have no row, which is what production looked like.
      insert_sandbox(status: "ready", machine_name: "known-1")

      test = self()

      handler = "reaper-untracked-#{System.unique_integer([:positive])}"
      on_exit(fn -> :telemetry.detach(handler) end)

      :telemetry.attach(
        handler,
        [:fountain, :reaper, :untracked],
        fn _e, measurements, _meta, _cfg -> send(test, {:untracked, measurements.count}) end,
        nil
      )

      capture_log(fn ->
        assert 2 =
                 SandboxReaper.report_untracked(%{
                   sprites: MapSet.new(["known-1", "stranger-a", "stranger-b"])
                 })
      end)

      assert_received {:untracked, 2}
    end

    test "a row whose sprite is already gone needs no work" do
      insert_sandbox(status: "terminated")
      stub_sprites([])
      capture_destroys()

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
    end

    test "one destroy failure does not stop the rest" do
      doomed = insert_sandbox(status: "terminated")
      other = insert_sandbox(status: "terminated")
      stub_sprites([doomed.machine_name, other.machine_name])

      test = self()
      stub(Sprites, :sprite, fn :client, name -> {:handle, name} end)

      stub(Sprites, :destroy, fn {:handle, name} ->
        if name == doomed.machine_name do
          {:error, :boom}
        else
          send(test, {:destroyed, name})
          :ok
        end
      end)

      capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == [other.machine_name]
    end
  end

  describe "when sprites.dev is unreachable" do
    test "stuck rows are still released and the job retries" do
      # The quota fix needs no network, so it must not be held hostage to the
      # API being up. Returning an error lets Oban retry the rest.
      sandbox = insert_sandbox(status: "pending") |> age_sandbox(120)
      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:error, :nxdomain} end)

      capture_log(fn ->
        # The adapter normalizes unknown transport reasons into the sandbox
        # error taxonomy; any {:error, _} is what lets Oban retry.
        assert {:error, {:provider, :sprites, :nxdomain}} = perform_job(SandboxReaper, %{})
      end)

      assert Repo.reload(sandbox).status == "failed"
    end

    test "a truncated listing destroys nothing" do
      # The client refuses to return a partial page set. Treating a partial
      # view as complete would make every unlisted sprite look like it had
      # already been destroyed.
      sandbox = insert_sandbox(status: "terminated")
      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:error, :truncated} end)
      capture_destroys()

      capture_log(fn -> assert {:error, :truncated} = perform_job(SandboxReaper, %{}) end)

      assert destroyed_names() == []
      assert Repo.reload(sandbox).status == "terminated"
    end
  end
end
