defmodule Fountain.Conversations.ProvisioningStepsTest do
  @moduledoc """
  The steps that moved out of `ConversationServer` in #1372: recording the
  machine's URL, the user's setup script and the runtime's files. Driven with
  the `Managoat.Sandbox` facade stubbed, no server.
  """
  use Fountain.DataCase, async: true
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations
  alias Fountain.Conversations.Provisioning
  alias Managoat.Sandbox.Handle

  defmodule ConfigRuntime do
    def write_config(_handle, agent, home), do: {:wrote, agent, home}

    def prepare_sandbox(_handle, agent, sprite_env, home),
      do: {:prepared, agent, sprite_env, home}
  end

  defmodule BareRuntime do
  end

  defp handle(name \\ "s"), do: %Handle{provider: :sprites, name: name}

  @home "/home/sprite/.managoat/c/9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"

  # The conversation a runtime step prepares for: its owner, its config home
  # and no cwd of its own.
  defp conv(attrs \\ %{}) do
    Map.merge(
      %{id: Ecto.UUID.generate(), user_id: nil, runtime: "gemini", config_home: @home, cwd: nil},
      attrs
    )
  end

  # The lease a provision would be holding while its pipeline runs.
  defp claim(sandbox) do
    {:ok, epoch} = Fountain.Machines.Lease.claim(sandbox.id)
    epoch
  end

  # One stage's output events, in order.
  defp setup_output(conv_id, stage \\ "setup") do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "output" and e.stage == ^stage,
        order_by: e.id
      )
    )
  end

  # An exec that runs the command in a local bash and streams its output to
  # the `:on_output` sink chunk by chunk, keeping none of it for the result.
  defp run_streaming(args, opts) do
    port =
      Port.open({:spawn_executable, System.find_executable("bash")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
      ])

    stream_port(port, opts[:on_output])
  end

  defp stream_port(port, sink) do
    receive do
      {^port, {:data, data}} ->
        sink.(data)
        stream_port(port, sink)

      {^port, {:exit_status, code}} ->
        {:ok, "", code}
    after
      30_000 -> {:error, :timeout}
    end
  end

  # The stage events of one stage as `{state, meta}` pairs, in order.
  defp stages(conv_id, stage) do
    Fountain.Repo.all(
      from(e in Conversations.LogEvent,
        where: e.conversation_id == ^conv_id and e.kind == "stage" and e.stage == ^stage,
        order_by: e.id
      )
    )
    |> Enum.map(&{&1.state, Jason.decode!(&1.data)})
  end

  # `create_sandbox_handle/2` left this module in ADR 0058 stage 7b, with the
  # discard of an interrupted attempt beside it: both are mutations of a machine
  # rather than steps inside one, and they are `Fountain.Machines.Provision`'s
  # now. `machines/provision_test.exs` covers them where they live.

  describe "record_sandbox_url/3" do
    test "stores the URL on the row and returns it" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)
      stub(Managoat.Sandbox, :public_url, fn _handle -> {:ok, "https://s.example"} end)

      assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == "https://s.example"

      assert Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"] ==
               "https://s.example"
    end

    test "is nil, and touches nothing, when the provider has no URL or fails or raises" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)

      for reply <- [{:error, :unsupported}, {:error, :timeout}] do
        stub(Managoat.Sandbox, :public_url, fn _handle -> reply end)
        assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == nil
      end

      stub(Managoat.Sandbox, :public_url, fn _handle -> raise "provider surprise" end)
      assert Provisioning.record_sandbox_url(sandbox, handle(), epoch) == nil

      refute Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"]
    end

    # The write is a compare-and-set on the provision's lease (stage 7b), so an
    # attempt that has lost the machine records nothing — the URL would name a
    # host it created and then destroyed, on a row another owner is building.
    test "records nothing for an attempt that no longer holds the machine" do
      sandbox = insert_sandbox()
      epoch = claim(sandbox)
      superseded = epoch + 7
      stub(Managoat.Sandbox, :public_url, fn _handle -> {:ok, "https://s.example"} end)

      assert capture_log(fn ->
               assert Provisioning.record_sandbox_url(sandbox, handle(), superseded) ==
                        "https://s.example"
             end) =~ "not recording the machine URL"

      refute Conversations._unsafe_get_sandbox(sandbox.id).provider_meta["public_url"]
    end
  end

  describe "run_setup_script/4" do
    test "is a no-op without a script" do
      assert :ok = Provisioning.run_setup_script(handle(), nil, [], "c")
      assert :ok = Provisioning.run_setup_script(handle(), %{setup_script: ""}, [], "c")
    end

    test "runs the script with the sprite env, logs its output and publishes the stage" do
      conv = insert_conversation()
      sprite_env = [{"A", "1"}]

      stub(Managoat.Sandbox, :exec, fn _handle,
                                       "bash",
                                       ["-c", wrapper, "fountain-setup", "echo hi"],
                                       opts ->
        # The runtime template (#2998): its directories are made in the same
        # exec, before the script, which finds them in the env.
        assert String.starts_with?(wrapper, Managoat.Runtimes.Template.prepare_script())
        assert String.ends_with?(wrapper, Provisioning.stream_wrapper())

        assert opts[:env] ==
                 sprite_env ++
                   [{"MANAGOAT_RUNTIME_TEMPLATE", "/home/sprite/.managoat/template"}]

        assert opts[:stderr_to_stdout]
        assert opts[:timeout] == 120_000
        {:ok, "hi\n", 0}
      end)

      assert :ok =
               Provisioning.run_setup_script(
                 handle(),
                 %{setup_script: "echo hi"},
                 sprite_env,
                 conv.id
               )

      assert [%{data: "hi\n", stage: "setup", stream: "stdout"}] =
               Fountain.Repo.all(
                 from(e in Conversations.LogEvent,
                   where: e.conversation_id == ^conv.id and e.kind == "output"
                 )
               )

      assert stages(conv.id, "setup") == [{"started", %{}}, {"done", %{"exit_code" => 0}}]
    end

    test "a persisted timeout reaches exec and timeout remains failed setup" do
      conv = insert_conversation()
      env = insert_env(setup_script: "install-dependencies", setup_timeout_seconds: 900)

      expect(Managoat.Sandbox, :exec, fn _handle,
                                         "bash",
                                         ["-c", _, "fountain-setup", "install-dependencies"],
                                         opts ->
        assert opts[:timeout] == 900_000
        {:error, :timeout}
      end)

      assert {:error, {:setup_unreachable, :timeout}} =
               Provisioning.run_setup_script(handle(), env, [], conv.id)

      assert stages(conv.id, "setup") == [
               {"started", %{}},
               {"failed", %{"reason" => ":timeout"}}
             ]
    end

    # #2558: the exec used to collect output until the pipe closed, so a
    # process the script left running held the step open. The wrapper is run
    # here by a real bash, with a background child that outlives the script by
    # far more than the step takes.
    test "the step ends when the script exits, whatever it leaves running" do
      conv = insert_conversation()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", args, _opts ->
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      script = "(sleep 30; echo late) & echo done; echo oops >&2; exit 4"

      {micros, result} =
        :timer.tc(fn ->
          Provisioning.run_setup_script(handle(), %{setup_script: script}, [], conv.id)
        end)

      assert {:error, {:setup_exit, 4, _tail}} = result
      assert micros < 10_000_000

      assert [%{data: "done\noops\n"}] =
               Fountain.Repo.all(
                 from(e in Conversations.LogEvent,
                   where: e.conversation_id == ^conv.id and e.kind == "output"
                 )
               )
    end

    # #2550: output reaches the log while the script runs, as whole lines, not
    # once at exit. The wrapper is run by a real bash through a port that hands
    # each chunk to the sink as it arrives, the way the adapters do.
    test "streams the script's output as it runs, a line at a time" do
      conv = insert_conversation()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", args, opts ->
        run_streaming(args, opts)
      end)

      script = "echo one; sleep 2; echo two; printf partial; exit 2"

      assert {:error, {:setup_exit, 2, "one\ntwo\npartial"}} =
               Provisioning.run_setup_script(handle(), %{setup_script: script}, [], conv.id)

      assert [one, two, partial] = setup_output(conv.id)
      assert {one.data, two.data, partial.data} == {"one\n", "two\n", "partial"}
      assert Enum.all?([one, two, partial], &(&1.stage == "setup" and &1.stream == "stdout"))

      [_started, failed] =
        Fountain.Repo.all(
          from(e in Conversations.LogEvent,
            where: e.conversation_id == ^conv.id and e.kind == "stage",
            order_by: e.id
          )
        )

      # "one" was written while the script slept, well before the step ended.
      assert DateTime.diff(failed.inserted_at, one.inserted_at, :millisecond) >= 1_000
      assert stages(conv.id, "setup") == [{"started", %{}}, {"failed", %{"exit_code" => 2}}]
    end

    test "output streamed before the sandbox became unreachable stays in the log" do
      conv = insert_conversation()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, opts ->
        opts[:on_output].("[12:00:00] step one\n[12:00:01] step t")
        {:error, {:unavailable, :closed_before_exit}}
      end)

      assert {:error, {:setup_unreachable, {:unavailable, :closed_before_exit}}} =
               Provisioning.run_setup_script(handle(), %{setup_script: "x"}, [], conv.id)

      assert Enum.map(setup_output(conv.id), & &1.data) == [
               "[12:00:00] step one\n",
               "[12:00:01] step t"
             ]
    end

    test "a non-zero exit is the step's failure, with the exit code" do
      conv = insert_conversation()
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:ok, "boom", 3} end)

      assert {:error, {:setup_exit, 3, "boom"}} =
               Provisioning.run_setup_script(handle(), %{setup_script: "exit 3"}, [], conv.id)

      assert stages(conv.id, "setup") == [{"started", %{}}, {"failed", %{"exit_code" => 3}}]
    end

    test "an unreachable sandbox is the step's failure, with the reason" do
      conv = insert_conversation()
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:error, :nxdomain} end)

      assert {:error, {:setup_unreachable, :nxdomain}} =
               Provisioning.run_setup_script(handle(), %{setup_script: "true"}, [], conv.id)

      assert stages(conv.id, "setup") == [
               {"started", %{}},
               {"failed", %{"reason" => ":nxdomain"}}
             ]
    end
  end

  describe "install_packages/4" do
    test "streams each command's output under the packages stage, and fails with its tail" do
      conv = insert_conversation()
      env = %Fountain.Environments.Environment{packages: %{"apt" => ["jq"]}}

      stub(Managoat.Sandbox, :exec, fn _handle,
                                       "bash",
                                       ["-c", _, "fountain-packages", cmd],
                                       opts ->
        assert cmd =~ "apt-get"
        assert opts[:timeout] == 300_000
        opts[:on_output].("Reading package lists...\nE: Unable to locate")
        opts[:on_output].(" package jq\n")
        {:ok, "", 100}
      end)

      assert {:error, {:packages, 100, tail}} =
               Provisioning.install_packages(handle(), env, [], conv.id)

      assert tail == "Reading package lists...\nE: Unable to locate package jq\n"

      assert Enum.map(setup_output(conv.id, "packages"), & &1.data) == [
               "Reading package lists...\n",
               "E: Unable to locate package jq\n"
             ]

      assert [{"started", _}, {"failed", %{"exit_code" => 100}}] = stages(conv.id, "packages")
    end

    # The deadline stops only the local collector; a second apt-get would
    # start beside the first, still in the sandbox (#2972).
    test "does not retry a command that ran out its timeout" do
      conv = insert_conversation()
      env = %Fountain.Environments.Environment{packages: %{"apt" => ["jq"]}}
      timeout = {:unavailable, {:exec_timeout, 300_000}}

      expect(Managoat.Sandbox, :exec, 1, fn _handle, "bash", _args, _opts ->
        {:error, timeout}
      end)

      assert {:error, {:packages_unreachable, ^timeout}} =
               Provisioning.install_packages(handle(), env, [], conv.id)

      assert [{"started", _}, {"failed", _}] = stages(conv.id, "packages")
    end

    test "retries a command whose connection to the sandbox dropped" do
      conv = insert_conversation()
      env = %Fountain.Environments.Environment{packages: %{"apt" => ["jq"]}}

      expect(Managoat.Sandbox, :exec, 1, fn _handle, "bash", _args, _opts ->
        {:error, {:unavailable, :closed}}
      end)

      expect(Managoat.Sandbox, :exec, 1, fn _handle, "bash", _args, _opts ->
        {:ok, "", 0}
      end)

      capture_log(fn ->
        assert :ok = Provisioning.install_packages(handle(), env, [], conv.id)
      end)
    end
  end

  describe "build_apt_commands/1" do
    # The command runs for real under bash, against a `dpkg-query` that knows
    # only the packages the test names and a `sudo` that prints what it was
    # asked to do, so the shell quoting is checked and nothing is installed.
    @tag :tmp_dir
    test "skips the update and install when every package is already installed", %{
      tmp_dir: dir
    } do
      [cmd] = Provisioning.build_apt_commands(["jq", "git"])

      assert run_apt(dir, cmd, ~w(jq git curl)) ==
               {"already installed: jq git\n", 0}

      {out, 0} = run_apt(dir, cmd, ~w(jq))
      assert out =~ "sudo apt-get update -qq\n"
      assert out =~ "apt-get install -y -qq jq git\n"

      {out, 0} = run_apt(dir, cmd, [])
      assert out =~ "apt-get install -y -qq jq git\n"
    end

    @tag :tmp_dir
    test "a package dpkg knows but has not installed is installed", %{tmp_dir: dir} do
      [cmd] = Provisioning.build_apt_commands(["jq"])
      {out, 0} = run_apt(dir, cmd, [], ~w(jq))
      assert out =~ "apt-get install -y -qq jq\n"
    end

    test "a name that is not a plain package name always installs" do
      for name <- ["jq=1.7", "jq/resolute-backports", "python3*", "../x"] do
        assert [cmd] = Provisioning.build_apt_commands([name, "git"])
        refute cmd =~ "dpkg-query", name
        assert cmd =~ "apt-get update"
      end
    end

    test "nothing to install is no command" do
      assert Provisioning.build_apt_commands([]) == []
      assert Provisioning.build_apt_commands([nil]) == []
    end
  end

  # Runs an apt command with stub `dpkg-query` (answering `installed` for
  # `installed`, `config-files` for `removed`, and nothing for the rest) and a
  # `sudo` that echoes its arguments.
  defp run_apt(dir, cmd, installed, removed \\ []) do
    cases =
      Enum.map(installed, &"  #{&1}) printf 'installed\\n' ;;\n") ++
        Enum.map(removed, &"  #{&1}) printf 'config-files\\n' ;;\n")

    File.write!(Path.join(dir, "dpkg-query"), """
    #!/bin/bash
    rc=0
    for p in "$@"; do
      case "$p" in
      -W|-f*|--) ;;
    #{cases}  *) echo "no packages found matching $p" >&2; rc=1 ;;
      esac
    done
    exit $rc
    """)

    File.write!(Path.join(dir, "sudo"), "#!/bin/sh\necho sudo \"$@\"\n")
    File.chmod!(Path.join(dir, "dpkg-query"), 0o755)
    File.chmod!(Path.join(dir, "sudo"), 0o755)

    System.cmd("bash", ["-c", cmd],
      env: [{"PATH", dir <> ":" <> System.get_env("PATH")}],
      stderr_to_stdout: true
    )
  end

  describe "write_runtime_config/4" do
    test "delegates to a runtime that writes config, and is :ok for one that does not" do
      assert {:wrote, %{mcp_servers: %{}}, @home} =
               Provisioning.write_runtime_config(
                 handle(),
                 ConfigRuntime,
                 %{mcp_servers: %{}},
                 @home
               )

      assert :ok = Provisioning.write_runtime_config(handle(), BareRuntime, %{}, @home)
    end
  end

  describe "write_instructions/4" do
    test "writes the agent's system prompt into the runtime's instructions file" do
      agent = %{name: "Desk", system: "Be brief."}

      # `Instructions.write/3` calls the facade's arity-3 `write_file`, and
      # Mimic intercepts a function by arity, so that is the one to stub.
      stub(Managoat.Sandbox, :write_file, fn _handle, path, body ->
        assert path == @home <> "/.gemini/GEMINI.md"
        assert body =~ "Be brief."
        :ok
      end)

      assert :ok = Provisioning.write_instructions(handle(), "gemini", agent, @home)
    end

    test "is best effort: a refused write is still :ok, and no agent is nothing to write" do
      stub(Managoat.Sandbox, :write_file, fn _handle, _path, _body -> {:error, :nope} end)

      assert :ok =
               Provisioning.write_instructions(
                 handle(),
                 "gemini",
                 %{name: "Desk", system: "x"},
                 @home
               )

      assert :ok = Provisioning.write_instructions(handle(), "gemini", nil, @home)
    end
  end

  describe "prepare_runtime_sprite/7 and prepare_acp_adapter/3" do
    test "a native ACP runtime installs nothing, then the runtime prepares the sandbox" do
      assert {:prepared, :agent, [{"A", "1"}], @home} =
               Provisioning.prepare_runtime_sprite(
                 handle(),
                 conv(),
                 "gemini",
                 ConfigRuntime,
                 :agent,
                 [{"A", "1"}],
                 nil
               )

      assert :ok =
               Provisioning.prepare_runtime_sprite(
                 handle(),
                 conv(%{runtime: "acp"}),
                 "acp",
                 BareRuntime,
                 nil,
                 [],
                 nil
               )
    end

    test "an adapter runtime installs the adapter first, and its failure is the step's" do
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-lc", script], _opts ->
        assert script =~ ".local/share/managoat/acp/claude-agent-acp@"
        {:ok, "", 0}
      end)

      assert :ok = Provisioning.prepare_acp_adapter(handle(), "claude", [])

      assert :ok =
               Provisioning.prepare_runtime_sprite(
                 handle(),
                 conv(%{runtime: "claude"}),
                 "claude",
                 BareRuntime,
                 nil,
                 [],
                 nil
               )

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:error, :nxdomain} end)

      assert {:error, _} =
               Provisioning.prepare_runtime_sprite(
                 handle(),
                 conv(%{runtime: "claude"}),
                 "claude",
                 ConfigRuntime,
                 nil,
                 [],
                 nil
               )
    end

    test "a launch's own cwd is created, with the config home, before the runtime prepares" do
      test = self()

      stub(Managoat.Sandbox, :exec, fn _handle, "bash", ["-c", script | args], _opts ->
        send(test, {:exec, script, args})
        {:ok, "", 0}
      end)

      assert {:prepared, nil, [], @home} =
               Provisioning.prepare_runtime_sandbox(
                 handle(),
                 conv(%{cwd: "/home/sprite/work/app"}),
                 "gemini",
                 ConfigRuntime,
                 nil,
                 [],
                 nil
               )

      assert_received {:exec, script, args}
      assert script == Fountain.Conversations.ConfigHome.directories_script()

      assert args == [
               "fountain-dirs",
               @home,
               "/home/sprite/work/app",
               "/home/sprite/.managoat",
               ""
             ]
    end

    test "the runtime's default cwd always exists, so it costs no exec" do
      reject(&Managoat.Sandbox.exec/4)

      assert {:prepared, nil, [], @home} =
               Provisioning.prepare_runtime_sandbox(
                 handle(),
                 conv(),
                 "gemini",
                 ConfigRuntime,
                 nil,
                 [],
                 nil
               )
    end

    test "a cwd that cannot be created fails the step before the runtime prepares" do
      stub(Managoat.Sandbox, :exec, fn _handle, "bash", _args, _opts -> {:ok, "denied", 1} end)

      assert {:error, {:conversation_directories, {:exit, 1}}} =
               Provisioning.prepare_runtime_sandbox(
                 handle(),
                 conv(%{cwd: "/home/sprite/x"}),
                 "gemini",
                 ConfigRuntime,
                 nil,
                 [],
                 nil
               )
    end

    test "a runtime that is not ACP-driven installs nothing" do
      assert :ok = Provisioning.prepare_acp_adapter(handle(), "legacy", [])
    end
  end
end
