defmodule Fountain.Conversations.InitialStartFailureTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, ConversationServer, Sandbox}
  alias Fountain.Conversations.Launch

  setup do
    user = insert_active_user()
    agent = insert_agent(user_id: user.id)
    {:ok, user: user, agent: agent}
  end

  test "an unchanged initial start failure retires both pending rows", ctx do
    expect_server_start(fn _, _ -> {:error, :max_children} end)
    assert {:ok, conv} = start(ctx)
    assert conv.status == "failed"
    sandbox = Fountain.Machines.Lease.get(conv.sandbox_id)
    assert sandbox.status == "failed"
    assert sandbox.terminated_at
  end

  test "a machine that cannot be failed leaves the conversation alone too", ctx do
    # **The two rows are one commit** (ADR 0058 stage 7b round 1, surfaces
    # review). `main` held them in one transaction under the per-sandbox
    # advisory lock; the machine's row is its owner's now, so the lock is gone,
    # and the transaction is what replaces it —
    # `Machine.fail_provision/2`'s `:before_write` hook runs inside the
    # compare-and-set's own transaction.
    #
    # Without that, a refused row write leaves a `failed` conversation pointing
    # at a `pending` machine: a reserved quota slot with no server, which
    # nothing but the reaper's hourly pass collects. That is the shape this
    # function exists to avoid leaving.
    expect(Fountain.Machines.Lease, :cas_update, fn _id, _epoch, _attrs, _opts ->
      {:error, {:database, :some_sqlstate}}
    end)

    expect_server_start(fn _, _ -> {:error, :max_children} end)
    assert {:ok, conv} = start(ctx)

    assert conv.status == "pending", "the conversation was failed without its machine"
    assert Fountain.Machines.Lease.get(conv.sandbox_id).status == "pending"
  end

  test "a delayed start error preserves a replacement binding and both machines", ctx do
    test = self()

    expect_server_start(fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      original = Fountain.Machines.Lease.get(args[:sandbox_id])
      replacement = insert_sandbox(user_id: ctx.user.id, status: "ready")

      {:ok, _} =
        Conversations.update_conversation(conv, %{sandbox_id: replacement.id, status: "idle"})

      send(test, {:bindings, original.id, replacement.id})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert_received {:bindings, original_id, replacement_id}
    assert conv.status == "idle"
    assert conv.sandbox_id == replacement_id
    assert Fountain.Machines.Lease.get(original_id).status == "pending"
    assert Fountain.Machines.Lease.get(replacement_id).status == "ready"
  end

  test "a start error cannot overwrite an already-provisioned conversation", ctx do
    expect_server_start(fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      sandbox = Fountain.Machines.Lease.get(args[:sandbox_id])
      {:ok, _} = update_sandbox(sandbox, %{status: "ready"})
      {:ok, _} = Conversations.update_conversation(conv, %{status: "idle"})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert conv.status == "idle"
    assert Fountain.Machines.Lease.get(conv.sandbox_id).status == "ready"
  end

  test "a cancelled parent keeps its terminal status", ctx do
    expect_server_start(fn _, {ConversationServer, args} ->
      conv = Repo.get!(Conversation, args[:conversation_id])
      {:ok, _} = Conversations.update_conversation(conv, %{status: "terminated"})
      {:error, :max_children}
    end)

    assert {:ok, conv} = start(ctx)
    assert conv.status == "terminated"
  end

  for change <- [:deleted, :reassigned] do
    @tag change: change
    test "a #{change} parent is not returned to the original caller", ctx do
      other = insert_active_user()

      expect_server_start(fn _, {ConversationServer, args} ->
        conv = Repo.get!(Conversation, args[:conversation_id])

        case ctx.change do
          :deleted -> Repo.delete!(conv)
          :reassigned -> conv |> Ecto.Changeset.change(user_id: other.id) |> Repo.update!()
        end

        {:error, :max_children}
      end)

      assert {:error, :not_found} = start(ctx)
      assert [sandbox] = Repo.all(from s in Sandbox, where: s.user_id == ^ctx.user.id)
      assert sandbox.status == "pending"
    end
  end

  defp start(ctx),
    do: Launch.start_conversation(%{"user_id" => ctx.user.id, "agent_id" => ctx.agent.id})
end
