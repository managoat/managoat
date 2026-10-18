defmodule Fountain.Accounts.DeletionTest do
  @moduledoc """
  Closing an account.

  Two things have to hold at once and they pull against each other: everything
  belonging to the person has to go, and nothing may be destroyed while they are
  still being charged for it. Most of these tests are about the ordering that
  keeps both true.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Accounts.{Deletion, User}
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo

  setup :set_mimic_global

  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    stub(Fountain.Conversations.ConversationServer, :whereis, fn _ -> nil end)
    :ok
  end

  describe "deletion confirmation email (#450)" do
    test "a verified account's deletion enqueues the confirmation, carrying the address" do
      user = insert_verified_user()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert_enqueued(
        worker: Fountain.Workers.AccountEmail,
        args: %{kind: "deleted", email: user.email}
      )
    end

    test "an unverified account gets no confirmation" do
      # An address that never proved it was theirs gets no mail from us,
      # whoever triggered the deletion.
      user = insert_user()

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute_enqueued(worker: Fountain.Workers.AccountEmail)
    end
  end

  describe "what is removed" do
    test "the user and everything cascading from them" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      env = insert_env(user_id: user.id)
      vault = insert_vault(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent)
      {_key, _raw} = insert_api_key(user)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.get(User, user.id)
      refute Repo.get(Fountain.Agents.Agent, agent.id)
      refute Repo.get(Fountain.Environments.Environment, env.id)
      refute Repo.get(Fountain.Vaults.Vault, vault.id)
      refute Repo.get(Fountain.Conversations.Conversation, conv.id)
      assert Repo.all(from k in Fountain.Accounts.ApiKey, where: k.user_id == ^user.id) == []
    end

    test "the account's workspaces, leaving their sandboxes as history (ADR 0097)" do
      user = insert_verified_user()
      ws = insert_workspace(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, workspace_id: ws.id, status: "terminated")

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.get(Fountain.Workspaces.Workspace, ws.id)
      assert %Sandbox{user_id: nil, workspace_id: nil} = Repo.get!(Sandbox, sandbox.id)
    end

    test "the tenant's data encryption key" do
      # The crypto-shred. Every environment and vault secret is encrypted with
      # this key, so destroying it makes any ciphertext that outlives the
      # cascade — a row missed by a future schema change, a stray copy —
      # undecryptable rather than merely unreferenced.
      user = insert_verified_user()
      {:ok, _dek} = Fountain.Crypto.load_tenant_key(user.id)

      assert Repo.exists?(
               from k in "user_data_keys", where: k.user_id == type(^user.id, :binary_id)
             )

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.exists?(
               from k in "user_data_keys", where: k.user_id == type(^user.id, :binary_id)
             )
    end
  end

  describe "sprites" do
    test "live sandboxes are destroyed" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      test = self()

      stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test, {:destroyed, handle.name}) && :ok
      end)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(user) end)

      assert_received {:destroyed, name}
      assert name == sandbox.machine_name
    end

    test "suspended sandboxes are destroyed too" do
      # Suspended is excluded from the quota but its sprite is alive at
      # sprites.dev — and deletion nilifies user_id, so a sprite missed here
      # is unfindable afterward, a permanent leak.
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "suspended")

      test = self()

      stub(Managoat.Sandbox.Sprites, :destroy, fn handle ->
        send(test, {:destroyed, handle.name}) && :ok
      end)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 1}} = Deletion.delete_user(user) end)

      assert_received {:destroyed, name}
      assert name == sandbox.machine_name
    end

    test "already-terminal sandboxes are not touched again" do
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "terminated")
      reject(&Managoat.Sandbox.Sprites.destroy/1)

      capture_log(fn -> assert {:ok, %{sprites_destroyed: 0}} = Deletion.delete_user(user) end)
    end

    test "a destroy failure does not abort the deletion" do
      # The reaper reconciles a leftover sprite on its next run. Refusing to
      # delete the account because sprites.dev was briefly unreachable would
      # leave the person unable to leave.
      user = insert_verified_user()
      insert_sandbox(user_id: user.id, status: "ready")
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :boom} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      refute Repo.get(User, user.id)
    end

    test "the sandbox row is marked terminated so the reaper can finish the job" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")
      stub(Managoat.Sandbox.Sprites, :destroy, fn _ -> {:error, :boom} end)

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user) end)

      assert Repo.get(Sandbox, sandbox.id).status == "terminated"
    end
  end

  describe "the audit trail" do
    test "records who was deleted, in a form that survives the delete" do
      # audit_events.user_id is SET NULL on delete, so an event relying on the
      # column alone would survive as an anonymous row saying an account was
      # deleted without saying which one.
      user = insert_verified_user()
      email = user.email

      capture_log(fn -> assert {:ok, _} = Deletion.delete_user(user, actor: "admin:123") end)

      event =
        Repo.one!(
          from e in Fountain.Audit.Event,
            where: e.action == "account.deleted" and e.resource_id == ^user.id
        )

      assert event.user_id == nil
      assert event.actor == "admin:123"
      assert event.metadata["email"] == email
      assert event.metadata["user_id"] == user.id
    end
  end
end
