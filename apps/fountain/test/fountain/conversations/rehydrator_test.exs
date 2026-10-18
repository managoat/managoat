defmodule Fountain.Conversations.RehydratorTest do
  # The sweep queries all resumable rows; do not overlap independent-connection
  # admission race fixtures in the async suites.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.{ConversationServer, Rehydrator}

  setup do
    owner = self()

    stub_server_start(fn _, {ConversationServer, args} ->
      send(owner, {:worker_start, args})
      {:ok, owner}
    end)

    :ok
  end

  test "boot starts every resumable conversation, including one with an existing server" do
    ordinary = resumable("idle")
    existing = resumable("running")
    owner = self()

    stub_server_start(fn _, {ConversationServer, args} ->
      send(owner, {:worker_start, args})

      if args[:conversation_id] == existing.id,
        do: {:error, {:already_started, owner}},
        else: {:ok, owner}
    end)

    assert sweep() == 2
    assert_received {:worker_start, first}
    assert_received {:worker_start, second}

    assert Enum.sort([first[:conversation_id], second[:conversation_id]]) ==
             Enum.sort([ordinary.id, existing.id])

    assert first[:initial_prompt] == nil
    assert second[:initial_prompt] == nil
    refute_received {:worker_start, _}
  end

  # ADR 0058 stage 6a. The sweep reads `ready` rows, and a `ready` row can be
  # one an owner holds between its intent and its finalize: a destroy, a reset,
  # and from stage 6b a park. Starting a server there gives the machine a
  # second writer during the one window the owner exists to prevent. Skipping
  # is right rather than failing: the next boot, or the conversation's own next
  # prompt, comes back after the lease has gone.
  test "boot skips a machine whose owner holds a live lease" do
    conv = resumable("idle")
    put_lease(conv.sandbox, held())

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
    assert log =~ "machine_busy"
    refute_received {:worker_start, _}
    assert Repo.reload!(conv).status == "idle"
  end

  for transition <- ["parking"] do
    test "boot starts a server on a #{transition} row whose lease died" do
      # Round 1: a stamped transition with no live lease is an owner that died,
      # not one working. Skipping it left the conversation with no server until
      # something else gave up on the row — the hourly reaper, for a teardown.
      conv = resumable("idle")

      conv.sandbox
      |> put_lease(
        transition: unquote(transition),
        lease_epoch: 1,
        lease_node: nil
      )

      assert sweep() == 1
      assert_received {:worker_start, args}
      assert args[:conversation_id] == conv.id
    end
  end

  test "boot preserves an interrupted readiness probe for the next wake" do
    conv = resumable("idle")

    conv.sandbox
    |> put_lease(
      transition: "resuming",
      lease_epoch: 1,
      lease_node: dead_lease_holder()
    )

    Fountain.Machines.Lease.sweep_boot()
    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
    assert log =~ "machine_resuming"
    refute_received {:worker_start, _}
    assert Repo.reload!(conv.sandbox).transition == "resuming"
  end

  test "boot skips an abandoned destroy, where stage 6a started a server on it" do
    # The one place stage 6a's reasoning genuinely inverts at stage 9a, and it
    # is worth saying why rather than only changing the number.
    #
    # 6a round 1 restored this start because refusing withheld a machine from a
    # conversation for as long as an hourly sweep took, where `main` had given
    # it one at once. That holds for an abandoned park or resume and not for an
    # abandoned destroy: `main` answers 409 (`:sandbox_reset_pending`) to a
    # prompt on a fenced row already, so this conversation is **blocked either
    # way** until the machine is gone, and then gets a fresh one. Skipping it
    # here costs it nothing it would have had, and starting a server costs the
    # intent — the door this sweep goes through,
    # `Conversations.register_server/2`, cleared a lease-less stamp on its way
    # in, which after stage 9b is the only record that the machine was asked to
    # go.
    #
    # The stamp with no columns is the shape 9b leaves, and it is the one
    # asserted: refusing on the columns alone would stop refusing the day they
    # are dropped.
    conv = resumable("idle")

    conv.sandbox
    |> put_lease(
      transition: "destroying",
      transition_reason: "terminated",
      lease_epoch: 1,
      lease_node: nil
    )

    # `reject` on the registration door, because the door refuses this row too
    # (rule 16's second door) and both refusals log the same word — so without
    # it this test would pass with `check_machine_free/2` deleted, from the
    # door's refusal instead of the sweep's own.
    reject(Fountain.Conversations, :register_server, 2)

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
    assert log =~ "machine_destroying"
    refute_received {:worker_start, _}

    kept = Repo.reload!(conv.sandbox)
    assert kept.transition == "destroying"
    assert kept.transition_reason == "terminated"
  end

  test "the registration door refuses the same row, for a caller that got past the check" do
    # `check_machine_free/2` reads the row with no lock, so the stamp can land
    # between it and the start. `Conversations.register_server/2` re-reads under
    # the per-sandbox advisory lock and refuses there too, which is the second
    # door of the same rule (rule 16) — and the one that would otherwise clear
    # the stamp.
    conv = resumable("idle")

    stub(Fountain.RuntimeDispatch, :for_agent, fn arg ->
      conv.sandbox
      |> put_lease(transition: "destroying", transition_reason: "terminated")

      Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [arg])
    end)

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)
    assert log =~ "machine_destroying"
    refute_received {:worker_start, _}
    assert Repo.reload!(conv.sandbox).transition == "destroying"
  end

  test "a lease claimed after the sweep's own check is refused at the door, and says so" do
    # `check_machine_free/1` reads the row with no lock; the door re-reads it
    # under the per-sandbox advisory lock and can refuse where our check
    # passed. That refusal comes back into the `with`'s *body*, which the
    # `else` below never sees, so before round 2 it left the sweep with no log
    # line at all (round 1, locks review).
    #
    # `RuntimeDispatch.for_agent/1` is the hook: it runs after
    # `check_machine_free/1` and before `register_server/2`, so a lease claimed
    # there is exactly a claim landing in that gap.
    conv = resumable("idle")

    stub(Fountain.RuntimeDispatch, :for_agent, fn c ->
      Repo.get!(Fountain.Conversations.Sandbox, conv.sandbox_id)
      |> put_lease(held())

      Mimic.call_original(Fountain.RuntimeDispatch, :for_agent, [c])
    end)

    log = ExUnit.CaptureLog.capture_log(fn -> assert sweep() == 0 end)

    assert log =~ "skipping conv #{conv.id} (machine_busy)"
    refute_received {:worker_start, _}
  end

  test "boot starts a server once the lease has expired" do
    conv = resumable("idle")

    conv.sandbox
    |> put_lease(held(:dead))

    assert sweep() == 1
    assert_received {:worker_start, args}
    assert args[:conversation_id] == conv.id
  end

  test "boot still leaves non-ready sandboxes to lazy recovery" do
    for status <- ["pending", "starting", "suspended", "terminated", "failed"] do
      conv = resumable("idle")
      conv.sandbox |> Ecto.Changeset.change(status: status) |> Repo.update!()
    end

    assert sweep() == 0
    refute_received {:worker_start, _}
  end

  # A lease somebody holds (ADR 0058) — the whole of what makes a machine busy
  # to a reader. Written straight onto the row: no changeset casts these
  # columns, which is itself part of the design.
  defp held(state \\ :live)
  defp held(:live), do: [lease_epoch: 1, lease_node: live_lease_holder()]
  defp held(:dead), do: [lease_epoch: 1, lease_node: dead_lease_holder()]

  defp resumable(status) do
    agent = insert_agent()
    sandbox = insert_sandbox(user_id: agent.user_id, status: "ready")
    insert_conversation(agent: agent, sandbox: sandbox, status: status)
  end

  defp sweep, do: Rehydrator.run()
end
