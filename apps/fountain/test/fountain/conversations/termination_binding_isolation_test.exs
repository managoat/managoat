defmodule Fountain.Conversations.TerminationBindingIsolationTest do
  use Fountain.DataCase, async: false

  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Termination

  test "a termination write waiting on reassignment rechecks the committed binding" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      old = insert_sandbox(user_id: user.id, status: "ready")
      replacement = insert_sandbox(user_id: user.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: old, status: "running")
      owner = self()

      reassign =
        independent(fn ->
          Repo.transaction(fn ->
            from(c in Conversation, where: c.id == ^conv.id)
            |> Repo.update_all(set: [sandbox_id: replacement.id])

            send(owner, :binding_written)

            receive do
              :commit -> :ok
            after
              10_000 -> raise "reassignment release timed out"
            end
          end)
        end)

      try do
        assert_receive :binding_written, 5_000

        terminate =
          independent(fn ->
            # Ownership: this test created the actor's conversation and sandbox.
            Termination._unsafe_finish_conversation_termination(conv.id, old.id)
          end)

        try do
          terminating_pid = terminate.pid
          assert_receive {:backend, ^terminating_pid, backend}, 5_000
          await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          send(reassign.pid, :commit)
          assert {:ok, :ok} = Task.await(reassign)
          assert {:error, :sandbox_unavailable} = Task.await(terminate)
          assert Repo.reload!(conv).sandbox_id == replacement.id
          assert Repo.reload!(conv).status == "running"
        after
          Task.shutdown(terminate, :brutal_kill)
        end
      after
        Task.shutdown(reassign, :brutal_kill)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
        Repo.delete!(user)
        Repo.delete!(old)
        Repo.delete!(replacement)
      end
    end)
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
