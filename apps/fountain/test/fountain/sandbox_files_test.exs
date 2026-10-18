defmodule Fountain.SandboxFilesTest do
  use Fountain.DataCase, async: true
  use Mimic

  alias Fountain.Crypto
  alias Fountain.Environments
  alias Fountain.SandboxFiles

  @home "/home/sprite"

  # A value that shares not one character with the text around it or with
  # `[REDACTED]`, so "no fragment of it survived" can be asserted byte by
  # byte rather than by eye.
  @straddled "QQWWZZ11223344556677"
  @straddle_body "p=" <> @straddled <> "|xyz|"

  setup do
    user = insert_verified_user()
    agent = insert_agent(user_id: user.id, runtime: "claude")
    sandbox = insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id)
    {:ok, user: user, agent: agent, sandbox: sandbox}
  end

  # The fixed argv shape every script is run with: the path and flags are
  # positional parameters after the script, never interpolated into it.
  defp expect_script(fun) do
    expect(Managoat.Sandbox, :exec, fn handle,
                                       "bash",
                                       ["-c", script, "fountain-files" | args],
                                       opts ->
      assert opts[:timeout] == 30_000
      fun.(handle, script, args)
    end)
  end

  defp b64(bytes), do: Base.encode64(bytes)

  # `XY path\0`: one record of git's porcelain v1 under `-z`.
  defp record(code, path), do: code <> " " <> path <> <<0>>

  # The repository root and the branch, NUL-terminated as the script writes
  # them, then the records as it passes them through.
  defp status_output(branch, records, root \\ @home),
    do: root <> <<0>> <> branch <> <<0>> <> IO.iodata_to_binary(records)

  # A diff's header: the root, NUL-terminated, then the base64 body.
  defp diff_output(root, bytes), do: root <> <<0>> <> b64(bytes)

  test "git roots and entry paths round-trip through file reads on a mapped backend", ctx do
    host = Fountain.TmpDir.mkdir!("sandbox-files-mapped")
    repo = Path.join(host, "repo")
    File.mkdir_p!(Path.join(repo, "nested"))
    env = [{"GIT_CONFIG_GLOBAL", "/dev/null"}, {"GIT_CONFIG_SYSTEM", "/dev/null"}]

    for args <- [
          ["init", "-q"],
          [
            "-c",
            "user.name=T",
            "-c",
            "user.email=t@example.com",
            "commit",
            "--allow-empty",
            "-qm",
            "init"
          ]
        ] do
      assert {_, 0} = System.cmd("git", args, cd: repo, env: env, stderr_to_stdout: true)
    end

    File.write!(Path.join(repo, "new.txt"), "from the sandbox\n")

    stub(Managoat.Sandbox, :host_path, fn _handle, path ->
      String.replace_prefix(path, @home, host)
    end)

    stub(Managoat.Sandbox, :exec, fn _handle, command, args, _opts ->
      {output, code} = System.cmd(command, args, env: env)
      {:ok, output, code}
    end)

    assert {:ok, %{repo_root: root, entries: [%{path: entry}]}} =
             SandboxFiles.status(ctx.sandbox, "repo/nested", untracked: "all")

    assert root == @home <> "/repo"
    assert {:ok, %{repo_root: ^root}} = SandboxFiles.diff(ctx.sandbox, "repo/nested")

    assert {:ok, %{content: "from the sandbox\n"}} =
             SandboxFiles.read(ctx.sandbox, Path.join(root, entry))
  end

  describe "resolve_path/2" do
    test "nil and relative paths resolve from the agent's working directory", ctx do
      assert {:ok, @home} = SandboxFiles.resolve_path(ctx.sandbox, nil)
      assert {:ok, @home <> "/src/app.ex"} = SandboxFiles.resolve_path(ctx.sandbox, "src/app.ex")
      assert {:ok, @home <> "/src"} = SandboxFiles.resolve_path(ctx.sandbox, "./src/../src")
    end

    test "an absolute path inside a root is kept, one outside is refused", ctx do
      assert {:ok, @home <> "/.env"} = SandboxFiles.resolve_path(ctx.sandbox, @home <> "/.env")

      assert {:error, :path_outside_sandbox} =
               SandboxFiles.resolve_path(ctx.sandbox, "/etc/passwd")

      assert {:error, :path_outside_sandbox} = SandboxFiles.resolve_path(ctx.sandbox, "../../etc")
      # A sibling that merely shares the prefix is not inside the root.
      assert {:error, :path_outside_sandbox} =
               SandboxFiles.resolve_path(ctx.sandbox, "/home/sprite2")
    end

    test "a NUL byte or invalid UTF-8 is an invalid path", ctx do
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, "a\0b")
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, <<0xFF, 0xFE>>)
      assert {:error, :invalid_path} = SandboxFiles.resolve_path(ctx.sandbox, 42)
    end

    test "a sandbox keeps its conversation's runtime roots after the agent changes or is removed",
         ctx do
      agent = insert_agent(user_id: ctx.user.id, runtime: "gemini")
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      insert_conversation(user_id: ctx.user.id, agent: agent, sandbox: sandbox, status: "idle")

      {:ok, _} =
        Fountain.Agents.update_agent(agent, %{"runtime" => "claude", "model" => ctx.agent.model})

      assert SandboxFiles.cwd(Repo.reload!(sandbox)) == "/tmp/gemini-workspace"
      assert {:ok, "/tmp/gemini-workspace/a.md"} = SandboxFiles.resolve_path(sandbox, "a.md")
      assert SandboxFiles.roots(sandbox) == [@home, "/tmp/gemini-workspace"]

      # A retained row can outlive its agent; path resolution still follows its disk.
      Repo.delete!(agent)
      assert SandboxFiles.cwd(Repo.reload!(sandbox)) == "/tmp/gemini-workspace"
    end

    test "a conversation's own cwd is where paths resolve from, and a root (ADR 0097)", ctx do
      agent = insert_agent(user_id: ctx.user.id, runtime: "claude")
      sandbox = insert_sandbox(user_id: ctx.user.id, agent_id: agent.id, status: "ready")
      conv = insert_conversation(user_id: ctx.user.id, agent: agent, sandbox: sandbox)
      conv |> Ecto.Changeset.change(cwd: "/home/sprite/work/app") |> Repo.update!()

      assert SandboxFiles.cwd(sandbox) == "/home/sprite/work/app"
      assert {:ok, "/home/sprite/work/app/a.md"} = SandboxFiles.resolve_path(sandbox, "a.md")
      assert SandboxFiles.roots(sandbox) == [@home, "/home/sprite/work/app"]
    end

    test "a gemini sandbox works from its /tmp workspace and may read the home too", ctx do
      agent = insert_agent(user_id: ctx.user.id, runtime: "gemini")
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready", agent_id: agent.id)

      assert SandboxFiles.cwd(sandbox) == "/tmp/gemini-workspace"
      assert SandboxFiles.roots(sandbox) == [@home, "/tmp/gemini-workspace"]
      assert {:ok, "/tmp/gemini-workspace/a.md"} = SandboxFiles.resolve_path(sandbox, "a.md")
      assert {:ok, @home <> "/x"} = SandboxFiles.resolve_path(sandbox, @home <> "/x")
      assert {:error, :path_outside_sandbox} = SandboxFiles.resolve_path(sandbox, "/tmp/other")
    end

    test "a sandbox whose agent is gone falls back to the home", ctx do
      sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")
      assert SandboxFiles.cwd(sandbox) == @home
    end
  end

  describe "list/2" do
    test "runs the listing script on the resolved path and sorts directories first", ctx do
      expect_script(fn handle, script, args ->
        assert handle.name == ctx.sandbox.machine_name
        assert script =~ "shopt -s dotglob nullglob"
        assert args == [@home <> "/src", @home, "sandbox:" <> @home]

        {:ok,
         "file\t12\tREADME.md\0directory\t\tlib\0file\t3\t.env\0" <>
           "symlink\t\tlink\0directory\t\tAssets\0file\t\tbroken\0", 0}
      end)

      assert {:ok, %{path: @home <> "/src", truncated: false, entries: entries}} =
               SandboxFiles.list(ctx.sandbox, "src")

      assert Enum.map(entries, &{&1.name, &1.type, &1.size}) == [
               {"Assets", "directory", nil},
               {"lib", "directory", nil},
               {".env", "file", 3},
               {"broken", "file", nil},
               {"link", "symlink", nil},
               {"README.md", "file", 12}
             ]
    end

    test "a name with a tab or newline survives", ctx do
      expect_script(fn _, _, _ -> {:ok, "file\t1\todd\tname\0file\t2\ttwo\nlines\0", 0} end)

      assert {:ok, %{entries: [%{name: "odd\tname"}, %{name: "two\nlines"}]}} =
               SandboxFiles.list(ctx.sandbox, nil)
    end

    test "redacts environment, vault and live conversation values from names and the path", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)
      vault = insert_vault(user_id: ctx.user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "sk-env-secret"}, dek)

      {:ok, _} =
        Fountain.Vaults.upsert_secret(
          vault,
          %{"key" => "TOKEN", "value" => "sk-vault-secret"},
          dek
        )

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          vault_id: vault.id,
          agent_id: ctx.agent.id
        )

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"CALLBACK_TOKEN", "sk-live-secret"}])
      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      expect_script(fn _, _, args ->
        assert args == [
                 @home <> "/sk-env-secret/sk-vault-secret/sk-live-secret",
                 @home,
                 "sandbox:" <> @home
               ]

        {:ok,
         "file\t12\tz-sk-env-secret.txt\0directory\t\tsk-vault-secret\0" <>
           "symlink\t\tsk-live-secret\0file\t3\tplain.txt\0", 0}
      end)

      assert {:ok,
              %{
                path: @home <> "/[REDACTED]/[REDACTED]/[REDACTED]",
                truncated: false,
                entries: [
                  %{name: "[REDACTED]", type: "directory", size: nil},
                  %{name: "plain.txt", type: "file", size: 3},
                  %{name: "[REDACTED]", type: "symlink", size: nil},
                  %{name: "z-[REDACTED].txt", type: "file", size: 12}
                ]
              }} = SandboxFiles.list(sandbox, "sk-env-secret/sk-vault-secret/sk-live-secret")
    end

    test "redacts a name's original bytes before recoding invalid UTF-8 for JSON", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"TOKEN", "sk-live-café"}])
      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      expect_script(fn _, _, _ ->
        {:ok, <<"file\t1\tcaf", 0xE9, "-sk-live-café.txt\0file\t2\t日本語.txt\0">>, 0}
      end)

      assert {:ok, %{entries: entries} = listing} = SandboxFiles.list(ctx.sandbox, nil)
      assert Enum.map(entries, & &1.name) == ["café-[REDACTED].txt", "日本語.txt"]
      assert {:ok, _} = Jason.encode(listing)
    end

    test "redaction preserves the entry cap, ordering and duplicate display names", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"A", "aaaaaaaa"}, {"Z", "zzzzzzzz"}])
      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      for {count, truncated} <- [{1_998, false}, {1_999, true}] do
        records = for i <- 1..count, do: "file\t1\tf#{i}.txt\0"

        expect_script(fn _, _, _ ->
          {:ok, "directory\t\tzzzzzzzz\0file\t2\taaaaaaaa\0" <> IO.iodata_to_binary(records), 0}
        end)

        assert {:ok, %{entries: entries, truncated: ^truncated}} =
                 SandboxFiles.list(ctx.sandbox, nil)

        assert length(entries) == 2_000

        assert [%{name: "[REDACTED]", type: "directory"}, %{name: "[REDACTED]", type: "file"} | _] =
                 entries
      end
    end

    test "the script's exit codes become the caller's errors", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.list(ctx.sandbox, "missing")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.list(ctx.sandbox, "README.md")

      expect_script(fn _, _, _ -> {:ok, "", 5} end)
      assert {:error, :path_unreadable} = SandboxFiles.list(ctx.sandbox, "locked")

      expect_script(fn _, _, _ -> {:ok, "", 9} end)
      assert {:error, :path_outside_sandbox} = SandboxFiles.list(ctx.sandbox, "escape")

      expect_script(fn _, _, _ -> {:ok, "bash: boom", 127} end)

      assert {:error, {:sandbox_command_failed, 127, "bash: boom"}} =
               SandboxFiles.list(ctx.sandbox, nil)
    end

    test "a provider error is unreachable, and nothing runs on a parked sandbox", ctx do
      expect_script(fn _, _, _ -> {:error, {:unavailable, :timeout}} end)

      assert {:error, {:sandbox_unreachable, {:unavailable, :timeout}}} =
               SandboxFiles.list(ctx.sandbox, nil)

      reject(&Managoat.Sandbox.exec/4)
      parked = %{ctx.sandbox | status: "suspended"}
      assert {:error, {:sandbox_not_ready, "suspended"}} = SandboxFiles.list(parked, nil)
    end

    test "paths cross the adapter's host_path mapping", ctx do
      stub(Managoat.Sandbox, :host_path, fn _handle, path -> "/Users/me/box" <> path end)

      expect_script(fn _, _, args ->
        assert args == [
                 "/Users/me/box/home/sprite/src",
                 "/Users/me/box/home/sprite",
                 "sandbox:" <> @home
               ]

        {:ok, "", 0}
      end)

      # The response names the in-sandbox path, not the host one.
      assert {:ok, %{path: @home <> "/src", entries: []}} = SandboxFiles.list(ctx.sandbox, "src")
    end
  end

  describe "read/3" do
    test "decodes the size line and the base64 body, and redacts the identity's secrets", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "API_TOKEN", "value" => "sk-live-abcdef"}, dek)

      # Too short to redact, on purpose: an eight-byte floor stops `true`
      # and `1` from scrubbing every file.
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "DEBUG", "value" => "yes"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      body = "token=sk-live-abcdef\ndebug=yes\n"

      expect_script(fn _, script, args ->
        assert script =~ "head -c"
        # The cap plus the overlap: one byte less than the longest value,
        # `sk-live-abcdef`, so a value lying across the cap arrives whole.
        assert args == ["#{262_144 + 13}", @home <> "/.env", @home, "sandbox:" <> @home]
        {:ok, "#{byte_size(body)}\n" <> b64(body), 0}
      end)

      assert {:ok, file} = SandboxFiles.read(sandbox, ".env")

      assert file == %{
               path: @home <> "/.env",
               size: byte_size(body),
               truncated: false,
               encoding: "utf-8",
               content: "token=[REDACTED]\ndebug=yes\n"
             }
    end

    test "max_bytes is clamped, and a file longer than it is truncated", ctx do
      expect_script(fn _, _, args ->
        assert args == ["4194304", @home <> "/big", @home, "sandbox:" <> @home]
        {:ok, "9999999\n" <> b64("start"), 0}
      end)

      assert {:ok, %{size: 9_999_999, truncated: true, content: "start"}} =
               SandboxFiles.read(ctx.sandbox, "big", max_bytes: 99_999_999)
    end

    test "bytes that are not UTF-8 come back base64", ctx do
      bytes = <<0xFF, 0x00, 0x89, "PNG">>
      expect_script(fn _, _, _ -> {:ok, "6\n" <> b64(bytes), 0} end)

      assert {:ok, %{encoding: "base64", content: content}} =
               SandboxFiles.read(ctx.sandbox, "img.png")

      assert Base.decode64!(content) == bytes
    end

    test "a directory, a missing file and an unreadable one are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :is_a_directory} = SandboxFiles.read(ctx.sandbox, "src")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.read(ctx.sandbox, "nope")

      expect_script(fn _, _, _ -> {:ok, "", 5} end)
      assert {:error, :path_unreadable} = SandboxFiles.read(ctx.sandbox, "root-only")

      expect_script(fn _, _, _ -> {:ok, "", 9} end)
      assert {:error, :path_outside_sandbox} = SandboxFiles.read(ctx.sandbox, "escape")
    end

    test "output the script did not produce is a command failure, not a crash", ctx do
      expect_script(fn _, _, _ -> {:ok, "not a size\n!!!", 0} end)
      assert {:error, {:sandbox_command_failed, 0, _}} = SandboxFiles.read(ctx.sandbox, "x")
    end
  end

  describe "diff/3" do
    test "runs git diff in the resolved directory with the ref and staged flag as parameters",
         ctx do
      diff = "diff --git a/x b/x\n--- a/x\n+++ b/x\n@@ -1 +1 @@\n-a\n+b\n"

      expect_script(fn _, script, args ->
        assert script =~ "git --no-pager --no-optional-locks diff --no-color --no-ext-diff"
        assert args == [@home <> "/repo", "262145", "main", "1", @home, "sandbox:" <> @home]
        {:ok, diff_output(@home <> "/repo", diff), 0}
      end)

      assert {:ok,
              %{
                path: @home <> "/repo",
                repo_root: @home <> "/repo",
                staged: true,
                ref: "main",
                diff: ^diff,
                truncated: false
              }} = SandboxFiles.diff(ctx.sandbox, "repo", staged: true, ref: "main")
    end

    test "no ref and no staged flag pass as empty and 0", ctx do
      expect_script(fn _, _, args ->
        assert args == [@home, "262145", "", "0", @home, "sandbox:" <> @home]
        {:ok, diff_output(@home, ""), 0}
      end)

      assert {:ok, %{ref: nil, staged: false, diff: ""}} = SandboxFiles.diff(ctx.sandbox, nil)
    end

    test "a ref that could read as a flag or a range is refused before anything runs", ctx do
      reject(&Managoat.Sandbox.exec/4)
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "--output=/tmp/x")
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "main..dev")
      assert {:error, :invalid_ref} = SandboxFiles.diff(ctx.sandbox, nil, ref: "a b")
    end

    test "the cap is one byte past max_bytes so an exact fit is not truncated", ctx do
      expect_script(fn _, _, [_, "6", _, _ | _] -> {:ok, diff_output("/r", "abcdefg"), 0} end)

      assert {:ok, %{diff: "abcde", truncated: true}} =
               SandboxFiles.diff(ctx.sandbox, nil, max_bytes: 5)

      expect_script(fn _, _, [_, "6", _, _ | _] -> {:ok, diff_output("/r", "abcde"), 0} end)

      assert {:ok, %{diff: "abcde", truncated: false}} =
               SandboxFiles.diff(ctx.sandbox, nil, max_bytes: 5)
    end

    test "a latin-1 hunk is recoded rather than refused", ctx do
      expect_script(fn _, _, _ -> {:ok, diff_output("/r", <<"caf", 0xE9>>), 0} end)
      assert {:ok, %{diff: "café"}} = SandboxFiles.diff(ctx.sandbox, nil)
    end

    test "a newline in the repository root keeps its header", ctx do
      root = @home <> "/re\npo"
      expect_script(fn _, _, _ -> {:ok, diff_output(root, "+x\n"), 0} end)

      assert {:ok, %{repo_root: ^root, diff: "+x\n"}} =
               SandboxFiles.diff(ctx.sandbox, "re\npo")
    end

    test "not a repository, an unknown ref and a missing directory are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 6} end)
      assert {:error, :not_a_repository} = SandboxFiles.diff(ctx.sandbox, "plain")

      expect_script(fn _, _, _ -> {:ok, "", 7} end)
      assert {:error, :ref_not_found} = SandboxFiles.diff(ctx.sandbox, nil, ref: "nope")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.diff(ctx.sandbox, "gone")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.diff(ctx.sandbox, "file.txt")
    end

    test "the diff is redacted with what a live conversation registered", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"ANTHROPIC_API_KEY", "sk-ant-secret-value"}])

      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      expect_script(fn _, _, _ ->
        {:ok, diff_output("/r/sk-ant-secret-value", "+key = sk-ant-secret-value\n"), 0}
      end)

      # The root goes through the same replacement the hunks do.
      assert {:ok, %{repo_root: "/r/[REDACTED]", diff: "+key = [REDACTED]\n"}} =
               SandboxFiles.diff(ctx.sandbox, nil)
    end
  end

  describe "status/3" do
    test "reports an untracked file, the one state a diff cannot show", ctx do
      expect_script(fn _, script, args ->
        assert script =~ "git --no-pager --no-optional-locks status --porcelain=v1 -z"
        assert args == [@home <> "/repo", "1048577", "normal", @home, "sandbox:" <> @home]

        {:ok,
         status_output("main", [
           record("??", "notes.md"),
           record(" M", "lib/app.ex"),
           record("A ", "lib/new.ex"),
           record("MM", "mix.exs"),
           record(" D", "gone.txt"),
           record("UU", "conflict.ex")
         ]), 0}
      end)

      assert {:ok,
              %{
                path: @home <> "/repo",
                repo_root: @home,
                branch: "main",
                untracked: "normal",
                truncated: false,
                entries: entries
              }} = SandboxFiles.status(ctx.sandbox, "repo")

      # Both porcelain columns, read separately: `MM` is staged and then
      # edited again, `??` is untracked on both sides the way git reports it.
      assert Enum.map(entries, &{&1.path, &1.index, &1.worktree}) == [
               {"conflict.ex", "unmerged", "unmerged"},
               {"gone.txt", "unchanged", "deleted"},
               {"lib/app.ex", "unchanged", "modified"},
               {"lib/new.ex", "added", "unchanged"},
               {"mix.exs", "modified", "modified"},
               {"notes.md", "untracked", "untracked"}
             ]
    end

    test "a rename takes the record after it as its origin, destination first", ctx do
      expect_script(fn _, _, _ ->
        {:ok,
         status_output("main", [
           record("R ", "lib/new.ex"),
           "lib/old.ex" <> <<0>>,
           record(" M", "z.txt")
         ]), 0}
      end)

      assert {:ok, %{entries: entries}} = SandboxFiles.status(ctx.sandbox, nil)

      assert entries == [
               %{
                 path: "lib/new.ex",
                 index: "renamed",
                 worktree: "unchanged",
                 renamed_from: "lib/old.ex"
               },
               %{path: "z.txt", index: "unchanged", worktree: "modified", renamed_from: nil}
             ]
    end

    test "the untracked mode is one of three, and anything else reads as normal", ctx do
      for mode <- ~w(all no normal) do
        expect_script(fn _, _, [_, _, passed | _] ->
          assert passed == mode
          {:ok, status_output("main", []), 0}
        end)

        assert {:ok, %{untracked: ^mode}} = SandboxFiles.status(ctx.sandbox, nil, untracked: mode)
      end

      expect_script(fn _, _, [_, _, "normal" | _] -> {:ok, status_output("main", []), 0} end)

      assert {:ok, %{untracked: "normal", entries: []}} =
               SandboxFiles.status(ctx.sandbox, nil, untracked: "--ignored")
    end

    test "a detached HEAD has no branch, and a clean tree no entries", ctx do
      expect_script(fn _, _, _ -> {:ok, status_output("", []), 0} end)

      assert {:ok, %{branch: nil, entries: [], truncated: false}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a record the byte cap cut in half is dropped rather than half-read", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record(" M", "a.txt"), " M b.tx"]), 0}
      end)

      assert {:ok, %{entries: [%{path: "a.txt"}], truncated: true}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a cut that landed on a record boundary is still truncated", ctx do
      # Whole and NUL-terminated, so the tail cannot show this cut. Only the
      # byte past the cap can, which is why the script is asked for one.
      name = String.duplicate("x", 1_048_577 - 4)

      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record(" M", name)]), 0}
      end)

      assert {:ok, %{entries: [%{path: ^name}], truncated: true}} =
               SandboxFiles.status(ctx.sandbox, nil)
    end

    test "more changes than the entry cap are cut to it and flagged", ctx do
      records = for i <- 1..2_001, do: record(" M", "f#{i}.txt")
      expect_script(fn _, _, _ -> {:ok, status_output("main", records), 0} end)

      assert {:ok, %{entries: entries, truncated: true}} = SandboxFiles.status(ctx.sandbox, nil)
      assert length(entries) == 2_000
    end

    test "a record with a letter git does not write is skipped, not guessed at", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record("ZZ", "odd.txt"), record(" M", "ok.txt")]), 0}
      end)

      assert {:ok, %{entries: [%{path: "ok.txt"}]}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a path git wrote verbatim that is not UTF-8 is recoded, not refused", ctx do
      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record("??", <<"caf", 0xE9, ".md">>)]), 0}
      end)

      assert {:ok, %{entries: [%{path: "café.md"}]}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a newline in the repository root keeps its header, its branch and its entry", ctx do
      # A directory may be named this, and `resolve_path/2` refuses only NUL
      # and invalid UTF-8, so a caller can reach one. Framed with newlines the
      # header read `repo_root: "<home>/re"`, `branch: "po"`, and the one real
      # record decoded from `main\n?? new.txt` and was dropped: a 200 with no
      # entries for a repository that has a change.
      root = @home <> "/re\npo"

      expect_script(fn _, _, _ ->
        {:ok, status_output("main", [record("??", "new.txt")], root), 0}
      end)

      assert {:ok, %{repo_root: ^root, branch: "main", entries: [%{path: "new.txt"}]}} =
               SandboxFiles.status(ctx.sandbox, "re\npo")
    end

    test "the roots the script confines discovery to cross host_path too", ctx do
      # They are compared against what `git rev-parse --show-toplevel` prints
      # inside the sandbox, so an unmapped root would refuse every repository
      # on a mapped backend rather than confine one.
      stub(Managoat.Sandbox, :host_path, fn _handle, path -> "/Users/me/box" <> path end)

      expect_script(fn _, _, args ->
        assert args == [
                 "/Users/me/box/home/sprite",
                 "1048577",
                 "normal",
                 "/Users/me/box/home/sprite",
                 "sandbox:/home/sprite"
               ]

        {:ok, status_output("main", [], "/Users/me/box/home/sprite"), 0}
      end)

      assert {:ok, %{path: @home}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "not a repository, a missing directory and a file are named", ctx do
      expect_script(fn _, _, _ -> {:ok, "", 6} end)
      assert {:error, :not_a_repository} = SandboxFiles.status(ctx.sandbox, "plain")

      expect_script(fn _, _, _ -> {:ok, "", 3} end)
      assert {:error, :path_not_found} = SandboxFiles.status(ctx.sandbox, "gone")

      expect_script(fn _, _, _ -> {:ok, "", 4} end)
      assert {:error, :not_a_directory} = SandboxFiles.status(ctx.sandbox, "file.txt")
    end

    test "output the script did not produce is a command failure, not a crash", ctx do
      expect_script(fn _, _, _ -> {:ok, "no second line", 0} end)
      assert {:error, {:sandbox_command_failed, 0, _}} = SandboxFiles.status(ctx.sandbox, nil)
    end

    test "a diagnostic the byte cap split mid-character still encodes as JSON", ctx do
      # The failure path caps git's message with `head -c 4096`, which cuts on
      # a byte: a diagnostic that long in a non-Latin filename or a translated
      # locale loses half of the character that straddles the cap. The 422
      # this error renders as would be a 500 if the body would not encode.
      cut = binary_part("fatal: unable to read '" <> String.duplicate("é", 3000), 0, 4096)
      refute String.valid?(cut)

      expect_script(fn _, _, _ -> {:ok, status_output("main", []) <> cut, 8} end)

      assert {:error, {:sandbox_command_failed, 8, output}} =
               SandboxFiles.status(ctx.sandbox, nil)

      assert String.valid?(output)
      assert {:ok, _} = Jason.encode(%{error: "sandbox_command_failed", output: output})
      assert output =~ "fatal: unable to read"
    end

    test "a failing command's output is redacted before it is recoded", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)
      secret = "sk-live-café"

      {:ok, _} = Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => secret}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      # Recoding first would rewrite the secret's own bytes, and the search
      # for them would then find nothing.
      message = "fatal: unable to read '" <> secret <> "'" <> String.duplicate("é", 3000)
      cut = binary_part(message, 0, 4096)
      refute String.valid?(cut)

      expect_script(fn _, _, _ -> {:ok, cut, 8} end)

      assert {:error, {:sandbox_command_failed, 8, output}} = SandboxFiles.status(sandbox, nil)
      assert String.valid?(output)
      assert output =~ "[REDACTED]"
      refute output =~ "café"
    end

    test "a path is redacted the way file content is", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)

      {:ok, _} =
        Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => "sk-live-abcdef"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      expect_script(fn _, _, _ ->
        {:ok,
         status_output(
           "sk-live-abcdef-branch",
           [
             record("R ", "dump-sk-live-abcdef.json"),
             "old-sk-live-abcdef.json" <> <<0>>
           ],
           @home <> "/clone-sk-live-abcdef"
         ), 0}
      end)

      # `repo_root` is a path the agent chose like the three beside it, so it
      # is replaced like them rather than handed back raw.
      assert {:ok,
              %{
                repo_root: @home <> "/clone-[REDACTED]",
                branch: "[REDACTED]-branch",
                entries: [
                  %{path: "dump-[REDACTED].json", renamed_from: "old-[REDACTED].json"}
                ]
              }} = SandboxFiles.status(sandbox, nil)
    end
  end

  # Redaction matches a value's own bytes, so a cut through one leaves a
  # prefix that matches nothing. The cut `head -c` makes is at `max_bytes`,
  # which the caller picks, so a caller that could move it across a value
  # could read the value out a piece at a time (#1907).
  describe "the caller's cap runs after redaction, not before (#1907)" do
    setup ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => @straddled}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      {:ok, secret_sandbox: sandbox}
    end

    test "read/3: no max_bytes anywhere across the value yields a fragment of it", ctx do
      body = @straddle_body

      for max_bytes <- 1..byte_size(body) do
        expect_script(fn _, _, [n, _, @home, "sandbox:" <> @home] ->
          n = String.to_integer(n)
          # The script is asked past the cap; it still cuts at what it is asked.
          assert n == max_bytes + byte_size(@straddled) - 1
          {:ok, "#{byte_size(body)}\n" <> b64(binary_part(body, 0, min(n, byte_size(body)))), 0}
        end)

        assert {:ok, %{content: content, encoding: "utf-8"}} =
                 SandboxFiles.read(ctx.secret_sandbox, "f", max_bytes: max_bytes)

        assert byte_size(content) <= max_bytes,
               "max_bytes=#{max_bytes} answered #{byte_size(content)} bytes"

        for k <- 1..byte_size(@straddled) do
          fragment = binary_part(@straddled, 0, k)

          refute String.contains?(content, fragment),
                 "max_bytes=#{max_bytes} leaked #{inspect(fragment)} in #{inspect(content)}"
        end
      end
    end

    test "read/3: a cap past the value replaces it whole", ctx do
      body = @straddle_body
      expect_script(fn _, _, _ -> {:ok, "#{byte_size(body)}\n" <> b64(body), 0} end)

      assert {:ok, %{content: "p=[REDACTED]|xyz|", truncated: false}} =
               SandboxFiles.read(ctx.secret_sandbox, "f")
    end

    test "diff/3: the same walk, one byte further out for the exact-fit probe", ctx do
      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: ctx.agent,
          sandbox: ctx.sandbox,
          status: "running"
        )

      Fountain.Conversations.Redaction.put(conv.id, [{"TOKEN", @straddled}])
      on_exit(fn -> Fountain.Conversations.Redaction.delete(conv.id) end)

      body = @straddle_body

      for max_bytes <- 1..byte_size(body) do
        expect_script(fn _, _, [_, n, _, _ | _] ->
          n = String.to_integer(n)
          assert n == max_bytes + 1 + byte_size(@straddled) - 1
          {:ok, diff_output("/r", binary_part(body, 0, min(n, byte_size(body)))), 0}
        end)

        assert {:ok, %{diff: diff}} = SandboxFiles.diff(ctx.sandbox, nil, max_bytes: max_bytes)

        assert byte_size(diff) <= max_bytes,
               "max_bytes=#{max_bytes} answered #{byte_size(diff)} bytes"

        for k <- 1..byte_size(@straddled) do
          fragment = binary_part(@straddled, 0, k)

          refute String.contains?(diff, fragment),
                 "max_bytes=#{max_bytes} leaked #{inspect(fragment)} in #{inspect(diff)}"
        end
      end
    end

    test "a value replaced earlier does not pull a fragment back inside the cap", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)
      long = String.duplicate("L", 30)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "LONG", "value" => long}, dek)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "TOKEN", "value" => @straddled}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      # `long` comes first and is three times the placeholder, so replacing
      # it moves everything behind it twenty bytes closer to the cap. That is
      # why the cut is taken in the bytes the script produced and not in the
      # redacted text: redacting the whole overlap and cutting afterwards
      # would carry an unmatched piece of the second value back inside.
      body = long <> "|" <> @straddled <> "|xyz|"

      for max_bytes <- 1..byte_size(body) do
        expect_script(fn _, _, [n, _, @home, "sandbox:" <> @home] ->
          n = String.to_integer(n)
          assert n == max_bytes + byte_size(long) - 1
          {:ok, "#{byte_size(body)}\n" <> b64(binary_part(body, 0, min(n, byte_size(body)))), 0}
        end)

        assert {:ok, %{content: content}} = SandboxFiles.read(sandbox, "f", max_bytes: max_bytes)

        assert byte_size(content) <= max_bytes,
               "max_bytes=#{max_bytes} answered #{byte_size(content)} bytes"

        for k <- 1..byte_size(@straddled) do
          fragment = binary_part(@straddled, 0, k)

          refute String.contains?(content, fragment),
                 "max_bytes=#{max_bytes} leaked #{inspect(fragment)} in #{inspect(content)}"
        end
      end
    end

    test "the cap holds when the placeholder is longer than the value it replaces", ctx do
      {:ok, dek} = Crypto.load_tenant_key(ctx.user.id)
      env = insert_env(user_id: ctx.user.id)
      {:ok, _} = Environments.upsert_secret(env, %{"key" => "T", "value" => "12345678"}, dek)

      sandbox =
        insert_sandbox(
          user_id: ctx.user.id,
          status: "ready",
          environment_id: env.id,
          agent_id: ctx.agent.id
        )

      # Exactly `max_bytes` on disk, so the only thing that can push the
      # answer past the cap is `[REDACTED]` being longer than the value.
      body = "ab12345678cd"

      expect_script(fn _, _, [n, _, @home, "sandbox:" <> @home] ->
        assert n == "#{12 + 7}"
        {:ok, "#{byte_size(body)}\n" <> b64(body), 0}
      end)

      assert {:ok, %{content: content, truncated: truncated}} =
               SandboxFiles.read(sandbox, "f", max_bytes: 12)

      assert content == "ab[REDACTED]"
      assert byte_size(content) == 12
      # The file fits the cap, so only the cut back down makes this true.
      assert truncated
    end
  end
end
