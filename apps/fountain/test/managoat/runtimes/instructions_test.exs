defmodule Managoat.Runtimes.InstructionsTest do
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Instructions

  setup :verify_on_exit!

  @handle %Managoat.Sandbox.Handle{provider: :sprites, name: "fountain-test"}
  @home "/home/sprite/.managoat/c/3d1f7a52-6b0e-4c9a-9e11-0a2b3c4d5e6f"

  test "each ACP runtime has a user-level instructions file in the config home; unknown none" do
    assert Instructions.path("claude", @home) == "#{@home}/CLAUDE.md"
    assert Instructions.path("codex", @home) == "#{@home}/AGENTS.md"

    # Under gemini's own `.gemini/`, inside the home GEMINI_CLI_HOME names.
    # An earlier version of this test asserted /home/sprite for gemini while
    # it ran with HOME=/tmp — the same wrong answer the code gave, so it
    # pinned the bug instead of catching it. `Managoat.Runtimes.LayoutTest`
    # checks the agreement rather than the literal.
    assert Instructions.path("gemini", @home) == "#{@home}/.gemini/GEMINI.md"

    assert Instructions.path("nope", @home) == nil
    assert Instructions.path(nil, @home) == nil
  end

  test "writes the prompt verbatim, with a provenance header, to the runtime's file" do
    path = "#{@home}/CLAUDE.md"

    expect(Managoat.Sandbox.Sprites, :write_file, fn @handle, ^path, body, _opts ->
      assert body =~ ~s(agent "team-lead")
      assert body =~ "You are team-lead, Jake's single point of contact."
      assert String.ends_with?(body, "contact.\n")
      :ok
    end)

    assert :ok =
             Instructions.write(
               @handle,
               "claude",
               %{
                 name: "team-lead",
                 system: "You are team-lead, Jake's single point of contact.\n\n"
               },
               @home
             )
  end

  test "a blank or missing prompt writes nothing" do
    reject(&Managoat.Sandbox.Sprites.write_file/4)
    assert :ok = Instructions.write(@handle, "claude", %{name: "x", system: "   \n"}, @home)
    assert :ok = Instructions.write(@handle, "claude", %{name: "x", system: nil}, @home)
    assert :ok = Instructions.write(@handle, "claude", nil, @home)
    assert :ok = Instructions.write(@handle, "unknown-runtime", %{name: "x", system: "hi"}, @home)
  end

  test "a refused write is reported, not raised" do
    expect(Managoat.Sandbox.Sprites, :write_file, fn _h, _p, _b, _o -> {:error, :boom} end)

    assert {:error, :boom} =
             Instructions.write(@handle, "codex", %{name: "x", system: "hi"}, @home)
  end
end
