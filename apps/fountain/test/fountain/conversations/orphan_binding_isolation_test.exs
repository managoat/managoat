defmodule Fountain.Conversations.OrphanBindingIsolationTest do
  use Fountain.DataCase, async: false

  alias Fountain.Conversations
  alias Fountain.Conversations.Conversation

  @moduledoc """
  The actor's binding check and the reassignment that invalidates it serialize.

  `TurnLocks._unsafe_recover_turn/3` takes `FOR UPDATE` on the parent
  before it compares the actor's `:sandbox_id` binding
  (`Fountain.Machines.Admission.bound?/2`), so the comparison and every write
  that follows it happen under one lock. These two tests run the pair in both
  orders against a real PostgreSQL backend and assert the lock wait is real,
  which a same-connection sandbox test cannot show.
  """

  for first <- [:reassignment, :orphan] do
    @tag first: first
    test "#{first} serializes orphan bookkeeping with reassignment", %{first: first} do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        old = insert_sandbox(user_id: user.id, status: "ready")
        replacement = insert_sandbox(user_id: user.id, status: "ready")
        conv = insert_conversation(user_id: user.id, sandbox: old, status: "running")
        turn = insert_turn(conv, status: "running")
        owner = self()
        handler = {__MODULE__, make_ref()}

        # Pause inside the real recovery transaction after its turn update. This
        # proves the parent lock remains held through the write, without wrapping
        # the public function (and its audit) in an artificial outer transaction.
        :telemetry.attach(handler, [:fountain, :repo, :query], &__MODULE__.pause_orphan/4, owner)

        orphan = fn ->
          # Internal actor reconciliation; the fixture belongs to this test's tenant.
          Conversations._unsafe_orphan_turn(turn, "binding_race", sandbox_id: old.id)
        end

        reassign = fn ->
          Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
        end

        leading =
          independent(fn ->
            if first == :orphan do
              Process.put(:pause_orphan_binding_test, true)
              orphan.()
            else
              Repo.transaction(fn ->
                from(c in Conversation, where: c.id == ^conv.id)
                |> Repo.update_all(set: [sandbox_id: replacement.id])

                hold(owner)
              end)
            end
          end)

        try do
          assert_receive :write_held, 5_000
          trailing = independent(if first == :orphan, do: reassign, else: orphan)

          try do
            trailing_pid = trailing.pid
            assert_receive {:backend, ^trailing_pid, backend}, 5_000
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(leading.pid, :commit)
            leading_result = Task.await(leading)
            trailing_result = Task.await(trailing)

            if first == :orphan do
              assert {:ok, _, _} = leading_result
              assert {:ok, _} = trailing_result
              assert Repo.reload(turn).status == "interrupted"
              assert Repo.reload(turn).orphaned_at
            else
              assert {:ok, :ok} = leading_result
              # The stale actor loses the same way #1751's journal mismatch
              # loses, and for the same reason: it no longer owns the parent.
              assert {:error, :ownership_changed} = trailing_result
              assert Repo.reload(turn).status == "running"
              assert Repo.reload(turn).orphaned_at == nil
            end

            assert Repo.reload(conv).sandbox_id == replacement.id
            assert Repo.reload(conv).status == if(first == :orphan, do: "idle", else: "running")
          after
            Task.shutdown(trailing, :brutal_kill)
          end
        after
          Task.shutdown(leading, :brutal_kill)
          :telemetry.detach(handler)
          Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
          Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
          Repo.delete!(user)
          Repo.delete!(old)
          Repo.delete!(replacement)
        end
      end)
    end
  end

  def pause_orphan(_event, _measurements, metadata, owner) do
    if Process.get(:pause_orphan_binding_test) &&
         String.starts_with?(metadata.query, ~s(UPDATE "turns")) do
      Process.delete(:pause_orphan_binding_test)
      hold(owner)
    end
  end

  defp hold(owner) do
    send(owner, :write_held)

    receive do
      :commit -> :ok
    after
      10_000 -> raise "binding write release timed out"
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
             "no PostgreSQL row-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
