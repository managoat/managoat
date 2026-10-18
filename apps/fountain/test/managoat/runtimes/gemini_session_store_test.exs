defmodule Managoat.Runtimes.Gemini.SessionStoreTest do
  @moduledoc """
  The Elixir half of the #659 workaround: that the script is installed where the
  turn-end call looks for it, and that a failing sandbox never costs a turn.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Managoat.Runtimes.Gemini.SessionStore

  setup :verify_on_exit!

  defp handle, do: %Managoat.Sandbox.Handle{provider: :sprites, name: "test-sprite", private: %{}}

  describe "install/1" do
    test "writes the real script to the path consolidate/3 runs" do
      test = self()

      Mimic.expect(Managoat.Sandbox, :write_file, fn _h, path, body ->
        send(test, {:wrote, path, body})
        :ok
      end)

      assert :ok = SessionStore.install(handle())
      assert_receive {:wrote, path, body}
      assert path == SessionStore.script_path()

      # The bundled script, not a placeholder — the module reads priv/ at
      # compile time, so a rename there fails here rather than in a sprite.
      assert body =~ "gemini-cli#28775"
      assert body =~ "PARKED_STAMP"
    end
  end

  describe "consolidate/3" do
    test "runs the script for the session, with HOME at the conversation's gemini home" do
      test = self()

      Mimic.expect(Managoat.Sandbox, :exec, fn _h, cmd, args, opts ->
        send(test, {:exec, cmd, args, opts[:env]})
        {:ok, ~s({"kept":1,"removed":1}), 0}
      end)

      assert :ok = SessionStore.consolidate(handle(), "sess-abc", "/home/sprite/.managoat/c/x")
      assert_receive {:exec, "node", [script, "sess-abc"], env}
      assert script == SessionStore.script_path()

      # Must be the GEMINI_CLI_HOME gemini ran under, or the script resolves a different
      # chats directory than the one gemini actually wrote to.
      assert {"HOME", "/home/sprite/.managoat/c/x"} in env
    end

    test "does nothing without a session id" do
      Mimic.reject(&Managoat.Sandbox.exec/4)
      assert :ok = SessionStore.consolidate(handle(), nil, "/tmp")
      assert :ok = SessionStore.consolidate(handle(), "", "/tmp")
    end

    test "a non-zero exit does not fail the turn that just succeeded" do
      Mimic.expect(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "boom", 1} end)
      assert :ok = SessionStore.consolidate(handle(), "sess-abc", "/home/sprite/.managoat/c/x")
    end

    test "an unreachable sandbox does not fail the turn either" do
      # Losing the consolidation costs the *next* turn its history, which is
      # bad; failing this turn on top of that would be worse.
      Mimic.expect(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)
      assert :ok = SessionStore.consolidate(handle(), "sess-abc", "/home/sprite/.managoat/c/x")
    end
  end
end
