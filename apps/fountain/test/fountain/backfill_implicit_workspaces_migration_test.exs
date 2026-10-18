defmodule Fountain.BackfillImplicitWorkspacesMigrationTest do
  @moduledoc """
  `20261018190100_backfill_implicit_workspaces` (ADR 0097, step 2): one
  implicit workspace per live sandbox, the sandbox and its conversations
  pointed at it, terminal rows left alone, and the odd shapes the migration's
  comment names.
  """

  use Fountain.DataCase, async: true

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Repo.Migrations.BackfillImplicitWorkspaces, as: Migration
  alias Fountain.Workspaces.Workspace

  unless Code.ensure_loaded?(Migration) do
    Code.require_file(
      "../../priv/repo/migrations/20261018190100_backfill_implicit_workspaces.exs",
      __DIR__
    )
  end

  defp migrate do
    capture_log(fn ->
      Ecto.Migration.Runner.run(
        Repo,
        Repo.config(),
        20_261_018_190_100,
        Migration,
        :forward,
        :up,
        :up,
        log: false
      )
    end)
  end

  defp workspace_of(%Sandbox{} = sandbox) do
    case Repo.reload!(sandbox).workspace_id do
      nil -> nil
      id -> Repo.get!(Workspace, id)
    end
  end

  defp conv_workspace_id(conv), do: Repo.get!(Conversation, conv.id).workspace_id

  defp live(user, status, extra \\ []) do
    insert_sandbox([user_id: user.id, status: status, workspace_id: nil] ++ extra)
  end

  test "a live sandbox gets an implicit workspace from its own environment and vault" do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    agent = insert_agent(user_id: user.id)
    sandbox = live(user, "suspended", environment_id: env.id, vault_id: vault.id, provider: "e2b")

    # A conversation launched on the agent's own environment records none of
    # its own; the sandbox carries the resolved one.
    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, vault_id: vault.id)

    before = Repo.get!(Conversation, conv.id).updated_at

    migrate()

    ws = workspace_of(sandbox)
    assert ws.implicit
    assert ws.name == nil
    assert ws.status == "ready"

    assert {ws.user_id, ws.environment_id, ws.vault_id, ws.provider} ==
             {user.id, env.id, vault.id, "e2b"}

    assert ws.inserted_at == Repo.reload!(sandbox).inserted_at
    assert conv_workspace_id(conv) == ws.id
    assert Repo.get!(Conversation, conv.id).updated_at == before
  end

  test "status follows the sandbox: in flight is provisioning, built is ready" do
    user = insert_verified_user()

    for {status, expected} <- [
          {"pending", "provisioning"},
          {"starting", "provisioning"},
          {"ready", "ready"},
          {"suspended", "ready"}
        ] do
      sandbox = live(user, status)
      migrate()
      assert workspace_of(sandbox).status == expected, "#{status} -> #{expected}"
    end
  end

  test "terminal sandboxes and their conversations keep a null workspace" do
    user = insert_verified_user()

    for status <- ["terminated", "failed"] do
      sandbox = live(user, status)
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "terminated")
      migrate()
      assert workspace_of(sandbox) == nil
      assert conv_workspace_id(conv) == nil
    end
  end

  test "a live sandbox with no conversation still gets one" do
    user = insert_verified_user()
    sandbox = live(user, "ready")

    migrate()

    assert %Workspace{user_id: user_id} = workspace_of(sandbox)
    assert user_id == user.id
  end

  test "several conversations on one live sandbox share its one workspace, whatever their status" do
    user = insert_verified_user()
    sandbox = live(user, "suspended")
    a = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    b = insert_conversation(user_id: user.id, sandbox: sandbox, status: "failed")

    migrate()

    ws = workspace_of(sandbox)
    assert conv_workspace_id(a) == ws.id
    assert conv_workspace_id(b) == ws.id
    assert Repo.aggregate(from(w in Workspace, where: w.user_id == ^user.id), :count) == 1
  end

  test "a live sandbox with no user is skipped and logged" do
    user = insert_verified_user()
    sandbox = live(user, "ready")
    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id), set: [user_id: nil])

    log = migrate()

    assert workspace_of(sandbox) == nil
    assert log =~ sandbox.id
  end

  test "is idempotent, and leaves a sandbox that already has a workspace alone" do
    user = insert_verified_user()
    existing = insert_workspace(user_id: user.id, status: "failed")
    owned = live(user, "ready", workspace_id: existing.id)
    conv = insert_conversation(user_id: user.id, sandbox: owned, workspace_id: existing.id)
    fresh = live(user, "ready")

    migrate()
    first = workspace_of(fresh)
    migrate()

    assert workspace_of(fresh).id == first.id
    assert workspace_of(owned).id == existing.id
    assert Repo.reload!(existing).status == "failed"
    assert conv_workspace_id(conv) == existing.id
    assert Repo.aggregate(from(w in Workspace, where: w.user_id == ^user.id), :count) == 2
  end
end
