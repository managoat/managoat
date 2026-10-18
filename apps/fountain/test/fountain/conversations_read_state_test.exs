defmodule Fountain.ConversationsReadStateTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Termination
  alias Fountain.Conversations.Wake

  # mark_read/2 and the last_active_at / unread reporting it feeds.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # mark_read/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "mark_read/2" do
    test "sets last_read_at to approximately now" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      assert is_nil(conv.last_read_at)

      before = DateTime.utc_now()
      :ok = Conversations.mark_read(conv.id, user.id)
      after_time = DateTime.utc_now()

      reloaded = Conversations.get_conversation(conv.id, user.id)
      refute is_nil(reloaded.last_read_at)
      assert DateTime.compare(reloaded.last_read_at, before) in [:gt, :eq]
      assert DateTime.compare(reloaded.last_read_at, after_time) in [:lt, :eq]
    end

    test "is scoped to owner — does not update another user's conversation" do
      user1 = insert_verified_user()
      user2 = insert_verified_user()
      conv = insert_conversation(user_id: user1.id)

      :ok = Conversations.mark_read(conv.id, user2.id)

      reloaded = Conversations.get_conversation(conv.id, user1.id)
      assert is_nil(reloaded.last_read_at)
    end

    test "calling twice updates last_read_at to a more recent time" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      :ok = Conversations.mark_read(conv.id, user.id)
      first_read = Conversations.get_conversation(conv.id, user.id).last_read_at

      Process.sleep(2)

      :ok = Conversations.mark_read(conv.id, user.id)
      second_read = Conversations.get_conversation(conv.id, user.id).last_read_at

      assert DateTime.compare(second_read, first_read) in [:gt, :eq]
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
  # list_conversations/2 — last_active_at and unread safety
  # ────────────────────────────────────────────────────────────────────────────

  describe "list_conversations/2 last_active_at" do
    test "defaults to inserted_at when there are no log events" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      [result] = Conversations.list_conversations(user.id)

      assert DateTime.compare(
               result.last_active_at,
               DateTime.from_naive!(result.inserted_at, "Etc/UTC")
             ) == :eq
    end

    test "advances past inserted_at when output log events exist" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      later = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:microsecond)
      insert_log_event(conv, kind: "output", stream: "stdout", inserted_at: later)

      [result] = Conversations.list_conversations(user.id)

      assert DateTime.compare(
               result.last_active_at,
               DateTime.from_naive!(conv.inserted_at, "Etc/UTC")
             ) == :gt
    end

    test "stage events (reconnects) do NOT advance last_active_at" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)

      baseline_at = List.first(Conversations.list_conversations(user.id)).last_active_at

      later = DateTime.utc_now() |> DateTime.add(300, :second) |> DateTime.truncate(:microsecond)
      insert_log_event(conv, kind: "stage", data: "reattach", stream: "", inserted_at: later)

      [result] = Conversations.list_conversations(user.id)
      assert DateTime.compare(result.last_active_at, baseline_at) == :eq
    end

    test "last_read_at is nil by default" do
      user = insert_verified_user()
      insert_conversation(user_id: user.id)

      [result] = Conversations.list_conversations(user.id)
      assert is_nil(result.last_read_at)
    end

    test "last_read_at is populated after mark_read" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id)
      Conversations.mark_read(conv.id, user.id)

      [result] = Conversations.list_conversations(user.id)
      refute is_nil(result.last_read_at)
    end
  end

  describe "Termination.reap_sandbox/1" do
    test "marks a ready sandbox with no live server terminated; conversations untouched" do
      sandbox = insert_sandbox(status: "ready")
      conv = insert_conversation(sandbox: sandbox, user_id: sandbox.user_id)

      assert {:ok, :released} = Termination.reap_sandbox(sandbox.id)

      reloaded = Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "terminated"
      assert reloaded.terminated_at
      refute Conversations._unsafe_get_conversation(conv.id).status == "terminated"
    end

    test "is a no-op on an already-terminal sandbox" do
      sandbox = insert_sandbox(status: "terminated")
      assert {:ok, :already_terminal} = Termination.reap_sandbox(sandbox.id)
    end

    test "returns not_found for an unknown id" do
      assert {:error, :not_found} = Termination.reap_sandbox(Ecto.UUID.generate())
    end
  end

  describe "concurrent wake loses cleanly (#330)" do
    # Two prompts race to wake the same dormant conversation. Both used to
    # reach create_fresh_sandbox_and_start; the loser's start_child returned
    # {:error, {:already_started, _}}, the `with` fell through, and its
    # just-created pending sandbox row sat holding a quota slot until the
    # reaper's pass an hour later — a user at their cap could lock themselves
    # out for an hour by double-clicking.

    test "the loser terminates its own sandbox row instead of stranding it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      # A row from before workspaces: the fresh-sandbox path (a kept
      # workspace's wake reserves no row of its own, ADR 0097 step 4).
      sandbox = insert_sandbox(user_id: user.id, workspace_id: nil)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub_server_start(fn _sup, _spec ->
        {:error, {:already_started, self()}}
      end)

      stub(Fountain.Conversations.ConversationServer, :queue_initial_prompt, fn _conv_id,
                                                                                _prompt,
                                                                                _images ->
        :ok
      end)

      before = Fountain.Repo.all(Fountain.Conversations.Sandbox) |> MapSet.new(& &1.id)

      assert {:ok, _conv} = Wake.wake_conversation(conv.id, "hi")

      # The row the loser created for itself is terminated, not pending —
      # which is what #330 is about: a double-click must not strand a quota
      # slot until the reaper's next pass.
      created =
        Fountain.Conversations.Sandbox
        |> Fountain.Repo.all()
        |> Enum.reject(&MapSet.member?(before, &1.id))

      assert created != []

      for sandbox <- created do
        assert sandbox.status == "terminated"
      end

      # The conversation's *existing* sandbox is deliberately left alone now
      # (#717). The loser does not know what the winner is running on, and
      # `wake_conversation`'s reuse arm starts a server against exactly this
      # sandbox — so retiring it here could terminate the one the winner is
      # using. The winner retires it if it provisioned a replacement.
      assert active_sandbox_count(user.id) == 1
    end

    test "the loser forwards its prompt to the winner" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
      test_pid = self()

      stub_server_start(fn _sup, _spec ->
        {:error, {:already_started, self()}}
      end)

      stub(Fountain.Conversations.ConversationServer, :queue_initial_prompt, fn conv_id,
                                                                                prompt,
                                                                                _images ->
        send(test_pid, {:forwarded, conv_id, prompt})
        :ok
      end)

      assert {:ok, _} = Wake.wake_conversation(conv.id, "the racing prompt")
      assert_received {:forwarded, _conv_id, "the racing prompt"}
    end

    test "a genuine start failure still surfaces as an error" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")

      stub_server_start(fn _sup, _spec ->
        {:error, :max_children}
      end)

      assert {:error, :max_children} = Wake.wake_conversation(conv.id, "hi")
    end
  end
end
