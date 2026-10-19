defmodule Fountain.Conversations.ConversationServerProvisionRetirementTest do
  use Fountain.ConversationServerCase

  alias Fountain.Machines.Lease

  for terminal <- ["terminated", "failed", "reset_pending"] do
    test "retirement to #{terminal} with another validation error before starting does not provision or fail the replacement" do
      stub_happy_sprite()
      user = insert_verified_user()
      agent = insert_agent(user_id: user.id, runtime: "gemini")
      conv = insert_conversation(user_id: user.id, agent: agent, status: "idle")
      sandbox = Conversations._unsafe_get_sandbox!(conv.sandbox_id)
      test = self()

      # The pause moved with the write (ADR 0058 stage 7b). `main` held the
      # server inside `claim_sandbox(… status: "starting")`, which is the write
      # the provision bracket replaced; the equivalent moment is the one before
      # the owner takes the machine, so the retirement lands between this
      # server reading its rows and the protocol revalidating them under its
      # lease. What is pinned is unchanged: the retirement wins, nothing is
      # provisioned, the replacement is untouched and the server exits
      # `:normal`.
      #
      # `main` also injected a second, unrelated validation error here, to show
      # that the retirement refusal outranked it. There is no changeset on this
      # path any more — `Lease.cas_update/3` writes named columns — so the
      # invalid attr has nothing to be injected into and the half of the test it
      # served is gone with the mechanism it tested.
      stub(Lease, :claim, fn id, opts ->
        send(test, {:starting_paused, self()})
        receive do: (:resume_starting -> :ok)
        Mimic.call_original(Lease, :claim, [id, opts])
      end)

      reject(Managoat.Sandbox.Sprites, :create, 2)
      reject(Managoat.Sandbox.Sprites, :destroy, 1)
      reject(Fountain.Broker, :prepare, 4)

      {:ok, pid} =
        GenServer.start(ConversationServer,
          conversation_id: conv.id,
          sandbox_id: sandbox.id,
          runtime_module: Managoat.Runtimes.Testing.FakeRuntime
        )

      ref = Process.monitor(pid)
      on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)
      assert_receive {:starting_paused, ^pid}, 5_000

      retired =
        if unquote(terminal) == "reset_pending" do
          sandbox
          |> put_lease(transition: "destroying", transition_reason: "reset")
        else
          {:ok, retired} = update_sandbox(sandbox, %{status: unquote(terminal)})
          retired
        end

      replacement = insert_sandbox(user_id: user.id, status: "ready")
      {:ok, _} = Conversations.update_conversation(conv, %{sandbox_id: replacement.id})
      send(pid, :resume_starting)

      assert :normal = assert_stopped(ref, 5_000)
      assert Fountain.Repo.reload!(sandbox).status == retired.status
      assert Fountain.Repo.reload!(sandbox).terminated_at == retired.terminated_at
      assert Fountain.Machines.Lease.get(sandbox.id).transition == retired.transition
      assert Fountain.Repo.reload!(conv).status == "idle"
      assert Fountain.Repo.reload!(conv).sandbox_id == replacement.id
      assert Fountain.Repo.reload!(replacement).status == "ready"
      assert is_nil(Fountain.Repo.reload!(conv).callback_api_key_id)
      refute Enum.any?(Conversations._unsafe_list_log_events(conv.id), &(&1.stage == "provision"))
    end
  end
end
