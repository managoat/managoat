defmodule Fountain.Machines.RegisterServerTest do
  @moduledoc """
  The registration door (ADR 0058 stage 6a, ADR 0072).

  `Conversations.register_server/2` starts a `ConversationServer` under the
  per-sandbox advisory lock, so the server is in the local registry before the
  lock is released and a reader that takes the lock after it — a park's claim,
  the reaper's owner calls — finds it. Until ADR 0072 the registry was Horde's
  CRDT and the door wrote a `woken_at` marker instead; these replace the tests
  that pinned it.

  What these pin is the lock (a holder of the per-sandbox lock delays the
  registration, proven with PostgreSQL's own wait report rather than with
  timing, and the child is started while the door still holds it), the two refusals
  the door makes — an enclosing transaction, and a machine whose owner holds a
  live lease, the latter decided *inside* the lock so a claim landing after the
  caller's own read still wins (round 1, locks review) — that every starter
  comes through the door, and that the supervisor's answer is passed back unchanged:
  the two callers do not agree on what `{:already_started, _}` means and
  normalizing it here would break one of them (#717).

  `async: false`: the lock case runs unboxed, on real connections, because the
  SQL sandbox puts every process on one transaction and a lock taken there is
  one the test already holds.
  """
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease

  # `Fountain.Conversations`' per-sandbox advisory namespace, which
  # `with_sandbox_lock/2` and so `register_server/2` take.
  @sandbox_lock_namespace 4316

  setup do
    user = insert_verified_user()
    %{user: user, sandbox: insert_sandbox(user_id: user.id, status: "ready")}
  end

  # A child that reports that it started, and — given `hold: true` — waits in
  # `init/1` to be told to finish, so a test can look at the database while
  # `start_child` is still running. Not a stand-in for a `ConversationServer`;
  # like one, it does no database work in `init/1`, which runs inside the
  # door's transaction.
  defmodule Probe do
    @moduledoc false
    use GenServer

    def start_link(opts) do
      case Keyword.get(opts, :name) do
        nil -> GenServer.start_link(__MODULE__, opts)
        name -> GenServer.start_link(__MODULE__, opts, name: name)
      end
    end

    @impl GenServer
    def init(opts) do
      owner = Keyword.fetch!(opts, :owner)
      send(owner, {:started, self()})

      if Keyword.get(opts, :hold, false) do
        receive do
          :finish_init -> :ok
        after
          10_000 -> raise "the probe was never told to finish"
        end
      end

      {:ok, opts}
    end
  end

  defp probe_spec(opts) do
    %{
      id: {__MODULE__, System.unique_integer()},
      start: {Probe, :start_link, [Keyword.put(opts, :owner, self())]},
      restart: :temporary
    }
  end

  defp stop(pid) do
    DynamicSupervisor.terminate_child(Fountain.ConversationSupervisor, pid)
  end

  test "boot registration cannot clear interrupted readiness", ctx do
    ctx.sandbox
    |> put_lease(
      transition: "resuming",
      lease_node: dead_lease_holder(),
      lease_epoch: 1
    )

    Lease.sweep_boot()

    assert {:error, :sandbox_unavailable} =
             Conversations.register_server(ctx.sandbox.id, probe_spec([]))

    refute_received {:started, _}
    assert Repo.reload!(ctx.sandbox).transition == "resuming"
  end

  describe "the child" do
    test "starts, and the row is not written", ctx do
      assert {:ok, pid} = Conversations.register_server(ctx.sandbox.id, probe_spec([]))
      assert_receive {:started, ^pid}, 5_000
      stop(pid)

      row = Repo.reload!(ctx.sandbox)
      assert row.status == "ready"
      assert row.lease_epoch == 0
      refute row.lease_node
      refute Lease.live?(row)
      assert row.updated_at == ctx.sandbox.updated_at
    end

    test "starts on a terminal row: the door carries no status rule", ctx do
      # The readers decide what a row means, and every one of them looks at the
      # status first. A door that refused here would be a second, silent status
      # rule.
      terminal = insert_sandbox(user_id: ctx.user.id, status: "terminated")

      assert {:ok, pid} = Conversations.register_server(terminal.id, probe_spec([]))
      assert_receive {:started, ^pid}, 5_000
      stop(pid)
    end

    test "a nil sandbox_id starts the child" do
      assert {:ok, pid} = Conversations.register_server(nil, probe_spec([]))
      assert_receive {:started, ^pid}, 5_000
      stop(pid)
    end

    test "a vanished sandbox does not stop the child starting" do
      id = Ecto.UUID.generate()

      assert {:ok, pid} = Conversations.register_server(id, probe_spec([]))
      assert_receive {:started, ^pid}, 5_000
      stop(pid)
    end

    test "the supervisor's answer comes back verbatim, including {:already_started, _}", ctx do
      # The two callers read this tuple differently: the rehydrator as success
      # (a prompt already started the server it wanted), `Wake` as a race it
      # has to compensate for (its own fresh sandbox row must be retired and
      # the prompt handed to the winner, #717/#330). The door must not choose
      # for them.
      # A named child, because that is how a real duplicate arises: a
      # `ConversationServer` registers under its conversation id, and the
      # second start of one is refused by the name, not by the supervisor.
      spec = probe_spec(name: :"probe_#{System.unique_integer([:positive])}")

      assert {:ok, pid} = Conversations.register_server(ctx.sandbox.id, spec)
      assert_receive {:started, ^pid}, 5_000

      assert {:error, {:already_started, ^pid}} =
               Conversations.register_server(ctx.sandbox.id, spec)

      stop(pid)
    end
  end

  describe "the door's refusals" do
    test "an enclosing transaction is refused before the lock is taken", ctx do
      # `with_sandbox_lock/2` is a plain `Repo.transaction`, so nested it joins
      # the caller's through a savepoint and holds the advisory lock until the
      # *outer* commit — across `start_child`, breaking both of the door's
      # promises with nothing failing (#2307 constraint 3). The same guard
      # `Machines.Destroy.run/2` carries.
      assert {:ok, {:error, :transaction_open}} =
               Repo.transaction(fn ->
                 Conversations.register_server(ctx.sandbox.id, probe_spec([]))
               end)

      refute_received {:started, _}
    end

    test "a machine whose owner holds a live lease is refused, and starts nothing", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id)

      assert {:error, :sandbox_unavailable} =
               Conversations.register_server(ctx.sandbox.id, probe_spec([]))

      refute_received {:started, _}
    end

    test "a lease whose holder has gone is not a refusal", ctx do
      {:ok, 1} = Lease.claim(ctx.sandbox.id)

      ctx.sandbox
      |> put_lease(lease_node: dead_lease_holder())

      assert {:ok, pid} = Conversations.register_server(ctx.sandbox.id, probe_spec([]))
      assert_receive {:started, ^pid}, 5_000
      stop(pid)
    end
  end

  describe "under the per-sandbox lock" do
    test "a holder of the sandbox lock delays the child" do
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

          # The probe here touches no database: this case runs unboxed, and
          # what it observes is *when* the child starts, not what it can read.
          registering =
            independent(fn ->
              Conversations.register_server(
                tenant.sandbox.id,
                %{
                  id: {__MODULE__, :locked_probe},
                  start: {Probe, :start_link, [[owner: owner]]},
                  restart: :temporary
                }
              )
            end)

          try do
            assert_receive {:backend, registering_pid, registering_backend}, 5_000
            assert registering_pid == registering.pid

            # Proof it serialized rather than merely finished second:
            # PostgreSQL reports the door's backend waiting on another one.
            await_blocked(registering_backend, System.monotonic_time(:millisecond) + 5_000)

            # And the load-bearing half: no child exists yet. If the child
            # were started outside the lock, the server would already be
            # running while another writer holds the machine.
            refute_received {:started, _}
            assert Task.yield(registering, 0) == nil

            send(blocker.pid, :commit)
            assert {:ok, :ok} = Task.await(blocker, 15_000)
            assert {:ok, pid} = Task.await(registering, 15_000)
            assert_receive {:started, ^pid}, 5_000
            stop(pid)
          after
            Task.shutdown(registering, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end

    test "the child is started while the door still holds the lock" do
      # What retired the `woken_at` marker (ADR 0072): a reader that takes the
      # lock after the door has released it finds the server registered,
      # because the start happened inside it.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()

        registering =
          independent(fn ->
            Conversations.register_server(tenant.sandbox.id, %{
              id: {__MODULE__, :held_probe},
              start: {Probe, :start_link, [[owner: owner, hold: true]]},
              restart: :temporary
            })
          end)

        try do
          assert_receive {:backend, _, registering_backend}, 5_000
          assert_receive {:started, probe}, 5_000

          %{rows: [[held]]} =
            Repo.query!(
              """
              SELECT count(*) FROM pg_locks
              WHERE locktype = 'advisory' AND granted AND pid = $1
                AND classid = $2 AND objid = $3 AND objsubid = 2
              """,
              [
                registering_backend,
                @sandbox_lock_namespace,
                Fountain.Conversations.sandbox_lock_key(tenant.sandbox.id)
              ]
            )

          assert held == 1, "the child started after the door released the sandbox lock"

          send(probe, :finish_init)
          assert {:ok, ^probe} = Task.await(registering, 15_000)
          stop(probe)
        after
          Task.shutdown(registering, :brutal_kill)
          discard(tenant)
        end
      end)
    end

    test "a lease taken while the door waits on the lock is still seen" do
      # The window the in-lock re-check closes (round 1, locks review).
      # `Wake.maybe_reuse_sandbox/1` reads the row with no lock at all, so a
      # `Lease.claim/4` landing between that read and this call would otherwise
      # get a `ConversationServer` started on a machine somebody is destroying.
      # Here the lease is taken *after* the door has already blocked on the
      # advisory lock, which is as late as a claim can possibly be: a verdict
      # made before the lock would miss it, and this one does not.
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        tenant = committed_tenant()
        owner = self()
        holder = live_lease_holder()

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
                @sandbox_lock_namespace,
                Fountain.Conversations.sandbox_lock_key(tenant.sandbox.id)
              ])

              send(owner, :locked)

              receive do
                :claim -> :ok
              after
                10_000 -> raise "claim barrier timed out"
              end

              # Straight onto the row rather than through `Lease.claim/2`,
              # which refuses to run inside this open transaction — the same
              # columns it would write, naming the test process, which outlives
              # this task, as the holder.
              put_lease(tenant.sandbox.id, lease_epoch: 1, lease_node: holder)
              {1, nil}
            end)
          end)

        try do
          assert_receive {:backend, _, _}, 5_000
          assert_receive :locked, 5_000

          registering =
            independent(fn ->
              Conversations.register_server(tenant.sandbox.id, %{
                id: {__MODULE__, :late_claim_probe},
                start: {Probe, :start_link, [[owner: owner]]},
                restart: :temporary
              })
            end)

          try do
            assert_receive {:backend, _, registering_backend}, 5_000
            await_blocked(registering_backend, System.monotonic_time(:millisecond) + 5_000)

            send(blocker.pid, :claim)
            assert {:ok, {1, nil}} = Task.await(blocker, 15_000)

            assert {:error, :sandbox_unavailable} = Task.await(registering, 15_000)
            refute_received {:started, _}
          after
            Task.shutdown(registering, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)
          discard(tenant)
        end
      end)
    end
  end

  describe "the door is the only way in" do
    # Every file that may name the supervisor at all: the one that starts it,
    # the one that terminates a child of it, and the door. `launch.ex`,
    # `wake.ex` and `rehydrator.ex` named it before stage 6a and do not now.
    @starters [
      "apps/fountain/lib/fountain/application.ex",
      "apps/fountain/lib/fountain/conversations.ex",
      "apps/fountain/lib/fountain/conversations/provision_watchdog.ex"
    ]

    test "nothing outside Conversations.register_server/2 starts a conversation server" do
      root = Path.expand("../../../../..", __DIR__)
      files = source_files(root)
      relative = MapSet.new(files, &Path.relative_to(&1, root))

      # The scan has to be shown to reach the files that legitimately name the
      # supervisor, or a broken climb would pass by finding nothing — the
      # failure mode `machine_bounds_test.exs` was written with in round 2 of
      # stage 5a.
      for expected <- @starters do
        assert expected in relative,
               "the scan missed #{expected} (#{MapSet.size(relative)} files seen); it cannot " <>
                 "pin who starts a conversation server if it does not read them"
      end

      naming =
        files
        |> Enum.filter(
          &String.contains?(strip_docs_and_comments(File.read!(&1)), "ConversationSupervisor")
        )
        |> Enum.map(&Path.relative_to(&1, root))
        |> Enum.sort()

      assert naming == Enum.sort(@starters),
             "`Fountain.ConversationSupervisor` is named outside the door by:\n  " <>
               Enum.join(naming, "\n  ") <>
               "\n\nOne door starts a conversation server (ADR 0058 stage 6a, ADR 0072), " <>
               "because it starts it under the per-sandbox lock that makes the " <>
               "registration visible to the reaper. `application.ex` starts the supervisor, " <>
               "`provision_watchdog.ex` terminates a child; a new *starter* is a decision."

      starting =
        files
        |> Enum.filter(fn file ->
          content = strip_docs_and_comments(File.read!(file))

          Regex.match?(
            ~r/DynamicSupervisor\.start_child\(\s*Fountain\.ConversationSupervisor/,
            content
          )
        end)
        |> Enum.map(&Path.relative_to(&1, root))

      assert starting == ["apps/fountain/lib/fountain/conversations.ex"]
    end

    defp source_files(root) do
      root
      |> Path.join("apps/fountain/lib")
      |> List.wrap()
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&Path.wildcard(Path.join(&1, "**/*.ex")))
      |> Enum.sort()
    end

    defp strip_docs_and_comments(content) do
      content
      |> then(&Regex.replace(~r/@(?:module)?doc\s+"""[\s\S]*?"""/, &1, ""))
      |> String.split("\n")
      |> Enum.map_join("\n", fn line ->
        if String.trim_leading(line) |> String.starts_with?("#"), do: "", else: line
      end)
    end
  end

  # ── unboxed helpers (the shape `lease_test.exs` established) ──────────────

  defp committed_tenant do
    user =
      Repo.insert!(%Fountain.Accounts.User{
        email: "register-server-#{Ecto.UUID.generate()}@example.test"
      })

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(%{
        machine_name: "register-#{Ecto.UUID.generate()}",
        status: "ready",
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

  describe "a stale operation stamp" do
    test "is cleared on the way past when no owner holds the machine", ctx do
      # ADR 0058 stage 6b, from the protocol review. Nothing else clears a
      # `transition` off a row whose lease has expired: `Machine.busy?/2`
      # ignores it by 6a's design, and the reaper's sweeps only ever look at
      # machines with no server. So an abandoned park on a machine that is then
      # woken kept its stamp for ever, and the next owner to claim that machine
      # read it as its own interrupted operation.
      put_lease(ctx.sandbox.id,
        lease_epoch: 1,
        lease_node: dead_lease_holder(),
        transition: "parking",
        transition_reason: "idle"
      )

      assert {:ok, pid} = Conversations.register_server(ctx.sandbox.id, probe_spec([]))
      on_exit(fn -> stop(pid) end)

      row = Repo.reload!(ctx.sandbox)
      assert is_nil(row.transition), "the stamp outlived the operation that wrote it"
      assert is_nil(row.transition_reason)
    end

    test "is left alone while an owner still holds the lease", ctx do
      # The other half: a live lease is an operation in flight, and this door
      # refuses rather than tidying up after it.
      put_lease(ctx.sandbox.id,
        lease_epoch: 1,
        lease_node: live_lease_holder(),
        transition: "parking",
        transition_reason: "idle"
      )

      assert {:error, :sandbox_unavailable} =
               Conversations.register_server(ctx.sandbox.id, probe_spec([]))

      assert Repo.reload!(ctx.sandbox).transition == "parking"
    end
  end
end
