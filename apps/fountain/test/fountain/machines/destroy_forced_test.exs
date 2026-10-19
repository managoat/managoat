defmodule Fountain.Machines.DestroyForcedTest do
  @moduledoc """
  The forced-teardown side of the destroy protocol (ADR 0058 stage 5b).

  Four sites stopped destroying the provider machine and writing the terminal
  row themselves and now ask `Fountain.Machines.Machine.destroy/2` for it:
  `Termination.destroy_home/2` (deleting an agent), `Accounts.Deletion`,
  `SandboxReaper`'s expiry of an abandoned machine, and
  `Termination.reap_sandbox/2`'s dead-server arm.

  What makes them *forced* is one option, and it is the only thing that could
  quietly break all four at once: they pass `terminating_conversation_id: nil`,
  so `Lifecycle.fence_sandbox_for_teardown/2` has no conversation to keep the
  machine *for* and `{:ok, :kept}` is unreachable. Stage 5a's review found the
  opposite mistake — a conversation id handed to a fence that had already
  decided — and what it costs is a machine fenced, live and billing that
  nothing will ever collect. So every site here is driven against both shapes
  the fence would otherwise keep: a persistent home, and a machine a second
  conversation still holds. One bound conversation naming *itself* is the one
  shape the fence does not keep, so a test with a single conversation on the
  machine proves nothing about this and is not the coverage.

  The protocol itself is `destroy_test.exs`; its two post-finalize effects are
  `destroy_effects_test.exs`. This file is about the four callers: what each one
  asks for, what the trail says afterwards, and what each does when the destroy
  is refused — because none of these callers may be stopped by one machine.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Accounts.Deletion
  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Termination
  alias Fountain.Machines.Destroy
  alias Fountain.Workers.SandboxReaper

  defmodule OkProbe do
    @moduledoc false
    use GenServer
    def init(state), do: {:ok, state}
    def handle_call(_message, _from, state), do: {:reply, :ok, state}
  end

  # A stand-in for a live `ConversationServer`, for the one thing `OkProbe`
  # cannot do: actually destroy the machine.
  #
  # `handle_call({:terminate_conv, opts}, ...)` is a transcription of
  # `Fountain.Conversations.ConversationServer`'s `terminate_machine/2` —
  # search that name there if this ever stops matching — reduced to the two lines
  # this file is about — `terminating_conversation_id: nil`, and the call to
  # `Termination._unsafe_destroy_machine/2` with the server's whole opts list.
  # A probe that merely replies `:ok` leaves the row `ready`, so account
  # deletion's late fence loop tears the machine down through
  # `destroy_sprite/2` instead, which reads `:audit` directly — and a test
  # written against that probe passes whether or not the flag ever reaches a
  # server. One did, for a whole review round.
  defmodule DestroyingProbe do
    @moduledoc false
    use GenServer

    alias Fountain.Conversations.Termination

    def init(state), do: {:ok, state}

    def handle_call({:terminate_conv, opts}, _from, state) do
      send(state.owner, {:server_opts, opts})
      opts = Keyword.put(opts, :terminating_conversation_id, nil)
      _ = Termination._unsafe_destroy_machine(state.sandbox_id, opts)
      {:reply, :ok, state}
    end

    def handle_call(_message, _from, state), do: {:reply, :ok, state}

    # A real server stops straight after its terminate, so the destroy's
    # `machine_gone` to every bound conversation (ADR 0097) never reaches it;
    # this stand-in lives on, and takes the cast as a no-op.
    def handle_cast(_message, state), do: {:noreply, state}
  end

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, agent: agent}
  end

  # ── shared helpers ────────────────────────────────────────────────────────

  # The provider, stubbed at the adapter rather than the `Managoat.Sandbox`
  # facade, so the handle the protocol builds from the row is really built and
  # the name it carries is the one asserted on.
  defp capture_provider do
    test = self()

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      send(test, {:destroyed, handle.name})
      :ok
    end)
  end

  defp destroyed_names do
    receive do
      {:destroyed, name} -> [name | destroyed_names()]
    after
      0 -> []
    end
  end

  # The order that matters, checked from inside the provider call itself: the
  # fence and the intent are on the row before the machine is touched, and the
  # row is still in a live status, so a finalize that never lands leaves
  # something `SandboxReaper.sweep_fenced_teardowns/0` can find.
  defp expect_provider_sees_the_intent(sandbox) do
    test = self()

    expect(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      row = Fountain.Machines.Lease.get(sandbox.id)

      send(
        test,
        {:at_provider, handle.name, row.status, row.transition, teardown_fenced?(row)}
      )

      :ok
    end)
  end

  defp events(user_id, action) do
    user_id
    |> Audit.list_recent_for_user(200)
    |> Enum.filter(&(&1.action == action))
  end

  defp no_servers, do: stub(ConversationServer, :whereis, fn _ -> nil end)

  # A provider that answers listings from what is still there, so pass 2 of a
  # whole reaper run can be observed: it filters terminal rows against the live
  # listing, and a fixed listing would keep naming a machine after it was
  # deleted. Same shape as `sandbox_reaper_test.exs`'s helper of this name.
  defp live_provider(names) do
    test = self()
    {:ok, live} = Agent.start_link(fn -> MapSet.new(names) end)

    stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:ok, Agent.get(live, & &1)} end)
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> :client end)

    stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
      Agent.update(live, &MapSet.delete(&1, handle.name))
      send(test, {:destroyed, handle.name})
      :ok
    end)
  end

  # A destroy nobody can run right now: the protocol's own `:machine_busy`,
  # which `Machine.destroy/2` renders as `:sandbox_unavailable`. Stubbed rather
  # than produced with a real held lease, because a real one costs the caller
  # `Destroy.busy_wait_ms/0` — five seconds — and no call site may shorten that
  # (`machine_bounds_test.exs`).
  defp refuse_destroy_of(sandbox_id), do: refuse_destroys_of([sandbox_id])

  # One stub for a whole set. `stub/3` replaces rather than accumulates, so
  # calling `refuse_destroy_of/1` in a loop leaves only the last id refused —
  # which is a quiet way to write a test that proves nothing about a run.
  defp refuse_destroys_of(sandbox_ids) do
    refused = MapSet.new(sandbox_ids)

    stub(Destroy, :run, fn id, opts ->
      if MapSet.member?(refused, id) do
        {:error, :machine_busy}
      else
        Mimic.call_original(Destroy, :run, [id, opts])
      end
    end)
  end

  defp age(sandbox, conv, minutes) do
    at = DateTime.utc_now() |> DateTime.add(-minutes * 60, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: at, updated_at: at]
    )

    if conv do
      Repo.update_all(
        from(c in Conversations.Conversation, where: c.id == ^conv.id),
        set: [inserted_at: at, updated_at: at]
      )
    end

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

  # ── site 1: destroy_home/2, the agent's homes ─────────────────────────────

  # ── site 2: account deletion ──────────────────────────────────────────────

  describe "account deletion destroys a tenant's machines through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: sandbox, conv: conv}
    end

    test "the machine is destroyed and the row ends terminal for the reaper", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(ctx.user)
      end)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    end

    test "a shared machine and a home are both destroyed, never kept", ctx do
      # Both shapes the fence would answer `:sandbox_kept` for if this path
      # named a terminating conversation: a machine a second conversation still
      # holds, and a persistent home. Either one left standing is exactly the
      # leak `@non_terminal` in `Accounts.Deletion` exists to prevent — a
      # machine owned by an account that no longer exists, with `user_id`
      # nilified seconds later so nothing could ever find it again.
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "idle"
      )

      home =
        insert_sandbox(
          user_id: ctx.user.id,
          agent_id: ctx.agent.id,
          mode: "persistent",
          status: "ready"
        )

      insert_conversation(user_id: ctx.user.id, agent: ctx.agent, sandbox: home, status: "idle")

      capture_provider()

      capture_log(fn ->
        assert {:ok, %{sprites_destroyed: 2}} = Deletion.delete_user(ctx.user)
      end)

      assert Enum.sort(destroyed_names()) ==
               Enum.sort([ctx.sandbox.machine_name, home.machine_name])

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).user_id == nil
      assert Repo.reload!(home).status == "terminated"
    end

    test "no per-machine sandbox.destroyed survives the delete", ctx do
      # The stage 5b decision on #2344. `audit_events.user_id` is nilified by
      # the delete, so a per-machine row would outlive its subject as an
      # anonymous event describing a cascade; `account.deleted` carries the
      # identity in its own metadata. The fence's intent is *not* suppressed —
      # it is written before this path can say anything about it, and a
      # teardown that was requested did happen.
      capture_provider()
      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      destroyed =
        Repo.all(from e in Audit.Event, where: e.action == "sandbox.destroyed", select: e.id)

      assert destroyed == []

      assert [_] =
               Repo.all(
                 from e in Audit.Event,
                   where:
                     e.action == "sandbox.teardown_requested" and e.resource_id == ^ctx.sandbox.id
               )
    end

    test "no sandbox.destroyed survives the delete on the live-server path either", ctx do
      # The describe's other suppression test runs under `no_servers()`, which
      # is the path `audit: false` always reached. This is the other one, and it
      # has to be driven through a server that *really destroys*: a machine
      # whose conversation is live is torn down by its own server, and the
      # suppression only gets there if `:audit_destroy` is on the opts that
      # server is handed.
      #
      # Two assertions before the one that matters, because the last one alone
      # is satisfiable by accident. The first is what the server received — the
      # keyword had to survive `terminate_conversation/2`'s `Keyword.take`. The
      # second is that the machine really went down this path, so the late
      # fence loop had nothing left to destroy through `destroy_sprite/2`,
      # which reads `:audit` and would have suppressed the event anyway.
      {:ok, probe} =
        GenServer.start_link(DestroyingProbe, %{owner: self(), sandbox_id: ctx.sandbox.id})

      stub(ConversationServer, :whereis, fn id -> if id == ctx.conv.id, do: probe, else: nil end)
      capture_provider()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      assert_received {:server_opts, opts}

      assert Keyword.get(opts, :audit_destroy) == false,
             "the server was handed #{inspect(opts)} — `:audit_destroy` did not survive " <>
               "`terminate_conversation/2`, so the machine event is recorded and the " <>
               "delete then orphans it"

      assert destroyed_names() == [ctx.sandbox.machine_name],
             "the machine was not destroyed by the server, so this test proves nothing " <>
               "about the live-server path"

      assert Repo.all(from e in Audit.Event, where: e.action == "sandbox.destroyed") == []
    end

    test "stopping a tenant's compute keeps its rows, so it records the destroy", ctx do
      # A bare `destroy_sprites/2`. Nothing is deleted here, `user_id` survives, and a machine torn down is worth an event —
      # which is why the suppression is `delete_user/2`'s and not this module's.
      capture_provider()

      capture_log(fn ->
        assert 1 ==
                 Deletion.destroy_sprites(ctx.user,
                   reason: "compute_stopped",
                   actor: "system:operator"
                 )
      end)

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.actor == "system:operator"
      assert destroyed.metadata["reason"] == "compute_stopped"
    end

    test "stopping a tenant's compute records the destroy but no conversation rows", ctx do
      # The two events this path leaves are deliberately split (ADR 0058 stage
      # 5b). `sandbox.destroyed` is recorded — nothing is being deleted,
      # `user_id` survives, and a machine torn down is worth an event.
      # `conversation.terminated` is not: `destroy_sprites/2` hardcodes that
      # for every caller.
      #
      # The regression this pins is one keyword wide: threading the
      # conversation audit through the caller's `:audit`, as the machine one
      # correctly is, turns the bare-stop path chatty while leaving the
      # deletion path looking right.
      {:ok, probe} =
        GenServer.start_link(DestroyingProbe, %{owner: self(), sandbox_id: ctx.sandbox.id})

      stub(ConversationServer, :whereis, fn id -> if id == ctx.conv.id, do: probe, else: nil end)
      capture_provider()

      # Zero, and not because nothing happened: the server destroyed the
      # machine, so the late fence loop — which is what this count comes from —
      # found no live row left to tear down. Unchanged by this stage; a machine
      # a live server takes down has never been in `sprites_destroyed`.
      capture_log(fn ->
        assert 0 ==
                 Deletion.destroy_sprites(ctx.user,
                   reason: "compute_stopped",
                   actor: "system:operator"
                 )
      end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert_received {:server_opts, opts}
      assert Keyword.get(opts, :audit_destroy) == true

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")

      # The caller's actor, on this path as on the other one (ADR 0058 stage
      # 5c). Until 5c `do_destroy_sprites/2` forwarded no `:actor` to
      # `terminate_conversation/2`, so this recorded `self` while the sibling
      # test above — the same operation on a machine whose conversation had no
      # live server — recorded the caller's actor. Which actor a
      # teardown was attributed to depended on whether a GenServer happened to
      # be up. Now both say who asked, and the row's
      # `sandbox.teardown_requested` agrees with its `sandbox.destroyed`.
      assert destroyed.actor == "system:operator"

      assert [requested] = events(ctx.user.id, "sandbox.teardown_requested")
      assert requested.actor == destroyed.actor

      assert events(ctx.user.id, "conversation.terminated") == [],
             "stopping a tenant's compute recorded a per-conversation event"
    end

    test "a provider error does not abort the deletion", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(ctx.user) end)

      refute Repo.get(Fountain.Accounts.User, ctx.user.id)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    end

    test "a refused destroy does not abort the deletion", ctx do
      refuse_destroy_of(ctx.sandbox.id)

      log =
        capture_log(fn ->
          assert {:ok, %{sprites_destroyed: 0}} = Deletion.delete_user(ctx.user)
        end)

      assert log =~ "refused"
      refute Repo.get(Fountain.Accounts.User, ctx.user.id)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
    end

    test "an enclosing transaction is still refused before any teardown", ctx do
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn -> Deletion.delete_user(ctx.user) end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      refute teardown_fenced?(Fountain.Machines.Lease.get(ctx.sandbox.id))
    end
  end

  # ── site 3: the reaper's expiry ───────────────────────────────────────────

  describe "the reaper expires an abandoned machine through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: age(sandbox, conv, 60 * 24 * 83), conv: conv}
    end

    defp sweep(fun) do
      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fun)
      end)
    end

    test "the machine dies in the same pass, with the row fenced and live when it does", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"

      # The thread survives a reclaimed machine; the next prompt provisions a
      # fresh one (decisions/0017).
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "an abandoned row with idle conversations bound is expired, never kept", ctx do
      # The failure this test exists for. An abandoned `ready` row still has
      # its conversations bound — that is what makes it abandoned rather than
      # empty — so a `terminating_conversation_id` on this path would answer
      # `:sandbox_kept` for every machine the ceiling was written to bound, and
      # each one would bill forever with nothing able to expire it. Two of
      # them, because one bound conversation naming *itself* is the one shape
      # the fence does not keep: it takes a co-tenant, or a home.
      second =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "idle"
        )

      capture_provider()
      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert Repo.reload!(second).status == "idle"
    end

    test "both the reaper's own event and the protocol's are recorded", ctx do
      capture_provider()
      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.actor == "system:sandbox_reaper"
      assert expired.metadata["reason"] == "past max lifetime"

      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.actor == "system:sandbox_reaper"
      assert destroyed.metadata["reason"] == "max_lifetime"
    end

    test "a provider error still retires the row", ctx do
      expect(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :unavailable} end)

      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert [_] = events(ctx.user.id, "sandbox.expired")
    end

    test "the idle arm on a provider that cannot park expires through the owner too", ctx do
      # `idle_sweep/1`'s first `expire/3` arm, which had no test before this
      # round: a provider whose `idle_action/1` is `:destroy` has no park to
      # offer, so an idle machine is reclaimed rather than suspended.
      # Past the idle bound but under the ceiling, so the verdict is
      # `{:expired, :idle}` and reaches `idle_sweep/2` — the describe's own
      # fixture is 83 days old and goes down the max-lifetime arm.
      sandbox = age(ctx.sandbox, ctx.conv, 60 * 5)
      stub(Lifecycle, :idle_action, fn _provider -> :destroy end)
      capture_provider()

      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload!(sandbox).status == "terminated"
      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.metadata["reason"] == "idle on a provider without suspend"
      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")
      assert destroyed.metadata["reason"] == "idle"
    end

    test "the idle arm whose suspend call fails expires through the owner too", ctx do
      # The second arm, and the one that matters for load: a provider whose
      # suspend is down sends every idle row down the destroy path at once,
      # which is why `@destroy_limit` now covers pass 1 (below).
      sandbox = age(ctx.sandbox, ctx.conv, 60 * 5)
      stub(Lifecycle, :idle_action, fn _provider -> :suspend end)
      stub(Managoat.Sandbox.Sprites, :suspend, fn _handle -> {:error, :unavailable} end)
      capture_provider()

      sweep(fn -> assert {0, 1, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [sandbox.machine_name]
      assert Repo.reload!(sandbox).status == "terminated"
      assert [expired] = events(ctx.user.id, "sandbox.expired")
      assert expired.metadata["reason"] == "idle; suspend call failed"
    end

    test "pass 1 spends at most @destroy_limit provider destroys in one sweep", ctx do
      # Before stage 5b the cap sat on pass 2, which made every provider
      # destroy the reaper made. Pass 1 now destroys in the call, so an
      # uncapped sweep would fire one per abandoned row — the burst the
      # constraint was written against.
      #
      # Named for pass 1 alone, deliberately: a whole *run* can make up to
      # `@destroy_limit + @pass_two_floor` calls, because pass 2 keeps a floor
      # when pass 1 saturates (the test below makes exactly that many). The
      # number is a drain rate, not a ceiling on the run.
      limit = 25

      extra =
        for _ <- 1..limit do
          s = insert_sandbox(user_id: ctx.user.id, status: "ready")
          c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
          age(s, c, 60 * 24 * 83)
        end

      capture_provider()

      # 26 rows past the ceiling, 25 destroys, one deferred to the next run and
      # counted as neither expired nor refused.
      sweep(fn -> assert {0, ^limit, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert length(destroyed_names()) == limit

      all = [ctx.sandbox | extra]
      terminal = Enum.count(all, &(Repo.reload!(&1).status == "terminated"))
      assert terminal == limit
      assert Enum.count(all, &(Repo.reload!(&1).status == "ready")) == 1
    end

    test "a refused expiry does not spend the run's provider-destroy budget", ctx do
      # The budget bounds calls to the provider, and the refusal that happens in
      # practice — another owner holding the lease — is decided before the fence
      # and makes no call. Charging it meant a run of refusals left pass 2 with
      # nothing, so an outage that reclaimed no machines also stopped the
      # leftover-sprite pass collecting the ones already known dead — and those
      # bill on, with no other pass looking at them.
      # Six leaked sprites and 26 refusals, and both numbers are load-bearing.
      # With `perform/1` subtracting refusals again, pass 2's budget is
      # `max(@pass_two_floor, 25 - 0 - 26)` — the floor, 5 — so a fixture with
      # five or fewer leaked sprites passes either way and pins nothing. Six is
      # the first number that tells the two apart.
      leaked =
        for _ <- 1..6 do
          insert_sandbox(user_id: ctx.user.id, status: "terminated")
        end

      refused =
        for _ <- 1..26 do
          s = insert_sandbox(user_id: ctx.user.id, status: "ready")
          c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
          age(s, c, 60 * 24 * 83)
        end

      refuse_destroys_of(Enum.map([ctx.sandbox | refused], & &1.id))
      live_provider(Enum.map(leaked, & &1.machine_name))

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      # Every expiry refused, no provider call made by pass 1, and pass 2 with
      # its budget intact — all six, not the five the floor alone would allow.
      assert Enum.sort(destroyed_names()) ==
               Enum.sort(Enum.map(leaked, & &1.machine_name))
    end

    test "refusals leave pass 1's own budget for the rows behind them", ctx do
      # The other half: a refusal must not consume the budget *within* the
      # sweep either, or a burst of contended rows at the front pushes healthy
      # ones behind them past the limit and they are deferred for no reason.
      # 25 refused and 2 reclaimable, against a budget of 25.
      refused =
        for _ <- 1..25 do
          s = insert_sandbox(user_id: ctx.user.id, status: "ready")
          c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
          age(s, c, 60 * 24 * 83)
        end

      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      other_conv = insert_conversation(user_id: ctx.user.id, sandbox: other, status: "idle")
      other = age(other, other_conv, 60 * 24 * 83)

      refuse_destroys_of(Enum.map(refused, & &1.id))
      capture_provider()

      sweep(fn -> assert {0, 2, 25, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert Enum.sort(destroyed_names()) ==
               Enum.sort([ctx.sandbox.machine_name, other.machine_name])
    end

    test "pass 2 keeps a floor even when pass 1 saturates the budget", ctx do
      # A backlog big enough to spend the whole budget every run would otherwise
      # leave pass 2 nothing, run after run, for as long as the backlog lasts —
      # and its rows are already terminal, so no other pass looks at them and
      # their machines bill unnoticed. The floor keeps it draining at a trickle.
      for _ <- 1..30 do
        s = insert_sandbox(user_id: ctx.user.id, status: "ready")
        c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
        age(s, c, 60 * 24 * 83)
      end

      leaked =
        for _ <- 1..6 do
          insert_sandbox(user_id: ctx.user.id, status: "terminated")
        end

      live_provider(Enum.map(leaked, & &1.machine_name))

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn -> assert :ok = perform_job(SandboxReaper, %{}) end)
      end)

      names = destroyed_names()
      leaked_names = MapSet.new(leaked, & &1.machine_name)
      collected = Enum.count(names, &MapSet.member?(leaked_names, &1))

      assert collected == 5,
             "pass 1 saturated the budget and pass 2 collected #{collected} leaked " <>
               "sprite(s); without a floor it collects none, run after run, while those " <>
               "machines keep billing"
    end

    test "the idle arm defers rather than expiring once the budget is spent", ctx do
      # `expire_within/3`'s other clause, and the one an outage reaches: a
      # provider whose suspend is down sends the whole idle backlog to the
      # destroy path at once. Past the budget a row is left exactly as it was —
      # no fence, no provider call, counted as neither expired nor refused — so
      # the next run sees it unchanged.
      idle =
        for _ <- 1..26 do
          s = insert_sandbox(user_id: ctx.user.id, status: "ready")
          c = insert_conversation(user_id: ctx.user.id, sandbox: s, status: "idle")
          age(s, c, 60 * 5)
        end

      stub(Lifecycle, :idle_action, fn _provider -> :destroy end)
      capture_provider()

      # 26 idle rows plus the describe's own row past the ceiling, against a
      # budget of 25.
      sweep(fn -> assert {0, 25, 0, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert length(destroyed_names()) == 25

      deferred = Enum.filter([ctx.sandbox | idle], &(Repo.reload!(&1).status == "ready"))
      assert length(deferred) == 2

      for row <- deferred do
        reloaded = Fountain.Machines.Lease.get(row.id)

        refute reloaded.transition == "destroying",
               "a deferred row was fenced — the next run must see it exactly as it was"
      end
    end

    test "a refused destroy records nothing and does not stop the sweep", ctx do
      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      other_conv = insert_conversation(user_id: ctx.user.id, sandbox: other, status: "idle")
      other = age(other, other_conv, 60 * 24 * 83)

      refuse_destroy_of(ctx.sandbox.id)
      capture_provider()

      # One reclaimed and one refused, counted apart. `expired` is graphed on
      # the finance board as "rows expired by the reaper", so a machine that is
      # still `ready`, still at the provider and still billing must not be in
      # it — otherwise an outage that refuses every destroy reports healthy
      # reclamation while nothing is reclaimed.
      sweep(fn -> assert {0, 1, 1, _} = SandboxReaper.sweep_abandoned_sandboxes() end)

      assert destroyed_names() == [other.machine_name]
      assert Repo.reload!(other).status == "terminated"

      # The refused one is untouched — the refusal here stands in for one the
      # protocol makes before it fences — and records no `sandbox.expired`,
      # because nothing happened to this tenant's machine. The next pass tries
      # again; a refusal that happened *after* the fence is
      # `sweep_fenced_teardowns/0`'s case.
      refused = Fountain.Machines.Lease.get(ctx.sandbox.id)
      assert refused.status == "ready"
      assert Enum.map(events(ctx.user.id, "sandbox.expired"), & &1.resource_id) == [other.id]
    end
  end

  # ── site 4: the admin reap ────────────────────────────────────────────────

  describe "reaping a machine with no live server destroys it through the owner" do
    setup ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "idle"
        )

      no_servers()
      {:ok, sandbox: sandbox, conv: conv}
    end

    test "the machine dies in this call, and the thread stays resumable", ctx do
      expect_provider_sees_the_intent(ctx.sandbox)

      assert {:ok, :released} = Termination.reap_sandbox(ctx.sandbox.id)

      assert_received {:at_provider, name, status, transition, fenced_at}
      assert name == ctx.sandbox.machine_name
      assert status == "ready"
      assert transition == "destroying"
      assert fenced_at

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert Repo.reload!(ctx.conv).status == "idle"
    end

    test "idle conversations bound to it do not make the reap a no-op", ctx do
      # A reap an operator clicked, or a suspension, on a machine whose
      # conversations are idle and serverless. That is the ordinary shape of a
      # runaway machine, and `:kept` would make /admin/sandboxes' Reap button
      # do nothing at all. Two conversations, for the same reason as the
      # reaper's case above: a co-tenant is what the fence keeps a machine for.
      insert_conversation(
        user_id: ctx.user.id,
        agent: ctx.agent,
        sandbox: ctx.sandbox,
        status: "idle"
      )

      capture_provider()
      assert {:ok, :released} = Termination.reap_sandbox(ctx.sandbox.id)
      assert destroyed_names() == [ctx.sandbox.machine_name]
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    end

    test "an admin's id folds to `admin` on both machine events, and is kept on the admin one",
         ctx do
      admin = insert_verified_user()
      capture_provider()

      assert {:ok, :released} =
               Termination.reap_sandbox(ctx.sandbox.id, admin_user_id: admin.id)

      assert [requested] = events(ctx.user.id, "sandbox.teardown_requested")
      assert [destroyed] = events(ctx.user.id, "sandbox.destroyed")

      # ADR 0013 reserves `admin:<operator_id>` for account deletion; the
      # operator's identity is in `admin.sandbox.reaped`, which stays the one
      # place it is recorded (#2255 decision 4).
      assert requested.actor == "admin"
      assert destroyed.actor == "admin"
      assert destroyed.metadata["reason"] == "admin_reap"

      admin_events =
        Audit._unsafe_list_events(action_prefix: "admin.", limit: 50)
        |> Enum.filter(&(&1.action == "admin.sandbox.reaped"))

      assert [event] = admin_events
      assert event.actor == "admin:#{admin.id}"
      assert event.metadata["outcome"] == "released"
    end

    test "a machine with a live server still goes through that server", ctx do
      # Unchanged by this stage and asserted so it stays that way: the reap of
      # a live conversation is a terminate through its server, which has gone
      # through the owner since 5a. `reap_sandbox/2` calls
      # `terminate_conversation/2` locally, so Mimic cannot stand in front of
      # it; the server is a probe that answers the call the way a real one does.
      {:ok, probe} = GenServer.start_link(OkProbe, %{})
      stub(ConversationServer, :whereis, fn id -> if id == ctx.conv.id, do: probe, else: nil end)
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      assert {:ok, :terminated} = Termination.reap_sandbox(ctx.sandbox.id)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
    end

    test "a refused destroy is reported", ctx do
      refuse_destroy_of(ctx.sandbox.id)
      capture_provider()

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = Termination.reap_sandbox(ctx.sandbox.id)
      end)

      assert destroyed_names() == []
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"

      # Nothing succeeded, so nothing was recorded — `audit_reap/3`'s rule,
      # unchanged.
      assert Audit._unsafe_list_events(action_prefix: "admin.", limit: 50)
             |> Enum.filter(&(&1.action == "admin.sandbox.reaped")) == []
    end
  end

  # ── two forced teardowns, one machine ─────────────────────────────────────

  describe "two of these sites racing for one machine" do
    test "an admin reap and a reaper expiry destroy it once between them", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")
      conv = insert_conversation(user_id: ctx.user.id, sandbox: sandbox, status: "idle")
      no_servers()
      test = self()

      # The winner holds its lease across the provider call for long enough
      # that the loser is certainly inside `Destroy`'s wait when it finishes —
      # well under the five-second bound, so the loser answers from the row
      # rather than timing out.
      stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test, {:destroyed, handle.name})
        Process.sleep(300)
        :ok
      end)

      capture_log(fn ->
        reap = Task.async(fn -> Termination.reap_sandbox(sandbox.id) end)

        expiry =
          Task.async(fn ->
            Termination._unsafe_destroy_machine(sandbox.id,
              actor: "system:sandbox_reaper",
              destroy_reason: :max_lifetime,
              reason: "sandbox_expired",
              terminating_conversation_id: nil
            )
          end)

        assert {:ok, _} = Task.await(reap, 15_000)
        assert {:ok, _} = Task.await(expiry, 15_000)
      end)

      # The thread is not part of the race, only of the shape: a machine two
      # forced teardowns arrive at is normally one that still has conversations
      # on it.
      assert Repo.reload!(conv).status == "idle"

      assert destroyed_names() == [sandbox.machine_name],
             "the machine was destroyed more than once: the lease did not serialize " <>
               "two forced teardowns of one machine"

      assert [_one] = events(ctx.user.id, "sandbox.destroyed")
      assert Repo.reload!(sandbox).status == "terminated"
      assert Fountain.Machines.Lease.get(sandbox.id).transition == nil
    end
  end

  # A forced teardown's fence: the `destroying` stamp with a reason that is not
  # a reset's. The stamp is the whole of it since ADR 0058 stage 9b.
  defp teardown_fenced?(row),
    do: row.transition == "destroying" and row.transition_reason != "reset"
end
