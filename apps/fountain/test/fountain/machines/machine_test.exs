defmodule Fountain.Machines.MachineTest do
  @moduledoc """
  The owner process and its two doors (ADR 0058 stages 4 and 5).

  The destroy protocol itself is `destroy_test.exs`; what is pinned here is
  the door — that the work runs in the owner, and what a caller is told when
  the owner cannot be reached at all.

  `async: false`: several cases count the owner supervisor's children, which
  are shared by every test that starts an owner.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "gemini")
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    a = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, a: a, b: b}
  end

  # An owner outliving its test would hold a checked-in sandbox connection and
  # stay registered under an id the next test may reuse. Its idle timer is a
  # minute by default, which is far longer than the suite.
  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil -> :ok
      pid -> stop_and_await(pid)
    end
  end

  defp stop_and_await(pid) do
    ref = Process.monitor(pid)
    DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _} -> :ok
    after
      2_000 -> Process.demonitor(ref, [:flush])
    end
  end

  describe "busy?/2" do
    test "a live lease is a machine mid-operation", ctx do
      # ADR 0058 stage 6a. The rest of `busy?/2` is pinned in
      # `mid_operation_readers_test.exs`.
      parking =
        ctx.sandbox
        |> put_lease(
          transition: "parking",
          lease_epoch: 1,
          lease_node: live_lease_holder()
        )

      assert Machine.busy?(parking)
    end
  end

  # The owners registered for one machine. Scoped to the test's own row: every
  # verb runs in an owner since stage 9b, so the async suites running beside
  # this one leave owners of their own machines behind for a minute each.
  #
  # Registered under the sandbox's workspace (ADR 0097, step 3b).
  defp owners_of(sandbox_id) do
    key = Machine.owner_key(sandbox_id)

    Registry.select(Fountain.MachineRegistry, [
      {{:"$1", :"$2", :_}, [{:==, :"$1", key}], [:"$2"]}
    ])
  end

  describe "the callers seam" do
    # `$callers` adoption is a test seam (`:owner_adopts_callers`, set in
    # `config/test.exs` only). In production the owner must put nothing there:
    # `opentelemetry_ecto` reads the key on every query, and `main`'s owner
    # never set it. This file is `async: false`, so it may switch the flag.
    defp with_adoption(value, fun) do
      previous = Application.fetch_env(:fountain, :owner_adopts_callers)
      Application.put_env(:fountain, :owner_adopts_callers, value)

      try do
        fun.()
      after
        case previous do
          {:ok, was} -> Application.put_env(:fountain, :owner_adopts_callers, was)
          :error -> Application.delete_env(:fountain, :owner_adopts_callers)
        end
      end
    end

    defp owner_callers(pid) do
      {:dictionary, dictionary} = Process.info(pid, :dictionary)
      Keyword.fetch(dictionary, :"$callers")
    end

    test "with the flag off, as in production, the owner never puts $callers", ctx do
      with_adoption(false, fn ->
        assert %Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
        pid = Machine.whereis(ctx.sandbox.id)
        assert is_pid(pid)
        assert owner_callers(pid) == :error, "the owner put $callers with the flag off"
      end)
    end

    test "with the flag on, as in the suite, the owner serves as its caller", ctx do
      with_adoption(true, fn ->
        assert %Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
        assert {:ok, [caller | _]} = owner_callers(Machine.whereis(ctx.sandbox.id))
        assert caller == self()
      end)
    end
  end

  describe "ensure_started/2 and whereis/1" do
    test "starts one owner and finds it again", ctx do
      assert Machine.whereis(ctx.sandbox.id) == nil

      assert {:ok, pid} = Machine.ensure_started(ctx.sandbox.id)
      assert Process.alive?(pid)
      assert Machine.whereis(ctx.sandbox.id) == pid
    end

    test "a second call returns the same pid rather than a second owner", ctx do
      assert {:ok, pid} = Machine.ensure_started(ctx.sandbox.id)
      assert {:ok, ^pid} = Machine.ensure_started(ctx.sandbox.id)
    end

    test "twenty concurrent starts produce one owner", ctx do
      # `whereis/1` can miss a winner that is registered but not yet
      # propagated, so the losers reach `start_child` and come back
      # `{:error, {:already_started, pid}}`, which is a success. Run it for
      # real rather than sequentially: the interleaving is the thing under
      # test, and two sequential calls never take the losing branch.
      results =
        1..20
        |> Task.async_stream(fn _ -> Machine.ensure_started(ctx.sandbox.id) end,
          max_concurrency: 20,
          timeout: 10_000
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert Enum.all?(results, &match?({:ok, pid} when is_pid(pid), &1)),
             "some starts failed: #{inspect(Enum.reject(results, &match?({:ok, _}, &1)))}"

      pids = results |> Enum.map(fn {:ok, pid} -> pid end) |> Enum.uniq()

      assert length(pids) == 1, "#{length(pids)} owners for one machine: #{inspect(pids)}"
      assert owners_of(ctx.sandbox.id) == pids
    end

    test "the losing branch returns the winner rather than an error", ctx do
      {:ok, winner} = Machine.ensure_started(ctx.sandbox.id)

      assert {:error, {:already_started, ^winner}} =
               DynamicSupervisor.start_child(
                 Fountain.MachineSupervisor,
                 {Machine, key: Machine.owner_key(ctx.sandbox.id)}
               )

      assert {:ok, ^winner} = Machine.ensure_started(ctx.sandbox.id)
    end

    test "different sandboxes get different owners", ctx do
      other = insert_sandbox(user_id: ctx.user.id, status: "ready")
      on_exit(fn -> stop_machine(other.id) end)

      {:ok, first} = Machine.ensure_started(ctx.sandbox.id)
      {:ok, second} = Machine.ensure_started(other.id)

      refute first == second
    end
  end

  describe "who_is_here/1" do
    test "answers exactly what Occupancy answers", ctx do
      insert_turn(ctx.b, %{
        status: "running",
        prompt: "go",
        started_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

      occupancy = Machine.who_is_here(ctx.sandbox.id)

      assert %Occupancy{} = occupancy
      assert Enum.sort(occupancy.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      assert occupancy.running_turns == %{ctx.b.id => "gemini"}
      assert occupancy.live == []
      assert occupancy.last_activity_at

      direct = Occupancy.load(ctx.sandbox.id)
      assert occupancy.bound |> Enum.sort() == direct.bound |> Enum.sort()
      assert occupancy.running_turns == direct.running_turns
      assert occupancy.activity == direct.activity
    end

    test "it is served by the owner", ctx do
      assert Machine.whereis(ctx.sandbox.id) == nil
      assert %Occupancy{} = Machine.who_is_here(ctx.sandbox.id)
      assert is_pid(Machine.whereis(ctx.sandbox.id))
    end

    test "an idle-stopped owner is simply replaced on the next question", ctx do
      {:ok, pid} = Machine.ensure_started(ctx.sandbox.id, idle_ms: 40)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000

      # The stale pid, called directly, is what the race below hands
      # `who_is_here/1`. Here the registry has already dropped it, so the
      # lookup misses and a fresh owner starts — no exit to survive.
      assert catch_exit(GenServer.call(pid, :who_is_here, 1_000))

      assert %Occupancy{} = occupancy = Machine.who_is_here(ctx.sandbox.id)
      assert Enum.sort(occupancy.bound) == Enum.sort([ctx.a.id, ctx.b.id])
      refute Machine.whereis(ctx.sandbox.id) == pid
    end

    test "an owner that dies between the lookup and the call is retried, not raised", ctx do
      # The real race, which the test above cannot reach: `ensure_started/2`
      # hands back a pid and the idle timer fires before the call lands.
      # `GenServer.call` *exits* on that, and a read-only verb must not take
      # its caller down with it.
      #
      # Driven deterministically by making the first registry lookup in THIS
      # process return a pid that is already dead. The supervisor's own
      # internals are untouched and the retry starts a genuine owner.
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _}, 1_000

      {:ok, lookups} = Agent.start_link(fn -> 0 end)

      # Only the machine registry. The owner this test starts finds its stubs
      # through `$callers`, so its own `Occupancy` lookups in the conversation
      # registry would land here too.
      stub(Registry, :lookup, fn
        Fountain.MachineRegistry, _key ->
          case Agent.get_and_update(lookups, &{&1, &1 + 1}) do
            0 -> [{dead, nil}]
            _ -> []
          end

        registry, key ->
          Mimic.call_original(Registry, :lookup, [registry, key])
      end)

      assert %Occupancy{} = occupancy = Machine.who_is_here(ctx.sandbox.id)
      assert Enum.sort(occupancy.bound) == Enum.sort([ctx.a.id, ctx.b.id])

      # The discriminator between retrying and giving up: the answer is a
      # struct either way, but only the retry starts a real owner. Without it
      # this test would pass against a bare `Occupancy.load/1` fallback.
      assert [_one] = owners_of(ctx.sandbox.id)
    end

    test "no predicate starts an owner", ctx do
      # A read never needs the process. `Machine.destroy/2` is the one verb
      # that does (stage 5), and the predicates below are not it:
      # `held_by_other?/2` in particular runs inside the teardown fence's own
      # advisory-locked transaction and reads that transaction's uncommitted
      # rows, so it must stay on the caller's connection and never go behind a
      # GenServer call (#2348 review).
      assert owners_of(ctx.sandbox.id) == []

      preloaded = Fountain.Repo.preload(ctx.sandbox, :conversations, force: true)

      assert Conversations._unsafe_sandbox_busy_elsewhere?(ctx.sandbox.id, ctx.a.id, 3600)
      assert Fountain.Machines.Binding.held_by_other?(ctx.sandbox.id, ctx.a.id)
      assert Lifecycle.live_conversation_ids(preloaded) == []
      refute Lifecycle.any_server_alive?(preloaded)
      assert Conversations._unsafe_list_cotenant_ids(ctx.sandbox.id, ctx.a.id) == [ctx.b.id]

      assert owners_of(ctx.sandbox.id) == [], "an owner was started"
    end
  end

  describe "destroy/2" do
    setup ctx do
      stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
      # Alone on the machine: a co-tenant would make the fence keep it.
      Fountain.Repo.delete!(ctx.b)
      :ok
    end

    test "it runs in the owner, which survives to answer again", ctx do
      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)

      assert {:ok, :destroyed} =
               Machine.destroy(ctx.sandbox.id,
                 actor: "api",
                 reason: :terminated,
                 terminating_conversation_id: ctx.a.id
               )

      # The idle window is re-armed by the call rather than left to fire
      # mid-destroy, so the owner is still there for the next verb.
      assert Machine.whereis(ctx.sandbox.id) == owner
      assert %Occupancy{} = Machine.who_is_here(ctx.sandbox.id)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    end

    test "an owner that cannot be started refuses rather than writing anyway", ctx do
      # The difference from `who_is_here/1`, which falls back to a direct read:
      # that verb only looked, and this one writes. A write with nowhere to run
      # has to say so, or two nodes end up destroying one machine by different
      # routes. `:sandbox_unavailable` and not the reason itself — it is a
      # tuple, the answer travels to `FallbackController`, and the door's job
      # is to keep the system's vocabulary (`destroy_test.exs`).
      stub(DynamicSupervisor, :start_child, fn Fountain.MachineSupervisor, _child ->
        {:error, :no_capacity}
      end)

      stub(Registry, :lookup, fn Fountain.MachineRegistry, _key -> [] end)
      reject(Managoat.Sandbox, :destroy, 1)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:error, :sandbox_unavailable} =
                   Machine.destroy(ctx.sandbox.id, actor: "api", reason: :terminated)
        end)

      assert log =~ "machine_unreachable"
      assert log =~ "no_capacity"

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition
    end
  end

  describe "idle-stop" do
    test "the owner stops itself after its idle window and comes back", ctx do
      {:ok, pid} = Machine.ensure_started(ctx.sandbox.id, idle_ms: 50)
      ref = Process.monitor(pid)

      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 2_000
      # The registry drops an exited process's entry a moment after the exit.
      assert_unregistered(ctx.sandbox.id, 100)

      assert {:ok, revived} = Machine.ensure_started(ctx.sandbox.id)
      refute revived == pid
    end

    test "a question re-arms the window rather than letting it fire", ctx do
      {:ok, pid} = Machine.ensure_started(ctx.sandbox.id, idle_ms: 300)
      ref = Process.monitor(pid)

      # Four calls across more than one idle window. A timer that was not
      # re-armed — or a stale one that was not ignored — stops the process
      # somewhere in here.
      for _ <- 1..4 do
        Process.sleep(100)
        assert %Occupancy{} = GenServer.call(pid, {:who_is_here, ctx.sandbox.id})
      end

      refute_received {:DOWN, ^ref, :process, ^pid, _}
      assert Process.alive?(pid)
    end
  end

  defp assert_unregistered(sandbox_id, tries) do
    cond do
      Machine.whereis(sandbox_id) == nil ->
        :ok

      tries == 0 ->
        flunk("the owner of #{sandbox_id} is still registered after it stopped")

      true ->
        Process.sleep(10)
        assert_unregistered(sandbox_id, tries - 1)
    end
  end
end
