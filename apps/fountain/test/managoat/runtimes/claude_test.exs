defmodule Managoat.Runtimes.ClaudeTest do
  @moduledoc """
  MCP servers are provisioned into the sandbox, as user-scope servers in the
  conversation's config home (`$CLAUDE_CONFIG_DIR/.claude.json`), because the
  ACP session-scoped channel is broken upstream (#837), and every sandbox gets
  the settings that keep thinking visible. Both files are Managoat's only in
  those keys: the rest, a runtime template's hooks included (#2998), is kept.
  This pins the provisioning shape, and the env `model_env/1` names.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.{Claude, JsonConfig}
  alias Managoat.Sandbox

  setup :set_mimic_from_context

  @home "/home/sprite/.managoat/c/7f3c2b9e-0d4a-4f1e-8a77-5b6c1d2e3f40"
  @settings "#{@home}/settings.json"
  @user_config "#{@home}/.claude.json"

  setup do
    Mimic.copy(Managoat.Sandbox)
    handle = %Sandbox.Handle{provider: :fake, name: "sb"}
    {:ok, handle: handle}
  end

  # Writes go to the test; the config files read as `existing` (a path to its
  # text; a path not there is not on the disk); every other exec (the rename,
  # a legacy removal) is reported and succeeds.
  defp stub_sandbox(existing) do
    test = self()

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, path, body, opts ->
      send(test, {:wrote, path, body, opts})
      :ok
    end)

    Mimic.stub(Managoat.Sandbox, :exec, fn
      _h, "bash", ["-c", _script, "managoat-json-read" | paths], _opts ->
        send(test, {:read, paths})
        {:ok, Enum.map_join(paths, "", &read_line(existing, &1)), 0}

      _h, "bash", ["-c", script], _opts ->
        send(test, {:exec, script})
        {:ok, "", 0}
    end)
  end

  defp read_line(existing, path) do
    case Map.fetch(existing, path) do
      {:ok, text} -> "+" <> Base.encode64(text) <> "\n"
      :error -> "-\n"
    end
  end

  defp assert_wrote(path) do
    assert_receive {:wrote, tmp, body, mode: 0o600}
    assert String.starts_with?(tmp, path <> ".managoat.")
    assert_receive {:exec, rename}
    assert rename == JsonConfig.rename_script(tmp, path)
    Jason.decode!(body)
  end

  test "config_env points the CLI at the conversation's config home" do
    assert Claude.config_env(@home) == [{"CLAUDE_CONFIG_DIR", @home}]
    assert Claude.skills_root(@home) == "#{@home}/skills"
  end

  test "without MCP servers the settings are written, thinking summaries on, and no servers",
       %{handle: handle} do
    stub_sandbox(%{})

    for agent <- [%{mcp_servers: %{}}, %{mcp_servers: nil}, nil, %{}] do
      assert Claude.write_config(handle, agent, @home) == :ok
      assert_receive {:read, [@settings, @user_config]}
      assert assert_wrote(@user_config) == %{"mcpServers" => %{}}
      assert assert_wrote(@settings) == %{"showThinkingSummaries" => true}
      refute_received {:wrote, "/home/sprite/.mcp.json", _, _}
    end
  end

  test "MCP servers are user-scope servers in the config home's .claude.json", %{handle: handle} do
    stub_sandbox(%{})

    mcp = %{
      "fs" => %{
        "command" => "npx",
        "args" => ["-y", "@modelcontextprotocol/server-filesystem", "."]
      }
    }

    assert Claude.write_config(handle, %{mcp_servers: mcp}, @home) == :ok

    # Both files are read in one exec, before anything is written.
    assert_receive {:read, [@settings, @user_config]}

    # Renamed into place, so the CLI never reads half a file.
    assert %{"mcpServers" => %{"fs" => %{"command" => "npx"}}} = assert_wrote(@user_config)

    # User-scope servers need no approval, so nothing is pre-approved.
    assert assert_wrote(@settings) == %{"showThinkingSummaries" => true}

    # Nothing goes to the project scope any more.
    refute_received {:wrote, "/home/sprite/.mcp.json", _, _}
  end

  test "the CLI's own state in .claude.json is kept; only mcpServers is replaced", %{
    handle: handle
  } do
    stub_sandbox(%{
      @settings => ~s({"showThinkingSummaries": true}),
      @user_config =>
        Jason.encode!(%{
          "firstStartTime" => "2026-10-18T19:41:51.182Z",
          "mcpServers" => %{"old" => %{"command" => "gone"}},
          "userID" => "abc"
        })
    })

    assert Claude.write_config(handle, %{mcp_servers: %{"new" => %{"command" => "x"}}}, @home) ==
             :ok

    assert assert_wrote(@user_config) == %{
             "firstStartTime" => "2026-10-18T19:41:51.182Z",
             "mcpServers" => %{"new" => %{"command" => "x"}},
             "userID" => "abc"
           }
  end

  test "a template's settings are kept; only showThinkingSummaries is Managoat's", %{
    handle: handle
  } do
    # The runtime template (#2998): a setup script's hooks must survive every
    # provision and wake.
    hooks = %{"PostToolUse" => [%{"matcher" => "Edit", "hooks" => []}]}

    stub_sandbox(%{
      @settings => Jason.encode!(%{"hooks" => hooks, "showThinkingSummaries" => false}),
      @user_config => ~s({"mcpServers": {}})
    })

    assert Claude.write_config(handle, %{}, @home) == :ok
    assert assert_wrote(@settings) == %{"hooks" => hooks, "showThinkingSummaries" => true}
  end

  test "a .claude.json that is there but unreadable is an error, never overwritten", %{
    handle: handle
  } do
    # A CLI halfway through its own write: replacing it would drop its state.
    stub_sandbox(%{@user_config => "{not json"})

    assert {:error, {:runtime_config, @user_config, :unreadable}} =
             Claude.write_config(handle, %{mcp_servers: %{"a" => %{"command" => "x"}}}, @home)

    refute_received {:wrote, _tmp, _body, _opts}
  end

  test "a settings.json that does not parse keeps nothing else from being written", %{
    handle: handle
  } do
    # A hand edit gone wrong: the servers (and a rotated token in them) still land.
    stub_sandbox(%{@settings => "{oops", @user_config => ~s({"mcpServers": {}})})
    servers = %{"a" => %{"command" => "x"}}

    assert {:error, {:runtime_config, @settings, :unreadable}} =
             Claude.write_config(handle, %{mcp_servers: servers}, @home)

    assert assert_wrote(@user_config) == %{"mcpServers" => servers}
    refute_received {:wrote, @settings <> _, _, _}
  end

  test "files that already carry these values are left alone, so a wake does not race a live CLI",
       %{handle: handle} do
    servers = %{"a" => %{"command" => "x"}}

    stub_sandbox(%{
      @settings => ~s({"showThinkingSummaries": true, "hooks": {}}),
      @user_config => Jason.encode!(%{"mcpServers" => servers, "userID" => "abc"})
    })

    assert Claude.write_config(handle, %{mcp_servers: servers}, @home) == :ok
    assert_receive {:read, _}
    refute_received {:wrote, _path, _body, _opts}
    refute_received {:exec, _}
  end

  test "the rename succeeds when a retried exec finds its file already moved" do
    tmp = @user_config <> ".managoat.7.tmp"
    script = JsonConfig.rename_script(tmp, @user_config)
    dir = Fountain.TmpDir.mkdir!("claude_rename")
    run = String.replace(script, @home, dir)

    File.write!(Path.join(dir, ".claude.json.managoat.7.tmp"), "{}")
    assert {_, 0} = System.cmd("bash", ["-c", run])
    assert File.read!(Path.join(dir, ".claude.json")) == "{}"
    # The first reply was lost; the retry finds the work done.
    assert {_, 0} = System.cmd("bash", ["-c", run])
    # Nothing there at all is a failure, not a success.
    File.rm!(Path.join(dir, ".claude.json"))
    assert {_, 1} = System.cmd("bash", ["-c", run])
  end

  test "the read script answers each path, there or not, on a line of its own" do
    dir = Fountain.TmpDir.mkdir!("claude_read")
    there = Path.join(dir, "settings.json")
    File.write!(there, ~s({"a": "line\\nbreak"}))
    stub_sandbox(%{})

    Mimic.stub(Managoat.Sandbox, :exec, fn _h, "bash", args, _opts ->
      {out, code} = System.cmd("bash", args)
      {:ok, out, code}
    end)

    missing = Path.join(dir, "missing.json")

    assert {:ok, %{^there => %{"a" => "line\nbreak"}, ^missing => nil}} =
             JsonConfig.read(%Sandbox.Handle{provider: :fake, name: "sb"}, [there, missing])
  end

  test "a conversation's own home never writes the legacy project .mcp.json", %{
    handle: handle
  } do
    stub_sandbox(%{})

    assert Claude.write_config(handle, %{mcp_servers: %{"a" => %{"command" => "x"}}}, @home) ==
             :ok

    refute_received {:wrote, "/home/sprite/.mcp.json", _, _}
  end

  test "a legacy home keeps the project .mcp.json written with the same servers", %{
    handle: handle
  } do
    # The previous release's adapter, still running after a deploy, reads it,
    # and project scope would shadow the user-scope servers on a collision.
    stub_sandbox(%{})
    servers = %{"a" => %{"command" => "x"}}
    assert Claude.write_config(handle, %{mcp_servers: servers}, "/home/sprite/.claude") == :ok
    assert_receive {:wrote, "/home/sprite/.mcp.json", body, _}
    assert Jason.decode!(body) == %{"mcpServers" => servers}

    # With no servers the file is left alone: it may be the tenant's.
    assert Claude.write_config(handle, %{}, "/home/sprite/.claude") == :ok
    refute_received {:wrote, "/home/sprite/.mcp.json", _, _}
  end

  test "a transient write error is retried, then the config lands", %{handle: handle} do
    # The first filesystem call into a freshly created sprite timed out once
    # in prod and, with no retry, failed the whole provision. Every write is
    # idempotent, so they go through Managoat.Sandbox.Retry.
    {:ok, calls} = Agent.start_link(fn -> 0 end)

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body, _opts ->
      case Agent.get_and_update(calls, &{&1, &1 + 1}) do
        0 -> {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
        _ -> :ok
      end
    end)

    Mimic.stub(Managoat.Sandbox, :exec, fn _h, "bash", args, _opts ->
      case args do
        ["-c", _, "managoat-json-read" | paths] ->
          {:ok, String.duplicate("-\n", length(paths)), 0}

        _ ->
          {:ok, "", 0}
      end
    end)

    assert Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}}, @home) ==
             :ok

    assert Agent.get(calls, & &1) == 3
  end

  test "a write that keeps failing is a tagged error, not a crash", %{handle: handle} do
    stub_sandbox(%{})

    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body, _opts ->
      {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
    end)

    assert {:error, {:runtime_config, @user_config, {:unavailable, _}}} =
             Claude.write_config(handle, %{mcp_servers: %{"fs" => %{"command" => "npx"}}}, @home)
  end

  test "a config read that keeps failing is a tagged error, not a crash", %{handle: handle} do
    Mimic.stub(Managoat.Sandbox, :write_file, fn _h, _path, _body, _opts -> :ok end)

    Mimic.stub(Managoat.Sandbox, :exec, fn _h, "bash", _args, _opts ->
      {:error, {:unavailable, %Req.TransportError{reason: :timeout}}}
    end)

    assert {:error, {:runtime_config, @settings, {:unavailable, _}}} =
             Claude.write_config(handle, %{}, @home)
  end

  describe "default_env/2" do
    test "prefers the oauth token over the api key" do
      env =
        Claude.default_env(nil, %{
          claude_code_oauth_token: "oauth-token",
          anthropic_api_key: "api-key"
        })

      assert env == [
               {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"},
               {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}
             ]
    end

    test "falls back to the api key when there is no oauth token" do
      env = Claude.default_env(nil, %{anthropic_api_key: "api-key"})

      assert env == [
               {"ANTHROPIC_API_KEY", "api-key"},
               {"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}
             ]
    end

    test "carries only the traffic flag when neither credential is on file" do
      # The first-start delay it avoids is the CLI's, whatever the credential.
      assert Claude.default_env(nil, %{}) == [{"CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC", "1"}]
    end
  end

  describe "fall_back_to_api_key/2 (#655)" do
    test "swaps the oauth token for the api key when one is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}, {"OTHER_VAR", "x"}]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "api-key"})

      assert {"ANTHROPIC_API_KEY", "api-key"} in result
      refute List.keymember?(result, "CLAUDE_CODE_OAUTH_TOKEN", 0)
      assert {"OTHER_VAR", "x"} in result
    end

    test "leaves the env untouched when no api key is on file" do
      env = [{"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"}]

      assert Claude.fall_back_to_api_key(env, %{}) == env
    end

    test "does not duplicate an api key entry the env already carries" do
      env = [
        {"CLAUDE_CODE_OAUTH_TOKEN", "oauth-token"},
        {"ANTHROPIC_API_KEY", "stale-key"}
      ]

      result = Claude.fall_back_to_api_key(env, %{anthropic_api_key: "fresh-key"})

      assert Enum.count(result, fn {k, _v} -> k == "ANTHROPIC_API_KEY" end) == 1
      assert {"ANTHROPIC_API_KEY", "fresh-key"} in result
    end
  end

  describe "model_env/1 (the opus alias)" do
    test "points the opus alias at Opus 5 for a turn that asks for it" do
      pair = [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]
      assert Claude.model_env("claude-opus-5") == pair
      assert Claude.model_env("anthropic/claude-opus-5") == pair
    end

    test "needs nothing for any other model, or none" do
      for model <- ["claude-opus-5-5", "opus", "claude-sonnet-5", "claude-fable-5-1", nil] do
        assert Claude.model_env(model) == [], "#{inspect(model)}"
      end
    end
  end
end
