defmodule Fountain.Conversations.InferenceAdmissionIsolationTest do
  use Fountain.DataCase, async: false
  alias Fountain.{Crypto, InferenceCredentials}

  test "credential replacement waits for an admitted binding and reaches its next use" do
    Ecto.Adapters.SQL.Sandbox.unboxed_run(Repo, fn ->
      user = insert_user()
      {:ok, dek} = Crypto.load_tenant_key(user.id)
      {:ok, _} = InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "first")
      owner = self()

      holder =
        independent(fn ->
          InferenceCredentials.with_source_lock(user.id, fn ->
            {:ok, source, _} = InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex")
            send(owner, {:resolved, source})

            receive do
              :commit -> :ok
            after
              5_000 -> raise "source barrier timed out"
            end
          end)
        end)

      try do
        assert_receive {:resolved, source}, 5_000
        assert_receive {:backend, holder_pid, _}, 5_000
        assert holder_pid == holder.pid

        writer =
          independent(fn ->
            InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "replacement")
          end)

        try do
          assert_receive {:backend, writer_pid, backend}, 5_000
          assert writer_pid == writer.pid
          await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          send(holder.pid, :commit)
          assert :ok = Task.await(holder)
          assert {:ok, _} = Task.await(writer)

          # Committed after the binding, so it is a rotation the binding's
          # next use runs on (#2602), not a value the binding was read from.
          assert :ok = InferenceCredentials.validate_source(user.id, source)

          assert {:ok, fresh, %{openai_api_key: "replacement"}} =
                   InferenceCredentials.resolve(user.id, "openai/gpt-5", "codex",
                     expected_source: InferenceCredentials.Source.dump(source)
                   )

          assert fresh.identity == source.identity
          refute fresh.revision == source.revision
        after
          Task.shutdown(writer, :brutal_kill)
        end
      after
        Task.shutdown(holder, :brutal_kill)
        Repo.delete_all(from e in Fountain.Audit.Event, where: e.user_id == ^user.id)
        Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
        Repo.delete!(user)
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
             "no PostgreSQL source-lock wait observed"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
