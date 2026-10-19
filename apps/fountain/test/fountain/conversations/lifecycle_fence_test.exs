defmodule Fountain.Conversations.LifecycleFenceTest do
  # The server callback reads application-wide lifecycle bounds.
  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.{Audit, Conversations}
  alias Fountain.Conversations.{ConversationServer, Lifecycle}

  setup do
    bounds = [sandbox_idle_timeout_minutes: 1, sandbox_max_lifetime_hours: 0]
    previous = Enum.map(bounds, fn {key, _} -> {key, Application.fetch_env(:fountain, key)} end)
    Enum.each(bounds, fn {key, value} -> Application.put_env(:fountain, key, value) end)

    on_exit(fn ->
      Enum.each(previous, fn
        {key, {:ok, value}} -> Application.put_env(:fountain, key, value)
        {key, :error} -> Application.delete_env(:fountain, key)
      end)
    end)

    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    handle = Managoat.Sandbox.build_handle(:sprites, sandbox.machine_name)

    state = %{
      conversation_id: conv.id,
      sandbox_id: sandbox.id,
      user_id: user.id,
      handle: handle,
      sandbox_started_at: DateTime.utc_now(),
      last_activity_at: DateTime.add(DateTime.utc_now(), -120),
      current_turn: nil,
      acp_peer: nil,
      acp_peer_mon: nil,
      current_command: :adapter,
      current_command_ref: nil,
      autonomous_quiet: nil
    }

    stub(Managoat.Sandbox, :supports?, fn :sprites, :suspend -> false end)
    %{user: user, sandbox: sandbox, conv: conv, handle: handle, state: state}
  end

  # One test, not one per capacity: since ADR 0058 stage 8a the bound is the
  # conversation's runtime, read by the owner under the lock, so a caller has no
  # capacity to pass and the fence is checked before any count is made.
  test "reclaim fences admission before provider destruction", ctx do
    expect(Managoat.Sandbox, :destroy, fn handle ->
      assert handle == ctx.handle
      refute Repo.in_transaction?()
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      assert active_sandbox_count(ctx.user.id) == 1
      assert {:error, :sandbox_unavailable} = admit(ctx)
      :ok
    end)

    assert :ok = Lifecycle.destroy(ctx.conv.id, ctx.sandbox.id, ctx.handle, :idle)
    assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "terminated"
    assert active_sandbox_count(ctx.user.id) == 0

    assert Repo.aggregate(
             from(t in Conversations.Turn, where: t.conversation_id == ^ctx.conv.id),
             :count
           ) == 0

    assert [event] =
             Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")

    assert event.actor == "system:conversation_server"
    assert event.metadata["reason"] == "idle"
  end

  test "the server fences before closing its adapter and records one request", ctx do
    expect(Managoat.Sandbox, :close_stdin, fn :adapter ->
      refute Repo.in_transaction?()
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
      assert {:error, :sandbox_unavailable} = admit(ctx)
      :ok
    end)

    expect(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    expect(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert {:stop, :normal, stopped} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert stopped.current_command == nil
    assert stopped.handle == nil
    assert [_] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.teardown_requested")
  end

  test "the server's fence carries its expiry as the row's destroy reason", ctx do
    # ADR 0058 stage 9a: the fence stamps `transition_reason`, and an owner that
    # dies between the fence and its own intent stamp leaves that value for
    # `SandboxReaper`'s driver to record on `sandbox.destroyed`. A caller that
    # stopped passing it would have the fence fall back to `teardown`. The row
    # cannot show that here — the protocol's stamp rewrites the reason a step
    # later — so this pins what `prepare_destroy/2` hands the fence, recorded
    # inside the stub and asserted outside it (the protocol rescues a raise).
    test = self()

    expect(Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
      send(test, {:fence_opts, opts})
      Mimic.call_original(Lifecycle, :fence_sandbox_for_teardown, [sandbox, opts])
    end)

    stub(Managoat.Sandbox, :close_stdin, fn :adapter -> :ok end)
    stub(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

    assert {:stop, :normal, _} = ConversationServer.handle_info(:lifecycle_check, ctx.state)

    assert_received {:fence_opts, opts}
    assert opts[:transition_reason] == :idle
  end

  for sandbox? <- [true, false] do
    test "an enclosing transaction refuses destruction with sandbox=#{sandbox?}", ctx do
      reject(Managoat.Sandbox, :destroy, 1)
      sandbox_id = if unquote(sandbox?), do: ctx.sandbox.id

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 Lifecycle.destroy(ctx.conv.id, sandbox_id, ctx.handle, :idle)
               end)

      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"
    end
  end

  test "a refused server reclaim retains its adapter and does not report completion", ctx do
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:ok, {:noreply, unchanged}} =
             Repo.transaction(fn ->
               ConversationServer.handle_info(:lifecycle_check, ctx.state)
             end)

    assert unchanged == ctx.state
    refute Fountain.Machines.Lease.get(ctx.sandbox.id).transition == "destroying"

    refute Repo.exists?(
             from(e in Conversations.LogEvent,
               where:
                 e.conversation_id == ^ctx.conv.id and e.stage == "sandbox" and e.state == "done"
             )
           )
  end

  test "a missing sandbox refuses preparation without touching the adapter", ctx do
    Repo.delete!(ctx.sandbox)
    reject(Managoat.Sandbox, :close_stdin, 1)
    reject(Managoat.Sandbox, :destroy, 1)
    assert {:noreply, unchanged} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert unchanged == ctx.state
  end

  test "a refusal after adapter shutdown keeps the fenced machine for retry", ctx do
    # The pre-check fence commits, the server closes its adapter, and the
    # destroy is then refused — the shape that must leave a fenced, `ready`
    # machine for a retry rather than a half-torn-down one.
    #
    # The refusal used to be the *second* fence call, stubbed to `:not_found`.
    # Since ADR 0058 stage 9a there is no second call: the pre-check stamps
    # `transition: "destroying"`, so `Machines.Destroy` continues from the
    # stamp instead of fencing again. So the refusal is now what the protocol
    # actually refuses with on this path — another owner holding the machine —
    # which reaches the server as the same `{:error, _}` from the same call.
    expect(Lifecycle, :fence_sandbox_for_teardown, fn sandbox, opts ->
      Mimic.call_original(Lifecycle, :fence_sandbox_for_teardown, [sandbox, opts])
    end)

    expect(Fountain.Machines.Destroy, :run, fn _id, _opts -> {:error, :machine_busy} end)

    expect(Managoat.Sandbox, :close_stdin, fn :adapter -> :ok end)
    expect(Managoat.Sandbox, :stop_command, fn :adapter -> :ok end)
    reject(Managoat.Sandbox, :destroy, 1)

    assert {:noreply, retry} = ConversationServer.handle_info(:lifecycle_check, ctx.state)
    assert retry.current_command == nil
    assert retry.handle == ctx.handle
    fenced = Fountain.Machines.Lease.get(ctx.sandbox.id)
    assert fenced.transition == "destroying"
    assert fenced.status == "ready"
    # And the stamp the pre-check wrote is still on the row, which is what the
    # retry — this server's next tick, or `SandboxReaper`'s driver — continues
    # from once the columns are gone.
    assert fenced.transition == "destroying"
    assert active_sandbox_count(ctx.user.id) == 1

    refute Repo.exists?(
             from(e in Conversations.LogEvent,
               where:
                 e.conversation_id == ^ctx.conv.id and e.stage == "sandbox" and e.state == "done"
             )
           )
  end

  defp admit(ctx) do
    Conversations._unsafe_create_turn_on_sandbox(
      %{conversation_id: ctx.conv.id, turn_number: 1, status: "running", prompt: "late"},
      ctx.sandbox.id
    )
  end
end
