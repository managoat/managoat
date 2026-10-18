defmodule Fountain.WorkspacesTest do
  @moduledoc """
  The writes ADR 0097's step 2 adds: an implicit workspace beside every new
  sandbox, its status following that sandbox's provision, and the schema's own
  rules (one live sandbox per workspace, the cascade on account deletion).
  Nothing reads a workspace yet; the launch, wake and provision suites pin
  where these writes are made.
  """

  use Fountain.DataCase, async: true

  alias Fountain.Conversations.{Conversation, Sandbox}
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Workspace

  describe "insert_implicit/1" do
    test "makes an implicit, provisioning workspace from the launch's resolved pair" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)

      assert {:ok, %Workspace{} = ws} =
               Workspaces.insert_implicit(%{
                 user_id: user.id,
                 environment_id: env.id,
                 vault_id: vault.id,
                 provider: "sprites",
                 # Sandbox attrs ride along at the launch; they are not the
                 # workspace's.
                 machine_name: "ignored",
                 status: "ready"
               })

      assert ws.implicit
      assert ws.status == "provisioning"
      assert ws.name == nil

      assert {ws.user_id, ws.environment_id, ws.vault_id, ws.provider} ==
               {user.id, env.id, vault.id, "sprites"}
    end

    test "refuses a missing owner or an unknown provider" do
      assert {:error, %Ecto.Changeset{}} = Workspaces.insert_implicit(%{provider: "sprites"})

      user = insert_verified_user()

      assert {:error, %Ecto.Changeset{}} =
               Workspaces.insert_implicit(%{user_id: user.id, provider: "runner"})
    end

    test "an explicit workspace without a name is refused by the database" do
      ws = insert_workspace()

      assert_raise Ecto.ConstraintError, ~r/workspaces_explicit_named_check/, fn ->
        ws |> Ecto.Changeset.change(implicit: false) |> Repo.update!()
      end
    end
  end

  describe "settle_provision/1" do
    setup do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "pending")
      {:ok, user: user, ws: ws, sandbox: sandbox}
    end

    for status <- ["ready", "failed"] do
      test "a #{status} sandbox settles its workspace #{status}", ctx do
        assert :ok = Workspaces.settle_provision(%{ctx.sandbox | status: unquote(status)})
        assert Repo.reload!(ctx.ws).status == unquote(status)
      end
    end

    for status <- ["pending", "starting", "suspended", "terminated"] do
      test "a #{status} sandbox leaves it alone", ctx do
        assert :ok = Workspaces.settle_provision(%{ctx.sandbox | status: unquote(status)})
        assert Repo.reload!(ctx.ws).status == "provisioning"
      end
    end

    test "a settled workspace is not moved again", ctx do
      assert :ok = Workspaces.settle_provision(%{ctx.sandbox | status: "ready"})
      assert :ok = Workspaces.settle_provision(%{ctx.sandbox | status: "failed"})
      assert Repo.reload!(ctx.ws).status == "ready"
    end

    test "is scoped by the sandbox's owner", ctx do
      other = insert_verified_user()

      assert :ok =
               Workspaces.settle_provision(%{ctx.sandbox | status: "ready", user_id: other.id})

      assert Repo.reload!(ctx.ws).status == "provisioning"
    end

    test "a sandbox with no workspace or no owner is a no-op", ctx do
      assert :ok =
               Workspaces.settle_provision(%{ctx.sandbox | status: "ready", workspace_id: nil})

      assert :ok = Workspaces.settle_provision(%{ctx.sandbox | status: "ready", user_id: nil})
      assert Repo.reload!(ctx.ws).status == "provisioning"
    end
  end

  describe "the schema" do
    test "a workspace has at most one live sandbox" do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)
      insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "ready")

      assert {:error, changeset} =
               %Sandbox{}
               |> Sandbox.changeset(%{
                 machine_name: "second-#{System.unique_integer([:positive])}",
                 status: "pending",
                 provider: "sprites",
                 user_id: user.id,
                 workspace_id: ws.id
               })
               |> Repo.insert()

      assert {"already has a live sandbox", _} = changeset.errors[:workspace_id]
    end

    test "terminal sandboxes do not count against it" do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)

      for status <- ["terminated", "failed"],
          do: insert_sandbox(user_id: user.id, workspace_id: ws.id, status: status)

      assert %Sandbox{} = insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "pending")
    end

    test "deleting a workspace keeps its sandbox and conversation, unpointed" do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "terminated")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, workspace_id: ws.id)

      Repo.delete!(ws)

      assert Repo.reload!(sandbox).workspace_id == nil
      assert Repo.get!(Conversation, conv.id).workspace_id == nil
    end

    test "deleting the environment or vault nilifies the workspace's pointer" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      ws = insert_workspace(user_id: user.id, environment_id: env.id, vault_id: vault.id)

      Repo.delete!(env)
      Repo.delete!(vault)

      assert %Workspace{environment_id: nil, vault_id: nil} = Repo.reload!(ws)
    end
  end
end
