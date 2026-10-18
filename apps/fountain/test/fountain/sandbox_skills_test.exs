defmodule Fountain.SandboxSkillsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.SandboxSkills
  alias Managoat.Runtimes.Testing.SkillRepo

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "skills-test"}
  # A home DiskRuntime ignores, and the acp runtime's legacy one for the module case.
  @home "/home/sprite/.claude"

  test "bundled/0 is the API skill, read from priv" do
    assert [%{"name" => "managoat", "content" => api}] = SandboxSkills.bundled()

    assert api =~ "MANAGOAT_CONVERSATION_ID"
  end

  test "mount/3 prepends the bundled skills to the agent's own and installs through the library" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok =
             SandboxSkills.mount(@handle, "claude", [%{"name" => "mine", "content" => "# m"}],
               config_home: Fountain.Conversations.ConfigHome.legacy_home("claude")
             )

    assert_receive {:wrote, "/home/sprite/.claude/skills/managoat/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md"}
  end

  # #1634: the string used to be forwarded to the library's own dispatcher,
  # which is a closed map of the four LLM runtimes. It answered
  # {:error, "unsupported runtime: acp"} and the sandbox came up with no
  # skills at all, silently.
  test "mount/3 resolves the acp runtime through Fountain.RuntimeDispatch" do
    test = self()

    stub(Managoat.Sandbox, :write_file, fn @handle, path, _body ->
      send(test, {:wrote, path})
      :ok
    end)

    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok =
             SandboxSkills.mount(@handle, "acp", [%{"name" => "mine", "content" => "# m"}],
               config_home: Fountain.Conversations.ConfigHome.legacy_home("acp")
             )

    root =
      Fountain.CommandRuntime.skills_root(Fountain.Conversations.ConfigHome.legacy_home("acp"))

    assert_receive {:wrote, ^root <> "/managoat/SKILL.md"}
    assert_receive {:wrote, ^root <> "/mine/SKILL.md"}
  end

  test "a module is passed straight through to the library" do
    test = self()
    stub(Managoat.Sandbox, :write_file, fn _h, path, _b -> send(test, {:wrote, path}) && :ok end)
    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    assert :ok = SandboxSkills.mount(@handle, Fountain.CommandRuntime, nil, config_home: @home)
    assert_receive {:wrote, "/home/sprite/.claude/skills/managoat/SKILL.md"}
  end

  test "a runtime nothing implements is logged and returned, never silent" do
    reject(&Managoat.Sandbox.write_file/3)

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:error, reason} =
                 SandboxSkills.mount(@handle, "nonesuch", [],
                   config_home: Fountain.Conversations.ConfigHome.legacy_home("nonesuch")
                 )

        assert reason =~ "unsupported runtime"
      end)

    assert log =~ "skills not mounted for runtime nonesuch"
  end

  test "a nil skills list mounts the bundled skills alone" do
    test = self()
    stub(Managoat.Sandbox, :exec, fn _, _, _, _ -> {:ok, "", 0} end)

    stub(Managoat.Sandbox, :write_file, fn _h, path, _b ->
      assert path in [
               "/home/sprite/.codex/skills/managoat/SKILL.md",
               "/home/sprite/.codex/skills/.fountain-managed-skills"
             ]

      send(test, {:wrote, path})
      :ok
    end)

    assert :ok =
             SandboxSkills.mount(@handle, "codex", nil,
               config_home: Fountain.Conversations.ConfigHome.legacy_home("codex")
             )

    assert_receive {:wrote, "/home/sprite/.codex/skills/managoat/SKILL.md"}
    assert_receive {:wrote, "/home/sprite/.codex/skills/.fountain-managed-skills"}
  end

  defmodule DiskRuntime do
    @moduledoc """
    A runtime whose skills root is a real directory on this machine, so the
    reconciliation can be measured against a filesystem rather than a mock.
    """
    def skills_root(_home), do: Process.get(:skills_test_root)
  end

  describe "reconciliation on disk" do
    setup do
      root = Fountain.TmpDir.mkdir!("fountain-skills")
      Process.put(:skills_test_root, root)

      stub(Managoat.Sandbox, :write_file, fn _, path, content ->
        File.mkdir_p!(Path.dirname(path))
        File.write(path, content)
      end)

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, opts -> SkillRepo.exec(args, opts) end)

      base = Fountain.TmpDir.mkdir!("fountain-skill-repos")

      SkillRepo.create!(base, "owner/repo", %{
        "skills/discovered/SKILL.md" => SkillRepo.skill_md("discovered", "Remote skill"),
        "skills/remote/SKILL.md" => SkillRepo.skill_md("remote", "Remote named skill")
      })

      %{root: root, base: base, env: SkillRepo.env(base)}
    end

    defp fetches do
      Stream.repeatedly(fn ->
        receive do
          {:fetch, env} -> env
        after
          0 -> nil
        end
      end)
      |> Enum.take_while(& &1)
    end

    defp count_fetches(test) do
      stub(Managoat.Sandbox, :exec, fn _, "bash", ["-c", script] = args, opts ->
        if script =~ "git init", do: send(test, {:fetch, opts[:env]})
        SkillRepo.exec(args, opts)
      end)
    end

    test "mount_fresh/3 leaves an empty root exactly as mount/3 does, with no exec", %{
      root: root
    } do
      skills = [%{"name" => "mine", "content" => "# m"}]
      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, skills, config_home: @home)
      reconciled = snapshot(root)

      File.rm_rf!(root)
      File.mkdir_p!(root)
      reject(&Managoat.Sandbox.exec/4)

      assert :ok = SandboxSkills.mount_fresh(@handle, DiskRuntime, skills, config_home: @home)
      assert snapshot(root) == reconciled
      assert Map.has_key?(reconciled, ".fountain-managed-skills")
    end

    test "mount_fresh/3 reconciles when a skill is remote", %{root: root, env: env} do
      count_fetches(self())

      assert :ok =
               SandboxSkills.mount_fresh(
                 @handle,
                 DiskRuntime,
                 [%{"source" => "owner/repo", "name" => "remote"}],
                 env: env,
                 config_home: @home
               )

      assert [_] = fetches()
      assert File.exists?(Path.join(root, "managoat/SKILL.md"))
      assert File.read!(Path.join(root, "remote/SKILL.md")) =~ "Remote named skill"
      refute File.exists?(Path.join(root, "discovered"))
    end

    test "removes an obsolete inline skill while preserving unrelated files", %{root: root} do
      File.mkdir_p!(Path.join(root, "personal"))
      File.write!(Path.join(root, "personal/SKILL.md"), "My local skill")

      assert :ok =
               SandboxSkills.mount(
                 @handle,
                 DiskRuntime,
                 [
                   %{"name" => "old", "content" => "Old skill"}
                 ],
                 config_home: @home
               )

      assert :ok =
               SandboxSkills.mount(
                 @handle,
                 DiskRuntime,
                 [
                   %{"name" => "new", "content" => "New skill"}
                 ],
                 config_home: @home
               )

      refute File.exists?(Path.join(root, "old"))
      assert File.read!(Path.join(root, "new/SKILL.md")) == "New skill"
      # Not Fountain's, so not Fountain's to delete.
      assert File.read!(Path.join(root, "personal/SKILL.md")) == "My local skill"
      assert File.exists?(Path.join(root, "managoat/SKILL.md"))
    end

    # ADR 0082 renamed the bundled skill. A machine provisioned before it has
    # `fountain/` on disk, recorded in the manifest as the bundled skill; the
    # next reconcile replaces it with `managoat/` rather than leaving both.
    test "replaces the bundled skill's old `fountain` directory", %{root: root} do
      File.mkdir_p!(Path.join(root, "fountain"))
      File.write!(Path.join(root, "fountain/SKILL.md"), "the old bundled skill")

      File.write!(
        Path.join(root, ".fountain-managed-skills"),
        Jason.encode!(%{Jason.encode!([nil, "fountain"]) => ["fountain"]})
      )

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [], config_home: @home)

      refute File.exists?(Path.join(root, "fountain"))
      assert File.exists?(Path.join(root, "managoat/SKILL.md"))
    end

    test "repeating a legacy reconciliation keeps the manifest and unrelated files", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      File.mkdir_p!(Path.join(root, "personal"))
      File.write!(Path.join(root, "personal/SKILL.md"), "Keep my work")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]
      selected = [%{"name" => "current", "content" => "Current skill"}]

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, selected, previous,
                 config_home: @home
               )

      manifest = File.read!(Path.join(root, ".fountain-managed-skills"))

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, selected, previous,
                 config_home: @home
               )

      assert File.read!(Path.join(root, ".fountain-managed-skills")) == manifest
      assert File.read!(Path.join(root, "current/SKILL.md")) == "Current skill"
      assert File.read!(Path.join(root, "personal/SKILL.md")) == "Keep my work"
      refute File.exists?(Path.join(root, "legacy"))
    end

    test "refuses malformed, unsafe and non-file manifests without touching skills", %{root: root} do
      manifest = Path.join(root, ".fountain-managed-skills")
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]

      for contents <- [
            "",
            "..\n../outside\n",
            "[]",
            ~s({"owned":["../outside"]}),
            ~s({"owned":["legacy",null]}),
            ~s({"owned":"legacy"})
          ] do
        File.write!(manifest, contents)

        assert {:error, :invalid_skill_manifest} =
                 SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

        assert File.read!(manifest) == contents
        assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
      end

      File.rm!(manifest)
      File.ln_s!(Path.join(root, "legacy/SKILL.md"), manifest)

      assert {:error, :invalid_skill_manifest} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      File.rm!(manifest)
      File.mkdir!(manifest)

      assert {:error, :invalid_skill_manifest} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
    end

    test "a completed reconciliation never reclaims a released name", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Personal replacement")

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Personal replacement"
    end

    test "a failed ownership write leaves old skills intact and migration is retryable", %{
      root: root
    } do
      File.mkdir_p!(Path.join(root, "legacy"))
      File.write!(Path.join(root, "legacy/SKILL.md"), "Old skill")
      previous = [%{"name" => "legacy", "content" => "Old skill"}]
      expect(Managoat.Sandbox, :write_file, fn _, _, _ -> {:error, :offline} end)

      assert {:error, :offline} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      assert File.read!(Path.join(root, "legacy/SKILL.md")) == "Old skill"
      refute File.exists?(Path.join(root, ".fountain-managed-skills"))

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], previous, config_home: @home)

      assert File.regular?(Path.join(root, ".fountain-managed-skills"))
      refute File.exists?(Path.join(root, "legacy"))
    end

    test "missing source-lock evidence does not certify an unnamed legacy install", %{root: root} do
      File.mkdir_p!(Path.join(root, "unknown-remote"))

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
          {:ok, "", 0}
        else
          {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
          {:ok, output, code}
        end
      end)

      for _retry <- 1..2 do
        assert {:error, :legacy_skill_ownership_unknown} =
                 SandboxSkills.reconcile(
                   @handle,
                   DiskRuntime,
                   [],
                   [
                     %{"source" => "owner/repo"}
                   ],
                   config_home: @home
                 )

        refute File.exists?(Path.join(root, ".fountain-managed-skills"))
        assert File.dir?(Path.join(root, "unknown-remote"))
      end
    end

    test "current manifests do not consult an unavailable historical GitHub source lock", %{
      root: root
    } do
      File.write!(Path.join(root, ".fountain-managed-skills"), "{}")

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        refute Enum.any?(args, &String.contains?(&1, "skills_lock="))
        {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
        {:ok, output, code}
      end)

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [%{"source" => "owner/repo"}],
                 config_home: @home
               )
    end

    test "recovers unnamed legacy GitHub skills from the source lock", %{root: root} do
      File.mkdir_p!(Path.join(root, "legacy-remote"))
      File.write!(Path.join(root, "legacy-remote/SKILL.md"), "Old remote skill")
      File.mkdir_p!(Path.join(root, "unrelated"))

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, _ ->
        if Enum.any?(args, &String.contains?(&1, "skills_lock=")) do
          {:ok,
           Jason.encode!(%{
             "skills" => %{
               "legacy-remote" => %{"source" => "owner/repo", "sourceType" => "github"},
               "unrelated" => %{"source" => "another/repo", "sourceType" => "github"},
               "../outside" => %{"source" => "owner/repo", "sourceType" => "github"}
             }
           }), 0}
        else
          {output, code} = System.cmd("bash", args, stderr_to_stdout: true)
          {:ok, output, code}
        end
      end)

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], [%{"source" => "owner/repo"}],
                 config_home: @home
               )

      refute File.exists?(Path.join(root, "legacy-remote"))
      # Installed from a source this conversation never named.
      assert File.dir?(Path.join(root, "unrelated"))
    end

    test "a retained remote skill survives an offline reinstall", %{root: root} do
      skill = %{"source" => "owner/repo", "name" => "remote"}
      File.mkdir_p!(Path.join(root, "remote"))
      File.write!(Path.join(root, "remote/SKILL.md"), "Already installed")

      # No env pointing git at the fixture: github.com is out of reach.
      stub(Managoat.Sandbox, :exec, fn _, "bash", ["-c", script] = args, opts ->
        if script =~ "git init", do: {:ok, "offline", 128}, else: SkillRepo.exec(args, opts)
      end)

      # Refreshed, because a present copy is otherwise not installed again.
      # The failed fetch is returned, so the caller does not record it.
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, [^skill]} =
                 SandboxSkills.reconcile(@handle, DiskRuntime, [skill], [skill],
                   refresh: [skill],
                   config_home: @home
                 )
      end)

      assert File.read!(Path.join(root, "remote/SKILL.md")) == "Already installed"
      assert File.read!(Path.join(root, ".fountain-managed-skills")) =~ "remote"
    end

    test "a remote skill on the disk is not installed again; a missing or refreshed one is", %{
      root: root,
      env: env
    } do
      count_fetches(self())
      skill = %{"source" => "owner/repo"}
      proxy = [{"HTTPS_PROXY", "http://tok:c-x@broker:8443"} | env]

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [skill], env: proxy, config_home: @home)

      assert [fetch_env] = fetches()
      assert {"HTTPS_PROXY", "http://tok:c-x@broker:8443"} in fetch_env
      assert File.read!(Path.join(root, "discovered/SKILL.md")) =~ "Remote skill"

      # A wake: the recorded directories are there, so no network.
      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [skill], nil,
                 env: env,
                 config_home: @home
               )

      assert fetches() == []
      manifest = File.read!(Path.join(root, ".fountain-managed-skills"))
      assert manifest =~ "discovered" and manifest =~ "remote"
      assert File.exists?(Path.join(root, "managoat/SKILL.md"))

      # Its ref moved.
      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [skill], nil,
                 refresh: [skill],
                 env: env,
                 config_home: @home
               )

      assert [_] = fetches()

      # One of its directories went missing.
      File.rm_rf!(Path.join(root, "discovered"))

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [skill], nil,
                 env: env,
                 config_home: @home
               )

      assert [_] = fetches()
      assert File.exists?(Path.join(root, "discovered/SKILL.md"))
    end

    test "two entries from one repository fetch it once", %{root: root, env: env} do
      count_fetches(self())

      skills = [
        %{"source" => "owner/repo", "name" => "remote"},
        %{"source" => "owner/repo", "name" => "discovered"}
      ]

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, skills, env: env, config_home: @home)
      assert [_] = fetches()
      assert File.exists?(Path.join(root, "remote/SKILL.md"))
      assert File.exists?(Path.join(root, "discovered/SKILL.md"))
    end

    test "tracks discovered GitHub skill names for a later removal", %{root: root, env: env} do
      File.mkdir_p!(Path.join(root, "personal"))

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [%{"source" => "owner/repo"}],
                 env: env,
                 config_home: @home
               )

      manifest = File.read!(Path.join(root, ".fountain-managed-skills"))
      assert manifest =~ "discovered" and manifest =~ "remote"
      refute manifest =~ "personal"

      assert :ok = SandboxSkills.mount(@handle, DiskRuntime, [], config_home: @home)
      refute File.exists?(Path.join(root, "discovered"))
      refute File.exists?(Path.join(root, "remote"))
      assert File.dir?(Path.join(root, "personal"))
    end

    test "a directory already on the disk is replaced but not claimed", %{root: root, env: env} do
      File.mkdir_p!(Path.join(root, "discovered"))
      File.write!(Path.join(root, "discovered/SKILL.md"), "Personal")

      assert :ok =
               SandboxSkills.mount(@handle, DiskRuntime, [%{"source" => "owner/repo"}],
                 env: env,
                 config_home: @home
               )

      assert File.read!(Path.join(root, "discovered/SKILL.md")) =~ "Remote skill"
      refute File.read!(Path.join(root, ".fountain-managed-skills")) =~ "discovered"
    end

    test "ownership is recorded before the copy, so an interrupted copy is retried", %{
      root: root,
      env: env
    } do
      skill = %{"source" => "owner/repo", "name" => "remote"}

      stub(Managoat.Sandbox, :exec, fn _, "bash", ["-c", script] = args, opts ->
        if script =~ "place()", do: {:error, :timeout}, else: SkillRepo.exec(args, opts)
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 SandboxSkills.mount(@handle, DiskRuntime, [skill], env: env, config_home: @home)
      end)

      refute File.exists?(Path.join(root, "remote"))
      assert File.read!(Path.join(root, ".fountain-managed-skills")) =~ "remote"

      stub(Managoat.Sandbox, :exec, fn _, "bash", args, opts -> SkillRepo.exec(args, opts) end)

      assert {:ok, []} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [skill], nil,
                 env: env,
                 config_home: @home
               )

      assert File.exists?(Path.join(root, "remote/SKILL.md"))
    end
  end

  defp snapshot(root) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, root), File.read!(&1)})
  end
end
