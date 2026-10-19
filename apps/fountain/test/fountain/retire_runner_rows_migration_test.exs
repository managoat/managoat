defmodule Fountain.RetireRunnerRowsMigrationTest do
  @moduledoc """
  What `20261014153100_retire_runner_rows` does to the rows it touches
  (#2676). It clears the sandbox's own `transition` columns, which
  `20261019150100_drop_sandbox_lease_columns` dropped later (#3000), so the
  test stands the schema where that migration found it, with the drop's
  `down/0`, and reads the sandbox's columns directly.
  """

  # Runs migrations inside its own SQL sandbox transaction, which takes
  # `ACCESS EXCLUSIVE` on `sandboxes` until it rolls back, so it runs alone.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo.Migrations.DropSandboxLeaseColumns, as: Drop
  alias Fountain.Repo.Migrations.RetireRunnerRows, as: Migration

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261014153100_retire_runner_rows.exs",
      __DIR__
    )
  end

  unless Code.ensure_loaded?(Drop) do
    Code.require_file(
      "../../priv/repo/migrations/20261019150100_drop_sandbox_lease_columns.exs",
      __DIR__
    )
  end

  defp run(version, module, direction) do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        version,
        module,
        :forward,
        direction,
        direction,
        log: false
      )
    end)
  end

  # Writes a value the changesets no longer accept, the way the previous
  # release left it in the table.
  defp force(schema, id, sets) do
    {1, _} = Repo.update_all(from(r in schema, where: r.id == ^id), set: sets)
    Repo.get!(schema, id)
  end

  defp transition_of(sandbox_id) do
    %{rows: [row]} =
      Repo.query!("SELECT transition, transition_reason FROM sandboxes WHERE id = $1", [
        Ecto.UUID.dump!(sandbox_id)
      ])

    row
  end

  test "unpins agents, terminates live runner sandboxes and leaves the rest" do
    run(20_261_019_150_100, Drop, :down)

    user = insert_verified_user()
    pinned = insert_agent(user_id: user.id)
    pinned = force(Agent, pinned.id, sandbox_provider: "runner")
    e2b = insert_agent(user_id: user.id)
    e2b = force(Agent, e2b.id, sandbox_provider: "e2b")

    live = insert_sandbox(user_id: user.id, status: "ready")
    live = force(Sandbox, live.id, provider: "runner", updated_at: ~U[2026-08-01 00:00:00Z])

    Repo.query!(
      "UPDATE sandboxes SET transition = 'suspending', transition_reason = 'idle' WHERE id = $1",
      [Ecto.UUID.dump!(live.id)]
    )

    parked = insert_sandbox(user_id: user.id, status: "suspended")
    parked = force(Sandbox, parked.id, provider: "runner")

    ended = insert_sandbox(user_id: user.id, status: "ready")

    ended =
      force(Sandbox, ended.id,
        provider: "runner",
        status: "failed",
        terminated_at: ~U[2026-07-01 00:00:00Z]
      )

    sprite = insert_sandbox(user_id: user.id, status: "ready")

    run(20_261_014_153_100, Migration, :up)

    assert Repo.reload!(pinned).sandbox_provider == nil
    assert Repo.reload!(e2b).sandbox_provider == "e2b"

    live = Repo.reload!(live)
    assert live.provider == "runner"
    assert live.status == "terminated"
    assert live.terminated_at == ~U[2026-08-01 00:00:00Z]
    assert transition_of(live.id) == [nil, nil]

    assert %Sandbox{status: "terminated"} = Repo.reload!(parked)

    assert %Sandbox{status: "failed", terminated_at: ~U[2026-07-01 00:00:00Z]} =
             Repo.reload!(ended)

    assert %Sandbox{provider: "sprites", status: "ready"} = Repo.reload!(sprite)

    run(20_261_019_150_100, Drop, :up)
  end
end
