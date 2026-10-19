defmodule Fountain.WorkspaceKnownLimitsTest do
  @moduledoc """
  #3001: the known limits ADR 0097's step 4 and 5 reviews left (#2992,
  #2993), each closed:

    * a second concurrent wake of one workspace no longer answers 503 while
      the first one's server holds the lease for a moment;
    * a config home left on a parked machine by a conversation that ended is
      removed on the next wake;
    * turns the rebuild's succession ends under its lock get their stage and
      their audit row;
    * a co-tenant's failed rebuild does not fail this conversation;
    * a failed rebuild records its own reason, not `:provision_raised`;
    * a prompt reported as not run carries its receipt and request id, and
      a provision that stands down for another owner reports a queued one
      rather than dropping it.

  The turn reason inside the automatic-rebuild window is pinned in
  `live_machine_loss_test.exs`.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import Ecto.Query
  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.{FreshProvision, PromptReceipt, Rebuild, Sandbox, Termination}
  alias Fountain.Conversations.{Turn, Wake}
  alias Fountain.Machines.{Machine, Provision}
  alias Managoat.Sandbox.Handle

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

  defp stages(conv_id, stage) do
    Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  defp eventually(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    case fun.() do
      falsy when falsy in [nil, false] ->
        if System.monotonic_time(:millisecond) < deadline do
          Process.sleep(25)
          eventually(fun, deadline)
        else
          flunk("condition never held")
        end

      value ->
        value
    end
  end

  # A co-tenant's server taking the workspace's lease for a moment, as a
  # reattach's `confirm_up/2` does, right after this wake found the machine up.
  defp lease_held_after_ensure_up(ctx, hold_ms) do
    test = self()

    stub(Machine, :ensure_up, fn sandbox_id, _opts ->
      holder =
        spawn(fn ->
          {:ok, epoch} = Fountain.Machines.Lease.claim(sandbox_id)
          send(test, :held)
          Process.sleep(hold_ms)
          Fountain.Machines.Lease.release(sandbox_id, epoch)
          send(test, :released)
        end)

      Ecto.Adapters.SQL.Sandbox.allow(Repo, test, holder)
      assert_receive :held, 2_000
      {:ok, :already_up}
    end)

    stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running}} end)
    ctx
  end

  describe "a second concurrent wake of one workspace" do
    test "waits out a co-tenant's moment on the lease at registration", ctx do
      explicit_workspace!(ctx.sandbox)
      test = self()
      lease_held_after_ensure_up(ctx, 800)

      stub_server_start(fn _sup, _spec ->
        send(test, :started)
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      Mimic.set_mimic_global()

      capture_log(fn ->
        assert {:ok, _} = Wake.wake_conversation(ctx.conv.id)
      end)

      assert_receive :released, 2_000
      assert_received :started
    end

    test "stops waiting when the holder retires the machine, and registers nothing on it",
         ctx do
      explicit_workspace!(ctx.sandbox)
      test = self()

      # The holder is retiring the machine (a co-tenant found it lost).
      stub(Machine, :ensure_up, fn sandbox_id, _opts ->
        holder =
          spawn(fn ->
            {:ok, epoch} = Fountain.Machines.Lease.claim(sandbox_id)

            Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox_id),
              set: [status: "terminated"]
            )

            send(test, :held)
            Process.sleep(1_500)
            Fountain.Machines.Lease.release(sandbox_id, epoch)
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, test, holder)
        assert_receive :held, 2_000
        {:ok, :already_up}
      end)

      stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running}} end)
      reject(&DynamicSupervisor.start_child/2)
      Mimic.set_mimic_global()

      started = System.monotonic_time(:millisecond)
      assert {:error, :sandbox_unavailable} = Wake.wake_conversation(ctx.conv.id)
      assert System.monotonic_time(:millisecond) - started < 1_000
    end

    test "a machine retired and let go between two polls is refused at the door", ctx do
      explicit_workspace!(ctx.sandbox)
      test = self()

      # The holder retires the machine and lets go right after the wake's
      # first refusal at the door, before the wait's own read, so only the
      # door's locked read on the retry can see it. Sequenced by messages,
      # not by time.
      stub(Machine, :ensure_up, fn sandbox_id, _opts ->
        holder =
          spawn(fn ->
            {:ok, epoch} = Fountain.Machines.Lease.claim(sandbox_id)
            send(test, {:held, self()})

            receive do
              :go -> :ok
            end

            Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox_id),
              set: [status: "terminated"]
            )

            Fountain.Machines.Lease.release(sandbox_id, epoch)
            send(test, :released)
          end)

        Ecto.Adapters.SQL.Sandbox.allow(Repo, test, holder)
        assert_receive {:held, ^holder}, 2_000
        Process.put(:holder, holder)
        {:ok, :already_up}
      end)

      # The wait's read after the first refusal still sees a `ready` row:
      # the holder is told to go only once that read has run.
      stub(Conversations, :register_server, fn sandbox_id, spec, opts ->
        result = Mimic.call_original(Conversations, :register_server, [sandbox_id, spec, opts])
        if opts == [], do: Process.put(:first_refused, result)
        result
      end)

      stub(Conversations, :_unsafe_get_sandbox, fn id ->
        result = Mimic.call_original(Conversations, :_unsafe_get_sandbox, [id])

        with holder when is_pid(holder) <- Process.get(:holder),
             {:error, :sandbox_unavailable} <- Process.delete(:first_refused) do
          send(holder, :go)
          assert_receive :released, 2_000
        end

        result
      end)

      stub(Managoat.Sandbox.Sprites, :get, fn _ -> {:ok, %{status: :running}} end)
      reject(&DynamicSupervisor.start_child/2)

      assert {:error, :sandbox_unavailable} = Wake.wake_conversation(ctx.conv.id)
      # The holder ran between the polls: the row the retry met was retired.
      assert Repo.reload!(ctx.sandbox).status == "terminated"
    end

    test "the door's refuse_terminal option refuses a retired row, and only with it", ctx do
      terminal = insert_sandbox(user_id: ctx.user.id, status: "terminated")
      test = self()

      stub(DynamicSupervisor, :start_child, fn _sup, _spec ->
        send(test, :started)
        {:ok, spawn(fn -> :ok end)}
      end)

      spec = {Task, fn -> :ok end}

      assert {:error, :sandbox_unavailable} =
               Conversations.register_server(terminal.id, spec, refuse_terminal: true)

      refute_received :started

      # Without it, a server is started on the retired row to find that out
      # for itself, as every other caller of the door has it.
      assert {:ok, _pid} = Conversations.register_server(terminal.id, spec)
      assert_received :started
    end

    test "an implicit machine's held lease is still answered at once", ctx do
      lease_held_after_ensure_up(ctx, 800)
      reject(&DynamicSupervisor.start_child/2)
      Mimic.set_mimic_global()

      assert {:error, :sandbox_unavailable} = Wake.wake_conversation(ctx.conv.id)
      assert_receive :released, 2_000
    end
  end

  describe "a config home left on a parked machine" do
    setup ctx do
      explicit_workspace!(ctx.sandbox)

      ended =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "terminated"
        )

      %{ended: ended}
    end

    test "is removed from the woken machine; a live conversation's is kept", ctx do
      test = self()
      unknown = Ecto.UUID.generate()
      # A 16-character name is not a conversation's, though Ecto would cast it.
      listing =
        Enum.join(
          [ctx.conv.id, ctx.ended.id, unknown, "not-a-conversation", "abcdefghijklmnop"],
          "\n"
        )

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", script], _opts ->
        send(test, {:exec, script})

        if String.starts_with?(script, "[ -d"),
          do: {:ok, listing <> "\n", 0},
          else: {:ok, "", 0}
      end)

      assert :ok = Termination.sweep_ended_homes(ctx.sandbox.id)

      assert_received {:exec, "[ -d" <> _}
      assert_received {:exec, "rm -rf -- " <> removed}

      assert removed =~ "/home/sprite/.managoat/c/#{ctx.ended.id}"
      assert removed =~ "/home/sprite/.managoat/c/#{unknown}"
      refute removed =~ ctx.conv.id
      refute removed =~ "not-a-conversation"
      refute removed =~ "abcdefghijklmnop"
    end

    test "nothing ended leaves nothing to remove", ctx do
      test = self()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", script], _opts ->
        send(test, {:exec, script})
        {:ok, ctx.conv.id <> "\n", 0}
      end)

      assert :ok = Termination.sweep_ended_homes(ctx.sandbox.id)
      assert_received {:exec, "[ -d" <> _}
      refute_received {:exec, "rm -rf" <> _}
    end

    test "a parked or an implicit machine is not touched", ctx do
      reject(&Managoat.Sandbox.exec/4)

      ctx.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
      assert :ok = Termination.sweep_ended_homes(ctx.sandbox.id)

      implicit = insert_sandbox(user_id: ctx.user.id, status: "ready")
      assert :ok = Termination.sweep_ended_homes(implicit.id)
    end

    test "the wake that resumed the machine starts the sweep; one that found it up does not",
         ctx do
      test = self()
      previous = Application.get_env(:fountain, :tidy_homes_after_resume)
      Application.put_env(:fountain, :tidy_homes_after_resume, true)
      on_exit(fn -> Application.put_env(:fountain, :tidy_homes_after_resume, previous) end)

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", script], _opts ->
        send(test, {:exec, script})
        {:ok, "", 0}
      end)

      Mimic.set_mimic_global()

      assert {:ok, :already_up} =
               Termination.tidy_after_resume({:ok, :already_up}, ctx.sandbox.id)

      assert {:error, :x} = Termination.tidy_after_resume({:error, :x}, ctx.sandbox.id)
      refute_receive {:exec, _}, 200

      assert {:ok, :resumed} = Termination.tidy_after_resume({:ok, :resumed}, ctx.sandbox.id)
      assert_receive {:exec, "[ -d" <> _}, 2_000
    end

    test "a wake's resume of the machine is what starts it, and only on an explicit one", ctx do
      test = self()
      previous = Application.get_env(:fountain, :tidy_homes_after_resume)
      Application.put_env(:fountain, :tidy_homes_after_resume, true)
      on_exit(fn -> Application.put_env(:fountain, :tidy_homes_after_resume, previous) end)

      stub(Machine, :ensure_up, fn _id, _opts -> {:ok, :resumed} end)

      stub(Managoat.Sandbox, :exec, fn handle, "bash", ["-c", script], _opts ->
        send(test, {:exec, handle.name, script})
        {:ok, "", 0}
      end)

      Mimic.set_mimic_global()

      implicit = insert_sandbox(user_id: ctx.user.id, status: "ready")
      assert {:ok, :resumed} = Wake.wake_suspended_sandbox(ctx.conv, implicit.id)
      refute_receive {:exec, _, _}, 300

      assert {:ok, :resumed} = Wake.wake_suspended_sandbox(ctx.conv, ctx.sandbox.id)
      name = ctx.sandbox.machine_name
      assert_receive {:exec, ^name, "[ -d" <> _}, 2_000
    end
  end

  describe "turns the succession ends under its lock" do
    test "get a turn stage and an audit row after the commit", ctx do
      explicit_workspace!(ctx.sandbox)

      # A turn admitted after the rebuild ended the old machine's turns and
      # before its lock: the owner's pass is skipped here to stand in for it.
      stub(Fountain.Machines.Admission, :end_turns_on, fn _id, _why, _opts -> :ok end)

      stub(Managoat.Sandbox, :create, fn provider, name ->
        {:ok, %Handle{provider: provider, name: name}}
      end)

      turn = insert_turn(ctx.conv, %{status: "running", started_at: DateTime.utc_now()})

      capture_log(fn ->
        assert {:ok, :rebuilt, %Sandbox{}, :built} =
                 Provision.rebuild(ctx.sandbox.id, fn _handle, _epoch -> {:ok, :built} end,
                   actor: "system:conversation_server",
                   environment: nil,
                   provider: :already_gone,
                   attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"}
                 )
      end)

      assert %Turn{status: "interrupted"} = Repo.reload!(turn)

      assert [{"interrupted", %{"reason" => "machine_destroyed", "turn_id" => turn_id}}] =
               stages(ctx.conv.id, "turn")

      assert turn_id == turn.id

      assert [audit] =
               Repo.all(
                 from(e in Fountain.Audit.Event,
                   where: e.action == "conversation.turn.orphaned" and e.resource_id == ^turn.id
                 )
               )

      assert audit.user_id == ctx.user.id
      assert audit.actor == "system:conversation_server"
      assert audit.metadata["reason"] == "machine_destroyed"
      assert audit.metadata["conversation_id"] == ctx.conv.id
    end
  end

  describe "a rebuild's failure" do
    # The server that rebuilt nothing of its own, with the conversation moved
    # by a co-tenant's rebuild to a row that then failed.
    setup ctx do
      explicit_workspace!(ctx.sandbox)
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})

      moved_to =
        insert_sandbox(
          user_id: ctx.user.id,
          workspace_id: ctx.sandbox.workspace_id,
          status: "failed"
        )

      ctx.conv
      |> Ecto.Changeset.change(sandbox_id: moved_to.id, status: "pending")
      |> Repo.update!()

      # The test process stands in for the server, whose process dictionary
      # `Rebuild.machine/2` writes the attempt to; it ends with the test.
      state = %{conversation_id: ctx.conv.id, sandbox_id: ctx.sandbox.id}
      %{moved_to: moved_to, state: state}
    end

    test "a co-tenant's failed row does not fail this conversation", ctx do
      capture_log(fn ->
        assert {:stop, :normal, _} =
                 Rebuild.failed(ctx.state, ctx.conv, :fenced, %{reason: "fenced"})
      end)

      conv = Repo.reload!(ctx.conv)
      assert conv.status == "idle"
      assert [{"failed", %{"reason" => "fenced", "retryable" => false}}] = stages(conv.id, "wake")
    end

    test "this attempt's own row fails the conversation, with the failure's reason", ctx do
      # This attempt's row, left mid-provision when its bracket unwound.
      ctx.moved_to |> Ecto.Changeset.change(status: "pending") |> Repo.update!()

      Process.put({Rebuild, :attempt}, ctx.moved_to.id)

      capture_log(fn ->
        assert {:stop, :normal, _} =
                 Rebuild.failed(ctx.state, ctx.conv, {:create, :boom}, %{reason: "boom"})
      end)

      failed = Fountain.Machines.Lease.get(ctx.moved_to.id)
      assert failed.status == "failed"
      assert failed.transition_reason =~ "create"
      refute failed.transition_reason =~ "provision_raised"
      assert Repo.reload!(ctx.conv).status == "failed"
    end

    test "the prompt it was started for is reported with its receipt", ctx do
      meta = PromptReceipt.accept(ctx.conv.id, client_request_id: "req-1")

      # The wake's cast, waiting in the stopping server's mailbox.
      send(self(), {:"$gen_cast", {:initial_prompt, "hello", [], meta}})

      capture_log(fn ->
        Rebuild.failed(ctx.state, ctx.conv, :fenced, %{reason: "fenced"})
      end)

      assert [{"failed", data}] = stages(ctx.conv.id, "wake")
      assert data["client_request_id"] == "req-1"
      assert data["prompt_receipt_id"] == meta[:prompt_receipt_id]
      refute PromptReceipt.pending?(ctx.conv.id, meta[:prompt_receipt_id])
      refute_received {:"$gen_cast", _}
    end
  end

  describe "a refused resume before a reattach" do
    test "reports its queued prompt with the receipt", ctx do
      explicit_workspace!(ctx.sandbox)
      suspended = ctx.sandbox |> Ecto.Changeset.change(status: "suspended") |> Repo.update!()
      stub(Machine, :ensure_up, fn _id, _opts -> {:error, :fleet_full} end)

      meta = PromptReceipt.accept(ctx.conv.id, client_request_id: "req-2")
      send(self(), {:"$gen_cast", {:initial_prompt, "hello", [], meta}})

      assert {:error, :fleet_full} =
               Fountain.Conversations.Reattachment.awake(suspended, ctx.conv.id)

      assert [{"failed", data}] = stages(ctx.conv.id, "wake")
      assert data["reason"] == "fleet_full"
      assert data["client_request_id"] == "req-2"
      assert data["prompt_receipt_id"] == meta[:prompt_receipt_id]
    end
  end

  test "an untaken machine reports a queued prompt, and nothing without one", ctx do
    Fountain.Conversations.Reattachment.untaken(ctx.conv.id, :claimed_elsewhere)
    assert stages(ctx.conv.id, "wake") == []

    meta = PromptReceipt.accept(ctx.conv.id, client_request_id: "req-3")
    send(self(), {:"$gen_cast", {:initial_prompt, "hello", [], meta}})
    Fountain.Conversations.Reattachment.untaken(ctx.conv.id, :already_terminal)

    assert [{"failed", data}] = stages(ctx.conv.id, "wake")
    assert data["reason"] == "machine_lost"
    assert data["retryable"] == true
    assert data["client_request_id"] == "req-3"
    _ = eventually(fn -> not PromptReceipt.pending?(ctx.conv.id, meta[:prompt_receipt_id]) end)
  end

  describe "a provision that stands down for another owner" do
    # `FreshProvision`'s silent arms: the machine is another owner's, so
    # nothing is said about it, but a prompt queued for this server dies with
    # its mailbox unless it is reported (#3001).
    for {answer, word} <- [
          {{:ok, :claimed_elsewhere}, "machine_busy"},
          {{:ok, :already_terminal}, "machine_lost"},
          {{:error, :sandbox_reset_pending}, "sandbox_unavailable"}
        ] do
      test "reports a queued prompt with its receipt on #{inspect(answer)}, and nothing without one",
           ctx do
        answer = unquote(Macro.escape(answer))
        word = unquote(word)
        stub(Machine, :provision, fn _id, _pipeline, _opts -> answer end)
        state = %{conversation_id: ctx.conv.id, sandbox_id: ctx.sandbox.id}
        run = fn -> FreshProvision.run(state, ctx.conv, ctx.sandbox, ctx.agent, nil, %{}) end

        assert {:stop, :normal, _} = run.()
        assert stages(ctx.conv.id, "wake") == []

        meta = PromptReceipt.accept(ctx.conv.id, client_request_id: "req-4")
        send(self(), {:"$gen_cast", {:initial_prompt, "hello", [], meta}})

        assert {:stop, :normal, _} = run.()

        assert [{"failed", data}] = stages(ctx.conv.id, "wake")
        assert data["reason"] == word
        assert data["retryable"] == true
        assert data["client_request_id"] == "req-4"
        assert data["prompt_receipt_id"] == meta[:prompt_receipt_id]
        refute PromptReceipt.pending?(ctx.conv.id, meta[:prompt_receipt_id])
        refute_received {:"$gen_cast", _}
      end
    end

    for status <- ["terminated", "failed"] do
      test "reports it as gone when the conversation is #{status}", ctx do
        stub(Machine, :provision, fn _id, _pipeline, _opts -> {:ok, :already_terminal} end)
        conv = ctx.conv |> Ecto.Changeset.change(status: unquote(status)) |> Repo.update!()
        meta = PromptReceipt.accept(conv.id, client_request_id: "req-5")
        send(self(), {:"$gen_cast", {:initial_prompt, "hello", [], meta}})

        state = %{conversation_id: conv.id, sandbox_id: ctx.sandbox.id}

        assert {:stop, :normal, _} =
                 FreshProvision.run(state, conv, ctx.sandbox, ctx.agent, nil, %{})

        assert [{"failed", %{"reason" => "gone", "retryable" => false}}] = stages(conv.id, "wake")
      end
    end
  end
end
