defmodule Managoat.Runtimes.LayoutTest do
  @moduledoc """
  The layout table, and the agreement it exists to enforce.

  The interesting tests here are the last ones: they walk every runtime and
  check that the directory the process is pointed at and the directory its
  files are written under are the same one. That disagreement is what
  shipped once — gemini (and the since-removed opencode) ran with
  `HOME=/tmp` while their system prompts were written to `/home/sprite`, so
  both ran on the CLI's default persona and nothing said so.
  """
  use ExUnit.Case, async: true

  alias Managoat.Runtimes
  alias Managoat.Runtimes.Instructions
  alias Managoat.Runtimes.Layout

  @id "0b7e5c1e-3f39-4a8e-9a8f-2d1a6f0c9e11"
  @home "/home/sprite/.managoat/c/#{@id}"

  test "every runtime in the dispatcher has a layout row, and vice versa" do
    assert Layout.runtimes() == ["claude", "codex", "gemini"]

    for runtime <- Layout.runtimes() do
      assert {:ok, _mod} = Runtimes.for_runtime(runtime)
    end
  end

  test "a conversation's config home is its own directory, whatever its runtime" do
    assert Layout.config_home(@id) == @home
    assert Layout.conversation_home?(@home)
  end

  test "only a direct child of the config homes directory is a conversation's home" do
    refute Layout.conversation_home?("/home/sprite/.managoat/c")
    refute Layout.conversation_home?("/home/sprite/.managoat/c/")
    refute Layout.conversation_home?("/home/sprite/.managoat/c/a/b")
    refute Layout.conversation_home?("/home/sprite/.managoat/c/../c")
    refute Layout.conversation_home?("/home/sprite/.managoat/c/..")
    refute Layout.conversation_home?("/home/sprite/.claude")
    refute Layout.conversation_home?("/tmp")
    refute Layout.conversation_home?(nil)
  end

  test "paths are derived from the config home and the runtime's config dir" do
    assert Layout.config_dir("claude", @home) == @home
    assert Layout.skills_root("claude", @home) == "#{@home}/skills"
    assert Layout.instructions_path("claude", @home) == "#{@home}/CLAUDE.md"

    assert Layout.config_dir("codex", @home) == @home
    assert Layout.skills_root("codex", @home) == "#{@home}/skills"
    assert Layout.instructions_path("codex", @home) == "#{@home}/AGENTS.md"

    # GEMINI_CLI_HOME names gemini's home, under which it keeps `.gemini/`.
    assert Layout.config_dir("gemini", @home) == "#{@home}/.gemini"
    assert Layout.skills_root("gemini", @home) == "#{@home}/.gemini/skills"
    assert Layout.instructions_path("gemini", @home) == "#{@home}/.gemini/GEMINI.md"
  end

  test "a legacy home gives exactly the paths a runtime used before config homes" do
    for {runtime, skills, instructions} <- [
          {"claude", "/home/sprite/.claude/skills", "/home/sprite/.claude/CLAUDE.md"},
          {"codex", "/home/sprite/.codex/skills", "/home/sprite/.codex/AGENTS.md"},
          {"gemini", "/tmp/.gemini/skills", "/tmp/.gemini/GEMINI.md"}
        ] do
      home = Layout.legacy_home(runtime)
      assert Layout.skills_root(runtime, home) == skills
      assert Layout.instructions_path(runtime, home) == instructions
    end
  end

  test "each runtime is pointed at its home by its own variable" do
    assert Layout.config_env("claude", @home) == [{"CLAUDE_CONFIG_DIR", @home}]
    assert Layout.config_env("codex", @home) == [{"CODEX_HOME", @home}]
    assert Layout.config_env("gemini", @home) == [{"GEMINI_CLI_HOME", @home}]
  end

  test "an unknown runtime has no layout rather than a plausible-looking one" do
    assert Layout.legacy_home("nope") == nil
    assert Layout.cwd("nope") == nil
    assert Layout.config_dir("nope", @home) == nil
    assert Layout.skills_root("nope", @home) == nil
    assert Layout.instructions_path("nope", @home) == nil
    assert Layout.config_env("nope", @home) == []
  end

  test "the workspace an agent runs in by default is the one its layout names" do
    assert Layout.cwd("claude") == "/home/sprite"
    assert Layout.cwd("codex") == "/home/sprite"
    assert Layout.cwd("gemini") == "/tmp/gemini-workspace"

    # ACP hands this to the agent in `session/new`; it must not have drifted
    # back into a second copy.
    for runtime <- Layout.runtimes() do
      assert Managoat.Runtimes.ACP.cwd(runtime) == Layout.cwd(runtime)
    end
  end

  describe "the directory a runtime is pointed at and the one its files go under" do
    test "agree, for every runtime" do
      for runtime <- Layout.runtimes() do
        {:ok, mod} = Runtimes.for_runtime(runtime)

        assert mod.config_env(@home) == Layout.config_env(runtime, @home)

        # No runtime moves HOME any more: the variable does the moving, so a
        # HOME export would only disagree with it.
        refute List.keymember?(mod.default_env(nil, %{}), "HOME", 0),
               "#{runtime} still exports HOME"
      end
    end

    test "so every provisioned path sits under the conversation's config home" do
      for runtime <- Layout.runtimes() do
        {:ok, mod} = Runtimes.for_runtime(runtime)

        for {what, path} <- [
              skills_root: mod.skills_root(@home),
              instructions: Instructions.path(runtime, @home)
            ] do
          assert String.starts_with?(path, @home <> "/"),
                 "#{runtime}'s #{what} is #{path}, which is not under #{@home}"
        end
      end
    end
  end

  test "runtime modules answer from the table rather than their own copy" do
    for runtime <- Layout.runtimes() do
      {:ok, mod} = Runtimes.for_runtime(runtime)
      assert mod.skills_root(@home) == Layout.skills_root(runtime, @home)
    end
  end
end
