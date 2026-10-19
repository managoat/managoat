defmodule Fountain.DropSandboxesAppliedSkillsMigrationTest do
  @moduledoc """
  `20261019150000_drop_sandboxes_applied_skills` (#3000): `down/0` restores
  the column from each sandbox's newest conversation's record, and `up/0`
  drops it again.
  """

  # Runs the migration down and up inside its own SQL sandbox transaction,
  # which takes `ACCESS EXCLUSIVE` on `sandboxes` until it rolls back.
  use Fountain.DataCase, async: false

  import ExUnit.CaptureLog

  alias Fountain.Repo.Migrations.DropSandboxesAppliedSkills, as: Migration

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261019150000_drop_sandboxes_applied_skills.exs",
      __DIR__
    )
  end

  defp run(direction) do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_019_150_000,
        Migration,
        :forward,
        direction,
        direction,
        log: false
      )
    end)
  end

  defp applied_skills(sandbox_id) do
    %{rows: [[skills]]} =
      Repo.query!("SELECT applied_skills FROM sandboxes WHERE id = $1", [
        Ecto.UUID.dump!(sandbox_id)
      ])

    skills
  end

  defp record(conv, skills, at) do
    Repo.update_all(
      from(c in Fountain.Conversations.Conversation, where: c.id == ^conv.id),
      set: [applied_skills: skills, inserted_at: at]
    )
  end

  test "down restores the newest conversation's record, and up drops the column" do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    older = insert_conversation(user_id: user.id, sandbox: sandbox)
    newer = insert_conversation(user_id: user.id, sandbox: sandbox)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    record(older, [%{"name" => "old"}], DateTime.add(now, -60, :second))
    record(newer, [%{"name" => "new"}], now)

    untouched = insert_sandbox(user_id: user.id, status: "ready")

    run(:down)

    assert applied_skills(sandbox.id) == [%{"name" => "new"}]
    assert applied_skills(untouched.id) == nil

    run(:up)

    %{rows: rows} =
      Repo.query!("""
      SELECT 1 FROM information_schema.columns
       WHERE table_name = 'sandboxes' AND column_name = 'applied_skills'
      """)

    assert rows == []
  end
end
