defmodule Fountain.WorkspaceLifecycleTest do
  @moduledoc """
  The conversation lifecycle reading the workspace (ADR 0097, step 4): what
  ending a conversation does to an implicit and an explicit workspace's
  machine, the ended implicit workspace's row, and the max-lifetime ceiling
  splitting by kind in the reaper.

  Explicit workspaces have no API until step 5, so these make one by flipping
  the flag (`explicit_workspace!/1`).
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.{Sandbox, Termination, Turn}
  alias Fountain.Machines.{Binding, Lease, Machine}
  alias Fountain.Workers.SandboxReaper
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Workspace

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, agent_id: agent.id, status: "ready")
    conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    on_exit(fn -> stop_machine(sandbox.id) end)

    {:ok, user: user, agent: agent, sandbox: sandbox, conv: conv}
  end

  defp stop_machine(sandbox_id) do
    case Machine.whereis(sandbox_id) do
      nil ->
        :ok

      pid ->
        ref = Process.monitor(pid)
        DynamicSupervisor.terminate_child(Fountain.MachineSupervisor, pid)

        receive do
          {:DOWN, ^ref, :process, ^pid, _} -> :ok
        after
          2_000 -> Process.demonitor(ref, [:flush])
        end
    end
  end

  defp workspace(sandbox), do: Repo.get(Workspace, sandbox.workspace_id)

  defp with_bounds(pairs, fun) do
    previous = Enum.map(pairs, fn {k, _} -> {k, Application.get_env(:fountain, k)} end)
    Enum.each(pairs, fn {k, v} -> Application.put_env(:fountain, k, v) end)

    try do
      fun.()
    after
      Enum.each(previous, fn {k, v} -> Application.put_env(:fountain, k, v) end)
    end
  end

  defp age(sandbox, hours) do
    at = DateTime.utc_now() |> DateTime.add(-hours * 3600, :second) |> DateTime.truncate(:second)

    Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
      set: [inserted_at: at, updated_at: at]
    )
  end

  describe "machine_kind/1" do
    test "is the workspace's flag, and implicit for a machine from before workspaces", ctx do
      assert Workspaces.machine_kind(ctx.sandbox) == :implicit
      assert Workspaces.machine_kind(explicit_workspace!(ctx.sandbox)) == :explicit
      assert Workspaces.machine_kind(%Sandbox{workspace_id: nil}) == :implicit
      assert Workspaces.machine_kind(%Sandbox{workspace_id: Ecto.UUID.generate()}) == :implicit
    end
  end

  describe "an ended implicit workspace" do
    test "is deleted once its conversation and its machine have both gone", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})

      # The conversation still live: the workspace is kept for its next
      # prompt, which builds the next machine in it.
      assert :ok = Workspaces.release_ended(ctx.sandbox.id)
      assert workspace(ctx.sandbox)

      {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "terminated"})
      assert :ok = Workspaces.release_ended(ctx.sandbox.id)

      refute workspace(ctx.sandbox)
      assert Repo.reload!(ctx.sandbox).workspace_id == nil
      assert Repo.reload!(ctx.conv).workspace_id == nil
    end

    test "is kept while its machine is live, whatever its conversation says", ctx do
      {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "terminated"})
      assert :ok = Workspaces.release_ended(ctx.sandbox.id)
      assert workspace(ctx.sandbox)
    end

    test "is ended by a terminate with no server, with its machine", ctx do
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      capture_log(fn -> assert :ok = Termination.terminate_conversation(ctx.conv.id) end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      refute workspace(ctx.sandbox)
    end

    test "is ended by a background destroy too, whichever finishes last", ctx do
      test = self()

      stub(Managoat.Sandbox, :destroy, fn _ ->
        send(test, :destroyed)
        :ok
      end)

      Mimic.set_mimic_global()

      capture_log(fn ->
        assert :ok = Termination.terminate_conversation(ctx.conv.id, destroy: :background)
        assert_receive :destroyed, 2_000
        # The task's release runs after the destroy commits.
        wait_until(fn -> is_nil(workspace(ctx.sandbox)) end)
      end)
    end

    test "an explicit workspace with an owner is never ended by it", ctx do
      explicit_workspace!(ctx.sandbox)
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})
      {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "terminated"})

      assert :ok = Workspaces.release_ended(ctx.sandbox.id)
      _ = Workspaces._unsafe_sweep_ended()
      assert workspace(ctx.sandbox)
    end

    test "the reaper's sweep collects leftovers, including ownerless ones", ctx do
      # A row a lost wake race left (no conversation, no machine), and an
      # explicit workspace whose account went while its machine's destroy
      # failed (#2329), once that machine is terminal.
      leftover = insert_workspace(user_id: ctx.user.id)

      other_user = insert_verified_user()
      ownerless = insert_workspace(user_id: other_user.id, implicit: false, name: "kept")

      orphan =
        insert_sandbox(user_id: other_user.id, workspace_id: ownerless.id, status: "terminated")

      Repo.update_all(from(w in Workspace, where: w.id == ^ownerless.id), set: [user_id: nil])

      # Live: kept.
      assert workspace(ctx.sandbox)

      # At least these two: the database may hold other tests' committed rows.
      assert SandboxReaper.sweep_ended_workspaces() >= 2
      refute Repo.get(Workspace, leftover.id)
      refute Repo.get(Workspace, ownerless.id)
      assert Repo.reload!(orphan).workspace_id == nil
      assert workspace(ctx.sandbox)
    end
  end

  describe "detach on an explicit workspace" do
    setup ctx do
      explicit_workspace!(ctx.sandbox)
      :ok
    end

    test "ends the binding and keeps the machine, with nothing written to it", ctx do
      reject(&Managoat.Sandbox.destroy/1)

      for destroy <- [true, false] do
        assert {:ok, :detached} =
                 Machine.detach(ctx.sandbox.id,
                   conversation_id: ctx.conv.id,
                   actor: "self",
                   destroy: destroy
                 )
      end

      sandbox = Lease.get(ctx.sandbox.id)
      assert sandbox.status == "ready"
      assert is_nil(sandbox.transition)
      assert Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.") == []
    end

    test "does not wait for another conversation's operation on the machine", ctx do
      {:ok, _epoch} = Lease.claim(ctx.sandbox.id)
      started = System.monotonic_time(:millisecond)

      assert {:ok, :detached} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, busy_wait_ms: 2_000)

      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "refuses a conversation no longer bound to the machine, and a caller that left", ctx do
      other = insert_conversation(user_id: ctx.user.id, status: "idle")

      assert {:error, :sandbox_unavailable} =
               Binding.detach(ctx.sandbox.id, conversation_id: other.id)

      past = DateTime.add(DateTime.utc_now(), -5, :second)

      assert {:error, :detach_expired} =
               Binding.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, deadline: past)
    end

    test "a terminate with no server keeps the machine and its workspace", ctx do
      test = self()
      stub(Managoat.Sandbox, :destroy, fn _ -> send(test, :destroyed) && :ok end)
      stub(Managoat.Sandbox, :list_sessions, fn _ -> {:ok, []} end)
      stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)
      Mimic.set_mimic_global()

      assert :ok = Termination.terminate_conversation(ctx.conv.id)

      assert Repo.reload!(ctx.conv).status == "terminated"
      assert Repo.reload!(ctx.sandbox).status == "ready"
      assert workspace(ctx.sandbox)
      refute_receive :destroyed, 200
    end
  end

  describe "tidying a kept machine for a conversation with no server" do
    setup ctx do
      explicit_workspace!(ctx.sandbox)
      home = "/home/sprite/.managoat/c/#{ctx.conv.id}"
      conv = ctx.conv |> Ecto.Changeset.change(config_home: home) |> Repo.update!()
      {:ok, conv: conv, home: home}
    end

    test "stops only the conversation's own adapter sessions and removes its home", ctx do
      test = self()
      mine = Fountain.Conversations.Identity.tag_command(ctx.conv.id, "claude-agent-acp", [])
      theirs = Fountain.Conversations.Identity.tag_command(Ecto.UUID.generate(), "codex", [])
      command = fn {cmd, args} -> Enum.join([cmd | args], " ") end

      stub(Managoat.Sandbox, :list_sessions, fn _ ->
        {:ok,
         [
           %Managoat.Sandbox.Session{id: "mine", command: command.(mine)},
           %Managoat.Sandbox.Session{id: "theirs", command: command.(theirs)}
         ]}
      end)

      stub(Managoat.Sandbox, :attach, fn _handle, id, _opts ->
        send(test, {:reaped, id})
        {:error, :gone}
      end)

      home = ctx.home

      expect(Managoat.Sandbox, :exec, fn _h, "bash", ["-c", script], _o ->
        assert script == "rm -rf -- '#{home}'"
        {:ok, "", 0}
      end)

      assert :ok = Termination.release_kept_now(ctx.conv, ctx.sandbox.id)
      assert_received {:reaped, "mine"}
      refute_received {:reaped, "theirs"}
    end

    test "leaves a parked machine parked", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      reject(&Managoat.Sandbox.list_sessions/1)
      reject(&Managoat.Sandbox.exec/4)
      assert :ok = Termination.release_kept_now(ctx.conv, ctx.sandbox.id)
    end
  end

  describe "the reaper at the ceiling" do
    test "parks an explicit workspace's machine, interrupting the turns left on it", ctx do
      explicit_workspace!(ctx.sandbox)
      age(ctx.sandbox, 48)
      # A turn nothing is driving: its server died mid-turn.
      turn = insert_turn(ctx.conv, %{status: "running", started_at: DateTime.utc_now()})
      reject(&Managoat.Sandbox.destroy/1)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn ->
          assert {1, 0, 0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
        end)
      end)

      assert Repo.reload!(ctx.sandbox).status == "suspended"
      assert %Turn{status: "interrupted"} = Repo.reload!(turn)

      assert [event] =
               Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.suspended")

      assert event.metadata["reason"] == "max_lifetime"
    end

    test "destroys an implicit workspace's machine, as it always has", ctx do
      age(ctx.sandbox, 48)
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)
      reject(&Managoat.Sandbox.suspend/1)

      with_bounds([sandbox_idle_timeout_minutes: 0, sandbox_max_lifetime_hours: 24], fn ->
        capture_log(fn ->
          assert {0, 1, 0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
        end)
      end)

      assert Repo.reload!(ctx.sandbox).status == "terminated"
      # The conversation stays, so its workspace does too: the next prompt
      # builds its next machine there.
      assert Repo.reload!(ctx.conv).status == "idle"
      assert workspace(ctx.sandbox)
    end

    test "parks an explicit workspace's machine with no conversation left on it", ctx do
      explicit_workspace!(ctx.sandbox)
      {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "terminated"})
      age(ctx.sandbox, 3)
      stub(Managoat.Sandbox, :suspend, fn _ -> :ok end)

      with_bounds([sandbox_idle_timeout_minutes: 60, sandbox_max_lifetime_hours: 0], fn ->
        capture_log(fn ->
          assert {1, 0, 0, 0} = SandboxReaper.sweep_abandoned_sandboxes()
        end)
      end)

      assert Repo.reload!(ctx.sandbox).status == "suspended"
    end
  end

  describe "review of step 4a" do
    test "a workspace whose lease is still held is not deleted yet", ctx do
      # A destroy writes its machine terminal before it releases the lease.
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})
      {:ok, _} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "terminated"})
      put_lease(ctx.sandbox.id, lease_epoch: 3, lease_node: live_lease_holder())

      assert :ok = Workspaces.release_ended(ctx.sandbox.id)
      assert workspace(ctx.sandbox)

      put_lease(ctx.sandbox.id, lease_node: nil)
      assert :ok = Workspaces.release_ended(ctx.sandbox.id)
      refute workspace(ctx.sandbox)
    end

    test "an explicit detach does not queue behind another operation in the owner", ctx do
      explicit_workspace!(ctx.sandbox)
      test = self()

      # A park holds the owner process at the provider.
      stub(Managoat.Sandbox, :suspend, fn _ ->
        send(test, :suspending)
        Process.sleep(1_500)
        :ok
      end)

      {:ok, owner} = Machine.ensure_started(ctx.sandbox.id)
      Mimic.allow(Managoat.Sandbox, self(), owner)
      sandbox_id = ctx.sandbox.id

      park =
        Task.async(fn ->
          capture_log(fn ->
            Machine.park(sandbox_id, actor: "system:sandbox_reaper", reason: :idle)
          end)
        end)

      assert_receive :suspending, 2_000
      started = System.monotonic_time(:millisecond)

      assert {:ok, :detached} =
               Machine.detach(ctx.sandbox.id, conversation_id: ctx.conv.id, actor: "self")

      assert System.monotonic_time(:millisecond) - started < 1_000
      Task.await(park, 5_000)
    end

    test "a kept machine is not tidied while an owner operates on it", ctx do
      explicit_workspace!(ctx.sandbox)
      put_lease(ctx.sandbox.id, transition: "parking", transition_reason: "idle")
      reject(&Managoat.Sandbox.list_sessions/1)
      reject(&Managoat.Sandbox.exec/4)

      assert :ok = Termination.release_kept_now(ctx.conv, ctx.sandbox.id)

      put_lease(ctx.sandbox.id,
        transition: nil,
        transition_reason: nil,
        lease_node: live_lease_holder()
      )

      assert :ok = Termination.release_kept_now(ctx.conv, ctx.sandbox.id)
    end

    test "a parked explicit machine is resumed through its owner before a reattach", ctx do
      {:ok, parked} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      test = self()

      stub(Machine, :ensure_up, fn id, opts ->
        send(test, {:ensure_up, id, opts[:requesting_conversation_id]})
        {:ok, _} = update_sandbox(parked, %{status: "ready"})
        {:ok, :resumed}
      end)

      # Implicit: confirmed as it always was, no resume.
      assert {:ok, ^parked} = Fountain.Conversations.Reattachment.awake(parked, ctx.conv.id)
      refute_received {:ensure_up, _, _}

      explicit_workspace!(parked)

      assert {:ok, %Sandbox{status: "ready"}} =
               Fountain.Conversations.Reattachment.awake(parked, ctx.conv.id)

      sandbox_id = parked.id
      conv_id = ctx.conv.id
      assert_received {:ensure_up, ^sandbox_id, ^conv_id}
    end

    test "a reattach does not confirm a parked explicit machine ready", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})

      # Implicit: confirmed as it always was.
      assert {:ok, :confirmed} =
               Fountain.Machines.Provision.confirm_up(ctx.sandbox.id,
                 actor: "system:conversation_server"
               )

      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      explicit_workspace!(ctx.sandbox)

      assert {:error, :sandbox_unavailable} =
               Fountain.Machines.Provision.confirm_up(ctx.sandbox.id,
                 actor: "system:conversation_server"
               )

      assert Repo.reload!(ctx.sandbox).status == "suspended"
    end

    test "an idle park waits for a co-tenant that is mid-wake", ctx do
      explicit_workspace!(ctx.sandbox)
      other = insert_conversation(user_id: ctx.user.id, sandbox: ctx.sandbox, status: "idle")
      test = self()

      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Fountain.ConversationRegistry, other.id, :setting_up)
           send(test, :registered)
           Process.sleep(:infinity)
         end}
      )

      assert_receive :registered
      reject(&Managoat.Sandbox.suspend/1)

      # The idle window off, so the co-tenant's row activity is not what refuses.
      with_bounds([sandbox_idle_timeout_minutes: 0], fn ->
        assert {:error, :machine_occupied} =
                 Fountain.Machines.Park.run(ctx.sandbox.id,
                   actor: "system:conversation_server",
                   reason: :idle,
                   requesting_conversation_id: ctx.conv.id
                 )
      end)
    end

    test "a destroy's notice reaches its requester too", ctx do
      test = self()

      start_supervised!(
        {Task,
         fn ->
           {:ok, _} = Registry.register(Fountain.ConversationRegistry, ctx.conv.id, nil)
           send(test, :registered)
           receive do: (msg -> send(test, {:told, msg}))
         end}
      )

      assert_receive :registered
      stub(Managoat.Sandbox, :destroy, fn _ -> :ok end)

      capture_log(fn ->
        assert {:ok, :destroyed} =
                 Fountain.Machines.Destroy.run(ctx.sandbox.id,
                   actor: "system:conversation_server",
                   reason: :idle,
                   notify: {ctx.conv.id, "reclaimed", "idle", "why"}
                 )
      end)

      sandbox_id = ctx.sandbox.id

      assert_receive {:told,
                      {:"$gen_cast", {:machine_gone, ^sandbox_id, "reclaimed", "idle", "why"}}}
    end

    test "a wake into an explicit workspace waits out a co-tenant's operation", ctx do
      explicit_workspace!(ctx.sandbox)
      test = self()

      # A co-tenant's owner operation, holding the workspace's lease briefly.
      holder =
        spawn(fn ->
          {:ok, epoch} = Fountain.Machines.Lease.claim(ctx.sandbox.id)
          send(test, :held)
          Process.sleep(800)
          Fountain.Machines.Lease.release(ctx.sandbox.id, epoch)
          send(test, :released)
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), holder)
      assert_receive :held, 2_000

      stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running}} end)

      stub_server_start(fn _sup, _spec ->
        send(test, :started)
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      Mimic.set_mimic_global()

      capture_log(fn ->
        assert {:ok, _} = Fountain.Conversations.Wake.wake_conversation(ctx.conv.id)
      end)

      assert_received :released
      assert_received :started
    end

    test "a wake into an implicit workspace still answers a held lease at once", ctx do
      test = self()

      holder =
        spawn(fn ->
          {:ok, epoch} = Fountain.Machines.Lease.claim(ctx.sandbox.id)
          send(test, :held)

          receive do
            :go -> Fountain.Machines.Lease.release(ctx.sandbox.id, epoch)
          end
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, self(), holder)
      assert_receive :held, 2_000

      assert {:error, :sandbox_unavailable} =
               Fountain.Conversations.Wake.wake_conversation(ctx.conv.id)

      send(holder, :go)
    end
  end

  defp wait_until(fun, tries \\ 40) do
    cond do
      fun.() -> :ok
      tries == 0 -> flunk("condition never held")
      true -> Process.sleep(50) && wait_until(fun, tries - 1)
    end
  end
end
