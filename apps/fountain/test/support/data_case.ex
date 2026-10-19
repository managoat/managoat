defmodule Fountain.DataCase do
  @moduledoc """
  This module defines the setup for tests requiring
  access to the application's data layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use Fountain.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Fountain.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      use Oban.Testing, repo: Fountain.Repo

      import Fountain.DataCase
      import Fountain.Factory
      import Fountain.ServerStart
    end
  end

  setup tags do
    Fountain.DataCase.setup_sandbox(tags)
    :ok
  end

  # Long enough that a `last_used_at` stamp or a test-adapter email always
  # lands, short enough that a task which is genuinely stuck cannot stall the
  # suite. Never reached in practice — both sites are a single round trip, and
  # this returns as soon as the task is down — but the ceiling is generous on
  # purpose: the drain exists to keep loaded runs from churning connections, so
  # it must not be the thing that gives up first when a run is loaded.
  @drain_timeout_ms 2_000

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    test_pid = self()
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Fountain.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)
    # `on_exit` callbacks run last-registered-first, so this drains before the
    # owner above is stopped.
    on_exit(fn -> drain_best_effort_tasks(test_pid) end)
  end

  @doc """
  Configure the Sprites provider for one test, as `setup
  {Fountain.DataCase, :configure_sprites}`. The test configuration carries no
  Sprites token, so `Fountain.SandboxProviders.enabled?(:sprites)` is false;
  a path that checks the provider is enabled, such as a workspace rebuild,
  needs one. Only for `async: false` modules: it writes application env.
  """
  def configure_sprites(_context) do
    previous = Application.get_env(:fountain, Managoat.Sandbox.Sprites, [])

    Application.put_env(
      :fountain,
      Managoat.Sandbox.Sprites,
      Keyword.put(previous, :token, "test-token")
    )

    on_exit(fn -> Application.put_env(:fountain, Managoat.Sandbox.Sprites, previous) end)
  end

  @doc """
  Wait for the fire-and-forget tasks this test started to finish.

  Best-effort work off a request — the `last_used_at` stamp, the password-reset
  email — runs in an *unlinked* task under `Fountain.TaskSupervisor` (#1040), so
  unlike the linked `Task.async` it replaced it is not killed when the test
  process finishes. Left alone it would still be holding a sandbox connection
  when the owner is stopped, which drops that connection and logs a disconnect:
  churn in the pool the flake in #1040 was blamed on to begin with.

  Only tasks started by `test_pid` are waited on — `Task.Supervisor` propagates
  `$callers`, which is also how the task reaches this test's connection at all,
  so it identifies the ones that matter without an async test waiting on
  another's work.
  """
  def drain_best_effort_tasks(test_pid) do
    Fountain.TaskSupervisor
    |> Task.Supervisor.children()
    |> Enum.filter(&started_by?(&1, test_pid))
    |> Enum.each(&await_down/1)
  end

  defp started_by?(pid, test_pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} -> test_pid in Keyword.get(dictionary, :"$callers", [])
      nil -> false
    end
  end

  defp await_down(pid) do
    ref = Process.monitor(pid)

    receive do
      {:DOWN, ^ref, :process, ^pid, _reason} -> :ok
    after
      @drain_timeout_ms -> Process.demonitor(ref, [:flush])
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
