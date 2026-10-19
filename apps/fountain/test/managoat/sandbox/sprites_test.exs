defmodule Managoat.Sandbox.SpritesTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Sandbox.Command
  alias Managoat.Sandbox.Handle
  alias Managoat.Sandbox.NetworkPolicy
  alias Managoat.Sandbox.Session
  alias Managoat.Sandbox.Sprites, as: Adapter

  @name "fountain-abc12345-deadbeef"

  defp handle, do: %Handle{provider: :sprites, name: @name}

  defp stub_client do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test-token"} end)

    stub(Managoat.Sandbox.Sprites.Client, :get!, fn _opts ->
      %Sprites.Client{token: "test-token"}
    end)
  end

  describe "identity" do
    test "provider/0 and pure build_handle/1" do
      assert Adapter.provider() == :sprites
      assert %Handle{provider: :sprites, name: @name, private: nil} = Adapter.build_handle(@name)
    end

    test "capabilities: :suspend (implicit park), network policy, attach" do
      caps = Adapter.capabilities()
      assert MapSet.member?(caps, :network_policy)
      assert MapSet.member?(caps, :attach)
      assert MapSet.member?(caps, :suspend)
    end

    test "a handle's inspect never leaks the client token" do
      client = %Sprites.Client{token: "sekrit-token"}
      sprite = %Sprites.Sprite{name: @name, client: client}
      handle = %Handle{provider: :sprites, name: @name, private: sprite}

      refute inspect(handle) =~ "sekrit-token"
    end
  end

  describe "create/2" do
    test "wraps a created sprite in a handle" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:ok, %Sprites.Sprite{name: @name}} end)
      stub(Sprites, :update_url_settings, fn _sprite, _settings -> :ok end)

      assert {:ok, %Handle{provider: :sprites, name: @name}} = Adapter.create(@name, [])
    end

    # Sprites' URLs default to `auth: sprite` — reachable only with a platform
    # credential, which is not what an agent serving a page for a human needs.
    test "opens the sprite's URL to the public" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:ok, %Sprites.Sprite{name: @name}} end)

      test_pid = self()

      stub(Sprites, :update_url_settings, fn _sprite, settings ->
        send(test_pid, {:url_settings, settings})
        :ok
      end)

      assert {:ok, %Handle{}} = Adapter.create(@name, [])
      assert_receive {:url_settings, %{auth: "public"}}
    end

    # A sandbox that provisions but cannot be made public is still a working
    # sandbox; trading the whole conversation for the URL setting would be the
    # wrong bargain.
    test "a failed url-settings call does not fail the create" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:ok, %Sprites.Sprite{name: @name}} end)
      stub(Sprites, :update_url_settings, fn _sprite, _settings -> {:error, :boom} end)

      assert {:ok, %Handle{provider: :sprites, name: @name}} = Adapter.create(@name, [])
    end

    # The `public_urls: false` case writes adapter config, so it lives in
    # sprites_public_urls_test.exs, an `async: false` sibling.
  end

  describe "public_url/1" do
    test "reports the URL the platform assigned" do
      stub_client()

      stub(Sprites, :get_sprite, fn _client, @name ->
        {:ok, %{"name" => @name, "url" => "https://#{@name}-abc12.sprites.app"}}
      end)

      assert {:ok, "https://" <> _} = Adapter.public_url(%Handle{provider: :sprites, name: @name})
    end

    # A sprite with no url field is not an error to shout about — it is a
    # platform that did not give this sandbox an endpoint.
    test "a sprite with no url is unsupported, not a failure" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:ok, %{"name" => @name}} end)

      assert {:error, :unsupported} =
               Adapter.public_url(%Handle{provider: :sprites, name: @name})
    end

    test "provider failures are normalized" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:error, {:api_error, 503, %{}}} end)

      assert {:error, {:unavailable, {:http, 503, %{}}}} = Adapter.public_url(handle())
    end

    test "adopts on 409 — the name already exists" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:error, {:api_error, 409, %{}}} end)

      assert {:ok, %Handle{provider: :sprites, name: @name}} = Adapter.create(@name, [])
    end

    test "normalizes other errors" do
      stub_client()
      stub(Sprites, :create, fn _client, @name, [] -> {:error, {:api_error, 500, %{}}} end)

      assert {:error, {:unavailable, {:http, 500, %{}}}} = Adapter.create(@name, [])
    end
  end

  describe "get/1" do
    test "normalizes status and keeps the raw body" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:ok, %{"status" => "running"}} end)

      assert {:ok, %{status: :running, raw: %{"status" => "running"}}} = Adapter.get(handle())
    end

    test "definitive not-found stays distinct from transient failures" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:error, {:not_found, %{}}} end)
      assert {:error, :not_found} = Adapter.get(handle())

      stub(Sprites, :get_sprite, fn _client, @name -> {:error, :timeout} end)
      assert {:error, {:unavailable, :timeout}} = Adapter.get(handle())
    end

    test "suspended and unfamiliar provider states normalize to the stable vocabulary" do
      stub_client()
      {:ok, status} = Agent.start_link(fn -> "paused" end)

      stub(Sprites, :get_sprite, fn _client, @name ->
        {:ok, %{"status" => Agent.get(status, & &1)}}
      end)

      assert {:ok, %{status: :suspended}} = Adapter.get(handle())
      Agent.update(status, fn _ -> "migrating" end)
      assert {:ok, %{status: :unknown}} = Adapter.get(handle())
    end
  end

  describe "destroy/1, suspend/1, resume/1" do
    test "destroy rebuilds the SDK sprite from a bare handle" do
      stub_client()

      stub(Sprites, :destroy, fn %Sprites.Sprite{name: @name} -> :ok end)
      assert :ok = Adapter.destroy(handle())
    end

    test "suspend is a documented no-op" do
      assert :ok = Adapter.suspend(handle())
    end

    test "resume probes and returns the handle" do
      stub_client()
      stub(Sprites, :get_sprite, fn _client, @name -> {:ok, %{"status" => "ready"}} end)
      assert {:ok, %Handle{name: @name}} = Adapter.resume(handle())

      stub(Sprites, :get_sprite, fn _client, @name -> {:error, {:not_found, %{}}} end)
      assert {:error, :not_found} = Adapter.resume(handle())
    end
  end

  describe "list_all_names/0" do
    test "passes the full view through and refuses truncation" do
      names = MapSet.new(["a", "b"])
      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:ok, names} end)
      assert {:ok, ^names} = Adapter.list_all_names()

      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn -> {:error, :truncated} end)
      assert {:error, :truncated} = Adapter.list_all_names()

      stub(Managoat.Sandbox.Sprites.Client, :list_all_names, fn ->
        {:error, {:api_error, 503, %{}}}
      end)

      assert {:error, {:unavailable, {:http, 503, %{}}}} = Adapter.list_all_names()
    end
  end

  describe "write_file/4" do
    test "writes through the SDK filesystem with the given mode" do
      stub_client()

      stub(Sprites, :filesystem, fn %Sprites.Sprite{name: @name}, "/" -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, "/home/sprite/.env", "A=1\n", mode: 0o600 ->
        :ok
      end)

      assert :ok = Adapter.write_file(handle(), "/home/sprite/.env", "A=1\n", mode: 0o600)
    end
  end

  describe "exec/4" do
    test "collects stdout and returns a nonzero exit as data, not an error" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, "bash", ["-lc", "x"], opts ->
        assert opts[:owner] == self()
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "he"})
        send(self(), {:stdout, %{ref: ref}, "llo"})
        send(self(), {:stderr, %{ref: ref}, "dropped"})
        send(self(), {:exit, %{ref: ref}, 3})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:ok, "hello", 3} = Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "stderr_to_stdout interleaves stderr into the output" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, "bash", _args, _opts ->
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "out"})
        send(self(), {:stderr, %{ref: ref}, "+err"})
        send(self(), {:exit, %{ref: ref}, 0})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:ok, "out+err", 0} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], stderr_to_stdout: true)
    end

    test "an :on_output sink gets each chunk as it arrives, and the result keeps none" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, "bash", _args, opts ->
        refute Keyword.has_key?(opts, :on_output)
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "out"})
        send(self(), {:stderr, %{ref: ref}, "+err"})
        send(self(), {:exit, %{ref: ref}, 0})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      test_pid = self()

      assert {:ok, "", 0} =
               Adapter.exec(handle(), "bash", ["-lc", "x"],
                 stderr_to_stdout: true,
                 on_output: &send(test_pid, {:chunk, self(), &1})
               )

      assert_received {:chunk, ^test_pid, "out"}
      assert_received {:chunk, ^test_pid, "+err"}
    end

    test "failure to start is a tagged error, never a raise" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts -> {:error, {:api_error, 401, %{}}} end)

      assert {:error, {:denied, {:http, 401, %{}}}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "a mid-run transport error frame is a tagged error" do
      stub_client()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts ->
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "partial"})
        send(self(), {:error, %{ref: ref}, :closed})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:error, {:provider, :sprites, :closed}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "a close before the exit frame is a transient error, not a clean run" do
      # sprites 0.2.2 reports the socket closing with no exit frame as
      # `:closed_before_exit`; 0.2.0 synthesised `{:exit, _, 0}`, which is
      # how a failed setup script read as a successful one (#880). exec must
      # answer with the error, and not with the output collected before it.
      stub_client()

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts ->
        ref = make_ref()
        send(self(), {:stdout, %{ref: ref}, "partial"})
        send(self(), {:error, %{ref: ref}, :closed_before_exit})
        {:ok, %Sprites.Command{ref: ref}}
      end)

      assert {:error, {:unavailable, :closed_before_exit}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], [])
    end

    test "timeout kills the command process and returns a transient error" do
      stub_client()
      lingering = spawn(fn -> Process.sleep(:infinity) end)
      ref = Process.monitor(lingering)

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts ->
        {:ok, %Sprites.Command{ref: make_ref(), pid: lingering}}
      end)

      assert {:error, {:unavailable, {:exec_timeout, 50}}} =
               Adapter.exec(handle(), "bash", ["-lc", "x"], timeout: 50)

      assert_receive {:DOWN, ^ref, :process, ^lingering, :killed}
    end
  end

  describe "spawn/4 and stdin" do
    test "wraps the SDK command, exposing its ref" do
      stub_client()
      sdk_ref = make_ref()

      stub(Sprites, :spawn, fn _sprite, "claude-agent-acp", [], _opts ->
        {:ok, %Sprites.Command{ref: sdk_ref}}
      end)

      assert {:ok, %Command{provider: :sprites, ref: ^sdk_ref}} =
               Adapter.spawn(handle(), "claude-agent-acp", [], stdin: true, detachable: true)
    end

    test "write_stdin is total: a dead command process yields :command_exited" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      command = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: dead}
      }

      assert {:error, :command_exited} = Adapter.write_stdin(command, "prompt\n")
    end

    test "write_stdin passes writes through when the command is alive" do
      sdk_command = %Sprites.Command{ref: make_ref(), pid: self()}
      command = %Command{provider: :sprites, ref: sdk_command.ref, private: sdk_command}

      stub(Sprites, :write, fn ^sdk_command, "data" -> :ok end)
      assert :ok = Adapter.write_stdin(command, "data")
    end

    test "stop_command stops a live command process and tolerates a dead one" do
      {:ok, agent} = Agent.start(fn -> :ok end)

      live = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: agent}
      }

      assert :ok = Adapter.stop_command(live)
      refute Process.alive?(agent)

      # Already stopped — total, no exit.
      assert :ok = Adapter.stop_command(live)

      # No private state at all (a handle that never carried the SDK struct).
      assert :ok = Adapter.stop_command(%Command{provider: :sprites, ref: make_ref()})
    end

    test "close_stdin on a dead command process is still :ok" do
      dead = spawn(fn -> :ok end)
      ref = Process.monitor(dead)
      assert_receive {:DOWN, ^ref, :process, ^dead, _reason}

      command = %Command{
        provider: :sprites,
        ref: make_ref(),
        private: %Sprites.Command{ref: make_ref(), pid: dead}
      }

      assert :ok = Adapter.close_stdin(command)
    end
  end

  describe "sessions" do
    test "list_sessions normalizes to Session structs without is_active" do
      stub_client()
      created = ~U[2026-08-14 10:00:00Z]

      stub(Sprites, :list_sessions, fn %Sprites.Sprite{name: @name} ->
        {:ok,
         [
           %Sprites.Session{
             id: "sess-1",
             command: "claude-agent-acp",
             created: created,
             last_activity: created,
             is_active: false,
             tty: true
           }
         ]}
      end)

      assert {:ok, [%Session{id: "sess-1", command: "claude-agent-acp", tty: true} = session]} =
               Adapter.list_sessions(handle())

      assert session.created_at == created
      refute Map.has_key?(session, :is_active)
    end

    test "attach wraps the re-joined command" do
      stub_client()
      sdk_ref = make_ref()

      stub(Sprites, :attach_session, fn %Sprites.Sprite{name: @name}, "sess-1", opts ->
        assert opts[:stdin] == true
        {:ok, %Sprites.Command{ref: sdk_ref}}
      end)

      assert {:ok, %Command{provider: :sprites, ref: ^sdk_ref}} =
               Adapter.attach(handle(), "sess-1", stdin: true)
    end
  end

  describe "network policy" do
    test "an empty allowlist compiles to an explicit standalone deny-all" do
      assert [%Sprites.Policy.Rule{domain: "*", action: "deny", include: nil}] =
               Adapter.compile_rules([])
    end

    test "hosts compile to allow rules" do
      assert [
               %Sprites.Policy.Rule{domain: "api.example.com", action: "allow"},
               %Sprites.Policy.Rule{domain: "*.github.com", action: "allow"}
             ] = Adapter.compile_rules(["api.example.com", "*.github.com"])
    end

    test "apply_network_policy sends the compiled rules — allow: [] is not a no-op" do
      stub_client()

      expect(Sprites, :update_network_policy, fn %Sprites.Sprite{name: @name},
                                                 %Sprites.Policy{rules: rules} ->
        assert [%Sprites.Policy.Rule{domain: "*", action: "deny", include: nil}] = rules
        :ok
      end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
    end
  end

  # A write resets the guest's open flows (fountain#2964), so an attach reads
  # the policy back and writes only when it differs.
  describe "network_policy_in_force?/2" do
    # The read reconfigures the client's Req request, so it needs a real one.
    defp read_client do
      stub(Managoat.Sandbox.Sprites.Client, :get!, fn _opts ->
        Sprites.new("test-token", base_url: "http://127.0.0.1:1")
      end)
    end

    defp reports(rules) do
      stub_client()
      read_client()

      stub(Sprites, :get_network_policy, fn %Sprites.Sprite{name: @name} ->
        {:ok, %Sprites.Policy{rules: rules}}
      end)
    end

    test "true only for exactly the compiled rules" do
      reports([%Sprites.Policy.Rule{domain: "broker.test", action: "allow"}])
      assert Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["other.test"]})

      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{
               allow: ["broker.test", "other.test"]
             })
    end

    test "no rules is Sprites' allow-all, never an empty allowlist's deny-all" do
      reports([])
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: []})
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})

      reports([%Sprites.Policy.Rule{domain: "*", action: "deny"}])
      assert Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: []})
    end

    test "an extra rule, a different action or an include is not a match" do
      reports([
        %Sprites.Policy.Rule{domain: "broker.test", action: "allow"},
        %Sprites.Policy.Rule{domain: "*", action: "allow", include: "defaults"}
      ])

      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})

      reports([%Sprites.Policy.Rule{domain: "broker.test", action: "deny"}])
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})

      reports([%Sprites.Policy.Rule{domain: "broker.test", action: "allow", include: "defaults"}])
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})
    end

    test "a failed read is not a match" do
      stub_client()
      read_client()
      stub(Sprites, :get_network_policy, fn _sprite -> {:error, {:api_error, 503, %{}}} end)
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})
    end

    test "a read that raises is not a match" do
      stub_client()
      read_client()
      stub(Sprites, :get_network_policy, fn _sprite -> raise FunctionClauseError end)
      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})
    end

    test "the read is short and not retried, unlike the write's 90 s client" do
      test_pid = self()

      stub(Managoat.Sandbox.Sprites.Client, :get!, fn opts ->
        send(test_pid, {:client_opts, opts})
        Sprites.new("test-token", base_url: "http://127.0.0.1:1")
      end)

      stub(Sprites, :get_network_policy, fn %Sprites.Sprite{client: client} ->
        send(test_pid, {:retry, client.req.options[:retry]})
        {:ok, %Sprites.Policy{rules: []}}
      end)

      refute Adapter.network_policy_in_force?(handle(), %NetworkPolicy{allow: ["broker.test"]})
      assert_received {:client_opts, [timeout: 10_000]}
      assert_received {:retry, false}
    end

    test "ensure_network_policy leaves a policy already in force alone" do
      reports([%Sprites.Policy.Rule{domain: "broker.test", action: "allow"}])
      reject(Sprites, :update_network_policy, 2)

      assert {:ok, :unchanged} =
               Managoat.Sandbox.ensure_network_policy(handle(), %NetworkPolicy{
                 allow: ["broker.test"]
               })
    end

    test "ensure_network_policy writes a policy that differs" do
      reports([])

      expect(Sprites, :update_network_policy, fn %Sprites.Sprite{name: @name},
                                                 %Sprites.Policy{rules: rules} ->
        assert [%Sprites.Policy.Rule{domain: "broker.test", action: "allow"}] = rules
        :ok
      end)

      assert {:ok, :written} =
               Managoat.Sandbox.ensure_network_policy(handle(), %NetworkPolicy{
                 allow: ["broker.test"]
               })
    end
  end

  describe "the network policy request's timeout (fountain#2559)" do
    # Sprites answers only once a booting sprite is up, which outlasts the
    # client's 30 s default; a timed-out request leaves its late answer on
    # the pooled connection for the retry to misread.
    test "is 90 s by default, on a client of its own" do
      test_pid = self()

      stub(Managoat.Sandbox.Sprites.Client, :get!, fn opts ->
        send(test_pid, {:client_opts, opts})
        %Sprites.Client{token: "test-token"}
      end)

      stub(Sprites, :update_network_policy, fn %Sprites.Sprite{name: @name}, _policy -> :ok end)

      assert :ok = Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []})
      assert_received {:client_opts, [timeout: 90_000]}
    end
  end

  describe "non-streaming provider failures" do
    test "filesystem, lifecycle, session, spawn, and policy errors stay tagged" do
      stub_client()
      raw_error = {:api_error, 503, %{"error" => "down"}}
      expected = {:error, {:unavailable, {:http, 503, %{"error" => "down"}}}}

      stub(Sprites, :destroy, fn _sprite -> {:error, raw_error} end)
      assert Adapter.destroy(handle()) == expected

      stub(Sprites, :filesystem, fn _sprite, "/" -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _data, _opts -> {:error, raw_error} end)

      assert Adapter.write_file(handle(), "/tmp/file", "data", []) == expected

      stub(Sprites, :spawn, fn _sprite, _cmd, _args, _opts -> {:error, raw_error} end)
      assert Adapter.spawn(handle(), "false", [], []) == expected

      stub(Sprites, :list_sessions, fn _sprite -> {:error, raw_error} end)
      assert Adapter.list_sessions(handle()) == expected

      stub(Sprites, :attach_session, fn _sprite, _id, _opts -> {:error, raw_error} end)
      assert Adapter.attach(handle(), "missing", []) == expected

      stub(Sprites, :update_network_policy, fn _sprite, _policy -> {:error, raw_error} end)
      assert Adapter.apply_network_policy(handle(), %NetworkPolicy{allow: []}) == expected
    end
  end
end
