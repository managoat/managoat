defmodule Fountain.Repo.Migrations.AddConversationConfigHomes do
  @moduledoc """
  ADR 0097 step 1: a conversation's working directory, its config home, and
  the record of the skills its config home carries.

  - `cwd`: the launch's working directory; nil runs the runtime's default.
  - `config_home`: the directory the runtime keeps its configuration in,
    `/home/sprite/.managoat/c/<id>`, set at launch. **Not backfilled**: a
    conversation from before this has nil, which
    `Fountain.Conversations.ConfigHome.home/1` reads as the shared directory
    its runtime used then, where its session and skills already are.
  - `applied_skills`: moved from `sandboxes.applied_skills`, since skills now
    live in a conversation's config home rather than in a machine-wide
    directory. **Backfilled** from the sandbox each conversation is bound to:
    a machine carries one conversation (ADR 0073), so that sandbox's record
    is this conversation's.

  **The old column stays for a release.** This release stops reading and
  writing `sandboxes.applied_skills`; a later migration, in a later release,
  drops it. A rollback to the previous release reads the sandbox's record as
  this migration found it, so it can at worst leave on the disk a skill this
  release installed and the agent has since dropped, the same trade
  `20261016150000_flatten_sandbox_applied_skills` made.

  **A rollback strands the sessions of conversations launched since.** The
  previous release ignores `config_home` and runs every runtime on the
  shared directories, so a conversation this release launched loses its
  runtime session, skills and instructions there (its transcript stays); its
  next turn starts a new runtime session. Conversations from before this
  release are unaffected either way.

  `down/0` drops the three columns; nothing else is changed by `up/0`.
  """
  use Ecto.Migration

  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("SET LOCAL statement_timeout = '30s'")

    alter table(:conversations) do
      add :cwd, :text
      add :config_home, :text
      add :applied_skills, {:array, :map}
    end

    flush()

    execute("""
    UPDATE conversations AS c
    SET applied_skills = s.applied_skills
    FROM sandboxes AS s
    WHERE c.sandbox_id = s.id
      AND c.user_id = s.user_id
      AND s.applied_skills IS NOT NULL
    """)
  end

  def down do
    execute("SET LOCAL lock_timeout = '5s'")

    alter table(:conversations) do
      remove :cwd
      remove :config_home
      remove :applied_skills
    end
  end
end
