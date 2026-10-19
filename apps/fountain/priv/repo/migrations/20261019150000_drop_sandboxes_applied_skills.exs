defmodule Fountain.Repo.Migrations.DropSandboxesAppliedSkills do
  @moduledoc """
  Drops `sandboxes.applied_skills` (ADR 0097 step 1, #3000).

  `20261018200000_add_conversation_config_homes` moved the record of a
  machine's skills onto the conversation (`conversations.applied_skills`),
  and the release that shipped it (#2988, v0.37.0) stopped mapping, reading
  and writing the sandbox's column. Take this only once a release with that
  migration is rolled out: a release before it maps the column, and Ecto
  selects every mapped field.

  `down/0` restores the column from `conversations.applied_skills`, taking
  each sandbox's newest conversation, so a release before #2988 can read it.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:sandboxes) do
      remove :applied_skills
    end
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:sandboxes) do
      add :applied_skills, {:array, :map}
    end

    flush()

    execute("""
    UPDATE sandboxes AS s
    SET applied_skills = latest.applied_skills
    FROM sandboxes AS s2
    CROSS JOIN LATERAL (
      SELECT c.applied_skills
      FROM conversations AS c
      WHERE c.sandbox_id = s2.id AND c.user_id = s2.user_id
      ORDER BY c.inserted_at DESC, c.id DESC
      LIMIT 1
    ) AS latest
    WHERE s2.id = s.id AND latest.applied_skills IS NOT NULL
    """)
  end
end
