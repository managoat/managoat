defmodule Fountain.Conversations.ConversationServerConversationAuthTest do
  # `"auth": "conversation"` through a real ConversationServer (ADR 0086,
  # #1405): a conversation key minted from the server's callback key (#2934)
  # and the conversation id reach
  # `session/new` as plain headers on every ACP runtime, and nowhere else —
  # not the stored agent, the agent's API JSON, the files written into the
  # sandbox or the server's resolved document.
  use Fountain.ConversationServerCase

  import Fountain.ConversationServerCase.ACP

  alias Fountain.Conversations.Connection

  @salon %{
    "type" => "http",
    "url" => "https://salon.example/mcp",
    "auth" => "conversation",
    "headers" => %{"X-Room" => "r1"}
  }

  # The real runtime modules, so their own MCP files are written as in
  # production: Claude's `.mcp.json`, Gemini's `settings.json`.
  @modules %{
    "claude" => Managoat.Runtimes.Claude,
    "codex" => Managoat.Runtimes.Codex,
    "gemini" => Managoat.Runtimes.Gemini
  }

  defp start(runtime) do
    user = insert_verified_user()

    agent =
      insert_agent(
        user_id: user.id,
        runtime: runtime,
        mcp_servers: %{"salon" => @salon, "fs" => %{"command" => "npx", "args" => ["fs"]}}
      )

    conv = insert_conversation(user_id: user.id, agent: agent)

    stub_happy_sprite()
    test = self()

    # Codex's provisioning refuses to start without a key to write.
    if runtime == "codex" do
      {:ok, _} =
        Fountain.InferenceCredentials.put_credential(
          user.id,
          <<0::256>>,
          :openai_api_key,
          "sk-test"
        )
    end

    Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, _opts ->
      send(test, {:file, path, IO.iodata_to_binary(data)})
      :ok
    end)

    ref = stub_acp_transport()

    {pid, _mon, :alive} =
      start_server(conv, initial_prompt: "first", runtime: Map.fetch!(@modules, runtime))

    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

    {pid, ref, conv, agent}
  end

  defp session_new(pid, ref) do
    %{"id" => init_id, "method" => "initialize"} = next_write(3_000)

    reply(pid, ref, init_id, %{
      "agentCapabilities" => %{"loadSession" => true, "sessionCapabilities" => %{"resume" => %{}}}
    })

    %{"method" => "session/new"} = frame = next_write()
    frame
  end

  defp files(acc \\ []) do
    receive do
      {:file, path, data} -> files([{path, data} | acc])
    after
      0 -> acc
    end
  end

  for runtime <- ~w(claude codex gemini) do
    test "#{runtime}: session/new carries a conversation key and the conversation id" do
      {pid, ref, conv, agent} = start(unquote(runtime))
      frame = session_new(pid, ref)

      state = :sys.get_state(pid)
      assert {parent_id, token} = state.conversation_key
      assert is_binary(token) and token != ""

      # Not the sandbox's own `sprite` key (#2934): a key of its own, minted
      # from it, that reads this conversation and nothing else.
      assert parent_id == state.callback_api_key_id
      refute token == state.callback_token
      refute inspect(frame) =~ state.callback_token

      assert {:ok, _user, key} = Fountain.Accounts.authenticate_api_key(token)
      assert key.scopes == ["conversation"]
      assert key.conversation_id == conv.id
      assert key.parent_key_id == state.callback_api_key_id

      assert [fs, salon] = Enum.sort_by(frame["params"]["mcpServers"], & &1["name"])
      assert fs["name"] == "fs"
      assert salon["name"] == "salon"
      assert salon["type"] == "http"
      assert salon["url"] == "https://salon.example/mcp"
      refute Map.has_key?(salon, "auth")

      assert Enum.sort_by(salon["headers"], & &1["name"]) == [
               %{"name" => "Authorization", "value" => "Bearer " <> token},
               %{"name" => "X-Managoat-Conversation-Id", "value" => conv.id},
               %{"name" => "X-Room", "value" => "r1"}
             ]

      # Its output is redacted like the callback key's.
      assert token in Fountain.Conversations.Redaction.lookup(conv.id)

      # Not in the server's resolved document, which a crash report shows
      # redacted but a future reader might not.
      refute inspect(state.resolved_mcp_servers) =~ token

      # Not in the stored agent, nor its API JSON.
      stored = Fountain.Agents.get_agent!(agent.id, conv.user_id)
      assert stored.mcp_servers["salon"] == @salon
      refute Jason.encode!(FountainWeb.AgentJSON.show(%{agent: stored})) =~ token

      # Not in any file written into the sandbox: the entry reaches the
      # runtime over session/new only, while the runtime's own MCP file still
      # carries the server that did not ask.
      written = files()

      for {path, data} <- written do
        refute data =~ token, path
        refute data =~ "salon.example", path
      end

      mcp_file =
        %{"claude" => ".mcp.json", "gemini" => "settings.json"}[unquote(runtime)]

      if mcp_file do
        # Written beside the file and renamed over it (`JsonConfig`).
        assert Enum.any?(written, fn {path, data} ->
                 (String.ends_with?(path, mcp_file) or
                    String.contains?(path, mcp_file <> ".managoat.")) and data =~ ~s("fs")
               end),
               "no #{mcp_file} naming fs in #{inspect(Enum.map(written, &elem(&1, 0)))}"
      end

      # Not in the transcript.
      for event <- Fountain.Conversations._unsafe_list_log_events(conv.id) do
        refute inspect(event) =~ token
      end

      # And a crash report from the peer names the headers without values.
      peer_state = :sys.get_state(state.acp_peer)
      redacted = Managoat.ACP.Peer.redact_session_options(peer_state)
      assert inspect(peer_state.session_options) =~ token
      refute inspect(redacted.session_options) =~ token
      assert inspect(redacted.session_options) =~ "X-Managoat-Conversation-Id"
    end
  end

  test "an idle peer whose callback key was rotated does not carry the next turn" do
    {pid, ref, conv, agent} = start("codex")
    _ = session_new(pid, ref)
    state = :sys.get_state(pid)

    assert Connection.stale_reason(state, false, conv, agent) == nil

    # What a reattach leaves: a peer from the previous server, whose key is
    # not the one this server holds.
    assert Connection.stale_reason(%{state | acp_callback_key_id: nil}, false, conv, agent) ==
             "callback_key_rotated"

    # So is one with no `"auth": "conversation"` server: the adapter's own
    # `MANAGOAT_TOKEN` holds the old key too (#2835).
    plain = %{state | acp_callback_key_id: nil, resolved_mcp_servers: %{}}
    assert Connection.stale_reason(plain, false, conv, agent) == "callback_key_rotated"
  end
end
