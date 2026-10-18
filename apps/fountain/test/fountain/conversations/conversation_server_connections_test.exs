defmodule Fountain.Conversations.ConversationServerConnectionsTest do
  # A connection through a real ConversationServer (ADR 0085): the token goes
  # to the broker with a bearer binding to the server's host, the sandbox and
  # every file written into it hold only the placeholder, and a connection
  # that can no longer serve refuses the turn.
  use Fountain.ConversationServerCase

  import Ecto.Query, only: [from: 2]

  alias Fountain.{Connections, Repo}
  alias Fountain.Connections.{Connection, FakeProvider}
  alias Fountain.Conversations.McpConnections

  @session %{vault: "c-test", token: "av_sess_conv", expires_at: nil}

  setup do
    Application.put_env(:fountain, :broker_listen_port, 14_322)
    Application.put_env(:fountain, :broker_proxy_url, "http://broker.test:14322")
    Req.Test.set_req_test_to_shared()
    FakeProvider.stub()
    # The key `stub_happy_sprite/1` gives the server, before the tokens are sealed.
    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id -> {:ok, <<0::256>>} end)
    Mimic.stub(Fountain.Crypto, :load_tenant_key, fn _user_id, _opts -> {:ok, <<0::256>>} end)

    user = insert_verified_user()
    {:ok, _pending, url} = Connections.create(user.id, %{"url" => FakeProvider.server_url()})
    state = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query() |> Map.fetch!("state")
    {:ok, conn} = Connections.complete(user.id, %{"state" => state, "code" => "good-code"})

    agent =
      insert_agent(
        user_id: user.id,
        runtime: "claude",
        mcp_servers: %{
          "linear" => %{
            "type" => "http",
            "url" => "https://mcp.example.com/mcp",
            "auth" => %{"connection" => conn.id}
          }
        }
      )

    {:ok, user: user, agent: agent, connection: conn}
  end

  test "the token reaches the broker and never the sandbox", %{
    user: user,
    agent: agent,
    connection: connection
  } do
    conv = insert_conversation(user_id: user.id, agent: agent)
    test = self()
    key = Connections.broker_key(connection.id)
    placeholder = Fountain.Broker.placeholder(key)

    stub_happy_sprite()

    Mimic.stub(Managoat.Sandbox.Sprites, :spawn, fn _h, cmd, args, opts ->
      send(test, {:spawned, cmd, args, opts})
      {:ok, %Managoat.Sandbox.Command{provider: :sprites, ref: make_ref()}}
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_stdin, fn _c, _data -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :close_stdin, fn _c -> :ok end)
    Mimic.stub(Managoat.Sandbox.Sprites, :stop_command, fn _c -> :ok end)

    stub(Fountain.Broker, :preflight, fn -> :ok end)
    stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

    stub(Fountain.Broker, :prepare, fn _conv_id, brokered, bindings, _opts ->
      send(test, {:prepared, brokered, bindings})
      {:ok, @session}
    end)

    Mimic.stub(Fountain.Conversations.Provisioning, :write_env_file, fn _h, env ->
      send(test, {:env_file, env})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, _opts ->
      send(test, {:wrote, path, data})
      :ok
    end)

    {pid, _mon, :alive} = start_server(conv, initial_prompt: "hello")
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    # The broker holds the token, bound as a bearer to the server's host only.
    assert_receive {:prepared, %{^key => "access-1"}, bindings}, 2_000

    assert [%{host: "mcp.example.com", auth_type: "bearer", key: ^key}] =
             Map.fetch!(bindings, key)

    # The process env and the env file hold neither the token nor its key.
    assert_receive {:spawned, _cmd, _args, opts}, 2_000
    spawn_env = Keyword.fetch!(opts, :env)
    refute Enum.any?(spawn_env, fn {k, v} -> k == key or String.contains?(v, "access-1") end)

    assert_receive {:env_file, file_env}, 2_000
    refute Enum.any?(file_env, fn {k, v} -> k == key or String.contains?(v, "access-1") end)

    # Nothing written into the sandbox carries the token; the MCP config that
    # the runtime reads names the placeholder.
    written = collect_writes([])
    refute Enum.any?(written, fn {_path, data} -> String.contains?(data, "access-1") end)

    # The one resolved document the session gets: a header, no auth.
    %{resolved_mcp_servers: %{"linear" => linear}} = :sys.get_state(pid)
    refute Map.has_key?(linear, "auth")
    assert linear["headers"]["Authorization"] == "Bearer " <> placeholder

    # What Claude's runtime writes into the sandbox from that document (the
    # config home's `.claude.json`, ADR 0097) names the placeholder and not
    # the token.
    Managoat.Runtimes.Claude.write_config(
      Managoat.Sandbox.Sprites.build_handle("test-sprite"),
      %{mcp_servers: %{"linear" => linear}},
      "/home/sprite/.managoat/c/#{Ecto.UUID.generate()}"
    )

    assert [{_, mcp_json}] =
             Enum.filter(collect_writes([]), fn {path, _} ->
               String.contains?(path, ".claude.json.managoat.")
             end)

    assert mcp_json =~ placeholder
    refute mcp_json =~ "access-1"

    assert %{connections: [%{id: id}]} = :sys.get_state(pid)
    assert id == connection.id
  end

  test "a connection that can no longer serve refuses the turn, naming itself", %{
    user: user,
    agent: agent,
    connection: connection
  } do
    conv = insert_conversation(user_id: user.id, agent: agent)
    stub_happy_sprite()
    stub(Fountain.Broker, :preflight, fn -> :ok end)
    stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
    stub(Fountain.Broker, :prepare, fn _, _, _, _ -> {:ok, @session} end)

    {pid, _mon, :alive} = start_server(conv)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
      set: [status: "revoked"]
    )

    id = connection.id

    assert {:error, {:connection_reconnect_required, ^id}} =
             GenServer.call(pid, {:send_prompt, "again", []})

    # A deleted one, the same.
    :ok = Connections.delete(user.id, id)

    assert {:error, {:connection_reconnect_required, ^id}} =
             GenServer.call(pid, {:send_prompt, "again", []})

    assert McpConnections.gate(user.id, :sys.get_state(pid).connections) ==
             {:error, {:connection_reconnect_required, id}}
  end

  test "a slow token endpoint does not hold up the server; the refresh lands when it answers",
       %{user: user, agent: agent, connection: connection} do
    conv = insert_conversation(user_id: user.id, agent: agent)
    test = self()
    key = Connections.broker_key(connection.id)

    stub_happy_sprite()
    stub(Fountain.Broker, :preflight, fn -> :ok end)
    stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
    stub(Fountain.Broker, :prepare, fn _, _, _, _ -> {:ok, @session} end)

    stub(Fountain.Broker, :refresh, fn _conv, brokered, _bindings, _opts ->
      send(test, {:rules, brokered})
      {:ok, 1}
    end)

    previous = Application.get_env(:fountain, :connection_refresh_wait_ms)
    Application.put_env(:fountain, :connection_refresh_wait_ms, 50)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:fountain, :connection_refresh_wait_ms, previous),
        else: Application.delete_env(:fountain, :connection_refresh_wait_ms)
    end)

    # The token is due a refresh, and the provider takes 2 s to answer one:
    # longer than the wait, though far shorter than its real 15 s budget.
    Repo.update_all(from(c in Connection, where: c.id == ^connection.id),
      set: [expires_at: DateTime.add(DateTime.utc_now(), 120) |> DateTime.truncate(:second)]
    )

    FakeProvider.stub(expires_in: 3600, refresh_delay_ms: 2_000)

    {elapsed_us, {pid, _mon, :alive}} = :timer.tc(fn -> start_server(conv) end)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert elapsed_us < 1_500_000

    # Answering while the refresh is still running, on the stored token.
    {call_us, state} = :timer.tc(fn -> :sys.get_state(pid, 1_000) end)
    assert call_us < 500_000
    assert state.brokered[key] == "access-1"

    # The refresh finishes in its task and the server rewrites the live rules.
    assert_receive {:rules, %{^key => "access-r" <> _ = fresh}}, 5_000
    assert :sys.get_state(pid).brokered[key] == fresh
  end

  defp collect_writes(acc) do
    receive do
      {:wrote, path, data} -> collect_writes([{path, IO.iodata_to_binary(data)} | acc])
    after
      300 -> acc
    end
  end
end
