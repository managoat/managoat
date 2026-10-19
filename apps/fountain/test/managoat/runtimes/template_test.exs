defmodule Managoat.Runtimes.TemplateTest do
  @moduledoc """
  The runtime template (#2998): what a setup script writes under
  `MANAGOAT_RUNTIME_TEMPLATE` is copied into a conversation's config home
  once, when the home is made, with Managoat's own files winning and the JSON
  files it writes keys into merged.

  The sandbox here is the test's own disk: every exec runs the real script
  with bash, and every file write lands under a temporary directory laid out
  like a sprite's `~/.managoat`.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.{Claude, Gemini, Template}
  alias Managoat.Sandbox

  setup :set_mimic_from_context

  setup do
    root = Fountain.TmpDir.mkdir!("runtime_template")
    managoat = Path.join(root, ".managoat")
    template = Path.join(managoat, "template")
    home = Path.join([managoat, "c", "7f3c2b9e-0d4a-4f1e-8a77-5b6c1d2e3f40"])
    File.mkdir_p!(template)

    test = self()

    stub(Sandbox, :exec, fn _handle, "bash", args, _opts ->
      send(test, {:exec, args})
      {out, code} = System.cmd("bash", args, stderr_to_stdout: false)
      {:ok, out, code}
    end)

    stub(Sandbox, :write_file, fn _handle, path, body, opts ->
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, body)
      if mode = opts[:mode], do: File.chmod!(path, mode)
      :ok
    end)

    %{
      root: root,
      managoat: managoat,
      template: template,
      home: home,
      handle: %Sandbox.Handle{provider: :fake, name: "sb"}
    }
  end

  defp put(path, body) do
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, body)
    path
  end

  defp json(path), do: path |> File.read!() |> Jason.decode!()

  defp seed(ctx, runtime, mode, opts \\ []) do
    Template.seed(ctx.handle, runtime, ctx.home, mode,
      template_root: ctx.template,
      skills: Keyword.get(opts, :skills, [])
    )
  end

  # Stages left behind; a commit's `.ok` marker stays, for a retry to read,
  # until the hourly sweep.
  defp stages(ctx) do
    ctx.managoat
    |> Path.join(".template-stage.*")
    |> Path.wildcard(match_dot: true)
    |> Enum.reject(&String.ends_with?(&1, ".ok"))
  end

  describe "a new config home (an attach to a machine that is already up)" do
    test "gets the runtime's template, with modes kept", ctx do
      t = Path.join(ctx.template, "claude")
      put(Path.join(t, "settings.json"), ~s({"hooks": {"Stop": []}, "env": {"A": "1"}}))
      hook = put(Path.join(t, "hooks/format.sh"), "#!/bin/sh\nexit 0\n")
      File.chmod!(hook, 0o755)
      put(Path.join(t, "CLAUDE.md"), "be brief\n")
      put(Path.join(t, "skills/mine/SKILL.md"), "---\nname: mine\n---\n")
      File.mkdir_p!(Path.join(t, "empty"))

      assert :ok = seed(ctx, "claude", :new)

      assert json(Path.join(ctx.home, "settings.json")) == %{
               "hooks" => %{"Stop" => []},
               "env" => %{"A" => "1"}
             }

      assert File.read!(Path.join(ctx.home, "CLAUDE.md")) == "be brief\n"
      assert File.read!(Path.join(ctx.home, "skills/mine/SKILL.md")) =~ "name: mine"
      assert File.stat!(Path.join(ctx.home, "hooks/format.sh")).mode |> Bitwise.band(0o111) != 0
      assert File.dir?(Path.join(ctx.home, "empty"))
      assert stages(ctx) == []
    end

    test "a home that is already there is left alone: a wake copies nothing", ctx do
      put(Path.join(ctx.template, "claude/CLAUDE.md"), "new\n")
      put(Path.join(ctx.home, "CLAUDE.md"), "old\n")

      assert :ok = seed(ctx, "claude", :new)
      assert File.read!(Path.join(ctx.home, "CLAUDE.md")) == "old\n"
      assert File.ls!(ctx.home) == ["CLAUDE.md"]
    end

    test "no template, or an empty one, makes no home", ctx do
      assert :ok = seed(ctx, "codex", :new)
      File.mkdir_p!(Path.join(ctx.template, "codex"))
      assert :ok = seed(ctx, "codex", :new)
      refute File.exists?(ctx.home)
    end

    test "symlinks are neither followed nor copied, nor is anything that is not a file", ctx do
      outside = put(Path.join(ctx.root, "outside/secret"), "s3cret")
      t = Path.join(ctx.template, "claude")
      put(Path.join(t, "settings.json"), "{}")
      File.ln_s!(outside, Path.join(t, "leak"))
      File.ln_s!(Path.dirname(outside), Path.join(t, "leakdir"))
      File.mkdir_p!(Path.join(t, "skills"))
      File.ln_s!(Path.dirname(outside), Path.join(t, "skills/linked"))
      {_, 0} = System.cmd("mkfifo", [Path.join(t, "fifo")])

      assert :ok = seed(ctx, "claude", :new)

      assert File.exists?(Path.join(ctx.home, "settings.json"))

      for name <- ["leak", "leakdir", "skills/linked", "fifo"] do
        refute File.exists?(Path.join(ctx.home, name)), name
        assert {:error, :enoent} = File.lstat(Path.join(ctx.home, name))
      end
    end

    test "a template, or a runtime's directory in it, that is a symlink is not used", ctx do
      elsewhere = Path.join(ctx.root, "elsewhere")
      put(Path.join(elsewhere, "claude/CLAUDE.md"), "via a link\n")

      File.ln_s!(Path.join(elsewhere, "claude"), Path.join(ctx.template, "claude"))
      assert :ok = seed(ctx, "claude", :new)
      refute File.exists?(ctx.home)

      File.rm_rf!(ctx.template)
      File.ln_s!(elsewhere, ctx.template)
      assert :ok = seed(ctx, "claude", :new)
      refute File.exists?(ctx.home)
    end

    test "the skills Managoat writes replace the template's whole, and its bookkeeping is never taken",
         ctx do
      t = Path.join(ctx.template, "claude")
      put(Path.join(t, "skills/managoat/extra.md"), "stale")
      put(Path.join(t, "skills/mine/SKILL.md"), "mine")
      put(Path.join(t, "skills/.fountain-managed-skills"), ~s({"x": ["mine"]}))
      put(Path.join(t, ".managoat-skill-fetch-1/x"), "x")
      put(Path.join(t, ".claude.json.managoat.9.tmp"), "{}")

      assert :ok = seed(ctx, "claude", :new, skills: ["managoat", "../escape"])

      refute File.exists?(Path.join(ctx.home, "skills/managoat"))
      assert File.exists?(Path.join(ctx.home, "skills/mine/SKILL.md"))
      refute File.exists?(Path.join(ctx.home, "skills/.fountain-managed-skills"))
      refute File.exists?(Path.join(ctx.home, ".managoat-skill-fetch-1"))
      refute File.exists?(Path.join(ctx.home, ".claude.json.managoat.9.tmp"))
    end

    test "a merged file that is not a JSON object fails the seed and makes no home", ctx do
      put(Path.join(ctx.template, "claude/settings.json"), "{not json")
      put(Path.join(ctx.template, "claude/CLAUDE.md"), "x")

      assert {:error, {:runtime_template, {:not_a_json_object, "settings.json"}}} =
               seed(ctx, "claude", :new)

      refute File.exists?(ctx.home)
      assert stages(ctx) == []
    end

    test "gemini's template is the contents of its .gemini directory", ctx do
      put(Path.join(ctx.template, "gemini/settings.json"), ~s({"ui": {"theme": "x"}}))
      put(Path.join(ctx.template, "gemini/GEMINI.md"), "hi")

      assert :ok = seed(ctx, "gemini", :new)
      assert json(Path.join(ctx.home, ".gemini/settings.json")) == %{"ui" => %{"theme" => "x"}}
      assert File.read!(Path.join(ctx.home, ".gemini/GEMINI.md")) == "hi"
    end

    test "Managoat's writes after it keep the template's settings", ctx do
      put(
        Path.join(ctx.template, "claude/settings.json"),
        ~s({"hooks": {"PostToolUse": []}, "showThinkingSummaries": false})
      )

      put(
        Path.join(ctx.template, "claude/.claude.json"),
        ~s({"theme": "dark", "mcpServers": {"tpl": {"command": "t"}}})
      )

      assert :ok = seed(ctx, "claude", :new)

      # A template's servers never run, not even before Managoat's own write.
      assert json(Path.join(ctx.home, ".claude.json")) == %{"theme" => "dark"}
      assert Bitwise.band(File.stat!(Path.join(ctx.home, ".claude.json")).mode, 0o777) == 0o600

      servers = %{"agent" => %{"command" => "a"}}
      assert :ok = Claude.write_config(ctx.handle, %{mcp_servers: servers}, ctx.home)

      assert json(Path.join(ctx.home, "settings.json")) == %{
               "hooks" => %{"PostToolUse" => []},
               "showThinkingSummaries" => true
             }

      # mcpServers is the agent's, whole.
      assert json(Path.join(ctx.home, ".claude.json")) == %{
               "theme" => "dark",
               "mcpServers" => servers
             }
    end
  end

  describe "into a home Managoat has written (a conversation's own provision)" do
    test "Managoat's files win and the merged files are merged", ctx do
      servers = %{"agent" => %{"command" => "a"}}
      assert :ok = Claude.write_config(ctx.handle, %{mcp_servers: servers}, ctx.home)
      put(Path.join(ctx.home, "CLAUDE.md"), "the agent's prompt")
      put(Path.join(ctx.home, "skills/managoat/SKILL.md"), "managoat")

      t = Path.join(ctx.template, "claude")

      put(
        Path.join(t, "settings.json"),
        ~s({"hooks": {"Stop": []}, "showThinkingSummaries": false})
      )

      put(Path.join(t, ".claude.json"), ~s({"theme": "dark", "mcpServers": {"tpl": {}}}))
      put(Path.join(t, "CLAUDE.md"), "the template's")
      put(Path.join(t, "skills/managoat/extra.md"), "stale")
      put(Path.join(t, "skills/mine/SKILL.md"), "mine")
      put(Path.join(t, "hooks/stop.sh"), "#!/bin/sh\n")

      assert :ok = seed(ctx, "claude", :into)

      assert json(Path.join(ctx.home, "settings.json")) == %{
               "hooks" => %{"Stop" => []},
               "showThinkingSummaries" => true
             }

      assert json(Path.join(ctx.home, ".claude.json")) == %{
               "theme" => "dark",
               "mcpServers" => servers
             }

      assert File.read!(Path.join(ctx.home, "CLAUDE.md")) == "the agent's prompt"
      refute File.exists?(Path.join(ctx.home, "skills/managoat/extra.md"))
      assert File.read!(Path.join(ctx.home, "skills/mine/SKILL.md")) == "mine"
      assert File.exists?(Path.join(ctx.home, "hooks/stop.sh"))
      assert stages(ctx) == []

      # And a wake's write after it keeps the merge.
      assert :ok = Claude.write_config(ctx.handle, %{mcp_servers: servers}, ctx.home)
      assert %{"hooks" => _} = json(Path.join(ctx.home, "settings.json"))
    end

    test "codex: the template's config.toml lands, Managoat's auth.json stays", ctx do
      put(Path.join(ctx.home, "auth.json"), ~s({"auth_mode": "apikey"}))
      put(Path.join(ctx.template, "codex/config.toml"), "project_doc_max_bytes = 65536\n")
      put(Path.join(ctx.template, "codex/auth.json"), ~s({"from": "template"}))

      assert :ok = seed(ctx, "codex", :into)
      assert File.read!(Path.join(ctx.home, "config.toml")) =~ "project_doc_max_bytes"
      assert json(Path.join(ctx.home, "auth.json")) == %{"auth_mode" => "apikey"}
    end

    test "gemini's settings are merged under .gemini", ctx do
      assert :ok = Gemini.write_config(ctx.handle, %{mcp_servers: %{"a" => %{}}}, ctx.home)

      put(
        Path.join(ctx.template, "gemini/settings.json"),
        ~s({"ui": {"theme": "x"}, "mcpServers": {}})
      )

      assert :ok = seed(ctx, "gemini", :into)

      assert json(Path.join(ctx.home, ".gemini/settings.json")) == %{
               "ui" => %{"theme" => "x"},
               "mcpServers" => %{"a" => %{}}
             }
    end

    test "a path that is a directory on one side and a file on the other is Managoat's", ctx do
      put(Path.join(ctx.home, "hooks/managoat.sh"), "managoat's")
      put(Path.join(ctx.home, "notes"), "managoat's file")
      put(Path.join(ctx.template, "claude/hooks"), "a file where Managoat has a directory")
      put(Path.join(ctx.template, "claude/notes/x"), "a directory where Managoat has a file")

      assert :ok = seed(ctx, "claude", :into)
      assert File.read!(Path.join(ctx.home, "hooks/managoat.sh")) == "managoat's"
      assert File.read!(Path.join(ctx.home, "notes")) == "managoat's file"
    end

    test "a large template is one pass, not a process per file", ctx do
      t = Path.join(ctx.template, "codex")

      for d <- 1..20, f <- 1..100, do: put(Path.join([t, "plugins", "d#{d}", "f#{f}"]), "x")

      put(Path.join(ctx.home, "auth.json"), "{}")

      {us, :ok} = :timer.tc(fn -> seed(ctx, "codex", :into) end)
      assert File.exists?(Path.join(ctx.home, "plugins/d20/f100"))
      assert us < 10_000_000, "#{div(us, 1000)} ms for 2000 files"
    end

    test "the merged files land mode 600", ctx do
      put(Path.join(ctx.home, ".claude.json"), ~s({"mcpServers": {}}))
      File.chmod!(put(Path.join(ctx.template, "claude/.claude.json"), ~s({"theme": "x"})), 0o644)

      assert :ok = seed(ctx, "claude", :into)
      path = Path.join(ctx.home, ".claude.json")
      assert json(path) == %{"theme" => "x", "mcpServers" => %{}}
      assert Bitwise.band(File.stat!(path).mode, 0o777) == 0o600
    end

    test "nothing is written through a symlink in the home", ctx do
      outside = Path.join(ctx.root, "outside")
      File.mkdir_p!(outside)
      File.mkdir_p!(ctx.home)
      File.ln_s!(outside, Path.join(ctx.home, "hooks"))
      put(Path.join(ctx.template, "claude/hooks/stop.sh"), "x")

      assert :ok = seed(ctx, "claude", :into)
      assert File.ls!(outside) == []
    end

    test "a merged file that is not a JSON object changes nothing", ctx do
      put(Path.join(ctx.home, "settings.json"), ~s({"showThinkingSummaries": true}))
      put(Path.join(ctx.template, "claude/settings.json"), "[1]")
      put(Path.join(ctx.template, "claude/CLAUDE.md"), "x")

      assert {:error, {:runtime_template, {:not_a_json_object, "settings.json"}}} =
               seed(ctx, "claude", :into)

      assert File.ls!(ctx.home) == ["settings.json"]
      assert stages(ctx) == []
    end
  end

  test "an answer with no status is not taken for success", ctx do
    # stdout lost on the way back: the seed fails, and a later attach, finding
    # no home, tries again.
    stub(Sandbox, :exec, fn _h, "bash", _args, _opts -> {:ok, "", 0} end)
    assert {:error, {:runtime_template, :no_answer}} = seed(ctx, "claude", :new)
  end

  test "a commit run twice (a retry after a lost reply) reports the work done", ctx do
    put(Path.join(ctx.template, "claude/settings.json"), "{}")
    test = self()

    stub(Sandbox, :exec, fn _handle, "bash", args, _opts ->
      {out, code} = System.cmd("bash", args)
      if Enum.at(args, 3) == "commit", do: send(test, {:commit, args})
      {:ok, out, code}
    end)

    assert :ok = seed(ctx, "claude", :new)
    assert_received {:commit, args}

    for mode <- ["new", "into"] do
      again = List.replace_at(args, 4, mode)
      assert {out, 0} = System.cmd("bash", again)
      assert out =~ ~r/managoat-template (present|done)/
    end
  end

  test "a commit retried after it failed is not taken for done", ctx do
    stage = Path.join(ctx.managoat, ".template-stage.gone")
    argv = ["-c", Template.script(), "t", "commit", "into", "", ctx.home, "", stage, "", ""]
    assert {_out, 3} = System.cmd("bash", argv)
  end

  test "the first status line is the answer", ctx do
    # A template file's name can carry a newline; nothing after the status counts.
    stub(Sandbox, :exec, fn _h, "bash", _args, _opts ->
      {:ok, "managoat-template unreadable x?\nmanagoat-template done\n", 0}
    end)

    assert {:error, {:runtime_template, {:unreadable, "x?"}}} = seed(ctx, "claude", :new)
  end

  test "an entry the sandbox user cannot read fails the seed, naming it", ctx do
    {uid, 0} = System.cmd("id", ["-u"])

    if String.trim(uid) == "0" do
      # root reads everything; the check needs an ordinary user, as on a sprite.
      :ok
    else
      t = Path.join(ctx.template, "claude")
      put(Path.join(t, "CLAUDE.md"), "x")
      File.chmod!(put(Path.join(t, "private/key"), "k"), 0o000)

      assert {:error, {:runtime_template, {:unreadable, "private/key"}}} =
               seed(ctx, "claude", :new)

      refute File.exists?(ctx.home)
    end
  end

  test "the home is the conversation's own, mode 700, whatever the template's mode", ctx do
    t = Path.join(ctx.template, "codex")
    put(Path.join(t, "config.toml"), "x = 1\n")
    File.chmod!(t, 0o555)

    assert :ok = seed(ctx, "codex", :new)
    assert Bitwise.band(File.stat!(ctx.home).mode, 0o777) == 0o700
    File.write!(Path.join(ctx.home, "auth.json"), "{}")
  end

  test "a failed exec is the seed's error", ctx do
    stub(Sandbox, :exec, fn _h, "bash", _args, _opts -> {:ok, "", 1} end)

    assert {:error, {:runtime_template, {"stage", {:exit, 1}}}} = seed(ctx, "claude", :new)
  end

  test "a runtime with no template directory is never seeded", ctx do
    reject(&Sandbox.exec/4)
    assert :ok = Template.seed(ctx.handle, "acp", ctx.home, :new)
  end

  test "the setup's env and the directories made before it" do
    assert Template.setup_env() == [
             {"MANAGOAT_RUNTIME_TEMPLATE", "/home/sprite/.managoat/template"}
           ]

    script = Template.prepare_script()
    assert script =~ "mkdir -p -m 700 -- '/home/sprite/.managoat/template'"

    for runtime <- ["claude", "codex", "gemini"],
        do: assert(script =~ "'/home/sprite/.managoat/template/#{runtime}'")
  end
end
