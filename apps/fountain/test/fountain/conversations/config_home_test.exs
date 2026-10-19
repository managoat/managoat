defmodule Fountain.Conversations.ConfigHomeTest do
  @moduledoc """
  A conversation's config home and working directory (ADR 0097 step 1): the
  launch rule for `cwd`, the legacy fallback for a conversation from before
  config homes, and the removal that never reaches a shared directory.
  """
  use ExUnit.Case, async: true
  use Mimic

  alias Fountain.Conversations.ConfigHome
  alias Managoat.Sandbox.Handle

  setup :verify_on_exit!

  @id "6f1e2d3c-4b5a-4968-8776-5a4b3c2d1e0f"
  @home "/home/sprite/.managoat/c/#{@id}"
  @handle %Handle{provider: :sprites, name: "config-home-test"}

  defp conv(attrs),
    do: Map.merge(%{id: @id, runtime: "claude", config_home: nil, cwd: nil}, attrs)

  describe "home/1" do
    test "is the row's own home when it has one, whatever the runtime" do
      for runtime <- ~w(claude codex gemini acp) do
        assert ConfigHome.home(conv(%{runtime: runtime, config_home: @home})) == @home
      end

      assert ConfigHome.for_launch(@id) == @home
    end

    test "is the runtime's shared pre-ADR directory for a row from before config homes" do
      assert ConfigHome.home(conv(%{runtime: "claude"})) == "/home/sprite/.claude"
      assert ConfigHome.home(conv(%{runtime: "codex"})) == "/home/sprite/.codex"
      # gemini's was its HOME, /tmp, under which it kept `.gemini/`.
      assert ConfigHome.home(conv(%{runtime: "gemini"})) == "/tmp"
      # The acp runtime borrowed claude's tree.
      assert ConfigHome.home(conv(%{runtime: "acp"})) == "/home/sprite/.claude"
    end
  end

  describe "cwd/1" do
    test "is the launch's, else the runtime's default" do
      assert ConfigHome.cwd(conv(%{cwd: "/home/sprite/app"})) == "/home/sprite/app"
      assert ConfigHome.cwd(conv(%{runtime: "claude"})) == "/home/sprite"
      assert ConfigHome.cwd(conv(%{runtime: "codex"})) == "/home/sprite"
      assert ConfigHome.cwd(conv(%{runtime: "gemini"})) == "/tmp/gemini-workspace"
      assert ConfigHome.cwd(conv(%{runtime: "acp"})) == "/home/sprite"
    end
  end

  describe "validate_cwd/2" do
    test "nothing asked for is nil: the runtime's default stands" do
      assert {:ok, nil} = ConfigHome.validate_cwd(nil, "claude")
      assert {:ok, nil} = ConfigHome.validate_cwd("", "claude")
    end

    test "an absolute path under /home/sprite is accepted, normalised" do
      assert {:ok, "/home/sprite"} = ConfigHome.validate_cwd("/home/sprite", "claude")
      assert {:ok, "/home/sprite/app"} = ConfigHome.validate_cwd("/home/sprite/app/", "codex")
      assert {:ok, "/home/sprite/b"} = ConfigHome.validate_cwd("/home/sprite/a/../b", "acp")
      assert {:ok, "/home/sprite/a b"} = ConfigHome.validate_cwd("/home/sprite/a b", "claude")
    end

    test "gemini may also run under /tmp, where its default is; the others may not" do
      assert {:ok, "/tmp/work"} = ConfigHome.validate_cwd("/tmp/work", "gemini")
      assert {:ok, "/home/sprite/x"} = ConfigHome.validate_cwd("/home/sprite/x", "gemini")
      assert {:error, cs} = ConfigHome.validate_cwd("/tmp/work", "claude")
      assert message(cs) =~ "/home/sprite"
    end

    test "anything else is a changeset error on :cwd" do
      for {cwd, why} <- [
            {"relative/dir", "absolute"},
            {"/etc", "/home/sprite"},
            {"/home/spriteish", "/home/sprite"},
            {"/home/sprite/../../etc", "/home/sprite"},
            {"/home/sprite/.managoat", "inside"},
            {"/home/sprite/.managoat/c/#{@id}", "inside"},
            {"/home/sprite/a\nb", "control"},
            {"/home/sprite/" <> String.duplicate("a", 1100), "bytes"},
            {123, "string"}
          ] do
        assert {:error, %Ecto.Changeset{} = cs} = ConfigHome.validate_cwd(cwd, "claude")
        assert [cwd: {_message, _}] = cs.errors, inspect(cwd)
        assert message(cs) =~ why, inspect(cwd)
      end
    end
  end

  # #2999: an environment's repository mounts widen the rule, as far as
  # `eligible_mounts/1` lets them.
  describe "eligible_mounts/1" do
    test "keeps a normalised mount outside the home, and one under it" do
      assert ConfigHome.eligible_mounts(["/work/app", "/work/app/", "/srv/./x/../y"]) ==
               ["/work/app", "/srv/y"]

      assert ConfigHome.eligible_mounts(["/home/sprite/app", "/tmp/repo"]) ==
               ["/home/sprite/app", "/tmp/repo"]
    end

    test "drops the root, the home and its ancestors, the config homes, and system trees" do
      for mount <- [
            "/",
            "/home",
            "/home/sprite",
            "/home/sprite/",
            "/home/sprite/.managoat",
            "/home/sprite/.managoat/c/x",
            "/home/sprite/app/../.managoat",
            "/etc",
            "/etc/app",
            "/proc/self",
            "/sys",
            "/dev/shm",
            "/usr/local/app",
            "/var/www",
            "/root/app",
            "/run/x",
            "/work/../etc",
            "/home/sprite/../../etc",
            "relative/app",
            "/work/a\nb",
            "/" <> String.duplicate("a", 1100)
          ] do
        assert ConfigHome.eligible_mounts([mount]) == [], inspect(mount)
      end

      assert ConfigHome.eligible_mounts(nil) == []
      assert ConfigHome.eligible_mounts([nil, 42, "/work/app"]) == ["/work/app"]
    end

    test "a prefix of a system tree's name is not that tree" do
      assert ConfigHome.eligible_mounts(["/etcetera", "/variant", "/home/spriteish"]) ==
               ["/etcetera", "/variant", "/home/spriteish"]
    end
  end

  describe "validate_cwd/3 with repository mounts" do
    test "a cwd at or under an eligible mount is accepted, normalised" do
      mounts = ["/work/app"]
      assert {:ok, "/work/app"} = ConfigHome.validate_cwd("/work/app/", "claude", mounts)

      assert {:ok, "/work/app/api"} =
               ConfigHome.validate_cwd("/work/app/x/../api", "codex", mounts)

      assert {:ok, "/home/sprite/x"} = ConfigHome.validate_cwd("/home/sprite/x", "codex", mounts)
    end

    test "a sibling, a parent, an escape by `..` and an ineligible mount are refused" do
      mounts = ["/work/app", "/etc", "/", "/home/sprite/.managoat"]

      for cwd <- [
            "/work",
            "/work/application",
            "/work/app/../other",
            "/etc",
            "/etc/x",
            "/usr",
            "/home/sprite/.managoat/c/x"
          ] do
        assert {:error, cs} = ConfigHome.validate_cwd(cwd, "claude", mounts), cwd
        assert [cwd: _] = cs.errors
      end
    end

    test "the refusal names the mounts that would have been accepted" do
      assert {:error, cs} = ConfigHome.validate_cwd("/srv", "claude", ["/work/app"])
      assert message(cs) =~ "/home/sprite or /work/app"
    end
  end

  describe "check_resume/2" do
    test "the directory a conversation runs in under a mount resumes, whatever the environment says now" do
      conv = conv(%{cwd: "/work/app"})
      assert :ok = ConfigHome.check_resume(conv, "/work/app/")
      assert {:error, cs} = ConfigHome.check_resume(conv, "/work/other")
      assert [cwd: _] = cs.errors
      assert {:error, _} = ConfigHome.check_resume(conv, "relative")
      assert {:error, _} = ConfigHome.check_resume(conv, 42)
    end

    test "nothing named, or the directory the conversation runs in, resumes" do
      assert :ok = ConfigHome.check_resume(conv(%{}), nil)
      assert :ok = ConfigHome.check_resume(conv(%{}), "/home/sprite")
      assert :ok = ConfigHome.check_resume(conv(%{cwd: "/home/sprite/app"}), "/home/sprite/app/")
    end

    test "another directory is refused: it is fixed for the conversation's life" do
      assert {:error, cs} =
               ConfigHome.check_resume(conv(%{cwd: "/home/sprite/app"}), "/home/sprite")

      assert message(cs) =~ "fixed"
      assert {:error, _} = ConfigHome.check_resume(conv(%{}), "/etc")
    end
  end

  describe "ensure/2" do
    test "creates the launch's cwd and the config home in one exec" do
      expect(Managoat.Sandbox, :exec, fn @handle, "bash", ["-c", script], _opts ->
        assert script == "mkdir -p -- '#{@home}' '/home/sprite/it'\\''s'"
        {:ok, "", 0}
      end)

      assert :ok =
               ConfigHome.ensure(@handle, conv(%{config_home: @home, cwd: "/home/sprite/it's"}))
    end

    test "costs nothing for the runtime's default cwd" do
      reject(&Managoat.Sandbox.exec/4)
      assert :ok = ConfigHome.ensure(@handle, conv(%{config_home: @home}))
    end
  end

  describe "remove/2" do
    test "removes a conversation's own home" do
      expect(Managoat.Sandbox, :exec, fn @handle, "bash", ["-c", script], _opts ->
        assert script == "rm -rf -- '#{@home}'"
        {:ok, "", 0}
      end)

      assert :ok = ConfigHome.remove(@handle, conv(%{config_home: @home}))
    end

    test "never removes a legacy home, which is shared" do
      reject(&Managoat.Sandbox.exec/4)

      for runtime <- ~w(claude codex gemini acp) do
        assert :ok = ConfigHome.remove(@handle, conv(%{runtime: runtime}))
      end

      # Nor a path that only looks like one.
      assert :ok = ConfigHome.remove(@handle, conv(%{config_home: "/home/sprite/.managoat/c"}))

      assert :ok =
               ConfigHome.remove(@handle, conv(%{config_home: "/home/sprite/.managoat/c/../.."}))
    end

    test "is best effort: a failure is :ok, and no handle is nothing to do" do
      expect(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:error, :unavailable} end)
      assert :ok = ConfigHome.remove(@handle, conv(%{config_home: @home}))
      assert :ok = ConfigHome.remove(nil, conv(%{config_home: @home}))
    end
  end

  defp message(%Ecto.Changeset{errors: [cwd: {message, _}]}), do: message
end
