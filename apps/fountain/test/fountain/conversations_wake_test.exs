defmodule Fountain.ConversationsWakeTest do
  use Fountain.DataCase, async: true
  use Mimic

  setup do
    stub(Managoat.Sandbox.Sprites, :exec, fn _, "true", [], _ -> {:ok, "", 0} end)
    :ok
  end

  alias Fountain.Conversations
  alias Fountain.Conversations.Wake

  # wake_conversation/2 — resume, provider stickiness and the sandbox it lands on.
  # Split out of the 2,215-line conversations_context_test.exs (#899): ExUnit
  # parallelises across modules, never within one, so that single module was a
  # 29.4s floor for whichever partition drew it.

  # wake_conversation/2
  # ────────────────────────────────────────────────────────────────────────────

  describe "wake_conversation/2" do
    test "returns {:error, :not_found} when conversation does not exist" do
      assert {:error, :not_found} = Wake.wake_conversation(Ecto.UUID.generate())
    end

    test "returns {:error, :gone} when conversation status is terminated" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "terminated")

      assert {:error, :gone} = Wake.wake_conversation(conv.id)
    end

    test "returns {:error, :gone} when conversation status is failed" do
      user = insert_verified_user()
      conv = insert_conversation(user_id: user.id, status: "failed")

      assert {:error, :gone} = Wake.wake_conversation(conv.id)
    end

    test "an idle conversation whose sandbox was reclaimed is still resumable" do
      # The case #167 created and the reason `completed` was never needed:
      # reclaiming an idle sandbox leaves the conversation resumable rather
      # than closing it, so waking it must not be refused as :gone.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, status: "terminated")
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      # The wake succeeds here, so it starts a server. Without this it is a
      # real one under the shared conversation supervisor, with no sandbox connection
      # in an async test and `restart: :transient` to put it back after every
      # raise (#1862).
      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      refute match?({:error, :gone}, Wake.wake_conversation(conv.id))
    end

    test "returns {:error, :no_agent} when conversation has no agent_id" do
      user = insert_verified_user()
      # insert_conversation does not set an agent by default, so agent_id is nil
      conv = insert_conversation(user_id: user.id, status: "idle")

      assert {:error, :no_agent} = Wake.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} reusing existing sandbox when sprite is still alive" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-alive")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "test-sprite-alive"}}}
      end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Wake.wake_conversation(conv.id)
    end

    test "a reuse that loses the start race hands the prompt to the winner (#667)" do
      # Two concurrent wakes of the same suspended/ready sandbox: the loser
      # used to get the raw {:error, {:already_started, pid}} back from
      # start_conversation_server, so the prompt was silently dropped instead
      # of reaching the winner's server.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-race")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      winner = spawn(fn -> Process.sleep(:infinity) end)
      test_pid = self()

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :running, raw: %{name: "test-sprite-race"}}}
      end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:error, {:already_started, winner}}
      end)

      stub(Fountain.Conversations.ConversationServer, :queue_initial_prompt, fn pid,
                                                                                prompt,
                                                                                _images ->
        send(test_pid, {:queued, pid, prompt})
        :ok
      end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id, "hello")
      assert_receive {:queued, ^winner, "hello"}

      # Reuse touches no row — the conversation still names the sandbox it
      # started with.
      assert woken.sandbox_id == sandbox.id
    end

    test "waking a suspended sandbox flips it to ready and stamps the clock" do
      # The core of decisions/0017: the parked sprite is reused, re-added to
      # the quota, and the max-lifetime ceiling restarts from the wake.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-parked")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{name: "test-sprite-parked"}}}
      end)

      # resume/1 is the explicit wake call (a probe on Sprites); the adapter
      # is the stubbing seam, so it needs its own stub here.
      stub(Managoat.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id)
      # Same sandbox — no fresh sprite was provisioned.
      assert woken.sandbox_id == sandbox.id

      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "ready"
      assert %DateTime{} = reloaded.last_resumed_at
    end

    test "waking a suspended sandbox records sandbox.resumed" do
      # New in ADR 0058 stage 7a. `main` recorded nothing when a parked machine
      # came back, so a tenant's trail showed the suspend and not the wake.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-audited")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{}}}
      end)

      stub(Managoat.Sandbox.Sprites, :resume, fn handle -> {:ok, handle} end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _woken} = Wake.wake_conversation(conv.id)

      assert [event] = Fountain.Audit.list_for_user(user.id, action_prefix: "sandbox.resumed")
      assert event.actor == "system:wake"
      assert event.resource_id == sandbox.id
      assert event.metadata["conversation_id"] == conv.id
    end

    test "a ready row whose machine the provider says is parked is woken, not just reused" do
      # The 6b review's other half (ADR 0058 stage 7a). A park whose finalize
      # was lost leaves a `ready` row over a machine E2B calls `paused`;
      # `main` reused it on any `{:ok, _info}` and
      # handed the conversation a handle to a machine that was not running.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(user_id: user.id, status: "ready", machine_name: "test-sprite-stopped")

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:ok, %{status: :suspended, raw: %{}}}
      end)

      test = self()

      stub(Managoat.Sandbox.Sprites, :resume, fn handle ->
        send(test, :resumed)
        {:ok, handle}
      end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id)
      assert woken.sandbox_id == sandbox.id
      assert_receive :resumed
    end

    test "a ready row the provider says is running is reused without a resume" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      sandbox =
        insert_sandbox(user_id: user.id, status: "ready", machine_name: "test-sprite-running")

      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :running, raw: %{}}} end)
      reject(&Managoat.Sandbox.Sprites.resume/1)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _woken} = Wake.wake_conversation(conv.id)
    end

    test "waking a suspended sandbox re-runs the fleet ceiling" do
      # A parked sprite is free; waking it is compute again. A full fleet must
      # refuse it, exactly as if this were a new conversation.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      fill_fleet()

      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-capped")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:ok, %{status: :unknown, raw: %{}}} end)

      assert {:error, :fleet_full} = Wake.wake_conversation(conv.id)
      # Refused means still parked — the row must not be half-woken.
      assert Repo.reload(sandbox).status == "suspended"
    end

    test "a transient sprite probe failure does not give up a suspended sandbox" do
      # Falling to :create_new would retire the row and route the still-live
      # sprite — the agent's memory — to the reaper's destroy pass. Only a
      # definitive not-found may do that; anything else fails retryably.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-blip")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, {:unavailable, :timeout}} end)

      assert {:error, :sprite_probe_failed} = Wake.wake_conversation(conv.id)
      assert Repo.reload(sandbox).status == "suspended"
    end

    test "a transient sprite probe failure does not give up a ready sandbox either (#799)" do
      # A `ready` row whose server is gone (deploy, crash, partition) is the
      # same parked disk as a suspended one. Until #799 only `suspended` was
      # protected; a `ready` row fell to :create_new, was marked terminated,
      # and the reaper destroyed a sprite that was fine.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-blip-ready")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle ->
        {:error, {:unavailable, %Req.TransportError{reason: :nxdomain}}}
      end)

      reject(&DynamicSupervisor.start_child/2)

      assert {:error, :sprite_probe_failed} = Wake.wake_conversation(conv.id)
      reloaded = Repo.reload(sandbox)
      assert reloaded.status == "ready"
      assert is_nil(reloaded.terminated_at)
      assert Repo.reload(conv).sandbox_id == sandbox.id
    end

    test "a definitively gone sprite retires the suspended sandbox and provisions fresh" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-vanished")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "suspended"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id)
      assert woken.sandbox_id != sandbox.id
      assert Repo.reload(sandbox).status == "terminated"
    end

    test "returns {:ok, conv} creating fresh sandbox when sprite is gone" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-gone")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      fake_client = %{}

      stub(Managoat.Sandbox.Sprites, :get, fn _handle -> {:error, :not_found} end)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Wake.wake_conversation(conv.id)
    end

    test "returns {:ok, conv} creating fresh sandbox when sandbox is pending (not ready)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)

      # A `pending` sandbox with no server anywhere: the provision died with
      # its BEAM. After the registry settle window (#800) the wake gives up
      # waiting and provisions fresh.
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id)
      assert woken.sandbox_id != sandbox.id
    end

    test "a pending sandbox whose server appears during the settle window is handed the prompt, not raced (#800)" do
      # `session/new` (POST /api/conversations) starts the server via the conversation supervisor,
      # which may place it on another pod; the first prompt arrives ~30 ms
      # later on this pod, sees a `pending` row and — before #800 — missed
      # the registry and took :create_new: two servers, two sprites, ~21 s of
      # provisioning each, and a name conflict that killed the loser after
      # the fact, leaving an orphan `ready` row. The prompt path now waits
      # for the registry to catch up and hands the prompt to the server it
      # finds.
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      test = self()

      # A stand-in for the first server: it only has to receive the prompt
      # cast and relay it.
      late_server =
        spawn_link(fn ->
          receive do
            {:"$gen_cast", {:initial_prompt, prompt, images}} ->
              send(test, {:handed_off, prompt, images})
          end
        end)

      # The registry catches up on the second poll. This used to be a
      # stand-in that slept 40 ms before registering for real, which made the
      # test a wall-clock race: a loaded runner could burn the whole settle
      # window before the sleep returned, the wake would correctly give up,
      # and the `reject` below would fail on a green build (#921). Deciding
      # per lookup which poll finds the server drives the same branch with no
      # clock in it.
      {:ok, polls} = Agent.start_link(fn -> 0 end)

      stub(Registry, :lookup, fn Fountain.ConversationRegistry, _key ->
        case Agent.get_and_update(polls, &{&1, &1 + 1}) do
          0 -> []
          _ -> [{late_server, nil}]
        end
      end)

      # No second server, no second sandbox.
      reject(&DynamicSupervisor.start_child/2)

      assert {:ok, woken} = Wake.wake_conversation(conv.id, "hello")
      assert_receive {:handed_off, "hello", []}, 500

      # The first poll missed: the wake waited for the registry rather than
      # concluding the provision was dead on the strength of one lookup.
      assert Agent.get(polls, & &1) >= 2

      assert woken.sandbox_id == sandbox.id
      assert Repo.reload(sandbox).status == "pending"

      assert Repo.aggregate(
               from(s in Fountain.Conversations.Sandbox, where: s.user_id == ^user.id),
               :count
             ) == 1

      Process.exit(late_server, :kill)
    end

    test "returns {:ok, conv} when old sandbox is already terminated (mark_old_sandbox_terminated no-op)" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      sandbox = insert_sandbox(user_id: user.id, machine_name: "test-sprite-terminated")
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "terminated"})
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      # sandbox status is "terminated" (not "ready"), so maybe_reuse_sandbox returns :create_new,
      # which calls create_fresh_sandbox_and_start -> mark_old_sandbox_terminated(sandbox.id)
      # where the sandbox is already terminated, hitting the no-op branch
      assert {:ok, _conv} = Wake.wake_conversation(conv.id)
    end

    test "a fresh sandbox comes with a fresh implicit workspace, and the conversation moves to it" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      old_ws = insert_workspace(user_id: user.id, status: "ready")

      sandbox =
        insert_sandbox(user_id: user.id, workspace_id: old_ws.id, machine_name: "gone-sprite")

      {:ok, sandbox} = update_sandbox(sandbox, %{status: "terminated"})

      conv =
        insert_conversation(
          user_id: user.id,
          agent: agent,
          sandbox: sandbox,
          workspace_id: old_ws.id,
          status: "idle"
        )

      stub_server_start(fn _supervisor, _child_spec -> {:ok, spawn(fn -> :ok end)} end)

      assert {:ok, woken} = Wake.wake_conversation(conv.id)
      assert woken.sandbox_id != sandbox.id

      new_sandbox = Conversations._unsafe_get_sandbox!(woken.sandbox_id)
      assert woken.workspace_id == new_sandbox.workspace_id
      refute woken.workspace_id in [nil, old_ws.id]

      ws = Repo.get!(Fountain.Workspaces.Workspace, woken.workspace_id)
      assert ws.implicit and ws.user_id == user.id and ws.provider == new_sandbox.provider

      # The old pair is history and is left as it was.
      assert Repo.reload!(sandbox).workspace_id == old_ws.id
    end

    test "mark_old_sandbox_terminated handles deleted sandbox gracefully" do
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id)
      # sandbox remains "pending" so maybe_reuse_sandbox returns :create_new
      sandbox = insert_sandbox(user_id: user.id)
      conv = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

      # Point the conversation at a non-existent sandbox_id (bypassing FK) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil,
      # hitting the nil -> :ok branch (line 635).
      ghost_sandbox_id = Ecto.UUID.generate()
      {:ok, ghost_uuid_bin} = Ecto.UUID.dump(ghost_sandbox_id)
      {:ok, conv_id_bin} = Ecto.UUID.dump(conv.id)

      # Temporarily disable FK checks, update the conversation to reference a
      # non-existent sandbox_id, then re-enable. This simulates the case where
      # a sandbox was deleted out-of-band (e.g., admin cleanup) so that
      # mark_old_sandbox_terminated receives an id whose get_sandbox returns nil.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = replica", [])

      Ecto.Adapters.SQL.query!(
        Fountain.Repo,
        "UPDATE conversations SET sandbox_id = $1 WHERE id = $2",
        [ghost_uuid_bin, conv_id_bin]
      )

      # Also delete the original sandbox record now that the FK is no longer referenced.
      Ecto.Adapters.SQL.query!(Fountain.Repo, "SET session_replication_role = DEFAULT", [])
      Fountain.Repo.delete!(sandbox)

      stub_server_start(fn _supervisor, _child_spec ->
        {:ok, spawn(fn -> :ok end)}
      end)

      assert {:ok, _conv} = Wake.wake_conversation(conv.id)
    end
  end

  # ────────────────────────────────────────────────────────────────────────────
end
