defmodule Managoat.Runtimes.ACPTest do
  use ExUnit.Case, async: true

  alias Managoat.Runtimes.ACP

  # The library reads the agent as a map (`t:Managoat.Runtimes.agent/0`), so
  # a host's struct and a literal here are the same thing to it.
  defp agent(attrs), do: Map.new(attrs)

  describe "enabled?/1" do
    test "a property of the runtime alone — agent, runtime string, or nil" do
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{}))
      assert ACP.enabled?("claude")

      refute ACP.enabled?(nil)
    end

    test "the retired metadata flag is ignored in both directions" do
      # The per-agent flag (gate 2's opt-in, then the default-on opt-out) died
      # with the legacy spawn path: for a supported runtime there is nothing
      # left to opt out into, so stale metadata must not route anywhere.
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => false}))
      assert ACP.enabled?(agent(runtime: "claude", metadata: %{"acp" => true}))

      # gemini was this test's counter-example while it was blocked; since #659
      # nothing is, so the only thing the flag still cannot switch on is a
      # runtime with no adapter entry at all.
      refute ACP.enabled?(agent(runtime: "nonesuch", metadata: %{"acp" => true}))
    end

    test "nothing is blocked any more: gemini ships" do
      # gemini was held back because loading a session erased it — the load
      # path's own chat recorder overwrote the message list before the lookup
      # read it (#658, gemini-cli#28775). It shipped behind a store
      # consolidation (#659), retired once gemini-cli 0.63.0 fixed the load.
      assert "gemini" in ACP.supported_runtimes()
      assert ACP.enabled?(agent(runtime: "gemini", metadata: %{}))
    end

    test "gemini's adapter entry still points at its own workspace" do
      # Not /home/sprite: gemini walks up from cwd looking for a .git, and
      # `Gemini.prepare_sandbox/3` git-inits exactly this directory.
      assert {"gemini", ["--acp"]} = ACP.command("gemini")
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
    end

    test "every supported runtime speaks ACP unconditionally" do
      for runtime <- ACP.supported_runtimes() do
        assert ACP.enabled?(runtime), "expected #{runtime} to be ACP-enabled"
        assert ACP.enabled?(agent(runtime: runtime, metadata: %{}))
      end
    end

    test "a runtime with no adapter entry stays legacy" do
      # For an unconvertible runtime the legacy path is the only path.
      refute ACP.enabled?("somethingelse")
      refute ACP.enabled?(agent(runtime: "somethingelse", metadata: %{}))
    end
  end

  describe "mcp_servers/1" do
    test "a stdio server carries no type, because the adapter branches on its absence" do
      # Sending `type: "stdio"` puts the entry down the http/sse branch of the
      # adapter's parser, which then looks for a `url` that is not there.
      [server] =
        ACP.mcp_servers(
          agent(mcp_servers: %{"files" => %{"command" => "mcp-files", "args" => ["--root", "/"]}})
        )

      refute Map.has_key?(server, :type)
      assert server.name == "files"
      assert server.command == "mcp-files"
      assert server.args == ["--root", "/"]
    end

    test "env becomes an array of name/value pairs, not a map" do
      # The detail that fails silently: a map is accepted as JSON and read as
      # nothing, so the server starts with no environment and surfaces much
      # later as a tool that cannot authenticate.
      [server] =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "gh" => %{"command" => "mcp-gh", "env" => %{"TOKEN" => "t", "HOST" => "h"}}
            }
          )
        )

      assert server.env == [%{name: "HOST", value: "h"}, %{name: "TOKEN", value: "t"}]
    end

    test "an absent or empty env is omitted rather than sent as an empty array" do
      [server] = ACP.mcp_servers(agent(mcp_servers: %{"a" => %{"command" => "x"}}))
      refute Map.has_key?(server, :env)

      [server] = ACP.mcp_servers(agent(mcp_servers: %{"a" => %{"command" => "x", "env" => %{}}}))
      refute Map.has_key?(server, :env)
    end

    test "http and sse servers keep their type and url" do
      servers =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "remote" => %{"type" => "http", "url" => "https://example.test/mcp"},
              "streamy" => %{"type" => "sse", "url" => "https://example.test/sse"}
            }
          )
        )

      assert [
               %{name: "remote", type: "http", url: "https://example.test/mcp"},
               %{name: "streamy", type: "sse", url: "https://example.test/sse"}
             ] = servers
    end

    test "http headers become name/value pairs too" do
      [server] =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "r" => %{
                "type" => "http",
                "url" => "https://x.test",
                "headers" => %{"Authorization" => "Bearer t"}
              }
            }
          )
        )

      assert server.headers == [%{name: "Authorization", value: "Bearer t"}]
    end

    test "already-normalized header arrays pass through unchanged" do
      headers = [%{name: "Authorization", value: "Bearer t"}]

      [server] =
        ACP.mcp_servers(
          agent(
            mcp_servers: %{
              "r" => %{"type" => "http", "url" => "https://x.test", "headers" => headers}
            }
          )
        )

      assert server.headers == headers
    end

    test "servers are ordered by name so the adapter's session snapshot is stable" do
      # The adapter snapshots {cwd, mcpServers} per session and tears the
      # session down when the snapshot changes. Map iteration order is not
      # guaranteed, so an unsorted list would look like a different config on
      # some resumes and silently drop the session.
      names =
        agent(mcp_servers: %{"c" => %{}, "a" => %{}, "b" => %{}})
        |> ACP.mcp_servers()
        |> Enum.map(& &1.name)

      assert names == ["a", "b", "c"]
    end

    test "no servers is an empty list" do
      assert [] = ACP.mcp_servers(agent(mcp_servers: %{}))
      assert [] = ACP.mcp_servers(agent(mcp_servers: nil))
      assert [] = ACP.mcp_servers(nil)
    end
  end

  describe "initialize_params/1" do
    test "declares no filesystem or terminal capability by default" do
      params = ACP.initialize_params()

      assert params.clientCapabilities.terminal == false
      assert params.clientCapabilities.fs.readTextFile == false
      assert params.clientCapabilities.fs.writeTextFile == false
    end

    test "a host that services fs/* passes its own capabilities" do
      caps = %{fs: %{readTextFile: true, writeTextFile: false}, terminal: false}
      params = ACP.initialize_params(caps)

      assert params.clientCapabilities == caps
      assert params == Managoat.ACP.Protocol.initialize_params(caps)
    end
  end

  describe "per-runtime launch" do
    test "claude runs an installed adapter" do
      # The exact-version pin is the manifest's (compile-time) and the
      # installer's (provisioning_test.exs).
      assert {"claude-agent-acp", []} = ACP.command("claude")
    end

    test "gemini speaks ACP natively, so there is nothing to pin" do
      assert {"gemini", ["--acp"]} = ACP.command("gemini")
    end

    test "the held-back gemini entry still points at the right workspace" do
      # gemini walks up from cwd looking for a .git; pointing it at
      # /home/sprite reintroduces the EACCES noise the workspace exists to
      # avoid, and leaves MemoryDiscovery crawling /home.
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
      assert ACP.cwd("claude") == "/home/sprite"
    end

    test "codex runs a pinned adapter" do
      assert {"codex-acp", []} = ACP.command("codex")
    end

    test "each runtime runs where its own runtime module prepared" do
      assert ACP.cwd("gemini") == "/tmp/gemini-workspace"
      assert ACP.cwd("codex") == "/home/sprite"
    end

    test "an unknown runtime raises rather than spawning something arbitrary" do
      assert_raise ArgumentError, fn -> ACP.command("nonesuch") end
    end

    test "a native runtime needs no install" do
      # No Sprites stub here on purpose: if this tried to shell out, the test
      # would fail rather than quietly pass.
      assert :ok = ACP.install(%{name: "s"}, "gemini", [])
    end
  end
end
