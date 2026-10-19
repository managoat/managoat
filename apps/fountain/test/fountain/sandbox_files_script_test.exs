defmodule Fountain.SandboxFilesScriptTest do
  @moduledoc """
  The scripts behind `Fountain.SandboxFiles`, run by a real bash against a
  real repository.

  The rest of the suite mocks `Managoat.Sandbox.exec/4`, which proves what
  parses the output and nothing at all about what produces it. Every defect
  #1596 found lived in the shell: a pipeline's exit status, an unconfined
  `git rev-parse --show-toplevel`, and a header framed with the one byte a
  path may contain.
  """
  use ExUnit.Case, async: true

  alias Fountain.SandboxFiles
  alias Fountain.TmpDir

  # The byte cap `status/3` passes: one past `@max_status_bytes`.
  @cap "1048577"

  # `exec/4` leaves `stderr_to_stdout: false` on every adapter, so a script's
  # stderr goes nowhere. Dropping it here keeps the test reading what a
  # caller reads — and keeps a deliberate `fatal:` out of the suite's output.
  defp run(kind, args, env \\ [], logical_roots \\ nil) do
    {flags, roots} = Enum.split(args, %{list: 1, read: 2, status: 3, diff: 4}[kind])
    pairs = Enum.zip_with(roots, logical_roots || roots, &[&1, "sandbox:" <> &2])
    args = flags ++ List.flatten(pairs)

    System.cmd(
      "bash",
      ["-c", "exec 2>/dev/null\n" <> SandboxFiles.script(kind), "fountain-files" | args],
      env: git_env() ++ env
    )
  end

  # A repository that is this test's alone: no global config, no templates,
  # no hooks the developer happens to have installed.
  defp git_env do
    [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]
  end

  defp git!(dir, args) do
    {out, code} = System.cmd("git", args, cd: dir, env: git_env(), stderr_to_stdout: true)
    assert code == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end

  # A repository with one commit, one tracked edit and one untracked file.
  defp repo!(dir) do
    File.mkdir_p!(dir)
    git!(dir, ["init", "-q"])
    git!(dir, ["checkout", "-q", "-b", "main"])
    File.write!(Path.join(dir, "a.txt"), "one\n")
    git!(dir, ["add", "a.txt"])
    git!(dir, ["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "init"])
    File.write!(Path.join(dir, "a.txt"), "two\n")
    File.write!(Path.join(dir, "new.txt"), "fresh\n")
    dir
  end

  describe "file paths are physically confined" do
    setup do
      dir = TmpDir.mkdir!("sandbox-files-paths")
      root = Path.join(dir, "home")
      outside = Path.join(dir, "home-outside")
      File.mkdir_p!(Path.join(root, "nested"))
      File.mkdir_p!(outside)
      File.write!(Path.join(root, "nested/inside.txt"), "inside")
      File.write!(Path.join(outside, "secret.txt"), "outside")
      %{root: root, outside: outside}
    end

    test "directory symlinks cannot list or read outside a root", c do
      link = Path.join(c.root, "escape")
      File.ln_s!(c.outside, link)
      assert {"", 9} = run(:list, [link, c.root])
      assert {"", 9} = run(:read, ["100", Path.join(link, "secret.txt"), c.root])
    end

    test "a final file symlink cannot read outside a root", c do
      link = Path.join(c.root, "escape.txt")
      File.ln_s!(Path.join(c.outside, "secret.txt"), link)
      assert {"", 9} = run(:read, ["100", link, c.root])
    end

    test "symlinks within a root and symlinked homes remain usable", c do
      home = Path.join(c.outside, "mapped-home")
      File.ln_s!(c.root, home)
      File.ln_s!(Path.join(c.root, "nested"), Path.join(c.root, "directory-link"))
      File.ln_s!(Path.join(c.root, "nested/inside.txt"), Path.join(c.root, "file-link"))

      assert {listing, 0} = run(:list, [Path.join(home, "directory-link"), home])
      assert listing == "file\t6\tinside.txt\0"
      assert {encoded, 0} = run(:read, ["100", Path.join(home, "file-link"), home])
      assert encoded == "6\naW5zaWRl\n"
      assert {listing, 0} = run(:list, [home, home])
      assert listing =~ "symlink\t\tfile-link\0"
    end

    test "either allowed root can contain the physical target", c do
      # A second root is a working directory under /tmp (gemini's), wherever
      # this host keeps its temporary directory.
      tmp = Path.join("/tmp", "sandbox-files-#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      on_exit(fn -> File.rm_rf(tmp) end)
      File.write!(Path.join(tmp, "secret.txt"), "outside")

      link = Path.join(c.root, "workspace")
      File.ln_s!(tmp, link)
      logical = ["/home/sprite", "/tmp/gemini-workspace"]
      assert {listing, 0} = run(:list, [link, c.root, tmp], [], logical)
      assert listing =~ "secret.txt"

      assert {_encoded, 0} =
               run(:read, ["100", Path.join(link, "secret.txt"), c.root, tmp], [], logical)
    end

    test "a home that does not resolve is no root, and admits no working directory under it",
         c do
      # The home made unreadable by a process on a shared machine must not
      # promote the next root to the home.
      link = Path.join(c.root, "b")
      File.ln_s!(c.outside, link)
      missing = Path.join(c.root, "no-such-home")

      assert {"", 9} =
               run(:read, ["100", Path.join(link, "secret.txt"), missing, link], [], [
                 "/home/sprite",
                 "/home/sprite/b"
               ])
    end

    test "a working-directory root replaced by a symlink out of the home is no root", c do
      # A conversation's cwd on a shared machine (ADR 0097) that another
      # process swapped for a link to somewhere else.
      link = Path.join(c.root, "b")
      File.ln_s!(c.outside, link)
      logical = ["/home/sprite", "/home/sprite/b"]

      assert {"", 9} =
               run(:read, ["100", Path.join(link, "secret.txt"), c.root, link], [], logical)

      # A real directory under the home still is one.
      nested = Path.join(c.root, "nested")

      assert {_encoded, 0} =
               run(:read, ["100", Path.join(nested, "inside.txt"), c.root, nested], [], [
                 "/home/sprite",
                 "/home/sprite/nested"
               ])
    end

    test "newlines at the end of physical paths are preserved", c do
      root = Path.join(c.root, "odd\n")
      File.mkdir_p!(root)
      file = Path.join(root, "file\n")
      File.write!(file, "inside")
      assert {"file\t6\tfile\n\0", 0} = run(:list, [root, root])
      assert {"6\naW5zaWRl\n", 0} = run(:read, ["100", file, root])
    end

    test "missing paths and wrong kinds retain their existing errors", c do
      missing = Path.join(c.root, "missing")
      File.ln_s!(missing, Path.join(c.root, "dangling"))
      assert {"", 3} = run(:list, [missing, c.root])
      assert {"", 3} = run(:read, ["100", missing, c.root])
      assert {"", 3} = run(:read, ["100", Path.join(c.root, "dangling"), c.root])
      assert {"", 4} = run(:list, [Path.join(c.root, "nested/inside.txt"), c.root])
      assert {"", 4} = run(:read, ["100", c.root, c.root])
    end

    test "unreadable files remain unreadable", c do
      file = Path.join(c.root, "locked")
      File.write!(file, "private")
      File.chmod!(file, 0o000)
      on_exit(fn -> File.chmod(file, 0o600) end)

      # A root-run test process can read mode 000; exercise the permission
      # refusal only when the OS actually denies the test user's read.
      if match?({:error, :eacces}, File.read(file)) do
        assert {"", 5} = run(:read, ["100", file, c.root])
      end
    end
  end

  describe "status_script/0 exit status" do
    test "a healthy repository answers 0 with its two changes" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))

      assert {output, 0} = run(:status, [repo, @cap, "all", repo])
      assert output =~ "M a.txt"
      assert output =~ "?? new.txt"
    end

    test "git failing after discovery is a failure, not an empty status" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))
      # What an unreadable index looks like. The realistic trigger is a clean
      # filter that is not installed (an LFS clone with no `git-lfs` on
      # PATH); this one is reproducible without a second binary.
      File.write!(Path.join(repo, ".git/index"), "x")

      assert {output, code} = run(:status, [repo, @cap, "all", repo])

      # Not 0: `entries: []` here is byte-for-byte what a clean tree returns,
      # and the tree is not clean.
      assert code == 8
      assert output =~ "fatal:"
    end

    test "the byte cap still truncates, and the SIGPIPE it causes is not a failure" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))

      # Past a pipe buffer, so `head -c` closing at the cap really does kill
      # git with SIGPIPE (status 141) rather than letting it finish writing
      # into the buffer. This is what a bare `set -o pipefail` would break.
      long = String.duplicate("n", 240)
      for i <- 1..1_000, do: File.write!(Path.join(repo, "#{long}#{i}.txt"), "x")

      assert {output, 0} = run(:status, [repo, "64", "all", repo])
      assert byte_size(output) < 1_000
    end
  end

  describe "diff_script/0 exit status" do
    test "a clean tracked tree still returns an empty diff" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))
      git!(repo, ["checkout", "--", "a.txt"])

      assert {output, 0} = run(:diff, [repo, @cap, "", "0", repo])
      assert [_root, encoded] = String.split(output, <<0>>, parts: 2)
      assert {:ok, ""} = Base.decode64(encoded, ignore: :whitespace)
    end

    test "a broken index fails both staged and unstaged diffs after discovery" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))
      File.write!(Path.join(repo, ".git/index"), "x")

      for staged <- ["0", "1"] do
        assert {output, 8} = run(:diff, [repo, @cap, "", staged, repo])
        assert output =~ "fatal:"
        refute output =~ <<0>>
      end
    end

    test "an encoding failure does not become an empty diff" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))
      bin = TmpDir.mkdir!("sandbox-files-bin")
      encoder = Path.join(bin, "base64")
      File.write!(encoder, "#!/bin/sh\nexit 1\n")
      File.chmod!(encoder, 0o755)

      assert {_output, 8} =
               run(:diff, [repo, @cap, "", "0", repo], [
                 {"PATH", bin <> ":" <> System.fetch_env!("PATH")}
               ])
    end

    test "the byte cap still permits SIGPIPE and returns a bounded diff" do
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "repo"))
      File.write!(Path.join(repo, "a.txt"), String.duplicate("changed\n", 25_000))

      assert {output, 0} = run(:diff, [repo, "64", "", "0", repo])
      assert [_root, encoded] = String.split(output, <<0>>, parts: 2)
      assert {:ok, diff} = Base.decode64(encoded, ignore: :whitespace)
      assert byte_size(diff) == 64
      assert diff =~ "diff --git"
    end
  end

  describe "the header a script writes" do
    test "is NUL-framed, so a newline in the repository's path survives it" do
      # A directory may be named this. Framed with newlines, the header of a
      # repository at `<dir>/re\npo` reported the root as `<dir>/re`, the
      # branch as `po`, and read the first real record out of the rest of its
      # own path — which decoded as nothing and was dropped.
      repo = repo!(Path.join(TmpDir.mkdir!("sandbox-files-script"), "re\npo"))

      assert {output, 0} = run(:status, [repo, @cap, "all", repo])
      # `--show-toplevel` prints the physical path, which on a mac reaches
      # this directory through `/private`; what matters is that the name
      # arrives whole rather than cut at its newline.
      assert [root, "main", body] = String.split(output, <<0>>, parts: 3)
      assert String.ends_with?(root, "/re\npo")
      assert body =~ "?? new.txt"

      assert {output, 0} = run(:diff, [repo, @cap, "", "0", repo])
      assert [^root, encoded] = String.split(output, <<0>>, parts: 2)
      assert {:ok, diff} = Base.decode64(encoded, ignore: :whitespace)
      assert diff =~ "a/a.txt"
    end
  end

  test "host roots become sandbox paths even through a symlinked home" do
    host = TmpDir.mkdir!("sandbox-files-host")
    alias_path = Path.join(TmpDir.mkdir!("sandbox-files-alias"), "home")
    File.ln_s!(host, alias_path)
    repo!(Path.join(host, "re\npo"))
    nested = Path.join(alias_path, "re\npo/nested")
    File.mkdir_p!(nested)

    for kind <- [:diff, :status] do
      flags = if kind == :status, do: [nested, @cap, "all"], else: [nested, @cap, "", "0"]
      assert {output, 0} = run(kind, flags ++ [alias_path], [], ["/home/sprite"])
      assert ["/home/sprite/re\npo" | _] = String.split(output, <<0>>)
      refute output =~ host
      refute output =~ alias_path
    end
  end

  describe "repository discovery is confined" do
    setup do
      # A sandbox that is a directory under a home that is itself a
      # repository (a dotfiles `$HOME`).
      outside = TmpDir.mkdir!("sandbox-files-script")
      repo!(outside)
      File.write!(Path.join(outside, ".ssh_id_rsa_name"), "private\n")
      sandbox = Path.join(outside, "sandbox")
      File.mkdir_p!(sandbox)
      {:ok, outside: outside, sandbox: sandbox}
    end

    test "a repository above the sandbox root is not a repository here", ctx do
      # Confined as a request path — it is the root — and still an ancestor
      # walk away from the operator's home.
      assert {output, 6} = run(:status, [ctx.sandbox, @cap, "all", ctx.sandbox])
      refute output =~ ".ssh_id_rsa_name"

      assert {output, 6} = run(:diff, [ctx.sandbox, @cap, "", "0", ctx.sandbox])
      assert output == ""
    end

    test "a repository at or under a root is answered", ctx do
      # The same discovery, with the root that contains it declared: this is
      # the ordinary case, where the agent's working directory is inside a
      # clone the agent made.
      assert {output, 0} = run(:status, [ctx.sandbox, @cap, "all", ctx.outside])
      assert output =~ "?? .ssh_id_rsa_name"

      assert {_output, 0} = run(:diff, [ctx.sandbox, @cap, "", "0", ctx.outside])
    end

    test "a newline in a root's own path does not smuggle one past the check", ctx do
      # The root is compared whole, so the two halves of a name with a
      # newline in it are not two roots.
      odd = Path.join(ctx.outside, "re\npo")
      repo!(odd)

      assert {_output, 0} = run(:status, [odd, @cap, "all", odd])
      assert {_output, 6} = run(:status, [odd, @cap, "all", Path.join(ctx.outside, "re")])
    end

    test "one of several roots is enough, the way `roots/1` passes them", ctx do
      # The home first, then a working directory that does not exist.
      assert {_output, 0} = run(:status, [ctx.sandbox, @cap, "all", ctx.outside, "/tmp/other"])

      elsewhere = TmpDir.mkdir!("sandbox-files-other-home")

      assert {_output, 6} =
               run(:status, [ctx.sandbox, @cap, "all", elsewhere, "/tmp/other"])
    end
  end
end
