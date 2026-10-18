defmodule Fountain.ConversationsContextTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Sandbox}

  # Sandboxes and conversations: the CRUD surface of the context.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # Ending a conversation whose server is gone now destroys its machine through
  # `Fountain.Machines.Machine` (ADR 0058 stage 5) rather than leaving the
  # sprite for the reaper, so these tests reach the provider where they did not
  # before. Nothing here is about the provider, so the adapter seam answers
  # yes and the assertions stay about the rows and the trail. Stubbed at
  # `Managoat.Sandbox.Sprites` rather than at the `Managoat.Sandbox` facade so
  # a test that drives either layer itself still overrides it.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    :ok
  end

  # Sandboxes
  # ────────────────────────────────────────────────────────────────────────────

  describe "_unsafe_get_sandbox/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations._unsafe_get_sandbox(sandbox.id)
      assert result.id == sandbox.id
      assert result.machine_name == sandbox.machine_name
    end

    test "returns nil when sandbox does not exist" do
      assert Conversations._unsafe_get_sandbox(Ecto.UUID.generate()) == nil
    end
  end

  describe "_unsafe_get_sandbox!/1" do
    test "returns the sandbox when it exists" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      result = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert result.id == sandbox.id
    end

    test "raises Ecto.NoResultsError when sandbox does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations._unsafe_get_sandbox!(Ecto.UUID.generate())
      end
    end
  end

  describe "create_sandbox/1" do
    test "creates a sandbox with valid attrs" do
      user = insert_verified_user()

      attrs = %{
        machine_name: "test-sprite-create",
        status: "pending",
        user_id: user.id,
        workspace_id: insert_workspace(user_id: user.id).id
      }

      assert {:ok, sandbox} = Fountain.Machines.Provision.reserve(attrs)
      assert sandbox.machine_name == "test-sprite-create"
      assert sandbox.status == "pending"
      assert sandbox.user_id == user.id
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Fountain.Machines.Provision.reserve(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:machine_name]
      # Every machine is born in a workspace (ADR 0097).
      assert errors_on(changeset)[:workspace_id]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()

      attrs = %{
        machine_name: "test-sprite",
        status: "bogus",
        user_id: user.id
      }

      assert {:error, changeset} = Fountain.Machines.Provision.reserve(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "list_conversations/1" do
    test "returns conversations scoped to user" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      c1 = insert_conversation(user_id: user1.id)
      _c2 = insert_conversation(user_id: user2.id)

      results = Conversations.list_conversations(user1.id)
      ids = Enum.map(results, & &1.id)
      assert c1.id in ids
      assert length(results) == 1
    end

    test "returns empty list for user with no conversations" do
      user = insert_verified_user()
      assert Conversations.list_conversations(user.id) == []
    end
  end

  describe "_unsafe_get_conversation/1" do
    test "returns the conversation when it exists" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation(conv.id)
      assert result.id == conv.id
    end

    test "returns nil when conversation does not exist" do
      assert Conversations._unsafe_get_conversation(Ecto.UUID.generate()) == nil
    end

    test "returns conversation regardless of owner" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      # user2 is not the owner, but _unsafe variant ignores that
      result = Conversations._unsafe_get_conversation(conv.id)
      assert result.id == conv.id
      assert result.user_id == user1.id
    end

    test "preloads sandbox, agent, and vault" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation(conv.id)
      assert %Sandbox{} = result.sandbox
    end
  end

  describe "_unsafe_get_conversation!/1" do
    test "returns the conversation when it exists" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations._unsafe_get_conversation!(conv.id)
      assert result.id == conv.id
    end

    test "raises Ecto.NoResultsError when conversation does not exist" do
      assert_raise Ecto.NoResultsError, fn ->
        Conversations._unsafe_get_conversation!(Ecto.UUID.generate())
      end
    end
  end

  describe "get_conversation/2" do
    test "a malformed id reads as nil rather than raising (#1679)" do
      user = insert_verified_user()

      assert Conversations.get_conversation("prod-steward", user.id) == nil
      # Sixteen characters is what a cast-based guard would have let through.
      assert Conversations.get_conversation("warehouse worker", user.id) == nil
    end

    test "returns the conversation when id and user_id match" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert result.id == conv.id
    end

    test "returns nil when conversation id does not exist" do
      user = insert_verified_user()
      assert Conversations.get_conversation(Ecto.UUID.generate(), user.id) == nil
    end

    test "returns nil when user_id does not match the owner" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      assert Conversations.get_conversation(conv.id, user2.id) == nil
    end

    test "preloads sandbox, agent, and vault" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      result = Conversations.get_conversation(conv.id, user.id)
      assert %Sandbox{} = result.sandbox
    end
  end

  describe "create_conversation/1" do
    test "creates a conversation with valid attrs" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      attrs = %{
        sandbox_id: sandbox.id,
        user_id: user.id,
        runtime: "claude",
        status: "pending"
      }

      assert {:ok, conv} = Conversations.create_conversation(attrs)
      assert conv.sandbox_id == sandbox.id
      assert conv.user_id == user.id
      assert conv.runtime == "claude"
      assert conv.status == "pending"
    end

    test "returns error changeset when required fields are missing" do
      assert {:error, changeset} = Conversations.create_conversation(%{})
      assert changeset.valid? == false
      assert errors_on(changeset)[:runtime]
      assert errors_on(changeset)[:sandbox_id]
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id)

      attrs = %{
        sandbox_id: sandbox.id,
        user_id: user.id,
        runtime: "claude",
        status: "bogus"
      }

      assert {:error, changeset} = Conversations.create_conversation(attrs)
      assert errors_on(changeset)[:status]
    end
  end

  describe "update_conversation/2" do
    test "updates a conversation with valid attrs" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, updated} = Conversations.update_conversation(conv, %{status: "idle"})
      assert updated.id == conv.id
      assert updated.status == "idle"
    end

    test "returns error changeset when status is invalid" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:error, changeset} = Conversations.update_conversation(conv, %{status: "invalid"})
      assert errors_on(changeset)[:status]
    end
  end

  describe "delete_conversation/1" do
    test "deletes the conversation row from the database" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      # ConversationServer.terminate_conversation/2 will return an error since the server
      # isn't running in tests, but delete_conversation proceeds with Repo.delete
      assert {:ok, _deleted} = Conversations.delete_conversation(conv)
      assert Conversations.get_conversation(conv.id, user.id) == nil
    end

    test "deleted conversation is not found via _unsafe_get_conversation" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      assert {:ok, _} = Conversations.delete_conversation(conv)
      assert Conversations._unsafe_get_conversation(conv.id) == nil
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
