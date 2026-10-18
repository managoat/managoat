defmodule Managoat.Runtimes.SkillsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Skills
  alias Managoat.Sandbox

  setup :verify_on_exit!

  @handle %Sandbox.Handle{provider: :sprites, name: "skills-test"}

  describe "install/3" do
    test "an empty skill set is a no-op" do
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert :ok =
               Skills.install(@handle, [], runtime: "claude", config_home: "/home/sprite/.claude")
    end

    test "inline skills land under the runtime's skills root, in the order given" do
      test = self()

      stub(Sandbox, :write_file, fn @handle, path, body ->
        send(test, {:wrote, path, body})
        :ok
      end)

      reject(&Sandbox.exec/4)

      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"name" => "managoat", "content" => "# API"},
                   %{name: "mine", content: "# mine"}
                 ],
                 runtime: "claude",
                 config_home: "/home/sprite/.claude"
               )

      assert_receive {:wrote, "/home/sprite/.claude/skills/managoat/SKILL.md", "# API"}
      assert_receive {:wrote, "/home/sprite/.claude/skills/mine/SKILL.md", "# mine"}
    end

    test "the skills root follows the runtime's own HOME" do
      test = self()
      stub(Sandbox, :write_file, fn _h, path, _body -> send(test, {:wrote, path}) && :ok end)

      assert :ok =
               Skills.install(@handle, [%{"name" => "s", "content" => "c"}],
                 runtime: "gemini",
                 config_home: "/tmp"
               )

      assert_receive {:wrote, "/tmp/.gemini/skills/s/SKILL.md"}
    end

    test "a github fetch runs with the env it is given and fails fast" do
      test = self()

      expect(Sandbox, :exec, fn @handle, "bash", ["-c", script], opts ->
        send(test, {:fetch, script, opts[:env]})
        {:ok, "fatal: unable to access", 128}
      end)

      # Removes the staging directories even though nothing was fetched.
      expect(Sandbox, :exec, fn @handle, "bash", ["-c", script], _opts ->
        send(test, {:place, script})
        {:ok, "", 0}
      end)

      proxy = [{"HTTPS_PROXY", "http://tok:c-x@broker:8443"}]

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert :ok =
                   Skills.install(@handle, [%{"source" => "owner/repo"}],
                     runtime: "claude",
                     config_home: "/home/sprite/.claude",
                     env: proxy
                   )
        end)

      assert_receive {:fetch, script, env}
      assert script =~ "'https://github.com/owner/repo.git' 'HEAD'"
      assert {"HTTPS_PROXY", "http://tok:c-x@broker:8443"} in env
      assert {"GIT_TERMINAL_PROMPT", "0"} in env
      assert_receive {:place, place}
      assert place =~ "'/home/sprite/.claude'/.managoat-skill-fetch-*"
      assert log =~ "github skill install failed"
    end

    test "a skill that fails to land is logged, not raised, and the rest still install" do
      test = self()

      stub(Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "fatal", 1} end)

      stub(Sandbox, :write_file, fn _h, path, _body ->
        send(test, {:wrote, path})
        if String.contains?(path, "/bad/"), do: {:error, :unavailable}, else: :ok
      end)

      ExUnit.CaptureLog.capture_log(fn ->
        assert :ok =
                 Skills.install(
                   @handle,
                   [
                     %{"source" => "owner/repo"},
                     %{"name" => "bad", "content" => "c"},
                     %{"name" => "good", "content" => "c"}
                   ],
                   runtime: "claude",
                   config_home: "/home/sprite/.claude"
                 )
      end)

      assert_receive {:wrote, "/home/sprite/.claude/skills/bad/SKILL.md"}
      assert_receive {:wrote, "/home/sprite/.claude/skills/good/SKILL.md"}
    end

    test "an unknown runtime is an error, and nothing is written" do
      reject(&Sandbox.write_file/3)
      reject(&Sandbox.exec/4)

      assert {:error, msg} =
               Skills.install(@handle, [%{"name" => "s", "content" => "c"}],
                 runtime: "nope",
                 config_home: "/tmp"
               )

      assert msg =~ "unsupported runtime"
    end
  end

  describe "github skills from a repository" do
    alias Managoat.Runtimes.Testing.SkillRepo

    defmodule DiskRuntime do
      def skills_root(_home), do: Process.get(:skills_lib_root)
    end

    setup do
      base = Fountain.TmpDir.mkdir!("skill-repos")
      home = Fountain.TmpDir.mkdir!("skill-home")
      root = Path.join(home, ".claude/skills")
      Process.put(:skills_lib_root, root)
      test = self()

      stub(Sandbox, :exec, fn _h, "bash", args, opts ->
        send(test, {:exec, args})
        SkillRepo.exec(args, opts)
      end)

      stub(Sandbox, :write_file, fn _h, path, content ->
        File.mkdir_p!(Path.dirname(path))
        File.write(path, content)
      end)

      SkillRepo.create!(base, "obra/superpowers", %{
        "README.md" => "readme",
        "skills/brainstorming/SKILL.md" => SkillRepo.skill_md("brainstorming"),
        "skills/brainstorming/helper.sh" => "echo hi",
        "skills/brainstorming/metadata.json" => "{}",
        "skills/brainstorming/__pycache__/x.pyc" => "x",
        "skills/writing-plans/SKILL.md" => SkillRepo.skill_md("writing-plans")
      })

      SkillRepo.create!(base, "anthropics/skills", %{
        "skills/internal-comms/SKILL.md" => SkillRepo.skill_md("internal-comms"),
        "skills/pdf/SKILL.md" => SkillRepo.skill_md("pdf"),
        "skills/Fancy Dir/SKILL.md" => SkillRepo.skill_md("Fancy Name_2")
      })

      %{base: base, home: home, root: root, env: SkillRepo.env(base)}
    end

    defp listing(root), do: root |> File.ls!() |> Enum.sort()

    test "an unnamed source installs every skill in the repository", ctx do
      assert :ok =
               Skills.install(@handle, [%{"source" => "obra/superpowers"}],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      assert listing(ctx.root) == ["brainstorming", "writing-plans"]
      assert File.read!(Path.join(ctx.root, "brainstorming/helper.sh")) == "echo hi"
      # Left out, as skills.sh left them out.
      refute File.exists?(Path.join(ctx.root, "brainstorming/metadata.json"))
      refute File.exists?(Path.join(ctx.root, "brainstorming/__pycache__"))
      # And nothing staged is left behind.
      assert File.ls!(Path.dirname(ctx.root)) == ["skills"]
    end

    test "a name selects one skill, ignoring case; every skill lands under its kebab-case name",
         ctx do
      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"source" => "anthropics/skills", "name" => "internal-comms"},
                   %{"source" => "anthropics/skills", "name" => "INTERNAL-COMMS"},
                   %{"source" => "anthropics/skills"}
                 ],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      assert listing(ctx.root) == ["fancy-name_2", "internal-comms", "pdf"]
    end

    test "each repository is fetched once, however many entries name it", ctx do
      assert :ok =
               Skills.install(
                 @handle,
                 [
                   %{"source" => "anthropics/skills", "name" => "internal-comms"},
                   %{"source" => "anthropics/skills", "name" => "pdf"},
                   %{"source" => "obra/superpowers"}
                 ],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      fetches =
        Stream.repeatedly(fn ->
          receive do
            {:exec, ["-c", script]} -> script
          after
            0 -> nil
          end
        end)
        |> Enum.take_while(& &1)
        |> Enum.filter(&String.contains?(&1, "git init"))

      assert length(fetches) == 2
      assert listing(ctx.root) == ["brainstorming", "internal-comms", "pdf", "writing-plans"]
    end

    test "a ref pins the fetch to a tag or a commit", ctx do
      old =
        SkillRepo.commit!(ctx.base, "obra/superpowers", %{
          "skills/v1/SKILL.md" => SkillRepo.skill_md("v1")
        })

      SkillRepo.tag!(ctx.base, "obra/superpowers", "v1.0.0")

      SkillRepo.commit!(ctx.base, "obra/superpowers", %{
        "skills/v2/SKILL.md" => SkillRepo.skill_md("v2")
      })

      assert :ok =
               Skills.install(@handle, [%{"source" => "obra/superpowers", "ref" => "v1.0.0"}],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      assert listing(ctx.root) == ["v1"]
      File.rm_rf!(ctx.root)

      assert :ok =
               Skills.install(@handle, [%{"source" => "obra/superpowers", "ref" => old}],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      assert listing(ctx.root) == ["v1"]
      File.rm_rf!(ctx.root)

      assert :ok =
               Skills.install(@handle, [%{"source" => "obra/superpowers", "ref" => "main"}],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      assert listing(ctx.root) == ["v2"]
    end

    test "a reinstall replaces the directory rather than merging into it", ctx do
      File.mkdir_p!(Path.join(ctx.root, "brainstorming"))
      File.write!(Path.join(ctx.root, "brainstorming/stale.md"), "old")

      assert :ok =
               Skills.install(@handle, [%{"source" => "obra/superpowers"}],
                 runtime: DiskRuntime,
                 config_home: "/unused",
                 env: ctx.env
               )

      refute File.exists?(Path.join(ctx.root, "brainstorming/stale.md"))
      assert File.exists?(Path.join(ctx.root, "brainstorming/SKILL.md"))
    end

    test "stage_github/4 says why an entry has nothing to install", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          assert [
                   {_, {:error, {:skill_not_found, "absent"}}},
                   {_, {:error, {:fetch_failed, 128, _}}},
                   {_, {:error, {:invalid_ref, "-x"}}}
                 ] =
                   Skills.stage_github(
                     @handle,
                     ctx.root,
                     [
                       %{"source" => "obra/superpowers", "name" => "absent"},
                       %{"source" => "nobody/nothing"},
                       %{"source" => "obra/superpowers", "ref" => "-x"}
                     ],
                     ctx.env
                   )
        end)

      assert log =~ "skill_not_found"
      refute File.exists?(ctx.root)
    end

    test "a token in the proxy URL is not logged when a fetch fails", ctx do
      stub(Sandbox, :exec, fn _h, "bash", _args, _opts ->
        {:ok, "fatal: unable to access via http://tok-secret:c-x@broker:8443", 128}
      end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Skills.stage_github(@handle, ctx.root, [%{"source" => "owner/repo"}], [
            {"HTTPS_PROXY", "http://tok-secret:c-x@broker:8443"}
          ])
        end)

      refute log =~ "tok-secret"
      assert log =~ "[REDACTED]"
    end
  end

  describe "shell safety" do
    test "a shell-unsafe source, ref or name raises before any exec" do
      reject(&Sandbox.exec/4)

      for entry <- [
            %{"source" => "owner/repo$(whoami)"},
            %{"source" => "owner/repo", "ref" => "main; rm -rf /"},
            %{"source" => "owner/repo", "name" => "x`id`"},
            %{"source" => "owner/repo", "ref" => "a@b"}
          ] do
        assert_raise ArgumentError, fn ->
          Skills.stage_github(@handle, "/home/sprite/.claude/skills", [entry], [])
        end
      end
    end

    test "a source that climbs out of the repository is refused" do
      reject(&Sandbox.exec/4)

      ExUnit.CaptureLog.capture_log(fn ->
        assert [{_, {:error, {:invalid_source, _}}}, {_, {:error, {:invalid_source, _}}}] =
                 Skills.stage_github(
                   @handle,
                   "/home/sprite/.claude/skills",
                   [%{"source" => "owner/repo/../../x"}, %{"source" => "-owner/repo"}],
                   []
                 )
      end)
    end

    test "names and staged paths reach the copy script single-quoted" do
      script =
        Skills.place_script("/home/sprite/.claude/skills", [
          {"ok-name", "/stage/it's here"}
        ])

      assert script =~ ~S(place 'ok-name' '/stage/it'\''s here')
    end
  end
end
