defmodule Fountain.Machines.MidOperationReadersTest do
  @moduledoc """
  The readers that refuse a machine whose owner holds a live lease (ADR 0058
  stage 6a, #2307 constraint 2's reader half).

  Nothing writes `transition: "parking"` yet — stage 6b's park protocol does.
  6a puts the readers in front of it, so the writer lands behind readers that
  already honour it, and so the transitions that *do* exist today (`destroying`
  from the destroy protocol, and any live lease) stop being invisible to a wake
  or an attach.

  Two doors, one answer (the attach door went with ADR 0073). `Wake.maybe_reuse_sandbox/1`, the attach door
  (`Binding.attachable/5` since stage 8b, `Launch.check_attachable/4` when this
  file was written) and `Rehydrator`'s boot sweep each turn `Machine.busy?/2`
  into `:sandbox_unavailable` — the word the system already has, 503 with a
  `Retry-After`.

  **A live lease is the whole of the question** (round 1). A stamped
  `transition` whose lease has expired is an owner that *died* mid-operation,
  and every door here must read such a row exactly as `main` does — refusing it
  withheld a machine for as long as the sweep that gives up on the row takes to
  run. Each door has that case beside its refusal, asserting the `main` verdict
  rather than merely "not 503".

  Two orderings are load-bearing and each has a case here: the reset fence
  answers before the transition check, because a refused reset leaves
  `transition: "destroying"` on a live row with its lease released (stage 5c)
  and `:sandbox_reset_pending` is the precise thing to say about it; and a
  terminal row is never "busy", because a finalize writes the terminal status
  and releases the lease as two statements.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Sandbox, Wake}
  alias Fountain.Machines.Machine

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id)

    sandbox =
      insert_sandbox(
        user_id: user.id,
        agent_id: agent.id,
        environment_id: agent.environment_id,
        status: "ready",
        machine_name: "mid-op-#{System.unique_integer([:positive])}"
      )

    conv =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    %{user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  # The columns no changeset casts: an owner writes them through
  # `Machines.Lease`, and a test writes them the same way the database does.
  defp stamp(sandbox, changes) do
    put_lease(sandbox, changes)
  end

  defp held(state \\ :live)
  defp held(:live), do: [lease_epoch: 1, lease_node: live_lease_holder()]
  defp held(:dead), do: [lease_epoch: 1, lease_node: dead_lease_holder()]

  # The owner logs an info line when it clears an abandoned stamp; the suite runs
  # at `:warning`, so this is only about not leaking output.
  defp capture_answer(fun) do
    answer = :erlang.make_ref()
    Process.put(answer, nil)
    capture_log(fn -> Process.put(answer, fun.()) end)
    Process.get(answer)
  end

  defp conv_with_sandbox(ctx), do: Repo.reload!(ctx.conv) |> Repo.preload(:sandbox)

  describe "Machine.busy?/2" do
    test "a live lease, and nothing else", ctx do
      refute Machine.busy?(ctx.sandbox)

      assert Machine.busy?(stamp(ctx.sandbox, held()))
      refute Machine.busy?(stamp(ctx.sandbox, held(:dead)))

      # An epoch with no holder is a row held by nobody, and reads as such.
      refute Machine.busy?(stamp(ctx.sandbox, Keyword.merge(held(), lease_node: nil)))
    end

    test "a stamped transition is not, on its own, an owner at work", ctx do
      # The round-1 correction. A transition with no live lease is an owner
      # that died mid-operation; `SandboxReaper.sweep_fenced_teardowns/0` calls
      # exactly that row abandoned, and two readers of one row must not
      # disagree. Refusing on it answered 503 until the sweep that gives up on
      # the row ran — hourly, so 16 to 75 minutes.
      released = stamp(ctx.sandbox, lease_epoch: 1, lease_node: nil)

      for transition <- Sandbox.transitions() do
        refute Machine.busy?(stamp(released, transition: transition)),
               "#{transition} with no live lease read as an owner at work"
      end

      # And with a live lease under it, every one of them is.
      for transition <- Sandbox.transitions() do
        assert Machine.busy?(stamp(released, Keyword.put(held(), :transition, transition)))
      end
    end
  end

  describe "Wake.maybe_reuse_sandbox/1" do
    test "a clean ready row probes and is reused", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a parking row under a live lease is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, Keyword.put(held(), :transition, "parking"))

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a parking row whose lease died probes and reuses, exactly as on main", ctx do
      # The abandoned-operation case. `main` probes the provider here and hands
      # the caller the machine; so does 6a.
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      stamp(ctx.sandbox, transition: "parking", lease_epoch: 1, lease_node: nil)

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an abandoned destroy answers its fence here, on this tree and on main", ctx do
      # The shape `Destroy` really leaves behind, which is not the one the
      # round-1 note reached for: it fences *before* it stamps, and the
      # teardown fence writes the `destroying` stamp. So a destroy whose owner
      # died carries it, and this door answers the fence from its first clause.
      # The wake door was therefore never the live 6a regression; the
      # rehydrator's sweep was, because its query has no reset filter
      # (`rehydrator_test.exs` pins that). Recorded here so a later reader does
      # not go looking for a difference that is not at this door.
      reject(Managoat.Sandbox, :get, 1)

      stamp(ctx.sandbox,
        transition: "destroying",
        transition_reason: "teardown",
        lease_epoch: 1,
        lease_node: nil
      )

      assert {:error, :sandbox_reset_pending} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an abandoned park has no fence to answer, and reuses as on main", ctx do
      # And this is why the definition matters at 6b. A park carries no fence,
      # so a park whose owner died reaches `busy?/2` with nothing in front of
      # it: under the round-0 definition every wake onto it answered 503 until
      # a sweep gave up on the row, with no fence to make that the right
      # answer.
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)

      stamp(ctx.sandbox,
        transition: "parking",
        lease_epoch: 1,
        lease_node: nil
      )

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "and the wake that follows that reuse is not refused either", ctx do
      # **The reader is only half the seam** (round 1 of #2368, behaviour
      # review). Stage 7a put `Machines.Resume` behind every reuse, and its
      # first draft read a lease-less stamp as a fence — so the reader above
      # handed the machine over and the owner refused it one call later, which
      # is 6a's decision undone one layer down. The two have to agree, so both
      # are asserted here rather than only the one this file was written for.
      stamp(ctx.sandbox,
        transition: "parking",
        lease_epoch: 1,
        lease_node: nil
      )

      assert {:ok, :already_up} =
               capture_answer(fn ->
                 Machine.ensure_up(ctx.sandbox.id, actor: "system:wake")
               end)

      assert is_nil(Fountain.Machines.Lease.get(ctx.sandbox.id).transition),
             "the owner left the abandoned stamp on the row it just handed out"
    end

    test "a live lease is refused before the provider is asked", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, held())

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "an expired lease is not a refusal", ctx do
      expect(Managoat.Sandbox, :get, fn _ -> {:ok, %{}} end)
      stamp(ctx.sandbox, held(:dead))

      assert {:reuse, _, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a suspended row under a live lease is refused too", ctx do
      reject(Managoat.Sandbox, :get, 1)
      stamp(ctx.sandbox, Keyword.merge(held(), status: "suspended", transition: "resuming"))

      assert {:error, :sandbox_unavailable} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a provisioning row under a live lease still waits for the registry", ctx do
      # **Reversed in stage 7b, deliberately.** 6a pinned this as
      # `:sandbox_unavailable`, reasoning that a row an owner is holding has a
      # writer and the wake should come back. Nothing claimed a lease on a
      # `pending` row when that was written; the provision bracket does, for
      # its whole length, so the rule 6a stated for an *abandoned* operation
      # would have applied to every ordinary one — and `session/new` followed
      # by a prompt 30ms later is exactly that shape. Refusing it answers 503 to
      # the case #800 exists to serve, for minutes.
      #
      # So the door waits for the registry, as on `main`, and 6a's rule moved
      # to the decision it was really about: `wake_conversation_for/3`'s
      # `:timeout` arm asks whether an owner holds the machine before it
      # replaces one, which is the test below.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "pending", transition: "provisioning"))

      assert {:provisioning, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a live lease refuses the replacement the registry's silence would make", ctx do
      # The other half. `await_registered/2` gives up after its settle window
      # and `main` then built a fresh machine; with a live lease on the row
      # that would be a second billable machine over one a server is still
      # building, wherever Horde's CRDT has got to.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "pending", transition: "provisioning"))

      conv = conv_with_sandbox(ctx)

      assert {:error, :sandbox_unavailable} =
               capture_answer(fn -> Wake.wake_conversation(conv.id, "hello") end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "pending",
             "the machine being provisioned was replaced anyway"
    end

    test "a provisioning row whose lease died still waits for the registry, as on main", ctx do
      stamp(ctx.sandbox,
        status: "pending",
        transition: "provisioning",
        lease_epoch: 1,
        lease_node: nil
      )

      assert {:provisioning, _} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "the reset fence wins over the transition it leaves behind", ctx do
      # Stage 5c's refused reset: a live `ready` row, its fence still stamped,
      # `transition: "destroying"` left on it, the lease released. The precise
      # answer is the fence (409, the reconciler will finish it), not "retry in
      # 30 seconds".
      reject(Managoat.Sandbox, :get, 1)

      stamp(ctx.sandbox,
        transition: "destroying",
        transition_reason: "reset",
        lease_epoch: 1,
        lease_node: nil
      )

      assert {:error, :sandbox_reset_pending} = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a terminal row is a fresh machine, however it is stamped", ctx do
      # A finalize writes `terminated` and releases the lease as two
      # statements, so terminal-and-held is a real momentary state. It means
      # the machine is gone, which is a new one — not a retry.
      stamp(ctx.sandbox, Keyword.merge(held(), status: "terminated", transition: "destroying"))

      assert :create_new = Wake.maybe_reuse_sandbox(conv_with_sandbox(ctx))
    end

    test "a conversation with no machine is untouched", ctx do
      conv = conv_with_sandbox(ctx)
      assert :create_new = Wake.maybe_reuse_sandbox(%{conv | sandbox_id: nil})
    end
  end
end
