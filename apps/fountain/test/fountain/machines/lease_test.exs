defmodule Fountain.Machines.LeaseTest do
  @moduledoc """
  The lease protocol of ADR 0058, stage 3, as ADR 0072 reduced it: the holder
  is a process of this boot, and a lease is live while that process is.

  The cases that need two real connections run under `unboxed_run/2`, because
  the SQL sandbox puts every process on one transaction and a lock taken there
  is a lock the whole test already holds — contention could not be observed and
  a rollback would not release anything. Those tests commit, so each one
  deletes what it made.
  """
  use Fountain.DataCase, async: false

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease

  # `Fountain.Conversations`' per-sandbox advisory namespace. The lease reuses
  # `with_sandbox_lock/2`, so a test that takes this key by hand blocks it.
  @sandbox_lock_namespace 4316

  describe "on one connection" do
    setup do
      %{sandbox: insert_sandbox(status: "pending")}
    end

    test "a claim takes the next epoch and a release keeps it", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id)

      held = Repo.get!(Sandbox, ctx.sandbox.id)
      assert held.lease_epoch == 1
      assert held.lease_node == Lease.holder(self())

      assert :ok = Lease.release(ctx.sandbox.id, 1)

      released = Repo.get!(Sandbox, ctx.sandbox.id)
      assert released.lease_epoch == 1
      refute released.lease_node

      # Strictly higher, never reused: the released holder's writes must stay
      # dead even though it gave the lease up politely.
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "failed"})
    end

    test "live?/1 is what a claim decides on, read from the row", ctx do
      # The one definition of "somebody holds this machine". What makes it
      # trustworthy is that `claim/2` refuses exactly when this says true, so
      # the readers and the claimant cannot disagree.
      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))

      holder = spawn(fn -> receive do: (:stop -> :ok) end)
      {:ok, 1} = Lease.claim(ctx.sandbox.id, holder: holder)
      held = Repo.get!(Sandbox, ctx.sandbox.id)

      assert held.lease_node == Lease.holder(holder)
      assert Lease.live?(held)
      assert {:error, {:held, _}} = Lease.claim(ctx.sandbox.id)

      # And exactly when it says false: the holder is gone, so the lease is.
      ref = Process.monitor(holder)
      send(holder, :stop)
      assert_receive {:DOWN, ^ref, :process, ^holder, _}
      refute Lease.live?(held)
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id)
    end

    test "live?/1 reads only a holder of this boot", ctx do
      refute Lease.live?(%{lease_node: nil})
      refute Lease.live?(%{lease_node: dead_lease_holder()})
      refute Lease.live?(%{lease_node: "fountain@node"})
      refute Lease.live?(%{lease_node: Lease.boot_prefix() <> "not-a-pid"})
      assert Lease.live?(%{lease_node: Lease.holder(self())})

      # A released lease keeps its epoch and has no holder.
      {:ok, 1} = Lease.claim(ctx.sandbox.id)
      :ok = Lease.release(ctx.sandbox.id, 1)
      refute Lease.live?(Repo.get!(Sandbox, ctx.sandbox.id))
    end

    test "supersede: takes the lease from that one live holder", ctx do
      holder = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(holder, :stop) end)
      {:ok, 1} = Lease.claim(ctx.sandbox.id, holder: holder)

      other = spawn(fn -> receive do: (:stop -> :ok) end)
      on_exit(fn -> send(other, :stop) end)

      # Naming some other process supersedes nothing.
      assert {:error, {:held, _}} = Lease.claim(ctx.sandbox.id, supersede: other)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert {:ok, 2} = Lease.claim(ctx.sandbox.id, supersede: holder)
        end)

      assert log =~ "still alive and is being stopped"

      # Everything the superseded holder writes from here is invisible.
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "failed"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_node == Lease.holder(self())
    end

    test "the boot sweep clears leases but preserves destroy and resume intent", ctx do
      old = insert_sandbox(status: "ready")
      destroying = insert_sandbox(status: "ready")
      mine = insert_sandbox(status: "ready")
      bare = insert_sandbox(status: "suspended")

      stamp = fn sandbox, set -> put_lease(sandbox, set) end

      stamp.(old,
        lease_epoch: 3,
        lease_node: dead_lease_holder(),
        transition: "parking",
        transition_reason: "idle"
      )

      stamp.(destroying,
        lease_epoch: 2,
        lease_node: dead_lease_holder(),
        transition: "destroying",
        transition_reason: "teardown"
      )

      stamp.(mine, lease_epoch: 1, lease_node: Lease.holder(self()), transition: "parking")
      stamp.(bare, transition: "resuming", transition_reason: "wake")

      # At least these two: the sweep is over every workspace, and rows other
      # suites committed and left behind are swept too.
      assert Lease.sweep_boot() >= 2

      cleared = Repo.get!(Sandbox, old.id)
      assert {cleared.lease_node, cleared.transition} == {nil, nil}
      assert cleared.lease_epoch == 3, "the epoch never goes back"

      # A destroy is a durable request, not an operation in flight.
      kept = Repo.get!(Sandbox, destroying.id)

      assert {kept.lease_node, kept.transition, kept.transition_reason} ==
               {nil, "destroying", "teardown"}

      # This boot's own lease is left alone.
      assert Repo.get!(Sandbox, mine.id).transition == "parking"
      assert Repo.get!(Sandbox, mine.id).lease_node == Lease.holder(self())

      assert Repo.get!(Sandbox, bare.id).transition == "resuming"
      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_epoch == 0
      assert Lease.sweep_boot() == 0
    end

    test "live?/1 takes a selected map, not only a row", ctx do
      # A caller may select the two columns beside the id rather than load
      # rows, as `SandboxResetReconciler`'s sweep did, and ask the same
      # predicate.
      {:ok, 1} = Lease.claim(ctx.sandbox.id)

      selected =
        Repo.one(
          from s in Sandbox,
            where: s.id == ^ctx.sandbox.id,
            select: %{id: s.id, lease_node: s.lease_node}
        )

      assert Lease.live?(selected)
    end

    test "a claim on a row that is not there says so" do
      assert {:error, :not_found} = Lease.claim(Ecto.UUID.generate())
    end

    test "the owner writes state and finalizes a transition through its epoch", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)

      assert {:ok, parking} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 transition: "parking",
                 transition_reason: "idle"
               })

      assert parking.transition == "parking"
      assert parking.transition_reason == "idle"
      assert parking.status == "pending"

      assert {:ok, parked} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 status: "suspended",
                 transition: nil,
                 transition_reason: nil
               })

      assert parked.status == "suspended"
      refute parked.transition
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "suspended"
    end

    test "a stale epoch writes nothing at all", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      # Epoch 0 is the default on every row and epoch 1 is the first a claim
      # ever hands out, so 0 is superseded here as well as never held. The
      # never-held half is its own test below; this one is the ordinary
      # overtaken-owner case.
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "failed"})
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before

      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "epoch 0 is not a lease anybody took", ctx do
      before = Repo.get!(Sandbox, ctx.sandbox.id)
      assert before.lease_epoch == 0

      # Every row starts at epoch 0 with no holder. Refused before the query:
      # claims start at 1.
      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id) == before

      # And the machine is still claimable, which is the point.
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id)
    end

    test "cas_update does not revive a retired machine", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "terminated"})

      # The same refusal `Conversations.update_sandbox/2` gets from
      # `prevent_sandbox_revival/1`. Holding the lease is not permission to
      # un-retire a row, and `:retired` says so rather than `:stale`, which
      # would send the owner looking for a takeover that never happened.
      assert {:error, :retired} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "terminated"

      # Terminal to terminal still goes through, exactly as it does through
      # `update_sandbox/2`, and a write that never names a status is untouched
      # by this.
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "failed"})

      assert {:ok, reaped} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{transition_reason: "reaped"})

      assert reaped.transition_reason == "reaped"
    end

    test "an epoch below 1 is refused even where a row somehow has a holder", ctx do
      # Unreachable through this module: `do_claim/3` is the only writer of the
      # holder columns and always moves the epoch to 1 or more. Forged straight
      # into the row so `taken_epoch?/1` is pinned on its own — `held_by/2`'s
      # holder columns mask it on every reachable row, which is exactly how a
      # defence-in-depth guard gets deleted in a refactor with nothing red.
      Repo.update_all(from(x in Sandbox, where: x.id == ^ctx.sandbox.id),
        set: [
          lease_epoch: 0,
          lease_node: Lease.holder(self())
        ]
      )

      assert {:error, :lost} = Lease.release(ctx.sandbox.id, 0)
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})
      assert Repo.get!(Sandbox, ctx.sandbox.id).status == "pending"
    end

    test "a terminal status carries its own terminated_at", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)

      # A writer that fails a machine never passes `terminated_at`. Without
      # this stamp `cas_update/3` would leave a retired sandbox reading as
      # still running, which is the bug `stamp_terminated_at/1` was written for.
      assert {:ok, live} = Lease.cas_update(ctx.sandbox.id, epoch, %{transition: "destroying"})
      refute live.terminated_at

      assert {:ok, terminated} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "terminated"})
      assert terminated.terminated_at

      # Stamped once. A second terminal write does not move the billed end.
      assert {:ok, failed} = Lease.cas_update(ctx.sandbox.id, epoch, %{status: "failed"})
      assert failed.terminated_at == terminated.terminated_at
    end

    test "a caller's own terminated_at wins over the stamp", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      theirs = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      assert {:ok, terminated} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 status: "failed",
                 terminated_at: theirs
               })

      assert terminated.terminated_at == theirs
    end

    test "a superseded epoch is stale even on a retired row", ctx do
      assert {:ok, 1} = Lease.claim(ctx.sandbox.id)
      assert {:ok, _} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "terminated"})
      assert {:ok, 2} = Lease.claim(ctx.sandbox.id, supersede: self())

      # `:stale` beats `:retired`. A caller that no longer holds the machine is
      # told it lost the lease, not what the row's status happens to be.
      assert {:error, :stale} = Lease.cas_update(ctx.sandbox.id, 1, %{status: "ready"})
      assert {:error, :retired} = Lease.cas_update(ctx.sandbox.id, 2, %{status: "ready"})
    end

    test "a caller's own bug is an answer, not a raise", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      # A duplicate key in a keyword list reaches Ecto as two `SET status =`
      # clauses and raises `Ecto.QueryError` from inside the transaction.
      assert {:error, {:invalid, :status}} =
               Lease.cas_update(ctx.sandbox.id, epoch, status: "failed", status: "suspended")

      # A struct is a map, so the spec and `is_map/1` both admit one and
      # `Enum.reduce_while/3` raises `Protocol.UndefinedError` on it.
      assert {:error, {:invalid, :attrs}} =
               Lease.cas_update(ctx.sandbox.id, epoch, %Sandbox{status: "ready"})

      # `is_binary/1` admits a string that is not a UUID; the query would raise
      # `Ecto.Query.CastError` on it. The raw 16-byte form passes
      # `Ecto.UUID.cast/1` and raises all the same, which is why the guard
      # checks the length too.
      {:ok, raw} = Ecto.UUID.dump(Ecto.UUID.generate())

      for id <- ["not-a-uuid", raw],
          call <- [
            fn id -> Lease.claim(id) end,
            fn id -> Lease.release(id, 1) end,
            fn id -> Lease.cas_update(id, 1, %{status: "ready"}) end
          ] do
        assert call.(id) == {:error, {:invalid, :sandbox_id}}
      end

      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "a transition reason is free text, not a 255-byte column", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      reason = String.duplicate("why this machine went away, at length. ", 40)

      assert {:ok, written} =
               Lease.cas_update(ctx.sandbox.id, epoch, %{
                 transition: "destroying",
                 transition_reason: reason
               })

      assert written.transition_reason == reason
    end

    test "cas_update refuses a value or a key the owner may not write", ctx do
      assert {:ok, epoch} = Lease.claim(ctx.sandbox.id)
      before = Repo.get!(Sandbox, ctx.sandbox.id)

      refusals = [
        {%{status: "exploded"}, {:invalid, :status}},
        {%{status: nil}, {:invalid, :status}},
        {%{transition: "melting"}, {:invalid, :transition}},
        {%{transition_reason: 17}, {:invalid, :transition_reason}},
        {%{terminated_at: "whenever"}, {:invalid, :terminated_at}},
        # Not the owner's to write, however plausible the column.
        {%{mode: "persistent"}, {:invalid, :mode}},
        {%{lease_epoch: 99}, {:invalid, :lease_epoch}},
        {%{user_id: Ecto.UUID.generate()}, {:invalid, :user_id}},
        # An owner's write is built in code, never forwarded from a caller's map.
        {%{"status" => "ready"}, {:invalid, "status"}},
        {%{}, {:invalid, :attrs}}
      ]

      for {attrs, reason} <- refusals do
        assert Lease.cas_update(ctx.sandbox.id, epoch, attrs) == {:error, reason}
      end

      assert Repo.get!(Sandbox, ctx.sandbox.id) == before
    end

    test "an enclosing transaction is refused by every function", ctx do
      assert {:ok, :unchanged} =
               Repo.transaction(fn ->
                 assert {:error, :transaction_open} =
                          Lease.claim(ctx.sandbox.id)

                 assert {:error, :transaction_open} = Lease.release(ctx.sandbox.id, 0)

                 assert {:error, :transaction_open} =
                          Lease.cas_update(ctx.sandbox.id, 0, %{status: "ready"})

                 :unchanged
               end)

      assert Repo.get!(Sandbox, ctx.sandbox.id).lease_epoch == 0
    end

    test "an enclosing transaction is permitted where a caller opts in", ctx do
      # The one exception, and it has one caller: `Machines.Resume`'s admission
      # runs this inside `Quotas.with_sandbox_reservation/2`'s transaction so the
      # `resuming` stamp and the quota count that authorised it commit together.
      # `cas_update/4` takes no advisory lock, so the moduledoc's reason for the
      # guard does not reach it; what nesting *does* do — a rollback undoing the
      # write — is what a reservation wants.
      {:ok, epoch} = Lease.claim(ctx.sandbox.id)

      assert {:ok, :rolled_back} =
               Repo.transaction(fn ->
                 assert {:ok, %Sandbox{transition: "resuming"}} =
                          Lease.cas_update(ctx.sandbox.id, epoch, [transition: "resuming"],
                            nest: true
                          )

                 :rolled_back
               end)

      # Committed, because the transaction above committed. The refusal half is
      # in `resume_test.exs`, where a quota that says no rolls the stamp back
      # with it.
      assert Repo.get!(Sandbox, ctx.sandbox.id).transition == "resuming"
    end

    test "opting in does not extend to the functions that take the lock", ctx do
      # `nest:` is `cas_update/4`'s alone. `claim/2` and its siblings hold
      # `pg_advisory_xact_lock(4316, …)`, and nesting one would hold that lock
      # until the *outer* commit — the thing the guard exists for.
      assert {:ok, :unchanged} =
               Repo.transaction(fn ->
                 assert {:error, :transaction_open} =
                          Lease.claim(ctx.sandbox.id)

                 :unchanged
               end)
    end
  end

  describe "the callers that may nest" do
    test "cas_update/4's nest: option has exactly the call sites it is argued for" do
      # 5c's precedent for its own opt-outs: an option that relaxes a guard is
      # only as safe as the list of callers that pass it, and the list is
      # otherwise nowhere. Each one is argued in `cas_update/4`'s docstring.
      #
      #   `Machines.Resume`      the admission (7a): the `resuming` stamp and the
      #                          quota count that authorised it commit together,
      #                          so a refused quota leaves no stamp.
      #   `Machines.Provision`   `fail/2`'s `:before_write` (7b): the hook writes
      #                          the *conversation* and the compare-and-set writes
      #                          the machine, and `Launch.fail_initial_start/2`
      #                          needs both or neither — `main` held them in one
      #                          transaction under the sandbox lock.
      #
      # Neither takes an advisory lock, which is what makes nesting them safe;
      # the moduledoc's reason for the guard is about holding
      # `pg_advisory_xact_lock(4316, …)` open until an outer commit.
      root = Path.expand("../../../../..", __DIR__)

      files =
        ([Path.join(root, "apps/fountain/lib")] ++
           Path.wildcard(Path.join(root, "apps/fountain_*/lib")))
        |> Enum.filter(&File.dir?/1)
        |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
        |> Enum.reject(&String.ends_with?(&1, "machines/lease.ex"))

      assert length(files) > 100, "the scan is broken; it proves nothing"

      callers =
        for file <- files,
            File.read!(file) =~ ~r/nest:\s*true/,
            do: Path.relative_to(file, root)

      assert callers == [
               "apps/fountain/lib/fountain/machines/provision.ex",
               "apps/fountain/lib/fountain/machines/resume.ex"
             ],
             "`nest: true` lets a caller write the machine's row inside its own transaction, " <>
               "which every other function here refuses. Adding one is a decision about " <>
               "transaction boundaries, not a call-site choice: #{inspect(callers)}"
    end
  end

  describe "across connections" do
    test "two claimants contend and exactly one takes the epoch" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()

        try do
          owner = self()

          claimants =
            for _ <- 1..2 do
              independent(fn ->
                receive do
                  :go -> :ok
                after
                  10_000 -> raise "claim barrier timed out"
                end

                # Held by the test process, which outlives both claimants.
                Lease.claim(tenant.sandbox.id, holder: owner)
              end)
            end

          try do
            # Both connections are open before either claims, so the winner is
            # decided by the lock rather than by task startup.
            for claimant <- claimants do
              assert_receive {:backend, pid, _backend}, 5_000
              assert pid in Enum.map(claimants, & &1.pid)
              _ = claimant
            end

            for claimant <- claimants, do: send(claimant.pid, :go)
            results = Enum.map(claimants, &Task.await(&1, 15_000))

            assert Enum.count(results, &match?({:ok, 1}, &1)) == 1
            assert Enum.count(results, &match?({:error, {:held, _}}, &1)) == 1

            # Advanced by exactly one: the loser saw the winner's row, not the
            # row as it was before the winner ran.
            assert Repo.get!(Sandbox, tenant.sandbox.id).lease_epoch == 1
          after
            for claimant <- claimants, do: Task.shutdown(claimant, :brutal_kill)
          end
        after
          discard(tenant)
        end
      end)
    end

    test "a claim waits on the per-sandbox advisory lock" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                @sandbox_lock_namespace,
                Fountain.Conversations.sandbox_lock_key(tenant.sandbox.id)
              ])

              send(owner, :locked)

              receive do
                :commit -> :ok
              after
                10_000 -> raise "advisory lock release timed out"
              end
            end)
          end)

        try do
          assert_receive {:backend, blocker_pid, _}, 5_000
          assert blocker_pid == blocker.pid
          assert_receive :locked, 5_000

          waiting =
            independent(fn -> Lease.claim(tenant.sandbox.id) end)

          try do
            assert_receive {:backend, waiting_pid, waiting_backend}, 5_000
            assert waiting_pid == waiting.pid

            # Proof it serialized rather than merely finished second: PostgreSQL
            # reports the claim's backend waiting on another one.
            await_blocked(waiting_backend, System.monotonic_time(:millisecond) + 5_000)
            assert Task.yield(waiting, 0) == nil

            send(blocker.pid, :commit)
            assert {:ok, :ok} = Task.await(blocker, 15_000)
            assert {:ok, 1} = Task.await(waiting, 15_000)
          after
            Task.shutdown(waiting, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end

    test "a database fault answers, and leaves no write and no lock behind" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()

        try do
          fault_on(tenant.sandbox.id)
          before = Repo.get!(Sandbox, tenant.sandbox.id)

          # A cancelled statement is an answer, not an exception the owner has
          # to rescue at every call site (the #2309 shape).
          assert {:error, {:database, code}} =
                   Lease.claim(tenant.sandbox.id)

          assert code == :query_canceled

          # Worth little on its own — the trigger is BEFORE UPDATE, so the row
          # could not have changed either way. Kept because it would catch a
          # later rewrite that moves the fault after a first write.
          assert Repo.get!(Sandbox, tenant.sandbox.id) == before

          drop_fault()

          # This is the load-bearing assertion. The advisory lock went back with
          # the rollback; on another connection this blocks forever if it did
          # not, and `Task.await` fails rather than hanging the suite.
          second =
            independent(fn -> Lease.claim(tenant.sandbox.id) end)

          try do
            assert_receive {:backend, _, _}, 5_000
            assert {:ok, 1} = Task.await(second, 15_000)
          after
            Task.shutdown(second, :brutal_kill)
          end
        after
          drop_fault()
          discard(tenant)
        end
      end)
    end
  end

  # ── unboxed helpers ───────────────────────────────────────────────────────

  # A committed user and sandbox, kept as small as the foreign keys allow so
  # `discard/1` can take them all back out again.
  defp committed_tenant do
    user =
      Repo.insert!(%User{
        email: "machine-lease-#{Ecto.UUID.generate()}@example.test"
      })

    {:ok, workspace} =
      Fountain.Workspaces.insert_implicit(%{user_id: user.id, provider: "sprites"})

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "lease-#{Ecto.UUID.generate()}",
        status: "pending",
        user_id: user.id,
        workspace_id: workspace.id
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

  # Scoped to the one row: a trigger that raised for every sandbox would fail
  # whatever else the suite is doing to the table.
  defp fault_on(sandbox_id) do
    Repo.query!("""
    CREATE OR REPLACE FUNCTION fountain_lease_fault() RETURNS trigger AS $fn$
    BEGIN
      IF NEW.id = '#{sandbox_id}'::uuid THEN
        RAISE EXCEPTION 'canceling statement due to statement timeout'
          USING ERRCODE = '57014';
      END IF;
      RETURN NEW;
    END;
    $fn$ LANGUAGE plpgsql
    """)

    Repo.query!("""
    CREATE TRIGGER fountain_lease_fault BEFORE UPDATE ON sandboxes
    FOR EACH ROW EXECUTE FUNCTION fountain_lease_fault()
    """)
  end

  defp drop_fault do
    Repo.query!("DROP TRIGGER IF EXISTS fountain_lease_fault ON sandboxes")
    Repo.query!("DROP FUNCTION IF EXISTS fountain_lease_fault()")
  end
end
