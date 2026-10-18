defmodule Fountain.SandboxSkillsRecoveryTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.SandboxSkills
  alias Managoat.Runtimes.Testing.SkillRepo

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "skills-recovery"}
  @remote [%{"source" => "owner/repo"}]

  defmodule DiskRuntime do
    def skills_root(_home), do: Process.get(:skills_recovery_root)
  end

  setup :verify_on_exit!

  setup do
    home = Fountain.TmpDir.mkdir!("skills-recovery")
    root = Path.join(home, "skills")
    File.mkdir_p!(root)
    Process.put(:skills_recovery_root, root)

    base = Fountain.TmpDir.mkdir!("skills-recovery-repos")

    SkillRepo.create!(base, "owner/repo", %{
      "skills/discovered/SKILL.md" => SkillRepo.skill_md("discovered", "Remote skill")
    })

    stub(Managoat.Sandbox, :write_file, fn _, path, content -> write_file(path, content) end)
    stub(Managoat.Sandbox, :exec, fn _, "bash", args, opts -> SkillRepo.exec(args, opts) end)

    %{
      root: root,
      home: home,
      env: SkillRepo.env(base),
      manifest: Path.join(root, ".fountain-managed-skills")
    }
  end

  test "nothing is copied until its ownership is durable, and nothing staged is left", ctx do
    stub(Managoat.Sandbox, :write_file, fn _, path, content ->
      if path == ctx.manifest and content =~ "discovered",
        do: {:error, :offline},
        else: write_file(path, content)
    end)

    assert {:error, :offline} =
             SandboxSkills.mount(@handle, DiskRuntime, @remote,
               env: ctx.env,
               config_home: "/unused"
             )

    refute File.exists?(Path.join(ctx.root, "discovered"))
    assert File.ls!(ctx.home) == ["skills"]

    stub(Managoat.Sandbox, :write_file, fn _, path, content -> write_file(path, content) end)

    assert {:ok, []} =
             SandboxSkills.reconcile(@handle, DiskRuntime, @remote, nil,
               env: ctx.env,
               config_home: "/unused"
             )

    assert File.exists?(Path.join(ctx.root, "discovered/SKILL.md"))
  end

  # The skills.sh installer recorded each install's intent before running it.
  # A machine that still holds one cannot say what that install created.
  test "an install the skills.sh installer left pending is refused", ctx do
    write_file(Path.join(ctx.root, "discovered/SKILL.md"), "Late installer output")

    pending =
      Jason.encode!(%{
        "version" => 1,
        "managed" => %{},
        "installing" => %{
          "source" => "owner/repo",
          "name" => nil,
          "before" => [],
          "locked_before" => []
        }
      })

    File.write!(ctx.manifest, pending)

    assert {:error, :skill_installation_incomplete} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil, config_home: "/unused")

    assert File.read!(ctx.manifest) == pending
    assert File.read!(Path.join(ctx.root, "discovered/SKILL.md")) == "Late installer output"
  end

  test "an overlapping reconcile cannot run beside an install", ctx do
    owner = self()

    stub(Managoat.Sandbox, :exec, fn _, "bash", ["-c", script] = args, opts ->
      if script =~ "git init" do
        send(owner, {:installer_started, self()})

        receive do
          :finish_install -> SkillRepo.exec(args, opts)
        after
          5_000 -> flunk("installer was not released")
        end
      else
        SkillRepo.exec(args, opts)
      end
    end)

    installer =
      Task.async(fn ->
        Mimic.allow(Managoat.Sandbox, owner, self())
        Process.put(:skills_recovery_root, ctx.root)
        SandboxSkills.mount(@handle, DiskRuntime, @remote, env: ctx.env, config_home: "/unused")
      end)

    assert_receive {:installer_started, pid}, 2_000
    before = File.read(ctx.manifest)

    assert {:error, :skill_reconciliation_busy} =
             SandboxSkills.reconcile(@handle, DiskRuntime, @remote, [], config_home: "/unused")

    assert File.read(ctx.manifest) == before
    send(pid, :finish_install)
    assert :ok = Task.await(installer)
    assert File.exists?(Path.join(ctx.root, "discovered/SKILL.md"))

    assert {:ok, []} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil, config_home: "/unused")

    refute File.exists?(Path.join(ctx.root, "discovered"))
  end

  test "unsafe or incomplete pending records fail closed", ctx do
    write_file(Path.join(ctx.root, "personal/SKILL.md"), "Preserve me")

    valid = %{
      "version" => 1,
      "managed" => %{},
      "installing" => %{
        "source" => "owner/repo",
        "name" => nil,
        "before" => [],
        "locked_before" => []
      }
    }

    reject(&Managoat.Sandbox.write_file/3)

    for invalid <- [
          put_in(valid, ["managed"], %{"bad" => ["../outside"]}),
          put_in(valid, ["installing", "before"], ["../outside"]),
          put_in(valid, ["installing", "name"], "../outside"),
          put_in(valid, ["installing", "source"], nil),
          Map.put(valid, "installing", %{}),
          Map.put(valid, "version", 2)
        ] do
      original = Jason.encode!(invalid)
      File.write!(ctx.manifest, original)

      assert {:error, :invalid_skill_manifest} =
               SandboxSkills.reconcile(@handle, DiskRuntime, [], nil, config_home: "/unused")

      assert File.read!(ctx.manifest) == original
      assert File.read!(Path.join(ctx.root, "personal/SKILL.md")) == "Preserve me"
    end
  end

  test "known inline destinations remain owned after a final commit failure", ctx do
    selection = [%{"name" => "inline", "content" => "Inline skill"}]

    stub(Managoat.Sandbox, :write_file, fn _, path, content ->
      if path == ctx.manifest and File.exists?(Path.join(ctx.root, "inline/SKILL.md")) and
           not Process.get(:failed_inline_commit, false) do
        Process.put(:failed_inline_commit, true)
        {:error, :offline}
      else
        write_file(path, content)
      end
    end)

    assert {:error, :offline} =
             SandboxSkills.mount(@handle, DiskRuntime, selection, config_home: "/unused")

    assert File.read!(Path.join(ctx.root, "inline/SKILL.md")) == "Inline skill"

    assert {:ok, []} =
             SandboxSkills.reconcile(@handle, DiskRuntime, [], nil, config_home: "/unused")

    refute File.exists?(Path.join(ctx.root, "inline"))
  end

  defp write_file(path, content) do
    File.mkdir_p!(Path.dirname(path))
    File.write(path, content)
  end
end
