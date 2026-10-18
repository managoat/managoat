defmodule Fountain.Conversations.InterruptDeadReconcilesTest do
  use Fountain.DataCase, async: true
  use Mimic

  import Ecto.Query

  alias Fountain.Audit
  alias Fountain.Conversations
  alias Fountain.Conversations.{Interruption, Sandbox, Turn, Wake}
  alias Fountain.Repo

  # #2175 open decision 1 (Jake, 2026-09-15): interrupting a conversation
  # whose server is dead and whose sandbox can no longer be reused reconciles
  # the orphaned turn; it never provisions a new sandbox on the interrupt's
  # behalf. Before this, `wake_conversation_for/3` treated `:interrupt` the
  # same as `:work` on a `:create_new` probe, so an interrupt on a dead
  # conversation paid to provision a fresh sprite and then timed out to
  # `{:error, :provisioning}` — no test covered that arm.

  test "interrupting a dead conversation with no reusable sandbox reconciles the turn, not provisions" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    # A terminal-status sandbox makes maybe_reuse_sandbox/1 fall straight to
    # :create_new without any provider probe (the same shape the reaper and
    # a dead machine leave behind).
    sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "running"
      )

    turn = insert_turn(conv, status: "running")

    sandbox_count_before = Repo.aggregate(Sandbox, :count)

    reject(&DynamicSupervisor.start_child/2)

    assert {:error, :not_running} = Interruption.interrupt(conv.id)

    reloaded_turn = Repo.reload!(turn)
    assert reloaded_turn.status == "interrupted"
    refute is_nil(reloaded_turn.orphaned_at)

    reloaded_conv = Repo.reload!(conv)
    assert reloaded_conv.status == "idle"

    assert Repo.aggregate(Sandbox, :count) == sandbox_count_before

    refute Repo.exists?(
             from e in Audit.Event,
               where:
                 e.resource_id == ^conv.id and
                   e.action == "conversation.interrupted"
           )
  end

  test "the same dead-sandbox shape still builds a machine for a plain prompt (:work)" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    sandbox = insert_sandbox(user_id: user.id, status: "terminated")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        status: "idle"
      )

    owner = self()

    stub_server_start(fn _supervisor, child_spec ->
      send(owner, {:start_child_called, child_spec})
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)

    assert {:ok, _woken} = Wake.wake_conversation(conv.id)
    assert_received {:start_child_called, child_spec}

    # Its workspace is kept (ADR 0097 step 4): the server is started on the
    # conversation's own row and rebuilds the machine there.
    assert child_spec |> inspect() |> String.contains?(sandbox.id)
  end

  # Three independent reviews of the first cut of this PR found the same gap:
  # the provider probe that answers `:create_new` for the OLD sandbox runs
  # outside any lock, against the sandbox_id read at the top of the wake. If
  # a concurrent :work wake rebinds the conversation and admits a running
  # successor turn while that stale probe is still in flight, reconciliation
  # must not touch the successor — it belongs to a live incarnation this
  # interrupt never asked about.
  test "a stale probe response after a concurrent rebind does not touch the live successor" do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)
    old_sandbox = insert_sandbox(user_id: user.id, status: "ready")
    replacement = insert_sandbox(user_id: user.id, status: "ready")

    conv =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: old_sandbox,
        status: "running"
      )

    # Before the (old, dead) sandbox's probe answers "gone", simulate a
    # concurrent :work wake winning the race: it rebinds the conversation to
    # a fresh sandbox and admits a running successor turn on it.
    stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
      {:ok, _conv} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
      insert_turn(conv, status: "running")
      {:error, :not_found}
    end)

    reject(&DynamicSupervisor.start_child/2)

    assert {:error, :not_running} = Interruption.interrupt(conv.id)

    successor =
      Repo.one!(from t in Turn, where: t.conversation_id == ^conv.id and t.status == "running")

    assert is_nil(successor.orphaned_at)

    reloaded_conv = Repo.reload!(conv)
    assert reloaded_conv.status == "running"
    assert reloaded_conv.sandbox_id == replacement.id
  end

  # P2: the same no-provision rule for a conversation stranded on a
  # `pending`/`starting` sandbox whose server never turns up during the
  # registry-settle wait — not just the flat `:create_new` probe above.
  for status <- ~w(pending starting) do
    test "a running conversation stranded on a #{status} sandbox reconciles instead of provisioning fresh" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: unquote(status))

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          status: "running"
        )

      turn = insert_turn(conv, status: "running")

      sandbox_count_before = Repo.aggregate(Sandbox, :count)

      reject(&DynamicSupervisor.start_child/2)

      # No server is registered for conv.id, so await_registered/1 times out
      # against the real registry after the configured settle window
      # (config/test.exs: 150ms) — no stub needed for that part.
      assert {:error, :not_running} = Interruption.interrupt(conv.id)

      reloaded_turn = Repo.reload!(turn)
      assert reloaded_turn.status == "interrupted"
      refute is_nil(reloaded_turn.orphaned_at)

      assert Repo.aggregate(Sandbox, :count) == sandbox_count_before
    end
  end
end
