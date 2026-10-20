defmodule Fountain.Machines.ReadsTest do
  @moduledoc """
  Read admission for the sandbox files API (#2394).

  What these pin is the pair of orders `Machines.Reads` argues for: a park or a
  destroy that holds the machine refuses a read before it reaches the
  provider, and a read that was admitted first is waited out before the
  operation's provider call. Plus the bounds that make the second one finite —
  release, the window's cutoff, and a caller that dies holding a read.

  `async: false`: the park and destroy cases run the protocols inside an owner
  process, and the lock case uses `unboxed_run` for connections of its own.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Reads
  alias Fountain.SandboxFiles

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  # An empty directory, as the listing script reports one.
  @empty_listing {:ok, "", 0}

  defp stamp(ctx, sets),
    do: put_lease(ctx.sandbox.id, sets)

  # Every entry the table holds for the machine, expired or not: what
  # `in_flight/1` counts plus what nobody has released yet.
  defp rows(sandbox_id),
    do: length(:ets.match_object(Fountain.Machines.Reads, {:_, sandbox_id, :_}))

  # A read whose exec blocks until the test lets it go. The exec's pid is sent
  # to the test so it can watch the provider call, which runs in the read's
  # own task and not in the process that called `run/3`.
  defp blocking_exec(test) do
    stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts ->
      send(test, {:exec_started, self()})

      receive do
        :finish -> send(test, :exec_finished) && @empty_listing
      end
    end)
  end

  defp start_read(test, sandbox) do
    Task.async(fn ->
      Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
      SandboxFiles.list(sandbox, nil)
    end)
  end

  defp park_opts(extra \\ []),
    do: Keyword.merge([actor: "system:sandbox_reaper", reason: :idle], extra)

  defp destroy_opts(ctx, extra \\ []) do
    Keyword.merge(
      [
        actor: "system:conversation_server",
        reason: :terminated,
        terminating_conversation_id: ctx.conv.id
      ],
      extra
    )
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
          5_000 -> :ok
        end
    end
  end

  # ── the original race, deterministically ──────────────────────────────────

  describe "the stale-ready race (#1715)" do
    test "a struct that says ready does not reach the provider once the row is parked", ctx do
      # The controller fetched this row while it was `ready`; a park then
      # committed. Before #2394 the read decided on the struct it was handed
      # and exec'd into a machine being suspended.
      stale = ctx.sandbox
      stamp(ctx, status: "suspended")
      reject(&Managoat.Sandbox.exec/4)

      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.list(stale, nil)
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.read(stale, "f")
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.diff(stale, nil)
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.status(stale, nil)
      assert rows(ctx.sandbox.id) == 0
    end

    for status <- ~w(terminated failed provisioning) do
      test "a #{status} row is refused whatever the struct says", ctx do
        stamp(ctx, status: unquote(status))
        reject(&Managoat.Sandbox.exec/4)

        assert {:error, {:sandbox_not_ready, unquote(status)}} =
                 SandboxFiles.list(ctx.sandbox, nil)
      end
    end

    test "a row that is gone is not found", ctx do
      reject(&Managoat.Sandbox.exec/4)
      Repo.delete_all(from c in Conversation, where: c.sandbox_id == ^ctx.sandbox.id)
      Repo.delete!(ctx.sandbox)

      assert {:error, :not_found} = SandboxFiles.list(ctx.sandbox, nil)
    end
  end

  # ── what an admission refuses ─────────────────────────────────────────────

  describe "admission" do
    test "a live lease refuses the read: an owner is mid-operation", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)

      assert rows(ctx.sandbox.id) == 0
    end

    test "durable destroying refuses the read after its lease has lapsed", ctx do
      stamp(ctx,
        transition: "destroying",
        transition_reason: "terminated",
        lease_epoch: 3,
        lease_node: dead_lease_holder()
      )

      refute Lease.live?(Fountain.Machines.Lease.get(ctx.sandbox.id))
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)
    end

    test "an abandoned parking stamp refuses the read: the machine may be asleep", ctx do
      # A park that died after its suspend and before its finalize leaves
      # `ready` over a suspended machine. Turn admission judges such a row by
      # its status; a read must not, or it is the wake this refuses.
      stamp(ctx, transition: "parking", transition_reason: "idle")
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)
    end

    test "a lapsed lease with no stamp is an owner that died and refuses nothing", ctx do
      stamp(ctx,
        lease_epoch: 1,
        lease_node: dead_lease_holder()
      )

      expect(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> @empty_listing end)

      assert {:ok, %{entries: []}} = SandboxFiles.list(ctx.sandbox, nil)
    end

    test "the exec is built from the row the admission read, not the caller's struct", ctx do
      stale = %{ctx.sandbox | machine_name: "a-machine-that-was-replaced"}
      machine_name = ctx.sandbox.machine_name

      expect(Managoat.Sandbox, :exec, fn %{name: ^machine_name}, "bash", _args, _opts ->
        @empty_listing
      end)

      assert {:ok, _} = SandboxFiles.list(stale, nil)
    end

    test "the read is in the table before its admission lets the lock go", ctx do
      # What a claim waiting on the lock relies on: the moment it holds 4316,
      # an admitted read is already there for its drain to count.
      test = self()

      stub(Conversations, :with_sandbox_lock, fn sandbox_id, fun ->
        call_original(Conversations, :with_sandbox_lock, [
          sandbox_id,
          fn ->
            result = fun.()
            send(test, {:under_lock, Reads.in_flight(sandbox_id)})
            result
          end
        ])
      end)

      expect(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> @empty_listing end)

      assert {:ok, _} = SandboxFiles.list(ctx.sandbox, nil)
      assert_received {:under_lock, 1}
      assert rows(ctx.sandbox.id) == 0
    end

    test "a refused admission leaves nothing behind", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)

      capture_log(fn ->
        for _ <- 1..3, do: {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)

      assert rows(ctx.sandbox.id) == 0
    end

    test "inside a caller's transaction the read is refused, not run under its lock", ctx do
      reject(&Managoat.Sandbox.exec/4)

      Repo.transaction(fn ->
        assert {:error, :transaction_open} = SandboxFiles.list(ctx.sandbox, nil)
      end)
    end
  end

  # ── release and the window ────────────────────────────────────────────────

  describe "the window" do
    test "a read that returns releases its row", ctx do
      test = self()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts ->
        send(test, {:in_flight, Reads.in_flight(ctx.sandbox.id)})
        @empty_listing
      end)

      assert {:ok, _} = SandboxFiles.list(ctx.sandbox, nil)
      assert_received {:in_flight, 1}
      assert rows(ctx.sandbox.id) == 0
    end

    test "a provider error releases its row", ctx do
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts ->
        {:error, {:unavailable, :boom}}
      end)

      assert {:error, {:sandbox_unreachable, {:unavailable, :boom}}} =
               SandboxFiles.list(ctx.sandbox, nil)

      assert rows(ctx.sandbox.id) == 0
    end

    test "a raise in the read is raised to the caller after its row is released", ctx do
      capture_log(fn ->
        reason = catch_exit(Reads.run(ctx.sandbox.id, fn _, _ -> raise "adapter bug" end))
        assert {%RuntimeError{message: "adapter bug"}, _stacktrace} = reason
      end)

      assert rows(ctx.sandbox.id) == 0
    end

    test "a read still at the provider at the cutoff is killed and answers 503", ctx do
      test = self()

      log =
        capture_log(fn ->
          assert {:error, {:sandbox_unreachable, :read_window_closed}} =
                   Reads.run(
                     ctx.sandbox.id,
                     fn _sandbox, budget ->
                       send(test, {:budget, budget, self()})
                       Process.sleep(:infinity)
                     end,
                     window_ms: 500
                   )
        end)

      assert log =~ "cut off at the end of its window"
      assert_received {:budget, budget, pid}
      assert budget <= 400, "the budget was not the window less its margin"
      refute Process.alive?(pid)
      assert rows(ctx.sandbox.id) == 0
    end

    test "a read whose window was spent before the exec never starts", ctx do
      # Nothing is queued anywhere: an admission that has already used its
      # budget answers here, and the provider is never called for it.
      assert {:error, :sandbox_unavailable} =
               Reads.run(ctx.sandbox.id, fn _, _ -> flunk("the read ran") end, window_ms: 0)

      assert rows(ctx.sandbox.id) == 0
    end

    test "a task the supervisor starts after the window never calls the provider", ctx do
      # Starting the task waits on the supervisor. A read admitted in time
      # whose task only starts after its cutoff must not reach the provider:
      # a drain may already have let a park or destroy through by then.
      test = self()
      supervisor = start_supervised!(Task.Supervisor)
      :sys.suspend(supervisor)

      read =
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())

          Reads.run(ctx.sandbox.id, fn _, _ -> send(test, :provider_called) end,
            window_ms: 500,
            task_supervisor: supervisor
          )
        end)

      wait_until(fn ->
        Process.info(supervisor, :message_queue_len) >= {:message_queue_len, 1}
      end)

      Process.sleep(700)
      :sys.resume(supervisor)

      capture_log(fn ->
        assert Task.await(read) in [
                 {:error, :sandbox_unavailable},
                 {:error, {:sandbox_unreachable, :read_window_closed}}
               ]
      end)

      refute_receive :provider_called, 200
      assert rows(ctx.sandbox.id) == 0
    end

    test "the cutoff holds for a caller killed the moment its task has started", ctx do
      # The caller dies as `async_nolink` returns: the task is running and has
      # its function, and the caller runs no further line. Only a cutoff armed
      # inside the task still stands, and the read must be off the provider
      # when it fires.
      test = self()

      stub(Task.Supervisor, :async_nolink, fn supervisor, fun ->
        _task = call_original(Task.Supervisor, :async_nolink, [supervisor, fun])
        Process.exit(self(), :kill)
      end)

      caller =
        spawn(fn ->
          receive do
            :go -> :ok
          end

          Reads.run(
            ctx.sandbox.id,
            fn _sandbox, _budget ->
              send(test, {:exec_started, self()})
              Process.sleep(:infinity)
            end,
            window_ms: 600
          )
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, test, caller)
      allow(Task.Supervisor, test, caller)
      caller_ref = Process.monitor(caller)
      send(caller, :go)

      assert_receive {:exec_started, exec}, 5_000
      exec_ref = Process.monitor(exec)
      assert_receive {:DOWN, ^caller_ref, :process, ^caller, :killed}, 1_000
      assert_receive {:DOWN, ^exec_ref, :process, ^exec, :killed}, 5_000
    end

    test "the exec timeout is never longer than the window allows", ctx do
      expect(Managoat.Sandbox, :exec, fn _handle, "bash", _args, opts ->
        assert opts[:timeout] == 30_000
        @empty_listing
      end)

      assert {:ok, _} = SandboxFiles.list(ctx.sandbox, nil)
    end
  end

  describe "a caller that dies holding a read" do
    test "its entry outlives it, the exec is killed at the cutoff, and a drain ends", ctx do
      test = self()

      caller =
        spawn(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())

          Reads.run(
            ctx.sandbox.id,
            fn _sandbox, _budget ->
              send(test, {:exec_started, self()})
              Process.sleep(:infinity)
            end,
            window_ms: 600
          )
        end)

      assert_receive {:exec_started, exec}, 5_000
      exec_ref = Process.monitor(exec)
      Process.exit(caller, :kill)

      # Nobody released it: the caller died before its `after` could run.
      assert Reads.in_flight(ctx.sandbox.id) == 1

      # The cutoff was armed on the task, not left to the dead caller's `yield`:
      # nothing else is left to kill it. The wait is generous because a runner
      # that stalls the BEAM past both timers can let this receive time out
      # before the watchdog's kill is delivered (#3034).
      assert_receive {:DOWN, ^exec_ref, :process, ^exec, :killed}, 5_000

      # A drain is bounded by the window, not by the caller coming back: the
      # entry ran out, so the drain ended without giving up at its deadline.
      # Judged by its log, not a wall clock a stalled runner can overrun.
      log = capture_log(fn -> assert :ok = Reads.drain(ctx.sandbox.id, read_window_ms: 600) end)
      refute log =~ "still counted past their window"
      assert Reads.in_flight(ctx.sandbox.id) == 0

      # And the next admission on the machine sweeps the leftover.
      assert rows(ctx.sandbox.id) == 1
      assert :ok = Reads.run(ctx.sandbox.id, fn _, _ -> :ok end)
      assert rows(ctx.sandbox.id) == 0
    end
  end

  # ── the two orders, through the owner ─────────────────────────────────────

  describe "park" do
    test "read first: the park's provider call waits for the read to finish", ctx do
      test = self()
      blocking_exec(test)

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, {:suspend, Reads.in_flight(ctx.sandbox.id)})
        :ok
      end)

      read = start_read(test, ctx.sandbox)
      assert_receive {:exec_started, exec}, 5_000

      park =
        Task.async(fn ->
          capture_log(fn -> send(test, {:parked, Machine.park(ctx.sandbox.id, park_opts())}) end)
        end)

      # The park has claimed and is draining: no suspend while the read is at
      # the provider, and no second read is admitted behind it.
      wait_until(fn -> Lease.live?(Fountain.Machines.Lease.get(ctx.sandbox.id)) end)
      refute_receive {:suspend, _}, 300
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)

      send(exec, :finish)
      assert_receive :exec_finished, 5_000
      assert {:ok, %{entries: []}} = Task.await(read)

      assert_receive {:suspend, 0}, 5_000
      assert_receive {:parked, {:ok, :parked}}, 5_000
      Task.await(park)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"
    end

    test "park first: the read is refused while the park is at the provider", ctx do
      test = self()

      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, {:suspending, self()})

        receive do
          :go -> :ok
        end
      end)

      park =
        Task.async(fn ->
          capture_log(fn -> Machine.park(ctx.sandbox.id, park_opts()) end)
        end)

      assert_receive {:suspending, owner}, 5_000
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)

      send(owner, :go)
      Task.await(park)

      # Parked now, and the refusal says so in the API's own word.
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.list(ctx.sandbox, nil)
      assert rows(ctx.sandbox.id) == 0
    end
  end

  describe "destroy" do
    test "read first: the provider destroy waits for the read to finish", ctx do
      test = self()
      blocking_exec(test)

      stub(Managoat.Sandbox, :destroy, fn _ ->
        send(test, {:destroy, Reads.in_flight(ctx.sandbox.id)})
        :ok
      end)

      read = start_read(test, ctx.sandbox)
      assert_receive {:exec_started, exec}, 5_000

      destroy =
        Task.async(fn ->
          capture_log(fn ->
            send(test, {:destroyed, Machine.destroy(ctx.sandbox.id, destroy_opts(ctx))})
          end)
        end)

      wait_until(fn -> Lease.live?(Fountain.Machines.Lease.get(ctx.sandbox.id)) end)
      refute_receive {:destroy, _}, 300

      send(exec, :finish)
      assert {:ok, _} = Task.await(read)

      assert_receive {:destroy, 0}, 5_000
      assert_receive {:destroyed, {:ok, :destroyed}}, 5_000
      Task.await(destroy)
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    end

    test "destroy first: the read is refused while the machine is being destroyed", ctx do
      test = self()

      stub(Managoat.Sandbox, :destroy, fn _ ->
        send(test, {:destroying, self()})

        receive do
          :go -> :ok
        end
      end)

      destroy =
        Task.async(fn ->
          capture_log(fn -> Machine.destroy(ctx.sandbox.id, destroy_opts(ctx)) end)
        end)

      assert_receive {:destroying, owner}, 5_000
      reject(&Managoat.Sandbox.exec/4)

      capture_log(fn ->
        assert {:error, :sandbox_unavailable} = SandboxFiles.list(ctx.sandbox, nil)
      end)

      send(owner, :go)
      Task.await(destroy)

      assert {:error, {:sandbox_not_ready, "terminated"}} = SandboxFiles.list(ctx.sandbox, nil)
    end

    test "a dead caller's read delays a destroy by at most its window", ctx do
      test = self()
      stub(Managoat.Sandbox, :destroy, fn _ -> send(test, :destroyed_at_provider) && :ok end)

      caller =
        spawn(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())

          Reads.run(
            ctx.sandbox.id,
            fn _, _ ->
              send(test, :exec_started)
              Process.sleep(:infinity)
            end,
            window_ms: 800
          )
        end)

      assert_receive :exec_started, 5_000
      Process.exit(caller, :kill)

      started = System.monotonic_time(:millisecond)

      capture_log(fn ->
        assert {:ok, :destroyed} =
                 Machine.destroy(ctx.sandbox.id, destroy_opts(ctx, read_window_ms: 800))
      end)

      waited = System.monotonic_time(:millisecond) - started
      assert_received :destroyed_at_provider
      assert waited >= 300, "the destroy did not wait for the admitted read"
      assert waited < 2_500, "the destroy waited longer than the read's window"
    end
  end

  # ── the lock itself, on connections of their own ──────────────────────────

  describe "on real connections" do
    test "a claim holding the lock makes the admission wait, then refuse on its lease" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        agent = insert_agent(user_id: user.id, runtime: "claude")
        sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
        owner = self()

        holder =
          independent(fn ->
            Conversations.with_sandbox_lock(sandbox.id, fn ->
              send(owner, :lock_held)

              receive do
                :commit -> {:ok, :ok}
              after
                10_000 -> raise "lock release timed out"
              end
            end)
          end)

        try do
          assert_receive :lock_held, 5_000

          read =
            independent(fn ->
              capture_log(fn ->
                send(
                  owner,
                  {:read, Reads.run(sandbox.id, fn _, _ -> send(owner, :exec_ran) end)}
                )
              end)
            end)

          try do
            read_pid = read.pid
            assert_receive {:backend, ^read_pid, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)

            # The holder becomes a lease and commits; the admission then reads
            # it under the lock it was waiting for.
            %Fountain.Conversations.Sandbox{} =
              put_lease(sandbox.id,
                lease_epoch: 1,
                lease_node: live_lease_holder()
              )

            send(holder.pid, :commit)
            assert {:ok, :ok} = Task.await(holder)
            assert_receive {:read, {:error, :sandbox_unavailable}}, 5_000
            refute_received :exec_ran
            Task.await(read)
            assert rows(sandbox.id) == 0
          after
            Task.shutdown(read, :brutal_kill)
          end
        after
          Task.shutdown(holder, :brutal_kill)
          discard(user, [sandbox])
        end
      end)
    end
  end

  defp wait_until(fun, tries \\ 500) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, tries - 1)
    end
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

  # `unboxed_run` commits, so the rows a race case makes are removed by hand.
  defp discard(user, sandboxes) do
    Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
    Repo.delete_all(from c in Conversation, where: c.user_id == ^user.id)
    for sandbox <- sandboxes, do: Repo.delete!(sandbox)
    Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
    Repo.delete!(user)
  end
end
