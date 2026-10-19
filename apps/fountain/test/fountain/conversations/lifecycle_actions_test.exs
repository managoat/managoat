defmodule Fountain.Conversations.LifecycleActionsTest do
  @moduledoc """
  The reclaim actions that moved out of `ConversationServer` in #1376: the
  sandbox clock, what each bound does to the machine, the park and the
  destroy, and what the co-tenants on it are told. Driven with the
  `Managoat.Sandbox` facade stubbed and no server — a co-tenant is a plain
  process registered under its conversation id, which is all `whereis/1`
  looks for.

  The policy half of `Lifecycle` is pinned by `lifecycle_test.exs`; this file
  only asserts the consequences.
  """
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.Lifecycle
  alias Managoat.Sandbox.Handle

  defp handle(name \\ "s"), do: %Handle{provider: :sprites, name: name}

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox_id: sandbox.id, status: "running")
    {:ok, user: user, sandbox: sandbox, conv: conv}
  end

  # The stage events of one stage as `{state, meta}` pairs, in order.
  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  # Collect one telemetry event into this process's mailbox.
  defp listen(event) do
    ref = make_ref()
    test = self()
    id = "lifecycle-actions-#{inspect(ref)}"

    :telemetry.attach(
      id,
      event,
      fn _e, measurements, meta, _ -> send(test, {ref, measurements, meta}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(id) end)
    ref
  end

  describe "provider/1 and clock_start/1" do
    test "the provider tag comes off the live handle, and defaults to sprites" do
      assert Lifecycle.provider(%Handle{provider: :e2b, name: "e"}) == :e2b
      assert Lifecycle.provider(nil) == :sprites
    end

    test "the clock starts at the last wake, else at creation" do
      created = ~U[2026-01-01 00:00:00Z]
      woke = ~U[2026-01-02 00:00:00Z]

      assert Lifecycle.clock_start(%{last_resumed_at: nil, inserted_at: created}) == created
      assert Lifecycle.clock_start(%{last_resumed_at: woke, inserted_at: created}) == woke
    end
  end

  describe "schedule_check/0" do
    test "arms :lifecycle_check in the calling process" do
      ref = Lifecycle.schedule_check()
      assert is_reference(ref)
      # The default is a minute; the point is that a timer exists and carries
      # the message the server's handle_info matches on.
      assert Process.read_timer(ref) > 0
      assert Process.cancel_timer(ref) > 0
    end
  end

  describe "busy_elsewhere?/2" do
    test "false when this conversation is alone on the machine", ctx do
      refute Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end

    test "true when a co-tenant is mid-turn", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())

      assert Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end

    test "a terminated co-tenant does not hold the machine", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())
      {:ok, _} = Conversations.update_conversation(other, %{status: "terminated"})

      refute Lifecycle.busy_elsewhere?(ctx.sandbox.id, ctx.conv.id)
    end
  end

  # `Lifecycle.suspend/1` is gone (ADR 0058 stage 6b): the provider call it
  # wrapped is `Fountain.Machines.Park`'s, made under the machine's lease with
  # the handle built from the row rather than from the server's state, so its
  # `nil` clause has no case left to answer. The two things it asserted are
  # asserted where the call now is — `machines/park_test.exs`'s
  # "stamps the intent, checkpoints, suspends, finalizes, audits, in that
  # order", which pins the handle the provider is given, and its
  # "the suspend that does not land" cases.
  describe "idle_machine_action/1" do
    # These no longer make the provider call. The decision is the provider's
    # *capability*, which is a pure question; the call, and the degradation
    # when it fails, are the protocol's. `machines/park_test.exs` pins the
    # failing call (`{:error, :suspend_failed}`) and
    # `conversation_server_lifetime_test.exs` pins that the server degrades to
    # a destroy on it end to end — "a failed suspend call degrades to destroy",
    # unchanged by this stage.
    test "parks where the provider can" do
      reject(&Managoat.Sandbox.suspend/1)
      assert Lifecycle.idle_machine_action(handle()) == :park
    end

    test "destroys where the provider cannot park" do
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
      reject(&Managoat.Sandbox.suspend/1)

      assert Lifecycle.idle_machine_action(handle()) == :destroy
    end
  end

  describe "idle_machine_action/3" do
    test "keeps the machine when a co-tenant is mid-turn", ctx do
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())

      assert Lifecycle.idle_machine_action(ctx.conv.id, ctx.sandbox.id, handle()) == :keep
    end

    test "parks when this conversation is alone on the machine", ctx do
      assert Lifecycle.idle_machine_action(ctx.conv.id, ctx.sandbox.id, handle()) == :park
    end

    test "a machine nobody else holds on a provider that cannot park is destroyed", ctx do
      stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)

      assert Lifecycle.idle_machine_action(ctx.conv.id, ctx.sandbox.id, handle()) == :destroy
    end
  end

  describe "park/4" do
    test "parks the row, idles the conversation, and says so on the stream", ctx do
      ref = listen([:fountain, :sandbox, :suspended])

      assert Lifecycle.park(ctx.conv.id, ctx.sandbox.id, handle(), :idle) == :ok

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "suspended"
      assert Repo.reload(ctx.conv).status == "idle"

      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["event"] == "suspended"
      assert meta["reason"] == "idle"
      assert meta["message"] == Lifecycle.explain(:idle, :suspend)

      assert_received {^ref, %{count: 1}, %{provider: :sprites}}
    end

    test "a row already terminated or failed is left alone", ctx do
      {:ok, sandbox} = update_sandbox(ctx.sandbox, %{status: "failed"})

      assert Lifecycle.park(ctx.conv.id, sandbox.id, handle(), :idle) == :ok
      assert Repo.reload(sandbox).status == "failed"
      assert Repo.reload(ctx.conv).status == "running"
      assert stages(ctx.conv.id, "sandbox") == []
    end

    test "a refused park writes nothing and says so", ctx do
      # `main` raised a `MatchError` out of `park_row/1` on any write error it
      # had no clause for, which took the calling server down with it. The
      # protocol has no changeset and no unexpected write errors: every refusal
      # is a value, and the server decides what to do with it (it keeps the
      # machine and asks again on the next tick). The refusal driven here is a
      # co-tenant mid-turn, which is the one a park meets in production.
      other =
        insert_conversation(user_id: ctx.user.id, sandbox_id: ctx.sandbox.id, status: "running")

      insert_turn(other, status: "running", started_at: DateTime.utc_now())

      assert Lifecycle.park(ctx.conv.id, ctx.sandbox.id, handle(), :idle) ==
               {:error, :machine_occupied}

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      assert Repo.reload!(ctx.conv).status == "running"
      assert stages(ctx.conv.id, "sandbox") == []
    end

    test "a conversation that is not running keeps its status", ctx do
      {:ok, conv} = Conversations.update_conversation(ctx.conv, %{status: "terminated"})

      assert Lifecycle.park(conv.id, ctx.sandbox.id, handle(), :idle) == :ok
      assert Repo.reload(conv).status == "terminated"
    end
  end

  describe "destroy/5" do
    # The machine destroyed is the one named on the *row*, not the one in the
    # caller's handle (ADR 0058 stage 5): the owner reads the machine it owns,
    # and the handle argument is left only to tag the telemetry. Before stage 5
    # this expected `%Handle{name: "s"}`, the handle this test made up.
    test "tears the sandbox down, terminates the row and idles the conversation", ctx do
      ref = listen([:fountain, :sandbox, :reclaimed])
      test = self()
      machine_name = ctx.sandbox.machine_name

      expect(Managoat.Sandbox, :destroy, fn %Handle{provider: :sprites, name: ^machine_name} ->
        send(test, :destroyed) && :ok
      end)

      assert Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, handle(), :max_lifetime) ==
               :ok

      assert_received :destroyed

      reloaded = Fountain.Machines.Lease.get(ctx.sandbox.id)
      assert reloaded.status == "terminated"
      assert reloaded.terminated_at
      assert Repo.reload(ctx.conv).status == "idle"

      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["event"] == "reclaimed"
      assert meta["reason"] == "max_lifetime"
      assert meta["message"] == Lifecycle.reclaim_message(:max_lifetime)

      assert_received {^ref, %{count: 1}, %{reason: :max_lifetime, provider: :sprites}}
    end

    # Before stage 5 this asserted the opposite — `reject(&destroy/1)`, "no
    # handle is nothing to tear down" — and a reclaim whose caller had already
    # dropped its handle left the machine running with a terminal row behind
    # it, for the reaper to find. The row names the machine, so the owner can
    # always reach it.
    test "a caller with no handle still destroys the machine the row names", ctx do
      machine_name = ctx.sandbox.machine_name
      expect(Managoat.Sandbox, :destroy, fn %Handle{name: ^machine_name} -> :ok end)

      assert Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, nil, :idle) == :ok

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
      assert [{"done", meta}] = stages(ctx.conv.id, "sandbox")
      assert meta["message"] == Lifecycle.reclaim_message(:idle)
      # The provider tag falls back with the handle.
      assert meta["reason"] == "idle"
    end
  end

  # `Lifecycle.stop_cotenants/5` is gone (ADR 0058 stage 6b). The co-tenant
  # notice is sent from inside the machine operation that earns it — by
  # `Machines.Destroy` since 5a and by `Machines.Park` now — through
  # `MachineEvents.tell_cotenants/5`, still the one sender of that cast, and
  # the wrapper had no callers left. Its two cases are
  # `machines/park_test.exs`'s "reaches every other live server on the machine
  # when the caller supplies one" and "a co-tenant with no live server is not
  # an error", driven through the park that actually sends them.

  describe "reclaim_message/1" do
    test "names the bound that destroyed the sandbox" do
      assert Lifecycle.reclaim_message(:max_lifetime) == Lifecycle.explain(:max_lifetime)
      assert Lifecycle.reclaim_message(:idle) == Lifecycle.explain(:idle, :destroy)
    end
  end
end
