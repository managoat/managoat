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

  describe "delete_for_account/1" do
    test "deletes the workspaces with no live sandbox and keeps the one whose machine survived" do
      user = insert_verified_user()
      done = insert_workspace(user_id: user.id)
      insert_sandbox(user_id: user.id, workspace_id: done.id, status: "terminated")
      empty = insert_workspace(user_id: user.id)
      survived = insert_workspace(user_id: user.id)
      live = insert_sandbox(user_id: user.id, workspace_id: survived.id, status: "ready")
      other = insert_workspace()

      assert :ok = Workspaces.delete_for_account(user.id)

      refute Repo.get(Workspace, done.id)
      refute Repo.get(Workspace, empty.id)
      assert Repo.get(Workspace, survived.id)
      assert Repo.get(Workspace, other.id)

      # The user's own delete then leaves it ownerless, with its sandbox, as
      # `sandboxes.user_id` is (#2329): the workspace holds that machine's
      # lease and its `destroying` stamp.
      Repo.delete!(Repo.get!(Fountain.Accounts.User, user.id))

      assert %Workspace{user_id: nil} = Repo.get!(Workspace, survived.id)
      assert %Sandbox{user_id: nil, workspace_id: ws_id} = Repo.reload!(live)
      assert ws_id == survived.id
    end
  end

  describe "_unsafe_reconcile_live/0" do
    test "gives a live sandbox with none a workspace, an ownerless one included" do
      user = insert_verified_user()
      env = insert_env(user_id: user.id)

      bare =
        insert_sandbox(
          user_id: user.id,
          workspace_id: nil,
          status: "suspended",
          environment_id: env.id
        )

      conv = insert_conversation(user_id: user.id, sandbox: bare)

      orphan = insert_sandbox(user_id: user.id, workspace_id: nil, status: "pending")
      Repo.update_all(from(s in Sandbox, where: s.id == ^orphan.id), set: [user_id: nil])

      terminal = insert_sandbox(user_id: user.id, workspace_id: nil, status: "terminated")

      assert {2, 1, 0} = Workspaces._unsafe_reconcile_live()

      ws = Repo.get!(Workspace, Repo.reload!(bare).workspace_id)

      assert {ws.implicit, ws.status, ws.user_id, ws.environment_id} ==
               {true, "ready", user.id, env.id}

      assert Repo.get!(Conversation, conv.id).workspace_id == ws.id

      assert %Workspace{user_id: nil, status: "provisioning"} =
               Repo.get!(Workspace, Repo.reload!(orphan).workspace_id)

      assert Repo.reload!(terminal).workspace_id == nil

      # Idempotent: a second run writes nothing.
      assert {0, 0, 0} = Workspaces._unsafe_reconcile_live()
    end

    test "repoints a conversation an earlier release moved off its workspace" do
      user = insert_verified_user()
      old_ws = insert_workspace(user_id: user.id)
      new_ws = insert_workspace(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, workspace_id: new_ws.id, status: "ready")
      conv = insert_conversation(user_id: user.id, sandbox: sandbox, workspace_id: old_ws.id)

      gone = insert_sandbox(user_id: user.id, workspace_id: nil, status: "terminated")
      stale = insert_conversation(user_id: user.id, sandbox: gone, workspace_id: old_ws.id)

      # Only a live sandbox's conversations: a terminal one's pointer is
      # history and is left as it is.
      assert {0, 1, 0} = Workspaces._unsafe_reconcile_live()
      assert Repo.get!(Conversation, conv.id).workspace_id == new_ws.id
      assert Repo.get!(Conversation, stale.id).workspace_id == old_ws.id
    end

    test "carries a stamp written on the sandbox row only, and never lowers the epoch" do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)
      ws |> Ecto.Changeset.change(lease_epoch: 9) |> Repo.update!()

      sandbox =
        insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "ready")
        |> Ecto.Changeset.change(
          lease_epoch: 3,
          transition: "destroying",
          transition_reason: "idle"
        )
        |> Repo.update!()

      done_ws = insert_workspace(user_id: user.id)

      insert_sandbox(user_id: user.id, workspace_id: done_ws.id, status: "terminated")
      |> Ecto.Changeset.change(transition: "destroying")
      |> Repo.update!()

      assert {0, 0, 1} = Workspaces._unsafe_reconcile_live()

      assert %Workspace{lease_epoch: 9, transition: "destroying", transition_reason: "idle"} =
               Repo.reload!(ws)

      assert %Workspace{transition: nil} = Repo.reload!(done_ws)
      assert Repo.reload!(sandbox).transition == "destroying"
    end
  end
end
