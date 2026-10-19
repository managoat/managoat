defmodule Fountain.Conversations.TerminationClientTest do
  use Fountain.DataCase, async: true

  alias Fountain.Audit
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Conversations.Termination

  defmodule Probe do
    use GenServer

    def start_link(args), do: GenServer.start_link(__MODULE__, args)

    def init({owner, reply, conv_id}) do
      {:ok, _} = Registry.register(Fountain.ConversationRegistry, conv_id, nil)
      {:ok, {owner, reply}}
    end

    def handle_call(message, _from, {owner, reply} = state) do
      send(owner, {:termination_request, self(), message})

      # A function reply lets a test answer by message shape, which is how a
      # pod predating the tuple clause behaves.
      case reply do
        fun when is_function(fun, 1) -> {:reply, fun.(message), state}
        term -> {:reply, term, state}
      end
    end
  end

  setup do
    user = insert_verified_user()
    sandbox = insert_sandbox(user_id: user.id, status: "ready")
    conv = insert_conversation(user_id: user.id, sandbox: sandbox, status: "idle")
    %{user: user, sandbox: sandbox, conv: conv}
  end

  test "forwards attribution to the actor and keeps the outer lifecycle audit", ctx do
    pid = probe(ctx.conv.id, :ok)
    opts = [actor: "ui", request_ip: "192.0.2.4"]
    assert :ok = Termination.terminate_conversation(ctx.conv.id, opts)
    assert_received {:termination_request, ^pid, {:terminate_conv, ^opts}}
    assert [event] = events(ctx)
    assert event.actor == "ui"
    assert event.request_ip == "192.0.2.4"
  end

  test "an actor refusal is returned without a completed-termination audit", ctx do
    probe(ctx.conv.id, {:error, :sandbox_unavailable})

    assert {:error, :sandbox_unavailable} =
             Termination.terminate_conversation(ctx.conv.id, actor: "ui")

    assert events(ctx) == []
  end

  for live? <- [true, false] do
    test "an enclosing transaction refuses termination with live_actor=#{live?}", ctx do
      if unquote(live?), do: probe(ctx.conv.id, :ok)

      assert {:ok, {:error, :provider_transaction_open}} =
               Repo.transaction(fn ->
                 Termination.terminate_conversation(ctx.conv.id, actor: "ui")
               end)

      refute_received {:termination_request, _, _}
      assert Repo.reload!(ctx.conv).status == "idle"
      assert Fountain.Machines.Lease.get(ctx.sandbox.id).status == "ready"
      assert events(ctx) == []
    end
  end

  describe "supported message contract" do
    test "an obsolete actor refusal is returned without an unattributed retry", ctx do
      pid = probe(ctx.conv.id, {:error, :unknown_call})

      assert {:error, :unknown_call} =
               Termination.terminate_conversation(ctx.conv.id, actor: "ui")

      assert_received {:termination_request, ^pid, {:terminate_conv, [actor: "ui"]}}
      refute_received {:termination_request, ^pid, :terminate_conv}
      assert events(ctx) == []
    end

    test "does not retry when the actor pod understands the tuple", ctx do
      probe(ctx.conv.id, :ok)
      assert :ok = Termination.terminate_conversation(ctx.conv.id, actor: "ui")
      assert_received {:termination_request, _, {:terminate_conv, _}}
      refute_received {:termination_request, _, :terminate_conv}
    end

    test "does not retry on an ordinary refusal", ctx do
      probe(ctx.conv.id, {:error, :sandbox_unavailable})

      assert {:error, :sandbox_unavailable} =
               Termination.terminate_conversation(ctx.conv.id, actor: "ui")

      assert_received {:termination_request, _, {:terminate_conv, _}}
      refute_received {:termination_request, _, :terminate_conv}
      assert events(ctx) == []
    end

    test "forwards only attribution keys to the actor", ctx do
      pid = probe(ctx.conv.id, :ok)

      assert :ok =
               Termination.terminate_conversation(ctx.conv.id,
                 actor: "ui",
                 request_ip: "192.0.2.9",
                 audit: false
               )

      assert_received {:termination_request, ^pid, {:terminate_conv, forwarded}}
      assert Enum.sort(Keyword.keys(forwarded)) == [:actor, :request_ip]
    end
  end

  defp probe(conv_id, reply) do
    pid = start_supervised!({Probe, {self(), reply, conv_id}})
    await_registered(conv_id, pid)
    pid
  end

  # Wait for the thing being asserted rather than assume it. Under Horde's
  # CRDT registry (before ADR 0072) the first read was a coin flip, which is
  # how partition 6 went red on an unrelated PR.
  defp await_registered(conv_id, pid, remaining \\ 200) do
    cond do
      ConversationServer.whereis(conv_id) == pid ->
        :ok

      remaining == 0 ->
        flunk("probe #{inspect(pid)} never became visible in the registry for #{conv_id}")

      true ->
        Process.sleep(10)
        await_registered(conv_id, pid, remaining - 1)
    end
  end

  defp events(ctx), do: Audit.list_for_user(ctx.user.id, action_prefix: "conversation.terminated")
end
