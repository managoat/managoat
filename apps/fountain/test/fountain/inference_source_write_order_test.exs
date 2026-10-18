defmodule Fountain.InferenceSourceWriteOrderTest do
  use Fountain.DataCase, async: false

  alias Ecto.Adapters.SQL.Sandbox
  alias Fountain.{Crypto, Environments, InferenceCredentials, Vaults}

  for operation <- [
        :environment_update,
        :environment_delete,
        :environment_secret_write,
        :environment_secret_delete,
        :vault_update,
        :vault_delete,
        :vault_secret_write,
        :vault_secret_delete,
        :vault_secret_metadata
      ] do
    @tag operation: operation
    test "#{operation} waits for source admission before taking a row lock" do
      Sandbox.unboxed_run(Repo, fn ->
        user = insert_verified_user()
        {:ok, dek} = Crypto.load_tenant_key(user.id)
        env = insert_env(user_id: user.id)
        vault = insert_vault(user_id: user.id)
        attrs = %{"key" => "OPENAI_API_KEY", "value" => "old-source"}
        {:ok, env_secret} = Environments.upsert_secret(env, attrs, dek)
        {:ok, vault_secret} = Vaults.upsert_secret(vault, attrs, dek)

        fixture = %{
          env: env,
          vault: vault,
          env_secret: env_secret,
          vault_secret: vault_secret,
          dek: dek
        }

        {table, id, write} = operation(unquote(operation), fixture)
        owner = self()

        admission =
          independent(fn ->
            InferenceCredentials.with_source_lock(user.id, fn ->
              send(owner, :source_locked)

              receive do
                :probe_row ->
                  result =
                    Repo.query("SELECT id FROM #{table} WHERE id = $1 FOR UPDATE NOWAIT", [
                      Ecto.UUID.dump!(id)
                    ])

                  send(owner, {:row_lock, result})
              after
                5_000 -> raise "row probe was not requested"
              end

              receive do
                :release -> :ok
              after
                5_000 -> raise "source lock was not released"
              end
            end)
          end)

        try do
          assert_receive :source_locked, 5_000
          writer = independent(write)

          try do
            assert_receive {:backend, admission_pid, _}, 5_000
            assert admission_pid == admission.pid
            assert_receive {:backend, writer_pid, backend}, 5_000
            assert writer_pid == writer.pid
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
            send(admission.pid, :probe_row)
            # A trigger alone takes the advisory lock too late: UPDATE/DELETE
            # already holds this tuple, deadlocking admission's later FK read.
            assert_receive {:row_lock, result}, 5_000
            assert {:ok, %{num_rows: 1}} = result
            send(admission.pid, :release)
            assert :ok = Task.await(admission)
            assert {:ok, _} = Task.await(writer)
          after
            Task.shutdown(writer, :brutal_kill)
          end
        after
          Task.shutdown(admission, :brutal_kill)
          Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
          Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
          Repo.delete!(user)
        end
      end)
    end
  end

  test "concurrent first writes both succeed into exactly one record" do
    Sandbox.unboxed_run(Repo, fn ->
      user = insert_verified_user()
      {:ok, dek} = Fountain.Crypto.load_tenant_key(user.id)
      owner = self()

      blocker =
        independent(fn ->
          InferenceCredentials.with_source_lock(user.id, fn ->
            send(owner, :source_locked)

            receive do
              :release -> :ok
            after
              5_000 -> raise "source lock was not released"
            end
          end)
        end)

      try do
        assert_receive :source_locked, 5_000
        assert_receive {:backend, blocker_pid, _}, 5_000
        assert blocker_pid == blocker.pid

        first =
          independent(fn ->
            InferenceCredentials.put_credential(user.id, dek, :anthropic_api_key, "sk-a")
          end)

        second =
          independent(fn ->
            InferenceCredentials.put_credential(user.id, dek, :openai_api_key, "sk-o")
          end)

        try do
          for _ <- 1..2 do
            assert_receive {:backend, creator, backend}, 5_000
            assert creator in [first.pid, second.pid]
            await_blocked(backend, System.monotonic_time(:millisecond) + 5_000)
          end

          send(blocker.pid, :release)
          assert :ok = Task.await(blocker)
          assert {:ok, _} = Task.await(first)
          assert {:ok, _} = Task.await(second)

          assert Repo.aggregate(
                   from(c in InferenceCredentials.Credential, where: c.user_id == ^user.id),
                   :count
                 ) == 1

          assert %{anthropic_api_key: true, openai_api_key: true} =
                   InferenceCredentials.status_for_user(user.id)
        after
          Task.shutdown(first, :brutal_kill)
          Task.shutdown(second, :brutal_kill)
        end
      after
        Task.shutdown(blocker, :brutal_kill)
        Repo.delete_all(from a in Fountain.Audit.Event, where: a.user_id == ^user.id)
        Repo.delete_all(from w in Fountain.Workspaces.Workspace, where: w.user_id == ^user.id)
        Repo.delete!(user)
      end
    end)
  end

  defp operation(:environment_update, f),
    do:
      {"environments", f.env.id,
       fn -> Environments.update_environment(f.env, %{name: "Renamed"}) end}

  defp operation(:environment_delete, f),
    do: {"environments", f.env.id, fn -> Environments.delete_environment(f.env) end}

  defp operation(:environment_secret_write, f),
    do:
      {"secrets", f.env_secret.id,
       fn ->
         Environments.upsert_secret(
           f.env,
           %{"key" => "OPENAI_API_KEY", "value" => "new-source"},
           f.dek
         )
       end}

  defp operation(:environment_secret_delete, f),
    do: {"secrets", f.env_secret.id, fn -> Environments.delete_secret(f.env, f.env_secret) end}

  defp operation(:vault_update, f),
    do: {"vaults", f.vault.id, fn -> Vaults.update_vault(f.vault, %{name: "Renamed"}) end}

  defp operation(:vault_delete, f),
    do: {"vaults", f.vault.id, fn -> Vaults.delete_vault(f.vault) end}

  defp operation(:vault_secret_write, f),
    do:
      {"vault_secrets", f.vault_secret.id,
       fn ->
         Vaults.upsert_secret(
           f.vault,
           %{"key" => "OPENAI_API_KEY", "value" => "new-source"},
           f.dek
         )
       end}

  defp operation(:vault_secret_delete, f),
    do:
      {"vault_secrets", f.vault_secret.id,
       fn -> Vaults.delete_secret(f.vault, f.vault_secret) end}

  defp operation(:vault_secret_metadata, f),
    do:
      {"vault_secrets", f.vault_secret.id,
       fn ->
         Vaults.update_secret_metadata(f.vault, "OPENAI_API_KEY", %{
           "expires_at" => "2027-01-01T00:00:00Z"
         })
       end}

  defp independent(fun) do
    owner = self()

    Task.async(fn ->
      Sandbox.unboxed_run(Repo, fn ->
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
             "writer did not wait on source admission"

      Process.sleep(5)
      await_blocked(backend, deadline)
    end
  end
end
