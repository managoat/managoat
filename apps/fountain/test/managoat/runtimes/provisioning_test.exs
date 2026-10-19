defmodule Managoat.Runtimes.ProvisioningTest do
  @moduledoc """
  The imperative half of each runtime — `prepare_sandbox/4`, `write_config/3`
  and the adapter install — driven against a stubbed sandbox.

  In Fountain these paths were covered by the conversation server's
  provisioning tests, which drive them through the real server. A package
  cannot lean on its host's tests, so the shape of every exec and write is
  pinned here: the script each runtime runs, the file it writes, and the
  tagged error it answers with when the sandbox refuses.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.{ACP, BundleCache, Claude, Codex, Gemini}
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "prov-test"}
  @home "/home/sprite/.managoat/c/5a0c9d3e-2b1f-4e6a-8c7d-9e0f1a2b3c4d"

  describe "Codex" do
    test "default_env/2 exports OPENAI_API_KEY, or nothing" do
      assert Codex.default_env(nil, %{openai_api_key: "sk"}) == [{"OPENAI_API_KEY", "sk"}]
      assert Codex.default_env(nil, %{openai_api_key: ""}) == []
      assert Codex.default_env(nil, %{}) == []
    end

    test "prepare_sandbox/4 writes auth.json, in the config home, as `codex login --with-api-key` does" do
      path = "#{@home}/auth.json"

      expect(Sandbox, :write_file, fn @handle, ^path, body, opts ->
        assert opts[:mode] == 0o600
        assert Jason.decode!(body) == %{"auth_mode" => "apikey", "OPENAI_API_KEY" => "sk-1"}
        :ok
      end)

      # No CLI involved: a sandbox without `codex` on PATH (a self-hosted
      # runner) logs in the same way.
      reject(&Sandbox.spawn/4)

      assert :ok = Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk-1"}], @home)
    end

    test "a legacy home writes the auth.json codex read before config homes" do
      expect(Sandbox, :write_file, fn @handle, "/home/sprite/.codex/auth.json", _body, _opts ->
        :ok
      end)

      assert :ok =
               Codex.prepare_sandbox(
                 @handle,
                 nil,
                 [{"OPENAI_API_KEY", "sk-1"}],
                 "/home/sprite/.codex"
               )
    end

    test "config_env points codex at the conversation's config home" do
      assert Codex.config_env(@home) == [{"CODEX_HOME", @home}]
    end

    test "a refused write is a tagged error" do
      expect(Sandbox, :write_file, fn _h, _p, _b, _o -> {:error, {:unavailable, :closed}} end)

      assert {:error, {:codex_auth_write, {:unavailable, :closed}}} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", "sk"}], @home)
    end

    test "no key in the env is named, rather than left for the first turn to 401 on" do
      reject(&Sandbox.write_file/4)
      assert {:error, :missing_openai_api_key} = Codex.prepare_sandbox(@handle, nil, [], @home)

      assert {:error, :missing_openai_api_key} =
               Codex.prepare_sandbox(@handle, nil, [{"OPENAI_API_KEY", ""}], @home)
    end
  end

  describe "Claude" do
    test "has no sandbox bootstrap: the pinned CLI lists its models itself" do
      reject(&Sandbox.exec/4)

      refute Managoat.Runtimes.implements?(Claude, :prepare_sandbox, 4)

      assert :ok =
               Managoat.Runtimes.prepare_sandbox(
                 Claude,
                 @handle,
                 nil,
                 [{"ANTHROPIC_API_KEY", "sk"}],
                 @home
               )
    end

    test "model_env/2 dispatches to claude, and is empty for a runtime without it" do
      assert Managoat.Runtimes.model_env(Claude, "claude-opus-5") ==
               [{"ANTHROPIC_DEFAULT_OPUS_MODEL", "claude-opus-5"}]

      assert Managoat.Runtimes.model_env(Codex, "gpt-5") == []
    end

    test "client_capabilities/2: claude declares form elicitation only under a policy that asks (#2492)" do
      default = Managoat.ACP.Protocol.default_client_capabilities()
      declared = Map.put(default, :elicitation, %{form: %{}})
      asks = %{"default" => "auto_allow", "execute" => "ask"}

      assert Managoat.Runtimes.client_capabilities(Claude, asks) == declared
      assert Managoat.Runtimes.client_capabilities(Claude, %{"default" => "ask"}) == declared

      # Asks nobody: the adapter keeps AskUserQuestion removed, and nothing waits.
      for policy <- [nil, %{}, %{"default" => "auto_allow"}, %{"execute" => "auto_deny"}] do
        assert Managoat.Runtimes.client_capabilities(Claude, policy) == default, inspect(policy)
      end

      assert Managoat.Runtimes.client_capabilities(Codex, asks) == default
      # A custom `acp` runtime has no module.
      assert Managoat.Runtimes.client_capabilities(nil, asks) == default
    end
  end

  describe "configuration no-ops" do
    test "an agent without runtime-specific config writes nothing" do
      assert :ok = Managoat.Runtimes.Instructions.write(@handle, "claude", %{}, @home)
    end
  end

  describe "Gemini" do
    test "default_env/2 exports the key and workspace trust, the last without a key, and no HOME" do
      trust = {"GEMINI_CLI_TRUST_WORKSPACE", "true"}

      assert Gemini.default_env(nil, %{gemini_api_key: "g"}) == [{"GEMINI_API_KEY", "g"}, trust]
      assert Gemini.default_env(nil, %{gemini_api_key: ""}) == [trust]
      assert Gemini.default_env(nil, %{}) == [trust]
    end

    test "config_env points gemini's home at the conversation's config home" do
      assert Gemini.config_env(@home) == [{"GEMINI_CLI_HOME", @home}]
    end

    # The settings file reads as `existing` (nil: not there); writes and the
    # rename into place are reported.
    defp stub_gemini_settings(existing) do
      test = self()

      stub(Sandbox, :exec, fn
        @handle, "bash", ["-c", _script, "managoat-json-read", path], _opts ->
          send(test, {:read, path})
          {:ok, if(existing, do: "+" <> Base.encode64(existing) <> "\n", else: "-\n"), 0}

        @handle, "bash", ["-c", _rename], _opts ->
          {:ok, "", 0}
      end)

      stub(Sandbox, :write_file, fn @handle, path, body, opts ->
        send(test, {:wrote, path, body, opts})
        :ok
      end)
    end

    test "write_config/3 writes user-scope MCP servers under gemini's own .gemini" do
      stub_gemini_settings(nil)

      servers = %{"fs" => %{"command" => "mcp-fs"}}
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: servers}, @home)

      path = "#{@home}/.gemini/settings.json"
      assert_receive {:read, ^path}
      assert_receive {:wrote, tmp, body, mode: 0o600}
      assert String.starts_with?(tmp, path <> ".managoat.")
      assert Jason.decode!(body) == %{"mcpServers" => servers}
    end

    test "write_config/3 without servers writes an empty list, so a dropped server goes" do
      stub_gemini_settings(~s({"mcpServers": {"gone": {}}}))

      for agent <- [nil, %{mcp_servers: %{}}, %{mcp_servers: nil}] do
        assert :ok = Gemini.write_config(@handle, agent, "/tmp")
        assert_receive {:wrote, "/tmp/.gemini/settings.json.managoat." <> _, body, _}
        assert Jason.decode!(body) == %{"mcpServers" => %{}}
      end
    end

    test "write_config/3 keeps the rest of the settings, a runtime template's included" do
      stub_gemini_settings(~s({"ui": {"theme": "x"}, "mcpServers": {}}))

      assert :ok = Gemini.write_config(@handle, %{mcp_servers: %{"a" => %{}}}, @home)
      assert_receive {:wrote, _tmp, body, _}
      assert Jason.decode!(body) == %{"ui" => %{"theme" => "x"}, "mcpServers" => %{"a" => %{}}}

      # Already so: nothing is written.
      stub_gemini_settings(~s({"ui": {}, "mcpServers": {"a": {}}}))
      assert :ok = Gemini.write_config(@handle, %{mcp_servers: %{"a" => %{}}}, @home)
      refute_receive {:wrote, _, _, _}, 50
    end

    test "a refused config write is reported, not swallowed" do
      stub_gemini_settings(nil)
      # `:not_found` is permanent in the sandbox taxonomy, so Retry does not
      # spend its attempts on it and the error comes straight back.
      stub(Sandbox, :write_file, fn _h, _p, _b, _o -> {:error, :not_found} end)

      path = "#{@home}/.gemini/settings.json"

      assert {:error, {:runtime_config, ^path, :not_found}} =
               Gemini.write_config(@handle, %{mcp_servers: %{"a" => %{}}}, @home)
    end

    test "prepare_sandbox/4 git-inits the workspace and writes nothing else" do
      test = self()

      # The session-store consolidation script went with gemini-cli#28775.
      reject(Sandbox, :write_file, 3)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        send(test, {:exec, script, opts[:env]})
        {:ok, "", 0}
      end)

      env = [{"GEMINI_CLI_HOME", @home}]
      assert :ok = Gemini.prepare_sandbox(@handle, nil, env, @home)

      assert_receive {:exec, script, ^env}
      assert script =~ "/tmp/gemini-workspace/.git"
      assert script =~ "git init -q"
      # The CLI is installed, pinned, only where the image did not bring it.
      assert script =~ "if ! command -v gemini >/dev/null; then"
      assert script =~ "npm install -g --no-progress --silent @google/gemini-cli@0.64.0"
    end

    test "a failed workspace init is a tagged error" do
      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "fatal", 128} end)

      assert {:error, {:gemini_workspace_init_exit, 128}} =
               Gemini.prepare_sandbox(@handle, nil, [], @home)

      expect(Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)

      assert {:error, {:gemini_workspace_init, :unavailable}} =
               Gemini.prepare_sandbox(@handle, nil, [], @home)
    end
  end

  @pins %{
    "claude" => {"@agentclientprotocol/claude-agent-acp", "claude-agent-acp@0.81.2"},
    "codex" => {"@agentclientprotocol/codex-acp", "codex-acp@2.2.2"}
  }

  describe "ACP.install/3 for an adapter runtime" do
    @claude_dir "/home/sprite/.local/share/managoat/acp/claude-agent-acp@0.81.2"

    test "an installed pin needs one check and no bundle" do
      reject(&BundleCache.fetch/3)
      reject(&Sandbox.spawn/4)

      expect(Sandbox, :exec, fn @handle, "bash", ["-lc", script], opts ->
        refute script =~ "flock"
        assert opts[:timeout] == 30_000
        {:ok, "__MANAGOAT_INSTALL__ cache_hit 1\n", 0}
      end)

      assert :ok = ACP.install(@handle, "claude", [{"X", "1"}])
    end

    test "a miss uploads the verified bundle for the locked installer" do
      check_misses()
      %{file: file, integrity: integrity} = sidecar("claude")
      expect(BundleCache, :fetch, fn ^file, ^integrity, _max -> {:ok, "verified bytes"} end)
      stub_install(0)

      assert :ok = ACP.install(@handle, "claude", [{"X", "1"}])

      assert_receive {:installed, script, opts}

      assert opts[:env] == [
               {"MANAGOAT_ACP_BUNDLE_FILE", "/tmp/managoat-claude-agent-acp@0.81.2.tar.gz"},
               {"MANAGOAT_ACP_DEADLINE_S", "175"},
               {"X", "1"}
             ]

      assert opts[:timeout] == 180_000
      assert_receive {:uploaded, "verified bytes"}
      assert script =~ "want=0.81.2"
      assert script =~ "dir=#{@claude_dir}"
      assert script =~ "integrity='#{integrity}'"
      assert script =~ "link=/home/sprite/.local/bin/claude-agent-acp"
      assert script =~ "flock -w 30 9"

      for removed <- ["npm", "curl", "registry", "manifest", "https://"] do
        refute script =~ removed
      end
    end

    test "codex installs the same way, from its own pin" do
      check_misses()
      %{file: file, integrity: integrity} = sidecar("codex")
      expect(BundleCache, :fetch, fn ^file, _, _ -> {:ok, "codex bytes"} end)
      stub_install(0)

      assert :ok = ACP.install(@handle, "codex", [])
      assert_receive {:installed, script, _opts}
      assert script =~ "dir=/home/sprite/.local/share/managoat/acp/codex-acp@2.2.2"
      assert script =~ "link=/home/sprite/.local/bin/codex-acp"
      assert script =~ "integrity='#{integrity}'"
      assert script =~ "@agentclientprotocol/codex-acp/dist/index.js"
    end

    test "a bundle the host cannot get fails the install and starts nothing" do
      check_misses()
      expect(BundleCache, :fetch, fn _, _, _ -> {:error, :bundle_integrity} end)
      reject(&Sandbox.spawn/4)

      assert {:error, {:acp_adapter_bundle, :bundle_integrity}} =
               ACP.install(@handle, "claude", [])
    end

    test "the release build fetches each bundle from its immutable release tag" do
      for runtime <- ["claude", "codex"] do
        %{url: url, file: file, integrity: integrity} = sidecar(runtime)

        assert %{url: ^url, file: ^file, integrity: ^integrity} =
                 Map.fetch!(ACP.bundles(), runtime)
      end
    end

    test "every provider runs the image CLI" do
      for runtime <- ["claude", "codex"], provider <- [:sprites, :e2b] do
        assert installer(runtime, provider) =~ "select_image_executable"
      end
    end

    test "a failed install retains bounded terminal diagnostics" do
      long = String.duplicate("e", 2_500) <> "terminal failure"
      stub(BundleCache, :fetch, fn _, _, _ -> {:ok, "bytes"} end)
      check_misses()
      stub_install(1, long)

      assert {:error, {:acp_adapter_install_exit, 1, out}} = ACP.install(@handle, "claude", [])
      assert byte_size(out) == 2_000
      assert String.ends_with?(out, "terminal failure")

      check_misses()
      expect(Sandbox, :write_file, fn _h, _p, _b -> {:error, :unavailable} end)
      assert {:error, {:acp_adapter_install, :unavailable}} = ACP.install(@handle, "claude", [])
    end
  end

  defp check_misses do
    expect(Sandbox, :exec, fn _h, "bash", ["-lc", script], _o ->
      refute script =~ "flock"
      {:ok, "", 75}
    end)
  end

  defp stub_install(code, out \\ "") do
    test = self()

    stub(Sandbox, :write_file, fn _handle, _path, bytes ->
      send(test, {:uploaded, bytes})
      :ok
    end)

    stub(Sandbox, :exec, fn _handle, "bash", ["-lc", script], opts ->
      send(test, {:installed, script, opts})
      {:ok, out, code}
    end)
  end

  # The bundle the reviewed sidecar beside a pin's TSV lock names.
  defp sidecar(runtime) do
    {_package, pin} = Map.fetch!(@pins, runtime)
    version = pin |> String.split("@") |> List.last()

    %{"file" => file, "integrity" => integrity} =
      Path.expand("../../../priv/runtimes/acp/#{pin}.bundle.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()
      |> get_in(["artifacts", "gzip"])

    %{
      url:
        "https://github.com/managoat/managoat/releases/download/acp-bundle-#{runtime}-#{version}/#{file}",
      file: file,
      integrity: integrity
    }
  end

  # The installer, run for real against a home directory standing in for a
  # sprite's: the staged bundle is a fixture whose SHA-512 replaces the pinned
  # one, and the image CLIs are scripts that print a version.
  describe "the bundle installer" do
    @tag :tmp_dir
    test "installs both adapters on the image CLI, then consumes the bundle", %{tmp_dir: root} do
      for runtime <- ~w(claude codex) do
        home = Path.join(root, runtime)
        image = image_cli_for(home, runtime)
        edit = bundle_fixture(home, runtime)

        assert {out, 0, ""} = run_installer(home, "", runtime, edit)
        assert out =~ "__MANAGOAT_INSTALL__ cache_hit 0"
        dir = install_dir(home, runtime)

        assert File.read!(Path.join(dir, "node_modules/#{package(runtime)}/dist/index.js")) ==
                 "verified entry"

        assert File.read!(Path.join(dir, ".#{runtime}-executable")) == image <> "\n"
        assert File.read!(Path.join(dir, ".install-timing")) =~ "method bundle"
        assert File.read!(Path.join(dir, ".installed")) == version(runtime)

        assert File.read_link!(Path.join(home, ".local/bin/#{bin(runtime)}")) ==
                 Path.join(dir, "launch")

        refute File.exists?(staged(home, runtime))
        assert installs(home, runtime) == [dir]
        assert String.starts_with?(dir, versioned_dir(home, runtime) <> ".")

        # The launcher hands the recorded executable to the adapter in the
        # variable it reads instead of spawning a bundled CLI.
        env = if runtime == "claude", do: "CLAUDE_CODE_EXECUTABLE", else: "CODEX_PATH"
        node = Path.join(home, "inspect-node")
        File.write!(node, "#!/bin/sh\nprintf '%s' \"$#{env}\"\n")
        File.chmod!(node, 0o755)
        File.write!(Path.join(dir, ".node"), node <> "\n")
        assert {^image, 0} = System.cmd(Path.join(dir, "launch"), [])

        # Installed: any uploaded file is discarded without being read.
        File.write!(staged(home, runtime), "unused upload")
        assert {cached, 0, ""} = run_installer(home, "", runtime, edit)
        assert cached == "__MANAGOAT_INSTALL__ cache_hit 1\n"
        refute File.exists?(staged(home, runtime))
      end
    end

    @tag :tmp_dir
    test "phase timings cover the bundle path and survive a misbehaving date", %{tmp_dir: home} do
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")
      formats = Path.join(home, "date-formats")

      # uutils coreutils, which the Sprites image ships as `date`, truncates
      # the *unpadded* nanoseconds for %3N (#2908). The phase clock does not
      # ask `date` at all when bash has EPOCHREALTIME.
      shim = ~s"""
      date() { printf '%s\\n' "$1" >>#{formats}; command date "$@"; }
      export -f date
      """

      assert {out, 0, ""} = run_installer(home, shim, "claude", edit)
      attrs = Managoat.Runtimes.InstallTiming.attributes(out)

      for phase <-
            ~w(lock_wait image_probe bundle_extract finalize node_wait link) do
        assert attrs["install_" <> phase <> "_ms"] in 0..180_000
      end

      assert attrs["install_cache_hit"] == 0
      assert attrs["install_timing_suspect"] == 0
      refute File.exists?(formats) and File.read!(formats) =~ "3N"

      assert File.read!(Path.join(install_dir(home), ".install-timing")) =~
               ~r/^start \d+\.\d{3}$/m
    end

    @tag :tmp_dir
    test "with no pushed bundle it fails closed and publishes nothing", %{tmp_dir: home} do
      image_claude(home, "2.1.296")
      assert {out, status, ""} = run_installer(home)
      assert status != 0
      assert out =~ "adapter install failed: step=deliver: no adapter bundle was delivered"
      assert_unpublished(home)
    end

    # `preload/2` runs the same installer before the floor; a failure there is
    # 75 and silent, since the host installs again after the floor.
    @tag :tmp_dir
    test "offline, it installs a pushed bundle, and any failure is a silent 75", %{tmp_dir: root} do
      home = Path.join(root, "ok")
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")
      assert {out, 0, ""} = run_installer(home, "export MANAGOAT_ACP_OFFLINE=1", "claude", edit)
      assert out =~ "cache_hit 0"
      assert File.read!(Path.join(install_dir(home), ".installed")) == "0.81.2"

      for failure <- ~w(integrity missing no_image) do
        home = Path.join(root, failure)
        if failure != "no_image", do: image_claude(home, "2.1.296")
        edit = bundle_fixture(home, "claude")
        if failure == "integrity", do: File.write!(staged(home, "claude"), "not the bundle")
        if failure == "missing", do: File.rm!(staged(home, "claude"))

        assert {out, 75, ""} =
                 run_installer(home, "export MANAGOAT_ACP_OFFLINE=1", "claude", edit)

        refute out =~ "adapter install failed"
        assert_unpublished(home)
        refute File.exists?(staged(home, "claude"))
      end
    end

    @tag :tmp_dir
    test "a bundle that is not the pinned one fails closed, with no fallback", %{tmp_dir: home} do
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")
      wrong = &Regex.replace(~r/^integrity=.*$/m, edit.(&1), "integrity='sha512-AAAA'")

      assert {out, status, calls} = run_installer(home, "", "claude", wrong)
      assert status != 0

      assert out =~
               "adapter install failed: step=verify: the adapter bundle does not match its pinned SHA-512"

      assert calls == ""
      assert_unpublished(home)
    end

    @tag :tmp_dir
    test "an archive that does not extract fails closed and clears staging", %{tmp_dir: home} do
      image_claude(home, "2.1.296")
      File.mkdir_p!(Path.dirname(staged(home, "claude")))
      File.write!(staged(home, "claude"), "not a gzip archive")
      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "not a gzip archive"))
      edit = &Regex.replace(~r/^integrity=.*$/m, &1, "integrity='#{sri}'")

      assert {out, status, ""} = run_installer(home, "", "claude", edit)
      assert status != 0
      assert out =~ "adapter install failed: step=extract: the adapter bundle did not extract"
      assert_unpublished(home)
    end

    @tag :tmp_dir
    test "a missing, old, malformed or failing image CLI fails closed, naming the floor", %{
      tmp_dir: root
    } do
      # Each failure also reports its status and the first line the CLI
      # printed, which the host turns into its own provision failure (#2968).
      cases = [
        {"claude", nil, 0, "no working claude >= 2.1.280 on PATH", "missing "},
        {"claude", "2.1.279", 0, "no working claude >= 2.1.280 on PATH",
         "below_floor 2.1.279 (Claude Code)"},
        {"claude", "unknown", 0, "no working claude >= 2.1.280 on PATH",
         "unparsed unknown (Claude Code)"},
        {"claude", "2.1.296", 1, "no working claude >= 2.1.280 on PATH",
         "exit:1 2.1.296 (Claude Code)"},
        {"codex", nil, 0, "no working codex >= 0.160.1 on PATH", "missing "},
        {"codex", "0.160.0", 0, "no working codex >= 0.160.1 on PATH",
         "below_floor codex-cli 0.160.0"},
        {"codex", "unknown", 0, "no working codex >= 0.160.1 on PATH",
         "unparsed codex-cli unknown"},
        {"codex", "0.162.1", 1, "no working codex >= 0.160.1 on PATH", "exit:1 codex-cli 0.162.1"}
      ]

      for {runtime, version, status, message, probe} <- cases do
        home = Path.join(root, "#{runtime}-#{version}-#{status}")

        if version do
          if runtime == "claude",
            do: image_claude(home, version, status),
            else: image_codex(home, version, status)
        end

        edit = bundle_fixture(home, runtime)
        assert {out, code, ""} = run_installer(home, "", runtime, edit)
        assert code != 0
        assert out =~ "step=image_probe: " <> message
        assert out =~ "\n__MANAGOAT_IMAGE_PROBE__ #{probe}\n"
        assert installs(home, runtime) == []
      end

      # At the floor exactly is enough.
      home = Path.join(root, "floor")
      image_codex(home, "0.160.1")
      assert {_, 0, ""} = run_installer(home, "", "codex", bundle_fixture(home, "codex"))
    end

    # The first X.Y.Z on the first line is the version, wherever it sits: an
    # image CLI that adds a suffix, a word or a line is still the CLI (#2968).
    @tag :tmp_dir
    test "the version is read from the first line of each runtime output, suffixes included", %{
      tmp_dir: root
    } do
      cases = [
        {"claude", "2.1.296 (Claude Code)"},
        {"claude", "2.1.300-beta.1 (Claude Code)"},
        {"claude", "2.1.300+build.7"},
        {"claude", "Claude Code 2.1.300\nupdate available: 2.1.301"},
        {"codex", "codex-cli 0.162.1"},
        {"codex", "codex-cli 0.163.0-alpha.2"},
        {"codex", "codex-cli 0.163.0 (linux x64)\nsecond line"}
      ]

      for {{runtime, printed}, i} <- Enum.with_index(cases) do
        home = Path.join(root, "#{runtime}-#{i}")
        image = image_printing(home, runtime, printed)
        edit = bundle_fixture(home, runtime)

        assert {out, 0, ""} = run_installer(home, "", runtime, edit), printed
        refute out =~ "__MANAGOAT_IMAGE_PROBE__"

        assert File.read!(Path.join(install_dir(home, runtime), ".#{runtime}-executable")) ==
                 image <> "\n"
      end

      # The floor still holds on a suffixed version, and only the first line counts.
      for {runtime, printed, probe} <- [
            {"claude", "2.1.279-beta.9 (Claude Code)",
             "below_floor 2.1.279-beta.9 (Claude Code)"},
            {"codex", "codex-cli\n0.162.1", "unparsed codex-cli"}
          ] do
        home = Path.join(root, "#{runtime}-refused")
        image_printing(home, runtime, printed)
        assert {out, code, ""} = run_installer(home, "", runtime, bundle_fixture(home, runtime))
        assert code != 0
        assert out =~ "\n__MANAGOAT_IMAGE_PROBE__ #{probe}\n"
      end
    end

    @tag :tmp_dir
    test "a probe that fails once is retried with a longer limit", %{tmp_dir: home} do
      count = Path.join(home, "probes")
      limits = Path.join(home, "limits")

      # Fails its first run, as a CLI too slow to start in 5 s would, and
      # records the limit `timeout` was given each time.
      image =
        image_cli(home, "claude", ".local/share/claude/versions/2.1.296", [
          "2.1.296 (Claude Code)",
          ~s{$(echo x >>#{count}; [ "$(wc -l <#{count})" -gt 1 ] && echo 0 || echo 124)}
        ])

      shim = ~s"""
      timeout() { printf '%s\\n' "$1" >>#{limits}; shift; "$@"; }
      """

      assert {out, 0, ""} = run_installer(home, shim, "claude", bundle_fixture(home, "claude"))
      refute out =~ "__MANAGOAT_IMAGE_PROBE__"
      assert File.read!(limits) == "5\n15\n"
      assert File.read!(Path.join(install_dir(home), ".claude-executable")) == image <> "\n"

      # Timing out twice fails closed, reporting what the CLI printed.
      home = Path.join(home, "slow")

      image_cli(home, "claude", ".local/share/claude/versions/2.1.296", [
        "2.1.296 (Claude Code)",
        124
      ])

      assert {out, code, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
      assert code != 0
      assert out =~ "\n__MANAGOAT_IMAGE_PROBE__ timeout 2.1.296 (Claude Code)\n"
      assert out =~ "step=image_probe: no working claude >= 2.1.280 on PATH (timeout)"
    end

    @tag :tmp_dir
    test "an install whose image CLI was removed is repaired against the current image CLI",
         %{tmp_dir: home} do
      image = image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")
      assert {_, 0, ""} = run_installer(home, "", "claude", edit)

      File.rm!(image)
      File.rm!(Path.join(home, ".local/bin/claude"))
      newer = image_claude(home, "2.1.300")
      edit = bundle_fixture(home, "claude")
      old = install_dir(home)
      assert {out, 0, ""} = run_installer(home, "", "claude", edit)
      assert out =~ "cache_hit 0"
      assert File.read!(Path.join(linked_dir(home), ".claude-executable")) == newer <> "\n"

      # The repair is a new directory: the one an adapter from the previous
      # connection may still be running from is left exactly as it was (#2969).
      assert linked_dir(home) != old
      assert installs(home) == Enum.sort([old, linked_dir(home)])
      assert File.read!(Path.join(old, ".claude-executable")) == image <> "\n"

      assert File.read!(Path.join(old, "node_modules/#{package("claude")}/dist/index.js")) ==
               "verified entry"
    end

    # The layout before #2969: the pin's directory itself, linked by name.
    @tag :tmp_dir
    test "an install in the unsuffixed pin directory is kept, and repaired beside it", %{
      tmp_dir: home
    } do
      image = image_claude(home, "2.1.296")
      assert {_, 0, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
      legacy = versioned_dir(home)
      File.rename!(install_dir(home), legacy)
      link = Path.join(home, ".local/bin/claude-agent-acp")
      File.rm!(link)
      File.ln_s!(Path.join(legacy, "launch"), link)

      assert {out, 0, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
      refute out =~ "cache_hit 0"
      assert File.read_link!(link) == Path.join(legacy, "launch")

      # The image moved its CLI: a fresh directory, the old one untouched.
      File.rm!(image)
      File.rm!(Path.join(home, ".local/bin/claude"))
      image_claude(home, "2.1.300")
      assert {out, 0, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
      assert out =~ "cache_hit 0"
      assert String.starts_with?(linked_dir(home), legacy <> ".")
      assert File.read!(Path.join(legacy, ".installed")) == "0.81.2"
      assert File.read!(Path.join(legacy, ".claude-executable")) == image <> "\n"
    end

    @tag :tmp_dir
    test "a lock another install holds is waited on for 30 s, then named", %{tmp_dir: home} do
      image_claude(home, "2.1.296")
      waits = Path.join(home, "waits")
      # `flock` answers as it does when the wait runs out.
      shim = ~s|flock() { printf '%s\\n' "$*" >>#{waits}; return 1; }|

      assert {out, code, ""} = run_installer(home, shim, "claude", bundle_fixture(home, "claude"))
      assert code != 0
      assert File.read!(waits) == "-w 30 9\n"

      assert out =~
               "adapter install failed: step=lock: another install of this adapter held its lock for 30 s"

      assert_unpublished(home)
    end

    @tag :tmp_dir
    test "a failed install stops the background Node lookup and leaves the lock free", %{
      tmp_dir: home
    } do
      image_claude(home, "2.1.296")
      File.mkdir_p!(Path.dirname(staged(home, "claude")))
      File.write!(staged(home, "claude"), "not a gzip archive")
      sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, "not a gzip archive"))
      edit = &Regex.replace(~r/^integrity=.*$/m, &1, "integrity='#{sri}'")
      pid_file = Path.join(home, "node.pid")
      fds = Path.join(home, "node.fds")

      # A Node lookup that would outlive the install, as a slow nvm shim's
      # does: it records its pid and its open descriptors, then sleeps.
      shim = ~s"""
      node() { echo $BASHPID >#{pid_file}; ls /proc/$BASHPID/fd >#{fds}; exec sleep 30; }
      """

      {micros, {out, code, ""}} =
        :timer.tc(fn -> run_installer(home, shim, "claude", edit) end)

      assert code != 0
      assert out =~ "step=extract: the adapter bundle did not extract"
      assert micros < 10_000_000

      # The lookup may be stopped before it records anything: the extract
      # fails at once. Whatever it recorded came from a process that is gone,
      # and that never held the lock's descriptor.
      case pid_file |> read_if_present() |> String.trim() do
        "" -> :ok
        pid -> refute File.exists?("/proc/#{pid}")
      end

      refute "9" in String.split(read_if_present(fds))

      lock = versioned_dir(home) <> ".lock"
      assert {_, 0} = System.cmd("flock", ["-n", lock, "true"])
      assert_unpublished(home)
    end

    @tag :tmp_dir
    test "an install still running at its deadline is stopped with everything it started", %{
      tmp_dir: home
    } do
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")
      # An extract that hangs, holding the lock.
      shim = """
      export MANAGOAT_ACP_DEADLINE_S=1
      tar() { sleep 30; }
      """

      {micros, {out, code, ""}} =
        :timer.tc(fn -> run_installer(home, shim, "claude", edit) end)

      assert code != 0
      # A surviving `sleep` would hold the exec's output open for 30 s.
      assert micros < 10_000_000

      assert out =~
               "adapter install failed: step=deadline: the install was still running after 1 s and was stopped"

      lock = versioned_dir(home) <> ".lock"
      assert {_, 0} = System.cmd("flock", ["-n", lock, "true"])
      refute File.exists?(Path.join(home, ".local/bin/claude-agent-acp"))

      # The stopped run's staging was never linked; the next install clears it.
      assert [_abandoned] = installs(home)
      assert {_, 0, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
      assert installs(home) == [linked_dir(home)]
    end

    @tag :tmp_dir
    test "arm and musl sandboxes fail closed: the bundle is Linux x64 glibc", %{tmp_dir: root} do
      for {platform, override, message} <- [
            {"arm", "uname() { if [ \"$1\" = -m ]; then echo aarch64; else echo Linux; fi; }",
             "built for x64"},
            {"musl", "ldd() { echo musl; }", "built for glibc"}
          ] do
        home = Path.join(root, platform)
        image_claude(home, "2.1.296")
        edit = bundle_fixture(home, "claude")
        assert {out, code, ""} = run_installer(home, override, "claude", edit)
        assert code != 0
        assert out =~ "step=platform: the adapter bundle is " <> message
        assert_unpublished(home)
      end
    end

    @tag :tmp_dir
    test "an installed pin is recognised without running anything", %{tmp_dir: home} do
      target = installed_fixture(home)
      File.ln_s!(target, Path.join(home, ".local/bin/claude-agent-acp"))

      assert {out, 0, ""} = run_installer(home)
      assert Managoat.Runtimes.InstallTiming.attributes(out) == %{"install_cache_hit" => 1}
    end

    @tag :tmp_dir
    test "a missing link is repointed without reinstalling", %{tmp_dir: home} do
      target = installed_fixture(home)

      assert {out, 0, ""} = run_installer(home)
      refute out =~ "cache_hit 0"
      assert File.read_link!(Path.join(home, ".local/bin/claude-agent-acp")) == target
    end

    @tag :tmp_dir
    test "an install from before the launcher gains one without reinstalling", %{tmp_dir: home} do
      target = installed_fixture(home)
      File.rm!(target)
      File.rm!(Path.join(install_dir(home), ".node"))

      entry =
        Path.join(
          install_dir(home),
          "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        )

      File.ln_s!(entry, Path.join(home, ".local/bin/claude-agent-acp"))

      assert {out, 0, ""} = run_installer(home)
      refute out =~ "cache_hit 0"
      assert File.read_link!(Path.join(home, ".local/bin/claude-agent-acp")) == target
      assert File.read!(Path.join(install_dir(home), ".node")) == "/opt/node/bin/node\n"
      assert {_, 0} = System.cmd("test", ["-x", target])
    end

    @tag :tmp_dir
    test "the launcher runs the entry on the recorded node, not the one on PATH", %{tmp_dir: home} do
      launch = installed_fixture(home)
      recorded = fake_node(home, "recorded")
      File.write!(Path.join(install_dir(home), ".node"), recorded <> "\n")
      on_path = fake_node(Path.join(home, "path"), "shim")

      {out, 0} =
        System.cmd(launch, ["--flag", "two words"],
          env: [{"PATH", Path.dirname(on_path) <> ":/usr/bin:/bin"}]
        )

      entry =
        Path.join(
          install_dir(home),
          "node_modules/@agentclientprotocol/claude-agent-acp/dist/index.js"
        )

      assert out == "recorded|#{entry}|--flag|two words\n"
    end

    @tag :tmp_dir
    test "a recorded node that is gone or relative falls back to the one on PATH", %{
      tmp_dir: home
    } do
      launch = installed_fixture(home)
      on_path = fake_node(Path.join(home, "path"), "shim")
      env = [{"PATH", Path.dirname(on_path) <> ":/usr/bin:/bin"}]

      for recorded <- ["/no/such/node\n", "node\n", ""] do
        File.write!(Path.join(install_dir(home), ".node"), recorded)
        assert {"shim|" <> _, 0} = System.cmd(launch, [], env: env)
      end

      File.rm!(Path.join(install_dir(home), ".node"))
      assert {"shim|" <> _, 0} = System.cmd(launch, [], env: env)
    end
  end

  describe "the Node the launcher records" do
    @tag :tmp_dir
    test "the image shim selects Node even when nvm holds one Node", %{tmp_dir: home} do
      fake_nvm(home, ["v24.18.0"])
      shim = node_shim(home)
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")

      assert {_out, 0, _} =
               run_installer(home, "unset -f node; export NVM_DIR=#{home}/nvm", "claude", edit)

      assert File.read!(Path.join(install_dir(home), ".node")) == "/opt/shim-chose/node\n"
      assert File.exists?(shim <> ".ran")
    end

    @tag :tmp_dir
    test "with several Nodes in nvm the shim chooses", %{tmp_dir: home} do
      fake_nvm(home, ["v22.1.0", "v24.18.0"])
      shim = node_shim(home)
      image_claude(home, "2.1.296")
      edit = bundle_fixture(home, "claude")

      assert {_out, 0, _} =
               run_installer(home, "unset -f node; export NVM_DIR=#{home}/nvm", "claude", edit)

      assert File.read!(Path.join(install_dir(home), ".node")) == "/opt/shim-chose/node\n"
      assert File.exists?(shim <> ".ran")
    end
  end

  defp fake_nvm(home, versions) do
    for v <- versions do
      node = Path.join(home, "nvm/versions/node/#{v}/bin/node")
      File.mkdir_p!(Path.dirname(node))
      File.write!(node, "#!/bin/sh\nexit 0\n")
      File.chmod!(node, 0o755)
      node
    end
    |> List.last()
  end

  # A sprite-like `node` on PATH: a script that notes it ran and answers
  # `node -p process.execPath` with a path of its own choosing.
  defp node_shim(home) do
    shim = Path.join(home, ".local/bin/node")
    File.mkdir_p!(Path.dirname(shim))
    File.write!(shim, "#!/bin/bash\n: >#{shim}.ran\necho /opt/shim-chose/node\n")
    File.chmod!(shim, 0o755)
    shim
  end

  # A gzip bundle holding the adapter's entry, staged where the server writes
  # it; answers the edit that pins the installer to its SHA-512.
  defp bundle_fixture(home, runtime) do
    tree = Path.join(home, "bundle-tree-#{System.unique_integer([:positive])}")
    entry = Path.join(tree, "node_modules/#{package(runtime)}/dist/index.js")
    File.mkdir_p!(Path.dirname(entry))
    File.write!(entry, "verified entry")
    archive = staged(home, runtime)
    File.mkdir_p!(Path.dirname(archive))
    assert {_, 0} = System.cmd("tar", ["-czf", archive, "-C", tree, "."])
    sri = "sha512-" <> Base.encode64(:crypto.hash(:sha512, File.read!(archive)))
    &Regex.replace(~r/^integrity=.*$/m, &1, "integrity='#{sri}'")
  end

  defp image_cli_for(home, "claude"), do: image_claude(home, "2.1.280")
  defp image_cli_for(home, "codex"), do: image_codex(home, "0.160.1")

  defp image_claude(home, version, status \\ 0) do
    image_cli(home, "claude", ".local/share/claude/versions/#{version}", [
      "#{version} (Claude Code)",
      status
    ])
  end

  # The image's own `codex`, as the Sprite image lays it out: a versioned
  # standalone release behind a `current` symlink, which is why the installer
  # resolves the link before recording what it selected.
  defp image_codex(home, version, status \\ 0) do
    image_cli(home, "codex", ".codex/packages/standalone/releases/#{version}/bin/codex", [
      "codex-cli #{version}",
      status
    ])
  end

  # An image CLI whose `--version` prints exactly `printed`, at a path that
  # does not depend on it.
  defp image_printing(home, "claude", printed),
    do: image_cli(home, "claude", ".local/share/claude/versions/current", [printed, 0])

  defp image_printing(home, "codex", printed),
    do: image_cli(home, "codex", ".codex/packages/standalone/current/bin/codex", [printed, 0])

  defp image_cli(home, name, relative, [printed, status]) do
    path = Path.join(home, relative)
    link = Path.join(home, ".local/bin/#{name}")
    File.mkdir_p!(Path.dirname(path))
    File.mkdir_p!(Path.dirname(link))
    File.write!(path, "#!/bin/sh\necho '#{printed}'\nexit #{status}\n")
    File.chmod!(path, 0o755)
    File.ln_s!(path, link)
    path
  end

  # One runtime's installer, run for real under `bash -lc` with `/home/sprite`
  # moved to `home`. The home has a ~/.bash_logout that fails, as the sprite's
  # does outside a console: an `exit` at the installer's top level would turn
  # success into exit 1 (the bug a fast-path `exit 0` shipped with). `npm` and
  # `curl` record any call, which no path may make. Answers {output, status,
  # calls}.
  defp run_installer(home, overrides \\ "", runtime \\ "claude", edit \\ & &1) do
    File.mkdir_p!(Path.join(home, ".local/bin"))
    File.write!(Path.join(home, ".bash_logout"), "false\n")
    calls = Path.join(home, "calls")

    script =
      installer(runtime, :sprites)
      |> String.replace("/home/sprite", home)
      |> edit.()

    # `node -p process.execPath` answers as a sprite's would, from an nvm tree.
    stubs = ~s"""
    export PATH="#{home}/.local/bin:/usr/bin:/bin"
    node() { echo /opt/node/bin/node; }
    npm() { echo "npm $*" >>"#{calls}"; }
    curl() { echo "curl $*" >>"#{calls}"; }
    #{stdin(home, runtime)}
    """

    {out, status} =
      System.cmd("bash", ["-lc", stubs <> overrides <> "\n" <> script],
        env: [{"HOME", home}],
        stderr_to_stdout: true
      )

    {out, status, if(File.exists?(calls), do: File.read!(calls), else: "")}
  end

  defp read_if_present(path) do
    case File.read(path) do
      {:ok, contents} -> contents
      {:error, :enoent} -> ""
    end
  end

  # The script `ACP.install/3` runs for `runtime` on `provider`, as it hands it
  # to the sandbox.
  defp installer(runtime, provider) do
    stub(BundleCache, :fetch, fn _file, _integrity, _max -> {:ok, "bytes"} end)
    check_misses()
    stub_install(0)

    :ok = ACP.install(%{@handle | provider: provider}, runtime, [])
    assert_received {:installed, script, _opts}
    script
  end

  # The uploaded bundle file, when the test staged one.
  defp stdin(home, runtime) do
    if File.exists?(staged(home, runtime)),
      do: "export MANAGOAT_ACP_BUNDLE_FILE='#{staged(home, runtime)}'",
      else: ""
  end

  defp package(runtime), do: @pins |> Map.fetch!(runtime) |> elem(0)

  defp version(runtime),
    do: @pins |> Map.fetch!(runtime) |> elem(1) |> String.split("@") |> List.last()

  defp bin(runtime), do: @pins |> Map.fetch!(runtime) |> elem(1) |> String.split("@") |> hd()

  # Where installs from before #2969 lived, and the prefix of every install
  # directory since.
  defp versioned_dir(home, runtime \\ "claude"),
    do: Path.join(home, ".local/share/managoat/acp/#{@pins |> Map.fetch!(runtime) |> elem(1)}")

  # Every directory of the pin's, staged or published, sorted.
  defp installs(home, runtime \\ "claude") do
    prefix = versioned_dir(home, runtime)
    parent = Path.dirname(prefix)

    case File.ls(parent) do
      {:ok, names} ->
        for name <- Enum.sort(names),
            path = Path.join(parent, name),
            String.starts_with?(path, prefix <> "."),
            File.dir?(path),
            do: path

      {:error, :enoent} ->
        []
    end
  end

  # The one install of the pin.
  defp install_dir(home, runtime \\ "claude") do
    case installs(home, runtime) do
      [dir] -> dir
      dirs -> flunk("expected one install of #{runtime}, found #{inspect(dirs)}")
    end
  end

  # The install the PATH link publishes.
  defp linked_dir(home, runtime \\ "claude"),
    do: Path.dirname(File.read_link!(Path.join(home, ".local/bin/#{bin(runtime)}")))

  # The bundle the host would upload, on disk for the test.
  defp staged(home, runtime), do: Path.join(home, "uploaded-#{runtime}.tar.gz")

  # An installed pin as the installer leaves it, launcher included, but with
  # no PATH link; answers the launcher's path, which is what the link points at.
  defp installed_fixture(home) do
    image_claude(home, "2.1.296")
    {_out, 0, ""} = run_installer(home, "", "claude", bundle_fixture(home, "claude"))
    File.rm!(Path.join(home, ".local/bin/claude-agent-acp"))
    Path.join(install_dir(home), "launch")
  end

  # A `node` that prints its name and argv, `|`-separated.
  defp fake_node(dir, name) do
    File.mkdir_p!(dir)
    path = Path.join(dir, "node")
    File.write!(path, ~s(#!/bin/sh\nIFS='|'; echo "#{name}|$*"\n))
    File.chmod!(path, 0o755)
    path
  end

  # Nothing linked, and no staging left behind.
  defp assert_unpublished(home) do
    assert installs(home) == []
    refute File.exists?(Path.join(versioned_dir(home), ".installed"))
    refute File.exists?(Path.join(home, ".local/bin/claude-agent-acp"))
  end
end
