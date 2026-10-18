defmodule Fountain.Conversations.AdmissionLockIsolationTest do
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.Sandbox
  alias Fountain.Conversations.Launch

  for row <- [:account, :agent] do
    test "a launch waiting on its #{row} does not hold the fleet lock" do
      Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
        first = tenant()
        second = tenant()
        owner = self()
        row = unquote(row)

        blocker =
          independent(fn ->
            Repo.transaction(fn ->
              # Any write may take this mode on users; an exclusive agent
              # write can likewise block its foreign keys.
              Repo.one!(lock(row_query(row, first), "FOR UPDATE"))
              send(owner, :row_locked)

              receive do
                :commit -> :ok
              after
                10_000 -> raise "row lock release timed out"
              end
            end)
          end)

        try do
          assert_receive :row_locked, 5_000
          waiting = launch(first)

          try do
            assert_receive {:backend, blocker_pid, blocker_backend}, 5_000
            assert blocker_pid == blocker.pid
            assert_receive {:backend, waiting_pid, waiting_backend}, 5_000
            assert waiting_pid == waiting.pid
            refute blocker_backend == waiting_backend
            await_blocked(waiting_backend, System.monotonic_time(:millisecond) + 5_000)
            other = launch(second)

            try do
              # Another real launch must commit while the first tenant remains
              # blocked. Checking lock acquisition alone would miss later waits.
              assert {:ok, {:ok, created}} = Task.yield(other, 2_000)
              assert created.user_id == second.user.id
              assert Task.yield(waiting, 0) == nil
              send(blocker.pid, :commit)
              assert {:ok, :ok} = Task.await(blocker)
              assert {:ok, created} = Task.await(waiting)
              assert created.user_id == first.user.id
            after
              Task.shutdown(other, :brutal_kill)
            end
          after
            Task.shutdown(waiting, :brutal_kill)
          end
        after
          Task.shutdown(blocker, :brutal_kill)

          for %{user: user} <- [first, second] do
            sandboxes = Repo.all(from s in Sandbox, where: s.user_id == ^user.id)
            Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
            Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
            Repo.delete!(user)
            for sandbox <- sandboxes, do: Repo.delete!(sandbox)
          end
        end
      end)
    end
  end

  defp row_query(:account, tenant),
    do: from(u in Fountain.Accounts.User, where: u.id == ^tenant.user.id)

  defp row_query(:agent, tenant),
    do: from(a in Fountain.Agents.Agent, where: a.id == ^tenant.agent.id)

  defp tenant do
    user =
      Repo.insert!(%Fountain.Accounts.User{
        email: "admission-lock-#{Ecto.UUID.generate()}@example.test"
      })

    Repo.insert!(%Fountain.Accounts.UserDataKey{
      user_id: user.id,
      wrapped_key: Fountain.Crypto.wrap_dek(Fountain.Crypto.generate_dek())
    })

    %{user: user, agent: insert_agent(user_id: user.id, runtime: "claude")}
  end

  defp launch(tenant) do
    independent(fn ->
      stub_server_start(fn _, _ -> {:ok, self()} end)

      Launch.start_conversation(%{
        "user_id" => tenant.user.id,
        "agent_id" => tenant.agent.id,
        "sandbox_mode" => "ephemeral"
      })
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
