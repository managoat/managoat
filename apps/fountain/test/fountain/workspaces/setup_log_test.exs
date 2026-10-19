defmodule Fountain.Workspaces.SetupLogTest do
  @moduledoc """
  #3009: an explicit workspace's setup output, live and kept. Output is
  framed into whole lines before it is redacted, so a value split across
  chunks, or printed a line at a time, never travels in the clear; it is
  kept per step within its bounds, sent as `workspace.setup` events within
  theirs, and replaced by the next setup. The real setup paths (a create, a
  rebuild after a loss run by a conversation) fill it; an implicit
  workspace's does not.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Conversations.Provisioning
  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Provision
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.SetupLog
  alias Fountain.Workspaces.SetupOutput
  alias Managoat.Sandbox.Handle

  setup :set_mimic_global

  @secret "s3cret-value-123456"

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "make setup")
    vault = insert_vault(user_id: user.id)
    insert_vault_secret(vault, %{"key" => "API_SECRET", "value" => @secret})

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)
    stub(Managoat.Sandbox, :write_file, fn _h, _p, _b, _o -> :ok end)
    stub(Managoat.Sandbox, :apply_network_policy, fn _h, _p -> :ok end)
    stub(Fountain.Broker.TransportRelay, :ensure, fn _h, _o -> :ok end)
    stub(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "", 0} end)

    # Every event and every write at once, unless a test is about pacing.
    put_env(:setup_event_interval_ms, 0)
    put_env(:setup_log_flush_ms, 0)

    {:ok, user: user, env: env, vault: vault}
  end

  defp put_env(key, value) do
    previous = Application.get_env(:fountain, key)
    Application.put_env(:fountain, key, value)

    on_exit(fn ->
      if previous == nil,
        do: Application.delete_env(:fountain, key),
        else: Application.put_env(:fountain, key, previous)
    end)
  end

  defp create!(ctx, env \\ nil) do
    test = self()

    stub(Provisioner, :start, fn _workspace, sandbox_id ->
      send(test, {:provision_started, sandbox_id})
      {:ok, self()}
    end)

    {:ok, workspace} =
      Workspaces.create_workspace(
        ctx.user.id,
        %{"name" => "w", "environment_id" => (env || ctx.env).id, "vault_id" => ctx.vault.id},
        actor: "api"
      )

    assert_receive {:provision_started, sandbox_id}
    {workspace, Repo.get!(Sandbox, sandbox_id)}
  end

  defp log(workspace), do: Workspaces.setup_log(Repo.reload!(workspace))

  defp step(log, name), do: Enum.find(log.steps, &(&1["step"] == name))

  defp events do
    receive do
      {:workspace_setup, payload} -> [payload | events()]
    after
      0 -> []
    end
  end

  # Drive the collector by hand, as a build would, on the test process.
  defp collect(sandbox, fun) do
    :ok = SetupOutput.begin(sandbox)
    assert SetupOutput.active?()
    fun.()
    :ok = SetupOutput.finish(:succeeded)
    refute SetupOutput.active?()
  end

  describe "redaction" do
    test "a value split across chunks is redacted whole, in the log and the events", ctx do
      {workspace, sandbox} = create!(ctx)
      :ok = Workspaces.subscribe(ctx.user.id)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        SetupOutput.output("token is s3cret-va")
        SetupOutput.output("lue-123456 and more\nnext li")
        SetupOutput.output("ne\n")
      end)

      output = step(log(workspace), "packages")["output"]
      assert output == "token is [REDACTED] and more\nnext line\n"

      sent = events() |> Enum.flat_map(& &1.lines) |> Enum.join("\n")
      refute sent =~ "s3cret"
      refute sent =~ "lue-123456"
      assert sent =~ "token is [REDACTED] and more"
    end

    test "each line of a value that spans lines is redacted", ctx do
      key = "-----BEGIN KEY-----\nAAAAsecretline1AAAA\nBBBBsecretline2BBBB\n-----END KEY-----"
      insert_vault_secret(ctx.vault, %{"key" => "DEPLOY_KEY", "value" => key})
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:setup_script)
        SetupOutput.output("cat key\n" <> key <> "\ndone\n")
      end)

      output = step(log(workspace), "setup_script")["output"]
      refute output =~ "secretline1"
      refute output =~ "secretline2"
      assert output =~ "done"
    end

    test "the setup session's token, added once it exists, is redacted", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.add_values(["proxy-token-abcdef0123"])
        SetupOutput.step(:packages)
        SetupOutput.output("HTTPS_PROXY=http://proxy-token-abcdef0123:x@broker\n")
      end)

      assert step(log(workspace), "packages")["output"] ==
               "HTTPS_PROXY=http://[REDACTED]:x@broker\n"
    end

    test "a value written after the setup began is redacted from the next step on", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        insert_vault_secret(ctx.vault, %{"key" => "LATE", "value" => "late-secret-0987654"})
        SetupOutput.step(:setup_script)
        SetupOutput.output("late-secret-0987654\n")
      end)

      assert step(log(workspace), "setup_script")["output"] == "[REDACTED]\n"
    end

    test "with no tenant key the output is withheld, with a line saying so", ctx do
      {workspace, sandbox} = create!(ctx)
      stub(Fountain.Crypto, :load_tenant_key, fn _ -> {:error, :unavailable} end)
      :ok = Workspaces.subscribe(ctx.user.id)

      collect(sandbox, fn ->
        SetupOutput.step(:setup_script)
        SetupOutput.output("#{@secret}\nmore #{@secret}\n")
      end)

      output = step(log(workspace), "setup_script")["output"]
      assert output =~ "withheld"
      refute output =~ @secret
      refute events() |> Enum.flat_map(& &1.lines) |> Enum.join() =~ @secret
    end

    test "a line is shown after its last carriage return, as text", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        SetupOutput.output("10%\r50%\r100% done\r\nbad \xff byte\0 here\n")
      end)

      assert step(log(workspace), "packages")["output"] == "100% done\nbad � byte here\n"
    end

    test "a secret printed with a carriage return in front is still redacted", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        SetupOutput.output("x\r#{@secret}\n")
      end)

      assert step(log(workspace), "packages")["output"] == "[REDACTED]\n"
    end
  end

  describe "bounds" do
    test "a long line is cut at 4 KiB", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        SetupOutput.output(String.duplicate("a", 10_000) <> "\n")
      end)

      [line] = step(log(workspace), "packages")["output"] |> String.split("\n", trim: true)
      assert line == String.duplicate("a", 4_096) <> " …"
    end

    test "a line with no newline past 64 KiB is written cut, and the rest of it dropped",
         ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        SetupOutput.output(String.duplicate("b", 70_000))
        SetupOutput.output(String.duplicate("c", 70_000) <> "\nafter\n")
      end)

      lines = step(log(workspace), "packages")["output"] |> String.split("\n", trim: true)
      assert [head, "after"] = lines
      assert head == String.duplicate("b", 4_096)
    end

    test "a value lying across the cut of an overlong line never shows in part", ctx do
      {workspace, sandbox} = create!(ctx)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        # The value starts 6 bytes before the 4 KiB cut.
        SetupOutput.output(
          String.duplicate("b", 4_090) <> @secret <> String.duplicate("b", 70_000)
        )

        SetupOutput.output("\n")
      end)

      [head] = step(log(workspace), "packages")["output"] |> String.split("\n", trim: true)
      refute head =~ "s3cr"
      # Redacted whole, then cut for display.
      assert head == String.duplicate("b", 4_090) <> "[REDAC …"
    end

    test "each step keeps its last 64 KiB, and says what it dropped", ctx do
      {workspace, sandbox} = create!(ctx)
      line = String.duplicate("x", 99)

      collect(sandbox, fn ->
        SetupOutput.step(:packages)
        for i <- 1..1_000, do: SetupOutput.output("#{line}#{rem(i, 10)}\n")
      end)

      packages = step(log(workspace), "packages")
      assert byte_size(packages["output"]) <= 65_536
      assert byte_size(packages["output"]) > 65_536 - 101
      kept = packages["output"] |> String.split("\n", trim: true) |> length()
      assert packages["omitted_lines"] == 1_000 - kept
      assert packages["omitted_bytes"] == packages["omitted_lines"] * 101
      # The last line is the last printed.
      assert String.ends_with?(packages["output"], line <> "0\n")
    end

    test "the whole log keeps 256 KiB, the earliest step losing its earliest lines", ctx do
      {workspace, sandbox} = create!(ctx)
      chunk = Enum.map_join(1..640, fn _ -> String.duplicate("y", 99) <> "\n" end)

      collect(sandbox, fn ->
        for name <- [:broker, :environment, :packages, :repositories, :setup_script] do
          SetupOutput.step(name)
          SetupOutput.output(chunk)
        end
      end)

      log = log(workspace)
      total = log.steps |> Enum.map(&byte_size(&1["output"])) |> Enum.sum()
      assert total <= 262_144
      # 320,000 bytes printed: the earliest step gave up the 579 lines over
      # the cap, its earliest first, and the later ones are whole.
      assert step(log, "broker")["omitted_lines"] == 579
      assert step(log, "broker")["omitted_bytes"] == 57_900

      for name <- ~w(environment packages repositories setup_script),
          do: assert(step(log, name)["omitted_lines"] == 0)
    end

    test "events come at most once per interval, each within 16 KiB, counting the rest",
         ctx do
      put_env(:setup_event_interval_ms, 60_000)
      {_workspace, sandbox} = create!(ctx)
      :ok = Workspaces.subscribe(ctx.user.id)
      line = String.duplicate("z", 99)

      collect(sandbox, fn ->
        SetupOutput.step(:setup_script)
        for _ <- 1..20, do: SetupOutput.output(Enum.map_join(1..50, fn _ -> line <> "\n" end))
      end)

      sent = events()

      # machine started, machine ended and setup_script started, then one
      # output event's worth at the step's end: nothing in between, however
      # many chunks arrived inside the interval.
      assert [
               %{step: "machine", status: "running", lines: []},
               %{step: "machine", status: "succeeded"},
               %{step: "setup_script", status: "running", lines: []},
               %{step: "setup_script", status: "succeeded", lines: lines, omitted_lines: omitted}
             ] = sent

      assert lines |> Enum.map(&(byte_size(&1) + 1)) |> Enum.sum() <= 16_384
      assert length(lines) + omitted == 1_000
      assert List.last(lines) == line
    end
  end

  describe "the log" do
    test "follows the steps, says which is running, and is replaced by the next setup", ctx do
      {workspace, sandbox} = create!(ctx)
      :ok = SetupOutput.begin(sandbox)
      :ok = SetupOutput.step(:packages)
      :ok = SetupOutput.output("installing\n")

      running = log(workspace)
      assert %SetupLog{status: "running", step: "packages"} = running
      assert running.sandbox_id == sandbox.id
      assert Enum.map(running.steps, & &1["status"]) == ["succeeded", "running"]
      assert Workspaces.setup_steps([Repo.reload!(workspace)]) == %{workspace.id => "packages"}

      # A step already running is not begun again.
      :ok = SetupOutput.step(:packages)
      :ok = SetupOutput.finish(:failed)

      done = log(workspace)
      assert %SetupLog{status: "failed", step: "packages", finished_at: %DateTime{}} = done

      assert Enum.map(done.steps, &{&1["step"], &1["status"]}) ==
               [{"machine", "succeeded"}, {"packages", "failed"}]

      assert Workspaces.setup_steps([Repo.reload!(workspace)]) == %{}

      # The next setup, on its own machine, replaces it.
      {:ok, _} = update_sandbox(sandbox, %{status: "failed"})
      next = insert_sandbox(user_id: ctx.user.id, workspace_id: workspace.id, status: "pending")
      :ok = SetupOutput.begin(next)
      assert %SetupLog{status: "running", step: "machine", sandbox_id: next_id} = log(workspace)
      assert next_id == next.id
      :ok = SetupOutput.finish(:succeeded)
    end

    test "a replaced setup writes nothing more", ctx do
      {workspace, sandbox} = create!(ctx)
      :ok = SetupOutput.begin(sandbox)
      :ok = SetupOutput.step(:packages)

      # Another setup begins (in another process, as a retry's would).
      {:ok, _} = update_sandbox(sandbox, %{status: "failed"})
      next = insert_sandbox(user_id: ctx.user.id, workspace_id: workspace.id, status: "pending")

      Task.async(fn -> SetupOutput.begin(next) end) |> Task.await()

      :ok = SetupOutput.output("stale\n")
      :ok = SetupOutput.finish(:failed)

      assert %SetupLog{status: "running", step: "machine"} = log = log(workspace)
      assert log.sandbox_id == next.id
      refute Enum.any?(log.steps, &(&1["output"] =~ "stale"))
    end

    test "a setup its deadline killed is settled failed with its machine", ctx do
      {workspace, sandbox} = create!(ctx)
      :ok = SetupOutput.begin(sandbox)
      :ok = SetupOutput.step(:setup_script)
      # The task is killed here: nothing more comes from it.
      Process.delete({SetupOutput, :setup})

      capture_log(fn ->
        Fountain.Machines.Machine.fail_provision(sandbox.id,
          actor: "system:workspace_setup",
          reason: :provision_deadline_exceeded
        )
      end)

      assert %SetupLog{status: "failed", finished_at: %DateTime{}} = log = log(workspace)
      assert step(log, "setup_script")["status"] == "failed"
      assert step(log, "setup_script")["finished_at"]
    end

    test "is not collected for an implicit workspace", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "pending")
      :ok = Workspaces.subscribe(ctx.user.id)

      :ok = SetupOutput.begin(sandbox)
      refute SetupOutput.active?()
      :ok = SetupOutput.step(:packages)
      :ok = SetupOutput.output("x\n")

      assert Repo.all(SetupLog) == []
      assert events() == []
    end

    test "is scoped to its owner", ctx do
      {workspace, sandbox} = create!(ctx)
      collect(sandbox, fn -> SetupOutput.step(:packages) end)
      other = insert_verified_user()

      assert SetupLog.get(workspace.id, ctx.user.id)
      refute SetupLog.get(workspace.id, other.id)
      assert SetupLog.running_steps([workspace.id], other.id) == %{}
    end
  end

  describe "a workspace's setup" do
    test "on create: every step in order, the output kept, and the events live", ctx do
      env =
        insert_env(
          user_id: ctx.user.id,
          setup_script: "make setup",
          packages: %{"apt" => ["jq"]}
        )

      {workspace, sandbox} = create!(ctx, env)
      :ok = Workspaces.subscribe(ctx.user.id)

      stub(Managoat.Sandbox, :exec, fn
        _h, "bash", ["-c", _wrapper, "fountain-packages", _cmd], opts ->
          Keyword.fetch!(opts, :on_output).("Reading package lists...\nSetting up j")
          Keyword.fetch!(opts, :on_output).("q (1.7)\n")
          {:ok, "", 0}

        _h, "bash", ["-c", _wrapper, "fountain-setup", _script], opts ->
          Keyword.fetch!(opts, :on_output).("using #{@secret}\n")
          {:ok, "done without a newline", 0}

        _h, _c, _a, _o ->
          {:ok, "", 0}
      end)

      capture_log(fn ->
        assert {:ok, :provisioned, :set_up} = Provisioner.run(workspace.id, sandbox.id)
      end)

      log = log(workspace)
      assert %SetupLog{status: "succeeded", step: "setup_script"} = log

      assert Enum.map(log.steps, &{&1["step"], &1["status"]}) == [
               {"machine", "succeeded"},
               {"broker", "succeeded"},
               {"environment", "succeeded"},
               {"packages", "succeeded"},
               {"setup_script", "succeeded"}
             ]

      assert step(log, "packages")["output"] == "Reading package lists...\nSetting up jq (1.7)\n"

      assert step(log, "setup_script")["output"] ==
               "using [REDACTED]\ndone without a newline\n"

      sent = events()
      assert Enum.all?(sent, &(&1.sandbox_id == sandbox.id and &1.workspace_id == workspace.id))
      assert %{step: "machine", status: "running"} = hd(sent)
      refute sent |> Enum.flat_map(& &1.lines) |> Enum.join() =~ @secret

      # The log was complete before the workspace said ready.
      assert_received {:workspace_status, %{status: "ready"}}
    end

    test "a failed step ends the log failed, at that step", ctx do
      {workspace, sandbox} = create!(ctx)

      stub(Managoat.Sandbox, :exec, fn
        _h, "bash", ["-c", _wrapper, "fountain-setup", _script], opts ->
          Keyword.fetch!(opts, :on_output).("make: *** [setup] Error 2\n")
          {:ok, "", 2}

        _h, _c, _a, _o ->
          {:ok, "", 0}
      end)

      capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

      log = log(workspace)
      assert %SetupLog{status: "failed", step: "setup_script"} = log
      assert step(log, "setup_script")["status"] == "failed"
      assert step(log, "setup_script")["output"] == "make: *** [setup] Error 2\n"
      assert Repo.reload!(workspace).status == "failed"
    end

    test "a machine the provider would not create ends the log failed at machine", ctx do
      {workspace, sandbox} = create!(ctx)
      stub(Managoat.Sandbox, :create, fn _p, _n -> {:error, {:denied, "quota"}} end)

      capture_log(fn -> Provisioner.run(workspace.id, sandbox.id) end)

      assert %SetupLog{status: "failed", step: "machine", steps: [machine]} = log(workspace)
      assert machine["status"] == "failed"
    end

    test "a rebuild after a loss, run by a conversation, goes to its transcript and the log",
         ctx do
      {workspace, old} = create!(ctx)
      capture_log(fn -> {:ok, :provisioned, :set_up} = Provisioner.run(workspace.id, old.id) end)
      first = log(workspace)

      conv = insert_conversation(user_id: ctx.user.id, sandbox: Repo.reload!(old))
      {:ok, _} = update_sandbox(Repo.reload!(old), %{status: "terminated"})

      stub(Managoat.Sandbox, :exec, fn
        _h, "bash", ["-c", _wrapper, "fountain-setup", _script], opts ->
          Keyword.fetch!(opts, :on_output).("rebuilt with #{@secret}\n")
          {:ok, "", 0}

        _h, _c, _a, _o ->
          {:ok, "", 0}
      end)

      env = Repo.reload!(ctx.env)

      pipeline = fn handle, _epoch ->
        :ok = Provisioning.run_setup_script(handle, env, [], conv.id)
        {:ok, :built}
      end

      capture_log(fn ->
        assert {:ok, :rebuilt, %Sandbox{} = next, :built} =
                 Provision.rebuild(old.id, pipeline,
                   actor: "system:conversation_server",
                   conversation_id: conv.id,
                   environment: env,
                   provider: :already_gone,
                   attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"}
                 )

        send(self(), {:next, next})
      end)

      assert_received {:next, next}
      log = log(workspace)
      assert log.sandbox_id == next.id
      refute log.sandbox_id == first.sandbox_id
      assert %SetupLog{status: "succeeded"} = log
      assert step(log, "setup_script")["output"] == "rebuilt with [REDACTED]\n"

      # The conversation's transcript has it too, redacted there by its own writer.
      transcript =
        conv.id
        |> Fountain.Conversations._unsafe_list_log_events()
        |> Enum.filter(&(&1.kind == "output"))
        |> Enum.map_join(& &1.data)

      assert transcript =~ "rebuilt with"
    end
  end
end
