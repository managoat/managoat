defmodule Fountain.Conversations.ProvisioningTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Conversations.Provisioning

  # The behavioural CA test below runs the generated command through a real
  # shell, so it needs the tools the sandbox has and a Mac does not: GNU
  # `install -D`, `flock` and `sha256sum`. Skipped rather than weakened
  # elsewhere, because stubbing `flock` would remove the one property that
  # test exists to check. CI runs on ubuntu, where it always runs.
  @posix_trust_store (case :os.type() do
                        {:unix, :linux} ->
                          Enum.all?(~w(flock sha256sum), &(System.find_executable(&1) != nil))

                        _ ->
                          false
                      end)

  # Full-stack: Provisioning -> Managoat.Sandbox facade -> real Sprites
  # adapter -> stubbed SDK, so the provider-quirk pins below still assert
  # the exact wire shapes Sprites receives.
  defp sandbox_handle(name \\ "test-sprite") do
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn -> %Sprites.Client{token: "test"} end)
    # The network policy request asks for a client of its own (0.5.2).
    stub(Managoat.Sandbox.Sprites.Client, :get!, fn _opts -> %Sprites.Client{token: "test"} end)
    Managoat.Sandbox.Sprites.build_handle(name)
  end

  describe "check_broker_support/2 (ADR 0019 gate 1a)" do
    test "a backend with :network_policy and a broker that answers passes" do
      conv = insert_conversation()

      expect(Fountain.Broker, :preflight, fn -> :ok end)
      assert :ok = Provisioning.check_broker_support(:sprites, conv.id)
      assert stage_events(conv.id, "broker") == []
    end

    test "a backend without :network_policy is refused: placeholders without a floor are half a control" do
      conv = insert_conversation()

      reject(Fountain.Broker, :preflight, 0)
      without_network_policy()

      assert {:error, {:broker, :backend_lacks_network_policy}} =
               Provisioning.check_broker_support(:bare, conv.id)

      assert [event] = stage_events(conv.id, "broker")

      assert %{"reason" => "backend_lacks_network_policy", "provider" => "bare"} =
               Jason.decode!(event.data)
    end

    test "a broker that does not answer fails the conversation before a sandbox exists" do
      conv = insert_conversation()

      expect(Fountain.Broker, :preflight, fn ->
        {:error, {:broker, :unreachable, :econnrefused}}
      end)

      assert {:error, {:broker, :unreachable, :econnrefused}} =
               Provisioning.check_broker_support(:sprites, conv.id)

      assert [event] = stage_events(conv.id, "broker")
      assert event.state == "failed"

      assert %{"reason" => "broker_unreachable", "detail" => ":econnrefused"} =
               Jason.decode!(event.data)
    end
  end

  describe "apply_broker_floor/2" do
    test "the broker host is the one allowed domain, whatever the environment says" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :proxy_host, fn -> "broker.example" end)

      Mimic.stub(Managoat.Sandbox.Sprites, :apply_network_policy, fn _handle, policy ->
        send(test, {:policy, policy})
        :ok
      end)

      assert :ok = Provisioning.apply_broker_floor(sandbox_handle(), conv.id)
      assert_received {:policy, %Managoat.Sandbox.NetworkPolicy{allow: ["broker.example"]}}

      assert [started, done] = stage_events(conv.id, "network")
      assert %{"type" => "broker"} = Jason.decode!(started.data)
      assert done.state == "done"
    end
  end

  describe "clone_repositories/5" do
    test "clones with basic proxy auth, so the CONNECT carries the credential first time" do
      # The other half of the #1485 fix. This one must hold even if
      # install_broker_ca/2 never ran: the clone is what fails visibly, as
      # "Proxy CONNECT aborted", when git is left on its `anyauth` default
      # against a proxy that closes the connection after a 407.
      conv = insert_conversation()
      test = self()

      env = %Fountain.Environments.Environment{
        repositories: [%{"url" => "https://github.com/o/r", "mount_path" => "/workspace/r"}]
      }

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, [_, script], _opts ->
        send(test, {:script, script})
        {:ok, "", 0}
      end)

      assert :ok =
               Provisioning.clone_repositories(
                 sandbox_handle(),
                 env,
                 %{},
                 [{"HTTPS_PROXY", "https://t:v@broker.example:443"}],
                 conv.id
               )

      assert_received {:script, script}
      assert script =~ "git -c http.proxyAuthMethod=basic clone --depth 50"
      # In the login shell without the startup files' stderr (#3026).
      assert String.starts_with?(script, "login_shell() {")
    end

    # A sprite answers 503 ("service temporarily unavailable, please retry")
    # for its first seconds. Every other provisioning step already rides that
    # out; the clone did not, so one cold sprite failed the conversation.
    test "a sprite that refuses the exec is retried — nothing ran, so nothing was half-written" do
      conv = insert_conversation()
      test = self()

      env = %Fountain.Environments.Environment{
        repositories: [%{"url" => "https://github.com/o/r", "mount_path" => "/workspace/r"}]
      }

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        send(test, :exec)

        receive do
          :already_refused -> {:ok, "", 0}
        after
          0 ->
            send(self(), :already_refused)

            {:error,
             {:unavailable, {:http, 503, %{"error" => "service temporarily unavailable"}}}}
        end
      end)

      assert :ok =
               Provisioning.clone_repositories(sandbox_handle(), env, %{}, [], conv.id)

      assert_received :exec
      assert_received :exec, "the refused attempt is retried, not surfaced as a failure"
    end

    test "a clone that ran and failed is never retried — a half-written mount is not cloned over" do
      conv = insert_conversation()
      test = self()

      env = %Fountain.Environments.Environment{
        repositories: [%{"url" => "https://github.com/o/r", "mount_path" => "/workspace/r"}]
      }

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        send(test, :exec)
        {:ok, "fatal: could not read Username", 128}
      end)

      assert {:error, {:clone, "https://github.com/o/r", 128}} =
               Provisioning.clone_repositories(sandbox_handle(), env, %{}, [], conv.id)

      assert_received :exec

      refute_received :exec,
                      "a command that ran is returned on the first attempt, exactly as before"
    end

    test "a timeout is not retried either — it can fire with the clone half-done" do
      conv = insert_conversation()
      test = self()

      env = %Fountain.Environments.Environment{
        repositories: [%{"url" => "https://github.com/o/r", "mount_path" => "/workspace/r"}]
      }

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        send(test, :exec)
        {:error, :timeout}
      end)

      assert {:error, {:clone_unreachable, "https://github.com/o/r", :timeout}} =
               Provisioning.clone_repositories(sandbox_handle(), env, %{}, [], conv.id)

      assert_received :exec
      refute_received :exec, "Retry's own default would have retried this; a clone must not"
    end
  end

  describe "clone_repositories/5 when the connection never opens" do
    @refused "Cloning into '/workspace/r'...\nfatal: unable to access " <>
               "'https://github.com/o/r/': Failed to connect to github.com port 443 " <>
               "via broker.example after 153 ms: Could not connect to server\n"

    defp clone(env) do
      Provisioning.clone_repositories(sandbox_handle(), env, %{}, [], insert_conversation().id)
    end

    @env %Fountain.Environments.Environment{
      repositories: [%{"url" => "https://github.com/o/r", "mount_path" => "/workspace/r"}]
    }

    test "retries, since a clone that never connected wrote nothing" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        case Agent.get_and_update(calls, &{&1, &1 + 1}) do
          0 -> {:ok, @refused, 128}
          _ -> {:ok, "Cloning into '/workspace/r'...\n", 0}
        end
      end)

      assert :ok = clone(@env)
      assert Agent.get(calls, & &1) == 2
    end

    test "gives up after the retries with the error it always had" do
      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        {:ok, @refused, 128}
      end)

      assert {:error, {:clone, "https://github.com/o/r", 128}} = clone(@env)
    end

    test "does not retry a clone that reached the remote" do
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, _args, _opts ->
        Agent.update(calls, &(&1 + 1))
        {:ok, "fatal: Authentication failed for 'https://github.com/o/r/'\n", 128}
      end)

      assert {:error, {:clone, "https://github.com/o/r", 128}} = clone(@env)
      assert Agent.get(calls, & &1) == 1
    end
  end

  describe "install_broker_ca/2" do
    # Pins the absolute paths and the sandbox command wiring. What the
    # command *does* — rebuild once, skip on an unchanged bundle, repair a
    # corrupted one, retry after a failed rebuild, and refuse to rebuild when
    # another installer holds the lock — is the behavioural test below;
    # `install_broker_ca/2`'s docstring has why each of those matters on a
    # shared sandbox.
    test "writes the CA where update-ca-certificates reads it, adding or rebuilding" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, opts ->
        send(test, {:wrote, path, data, opts})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, cmd, args, _opts ->
        send(test, {:exec, cmd, args})
        {:ok, "Updating certificates... 1 added", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)

      # The staging file is per invocation, so several conversations writing
      # it at once cannot change each other's input to the comparison and
      # `install`.
      assert_received {:wrote, staging, "PEM", [mode: 0o644]}
      assert String.starts_with?(staging, "/tmp/agent-vault-ca.crt.")
      refute staging == "/tmp/agent-vault-ca.crt"

      # A plain shell: nothing here needs a login profile, which costs a
      # sprite ~0.1-0.2 s per exec.
      assert_received {:exec, "bash", ["-c", cmd]}
      ca = "/usr/local/share/ca-certificates/agent-vault.crt"
      bundle = "/etc/ssl/certs/ca-certificates.crt"
      marker = ca <> ".trust-store-ready"

      assert cmd ==
               "( trap 'rm -f -- '\\''#{staging}'\\''' EXIT; " <>
                 "safe=0; " <>
                 "if command -v flock >/dev/null 2>&1; then flock -w 120 9 || exit 75; safe=1; fi; " <>
                 "{ { staged_key=$(openssl x509 -noout -pubkey -in '#{staging}' 2>/dev/null) && " <>
                 "installed_key=$(openssl x509 -noout -pubkey -in '#{ca}' 2>/dev/null) && " <>
                 ~s([ -n "$staged_key" ] && [ "$staged_key" = "$installed_key" ]; } && ) <>
                 "sha256sum -c --status '#{marker}' 2>/dev/null; } || " <>
                 "{ sudo rm -f -- '#{marker}' && " <>
                 "if [ ! -e '#{ca}' ] && [ -s '#{bundle}' ]; then " <>
                 "sudo install -D -m 644 '#{staging}' '#{ca}' && " <>
                 "sudo sh -c #{Provisioning.shell_quote(Provisioning.add_to_trust_store())} add '#{ca}' '#{bundle}'; " <>
                 "else " <>
                 "sudo install -D -m 644 '#{staging}' '#{ca}' && " <>
                 "sudo update-ca-certificates; fi && " <>
                 "{ [ \"$safe\" = 1 ] && sudo sh -c " <>
                 "'sha256sum '\\''#{bundle}'\\'' > '\\''#{marker}'\\''' " <>
                 "|| true; }; } && " <>
                 "printf '%s\\n' 'Defaults env_keep += \"HTTPS_PROXY HTTP_PROXY https_proxy http_proxy " <>
                 "NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE REQUESTS_CA_BUNDLE CARGO_HTTP_CAINFO " <>
                 "GIT_SSL_CAINFO HEX_CACERTS_PATH UV_NATIVE_TLS\"' > '/tmp/fountain-broker-proxy.sudoers' && " <>
                 "sudo visudo -cf '/tmp/fountain-broker-proxy.sudoers' && " <>
                 "sudo install -m 440 '/tmp/fountain-broker-proxy.sudoers' '/etc/sudoers.d/fountain-broker-proxy' && " <>
                 "git config --global http.proxyAuthMethod basic ) 9>'/tmp/fountain-broker-ca.lock'"
    end

    @tag :tmp_dir
    @tag skip:
           unless(@posix_trust_store,
             do: "needs GNU install -D, flock and sha256sum; runs on Linux"
           )
    test "serializes broker setup and repairs the trust store only when needed", %{
      tmp_dir: tmp_dir
    } do
      conv = insert_conversation()
      test = self()

      # A real broker CA: the comparison is by public key, which needs one.
      seed = :crypto.strong_rand_bytes(32)
      stub(Fountain.Broker, :ca_pem, fn -> {:ok, Managoat.Broker.CA.pem(seed)} end)

      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, path, data, _opts ->
        send(test, {:staged, path, data})
        :ok
      end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, "bash", ["-c", cmd], _opts ->
        send(test, {:install_command, cmd})
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)
      assert_received {:staged, staging, pem}
      assert_received {:install_command, cmd}

      # Redirect every absolute write into this test's tree. Run without a login
      # shell so PATH keeps our sudo, trust-store builder and git stubs.
      cmd =
        String.replace(
          cmd,
          ~r{/usr/local/share/ca-certificates|/etc/ssl/certs|/etc/sudoers.d|/tmp/},
          fn prefix -> tmp_dir <> prefix end
        )

      ca = tmp_dir <> Fountain.Broker.ca_path()
      bundle = tmp_dir <> Fountain.Broker.system_ca_bundle()
      marker = ca <> ".trust-store-ready"
      counter = Path.join(tmp_dir, "rebuilds")
      failure = Path.join(tmp_dir, "fail-rebuild")
      bin = Path.join(tmp_dir, "bin")

      for dir <- [
            bin,
            Path.dirname(ca),
            Path.dirname(bundle),
            tmp_dir <> "/etc/sudoers.d",
            tmp_dir <> "/tmp"
          ] do
        File.mkdir_p!(dir)
      end

      for {name, body} <- [
            {"sudo", ~s(exec "$@"\n)},
            {"visudo", "exit 0\n"},
            {"git", "exit 0\n"},
            {"update-ca-certificates",
             """
             echo rebuild >> "$TEST_CA_ROOT/rebuilds"
             [ ! -f "$TEST_CA_ROOT/fail-rebuild" ] || exit 3
             cat "$TEST_CA_ROOT/usr/local/share/ca-certificates/agent-vault.crt" > "$TEST_CA_ROOT/etc/ssl/certs/ca-certificates.crt"
             echo system-roots >> "$TEST_CA_ROOT/etc/ssl/certs/ca-certificates.crt"
             """}
          ] do
        path = Path.join(bin, name)
        File.write!(path, "#!/bin/sh\n" <> body)
        File.chmod!(path, 0o755)
      end

      run_with = fn staged ->
        # The EXIT trap consumes the staging file on every invocation.
        File.write!(tmp_dir <> staging, staged)

        result =
          System.cmd("bash", ["-c", cmd],
            env: [{"PATH", bin <> ":" <> System.fetch_env!("PATH")}, {"TEST_CA_ROOT", tmp_dir}],
            stderr_to_stdout: true
          )

        refute File.exists?(tmp_dir <> staging)
        result
      end

      run = fn -> run_with.(pem) end

      # A fresh sandbox: the image's bundle, and no broker CA yet. The CA is
      # added to the bundle without a rebuild.
      File.write!(bundle, "system-roots\n")
      assert {_, 0} = run.()
      assert File.read!(ca) == pem
      assert File.read!(bundle) == "system-roots\n" <> pem
      assert File.exists?(marker)
      refute File.exists?(counter)

      assert {_, 0} = run.()
      refute File.exists?(counter)

      # The same CA derived again: every byte of its PEM differs, because
      # ECDSA signing is randomised, but its key does not, and it is the same
      # trust anchor. Compared byte for byte, this rebuilt the trust store on
      # every wake (1.5-2.3 s, 2026-10-07).
      rederived = Managoat.Broker.CA.pem(seed)
      refute rederived == pem
      assert {_, 0} = run_with.(rederived)
      refute File.exists?(counter)
      assert File.read!(ca) == pem

      # Anything but "never installed" rebuilds, which is what repairs.
      File.write!(bundle, "truncated bundle\n")
      assert {_, 0} = run.()
      assert File.read!(bundle) == pem <> "system-roots\n"
      assert File.read!(counter) == "rebuild\n"

      File.write!(bundle, "corrupted again\n")
      File.touch!(failure)
      assert {_, 3} = run.()
      refute File.exists?(marker)
      assert File.read!(counter) == String.duplicate("rebuild\n", 2)

      File.rm!(failure)
      assert {_, 0} = run.()
      assert File.read!(bundle) == pem <> "system-roots\n"
      assert File.exists?(marker)
      assert File.read!(counter) == String.duplicate("rebuild\n", 3)

      # A replaced CA rebuilds too, so the old one leaves the bundle rather
      # than staying trusted beside the new one.
      File.write!(ca, Managoat.Broker.CA.pem(:crypto.strong_rand_bytes(32)))
      assert {_, 0} = run.()
      assert File.read!(ca) == pem
      assert File.read!(bundle) == pem <> "system-roots\n"
      assert File.read!(counter) == String.duplicate("rebuild\n", 4)

      # Another installer holds the machine lock. Waiting it out and
      # rebuilding anyway is the concurrent write against the fixed temporary
      # bundle that this whole command exists to prevent — and worse, the
      # holder stamps its digest after its own rebuild returns, so a bundle
      # truncated in between is recorded as good and never repaired. Exit 75
      # and touch nothing instead: a failed conversation is recoverable.
      lock = Path.join(tmp_dir, "/tmp/fountain-broker-ca.lock")
      File.write!(bundle, "corrupted while another installer holds the lock\n")

      holder =
        Task.async(fn ->
          System.cmd("flock", [lock, "sleep", "3"], stderr_to_stdout: true)
        end)

      # Give the holder the lock before racing it, and shorten only the wait
      # so the test does not sit out the real 120 seconds. Everything else in
      # the command, including which failure the timeout produces, is the
      # string Fountain builds.
      Process.sleep(300)
      contended = String.replace(cmd, "flock -w 120 9", "flock -w 1 9")
      refute contended == cmd

      File.write!(tmp_dir <> staging, pem)

      assert {_, 75} =
               System.cmd("bash", ["-c", contended],
                 env: [
                   {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
                   {"TEST_CA_ROOT", tmp_dir}
                 ],
                 stderr_to_stdout: true
               )

      refute File.exists?(tmp_dir <> staging)

      # Nothing was rebuilt, and the corrupted bundle was left for whoever
      # holds the lock — or for the next conversation, whose `sha256sum -c`
      # still misses.
      assert File.read!(bundle) == "corrupted while another installer holds the lock\n"
      assert File.read!(counter) == String.duplicate("rebuild\n", 4)

      Task.await(holder, 10_000)

      # A wake also writes the shared sudoers drop-in and ~/.gitconfig.
      # Pause the first caller in each operation, then make a second caller
      # exhaust its lock wait. Releasing the lock after the CA rebuild lets
      # the second caller enter the same operation and fail with exit 73.
      for step <- ["visudo", "git"] do
        ready = Path.join(tmp_dir, "#{step}-ready")
        release = Path.join(tmp_dir, "#{step}-release")
        gate = Path.join(bin, step)

        File.write!(gate, """
        #!/bin/sh
        if [ ! -f "$TEST_CA_ROOT/#{step}-release" ]; then
          mkdir "$TEST_CA_ROOT/#{step}-owner" 2>/dev/null || exit 73
          touch "$TEST_CA_ROOT/#{step}-ready"
          while [ ! -f "$TEST_CA_ROOT/#{step}-release" ]; do sleep 0.01; done
        fi
        """)

        first = Task.async(run)

        try do
          assert Enum.reduce_while(1..500, false, fn _, _ ->
                   if File.exists?(ready) do
                     {:halt, true}
                   else
                     Process.sleep(10)
                     {:cont, false}
                   end
                 end),
                 "first setup never reached #{step}"

          # Every real invocation stages its own PEM before taking the lock.
          other_staging = staging <> ".contender"
          File.write!(tmp_dir <> other_staging, pem)
          other_cmd = String.replace(contended, staging, other_staging)

          assert {_, 75} =
                   System.cmd("bash", ["-c", other_cmd],
                     env: [
                       {"PATH", bin <> ":" <> System.fetch_env!("PATH")},
                       {"TEST_CA_ROOT", tmp_dir}
                     ],
                     stderr_to_stdout: true
                   )

          refute File.exists?(tmp_dir <> other_staging)
        after
          File.touch!(release)
          assert {_, 0} = Task.await(first, 10_000)
          File.write!(gate, "#!/bin/sh\nexit 0\n")
        end

        assert {_, 0} = run.()
      end
    end

    # The trap that removes the staging file runs inside bash, so an exec that
    # never got that far leaves a uniquely-named PEM on a machine that
    # reattaches for weeks. The old fixed path was self-limiting.
    test "removes the staged CA when the exec never ran" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn
        _h, "bash", _args, _opts ->
          {:error, :timeout}

        _h, cmd, args, _opts ->
          send(test, {:exec, cmd, args})
          {:ok, "", 0}
      end)

      assert {:error, {:broker, :ca_install, :timeout}} =
               Provisioning.install_broker_ca(sandbox_handle(), conv.id)

      assert_received {:exec, "rm", ["-f", "--", staged]}
      assert String.starts_with?(staged, "/tmp/agent-vault-ca.crt.")
    end

    test "pins git's proxy auth to basic, so a brokered clone never waits for a 407" do
      # git's `anyauth` default sends CONNECT bare, reads the 407 naming the
      # scheme, and retries on the same connection. The native broker closes
      # after a 407, so the retry hits a dead socket and git says
      # "Proxy CONNECT aborted" — every brokered clone failing to provision
      # (#1485). Basic sends the credential on the first CONNECT instead.
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, [_, script], _opts ->
        send(test, {:script, script})
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)
      assert_received {:script, script}
      assert script =~ "git config --global http.proxyAuthMethod basic"
    end

    test "sudo keeps every proxy variable the broker sets, so `sudo apt-get` reaches a mirror" do
      conv = insert_conversation()
      test = self()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)

      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _cmd, [_, script], _opts ->
        send(test, {:script, script})
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.install_broker_ca(sandbox_handle(), conv.id)
      assert_received {:script, script}

      # The token-bearing variables must survive sudo for apt's sake, but the
      # drop-in itself carries only names, never the proxy URL.
      for key <- Fountain.Broker.env_keys(), do: assert(script =~ key)
      refute script =~ "@"
      assert script =~ "visudo -cf"
    end

    test "a failed install is a broker failure, by name" do
      conv = insert_conversation()

      stub(Fountain.Broker, :ca_pem, fn -> {:ok, "PEM"} end)
      Mimic.stub(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _d, _o -> :ok end)
      Mimic.stub(Managoat.Sandbox.Sprites, :exec, fn _h, _c, _a, _o -> {:ok, "no sudo", 1} end)

      assert {:error, {:broker, :ca_install_exit, 1, "no sudo"}} =
               Provisioning.install_broker_ca(sandbox_handle(), conv.id)

      assert [event] = stage_events(conv.id, "broker")
      assert %{"reason" => "ca_install_exit", "exit_code" => 1} = Jason.decode!(event.data)
    end
  end

  describe "Broker.ca_env/1" do
    @tag :tmp_dir
    @tag skip:
           unless(System.find_executable("git") && System.find_executable("openssl"),
             do: "needs git and openssl"
           )
    test "git trusts the broker CA through the env alone", %{tmp_dir: tmp_dir} do
      # Git reads none of the other CA variables: Apple's git ignores
      # SSL_CERT_FILE. A local HTTPS server with a certificate a temporary CA
      # signed stands in for the broker. openssl makes the pair,
      # because GnuTLS, which Ubuntu's git uses, is stricter about a
      # certificate's extensions than the tools that would otherwise do.
      openssl = fn args ->
        {_, 0} = System.cmd("openssl", args, cd: tmp_dir, stderr_to_stdout: true)
      end

      openssl.(
        ~w(req -x509 -newkey rsa:2048 -nodes -keyout ca.key -out ca.crt -days 2 -subj /CN=fountain-test-ca) ++
          ~w(-addext basicConstraints=critical,CA:TRUE -addext keyUsage=critical,keyCertSign,cRLSign)
      )

      openssl.(~w(req -newkey rsa:2048 -nodes -keyout leaf.key -out leaf.csr -subj /CN=localhost))

      File.write!(
        Path.join(tmp_dir, "leaf.ext"),
        "subjectAltName=DNS:localhost\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n"
      )

      openssl.(
        ~w(x509 -req -in leaf.csr -CA ca.crt -CAkey ca.key -CAcreateserial -out leaf.crt -days 2) ++
          ~w(-extfile leaf.ext)
      )

      {:ok, listen} =
        :ssl.listen(0,
          certfile: to_charlist(Path.join(tmp_dir, "leaf.crt")),
          keyfile: to_charlist(Path.join(tmp_dir, "leaf.key")),
          active: false,
          reuseaddr: true
        )

      {:ok, {_, port}} = :ssl.sockname(listen)

      serve = fn serve ->
        with {:ok, socket} <- :ssl.transport_accept(listen),
             {:ok, socket} <- :ssl.handshake(socket, 5_000) do
          _ = :ssl.recv(socket, 0, 5_000)

          :ssl.send(
            socket,
            "HTTP/1.1 404 Not Found\r\ncontent-length: 0\r\nconnection: close\r\n\r\n"
          )

          :ssl.close(socket)
        end

        serve.(serve)
      end

      server_pid = spawn(fn -> serve.(serve) end)
      on_exit(fn -> Process.exit(server_pid, :kill) end)

      roots =
        Enum.find(
          ~w(/etc/ssl/certs/ca-certificates.crt /etc/pki/tls/certs/ca-bundle.crt /etc/ssl/cert.pem),
          &File.regular?/1
        )

      bundle = Path.join(tmp_dir, "ca-bundle.crt")
      File.write!(bundle, File.read!(roots) <> File.read!(Path.join(tmp_dir, "ca.crt")))
      files = %{ca: Path.join(tmp_dir, "ca.crt"), bundle: bundle}

      git = fn env ->
        System.cmd("git", ["ls-remote", "https://localhost:#{port}/r.git"],
          env:
            [{"HOME", tmp_dir}, {"GIT_TERMINAL_PROMPT", "0"}, {"GIT_CONFIG_NOSYSTEM", "1"}] ++
              env,
          stderr_to_stdout: true
        )
      end

      # Control: the same bundle, without the variable git reads.
      without = Enum.reject(Fountain.Broker.ca_env(files), &(elem(&1, 0) == "GIT_SSL_CAINFO"))
      {out, _} = git.(without)
      assert out =~ ~r/certificate/i

      # The TLS handshake succeeds; what fails is the fake repository.
      {out, _} = git.(Fountain.Broker.ca_env(files))
      refute out =~ ~r/certificate/i
      assert out =~ ~r/not found|not valid|404/i
    end
  end

  # Every shipped adapter advertises `:network_policy`; `:bare` stands in for
  # one that does not.
  defp without_network_policy do
    stub(Managoat.Sandbox, :supports?, fn :bare, :network_policy -> false end)
  end

  defp stage_events(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Fountain.Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
  end

  # ── .env quoting ───────────────────────────────────────────────────────────

  # The file exists to be `source`d by the user's setup_script, so the only
  # assertion worth making is what a real shell sees when it reads it back.
  # Values used to be wrapped in *double* quotes with only `"` escaped, so
  # $(...), backticks and backslashes stayed live, and a newline split the value
  # across lines.
  defp sourced_value(value) do
    body = Provisioning.render_env_file(%{"SECRET" => value})
    dir = Fountain.TmpDir.path("envq")
    File.mkdir_p!(dir)
    file = Path.join(dir, ".env")
    File.write!(file, body)

    try do
      {out, 0} =
        System.cmd("bash", ["-c", "set -a; source #{file}; printf %s \"$SECRET\""],
          stderr_to_stdout: true
        )

      out
    after
      File.rm_rf!(dir)
    end
  end

  describe "render_env_file/1" do
    test "a command substitution is not executed" do
      assert sourced_value("pw-$(id -u)-end") == "pw-$(id -u)-end"
      assert sourced_value("pw-`id -u`-end") == "pw-`id -u`-end"
    end

    test "a variable reference is not expanded" do
      assert sourced_value("literal-$HOME") == "literal-$HOME"
      assert sourced_value("literal-${HOME}") == "literal-${HOME}"
    end

    test "backslashes survive" do
      # Windows-style paths and anything base64/PEM-adjacent hit this.
      assert sourced_value("C:\\Users\\me") == "C:\\Users\\me"
      assert sourced_value("a\\nb") == "a\\nb"
    end

    test "a multi-line value survives instead of splitting the file" do
      pem = "-----BEGIN KEY-----\nabc\ndef\n-----END KEY-----"
      assert sourced_value(pem) == pem
    end

    test "quotes of both kinds survive" do
      assert sourced_value(~s|it's a "quote"|) == ~s|it's a "quote"|
      assert sourced_value("'") == "'"
    end

    test "a value cannot introduce a second assignment" do
      assert sourced_value("x\nINJECTED=1") == "x\nINJECTED=1"

      body = Provisioning.render_env_file(%{"SECRET" => "x\nINJECTED=1"})
      script = "set -a; source /dev/stdin <<'EOF'\n#{body}EOF\necho \"[${INJECTED-}]\""
      {out, 0} = System.cmd("bash", ["-c", script], stderr_to_stdout: true)

      assert String.trim(out) == "[]"
    end

    test "ordinary values still round-trip" do
      assert sourced_value("plain") == "plain"
      assert sourced_value("") == ""
    end
  end

  describe "retry behaviour on transient Sprites failures" do
    defp stub_chmod_exec do
      # The belt-and-suspenders chmod goes through the adapter's exec, which
      # spawns and collects frames; hand back an immediate clean exit.
      stub(Sprites, :spawn, fn _sprite, "chmod", _args, _opts ->
        ref = make_ref()
        send(self(), {:exit, %{ref: ref}, 0})
        {:ok, %Sprites.Command{ref: ref}}
      end)
    end

    test "empty process-filtered env overwrites any credential left in the shared file" do
      handle = sandbox_handle("s")
      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      expect(Sprites.Filesystem, :write, 2, fn :fake_fs, _path, body, _opts ->
        assert body == "\n"
        :ok
      end)

      stub_chmod_exec()

      only_credentials = Fountain.Conversations.Identity.disk_env([{"OPENAI_API_KEY", "old-key"}])
      assert only_credentials == []
      assert :ok = Provisioning.write_env_file(handle, only_credentials)
      assert :ok = Provisioning.write_env_file(handle, nil)
    end

    test "write_env_file survives one transport failure on the file write" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handle = sandbox_handle("s")

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body, _opts ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> {:error, :timeout}
          _ -> :ok
        end
      end)

      stub_chmod_exec()

      assert :ok = Provisioning.write_env_file(handle, [{"A", "1"}])
      assert Agent.get(counter, & &1) == 2
    end

    test "write_env_file does not retry a permanent not-found" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      handle = sandbox_handle("s")

      stub(Sprites, :filesystem, fn _sprite, _root -> :fake_fs end)

      stub(Sprites.Filesystem, :write, fn :fake_fs, _path, _body, _opts ->
        Agent.update(counter, &(&1 + 1))
        {:error, {:api_error, 404, "no such sprite"}}
      end)

      assert {:error, :not_found} = Provisioning.write_env_file(handle, [{"A", "1"}])

      assert Agent.get(counter, & &1) == 1
    end

    test "apply_broker_floor retries a 503 and succeeds" do
      {:ok, counter} = Agent.start_link(fn -> 0 end)
      conv = insert_conversation()

      stub(Sprites, :update_network_policy, fn _sprite, _policy ->
        case Agent.get_and_update(counter, &{&1 + 1, &1 + 1}) do
          1 -> {:error, {:api_error, 503, "unavailable"}}
          _ -> :ok
        end
      end)

      assert :ok = Provisioning.apply_broker_floor(sandbox_handle("s"), conv.id)
      assert Agent.get(counter, & &1) == 2
    end
  end
end
