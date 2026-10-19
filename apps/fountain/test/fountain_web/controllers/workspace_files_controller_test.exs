defmodule FountainWeb.WorkspaceFilesControllerTest do
  @moduledoc """
  ADR 0097, Files: `/api/workspaces/:id/files`, `/file`, `/diff` and
  `/git-status` read the workspace's current machine as ADR 0039's sandbox
  routes do, with the home as the relative base, the home and every live
  conversation's working directory as the roots, and redaction over the
  workspace's environment and vault and every live conversation's
  registered values. Full scope, and another account's workspace is 404.
  """

  use FountainWeb.ConnCase, async: true
  use Mimic

  import Ecto.Query, only: [from: 2]

  @home "/home/sprite"

  setup do
    user = insert_verified_user()
    {_key, raw_key} = insert_api_key(user)
    {_key, sprite_key} = insert_sprite_api_key(user)
    vault = insert_vault(user_id: user.id)
    insert_vault_secret(vault, %{"key" => "API_TOKEN", "value" => "vault-secret-1234"})
    env = insert_env(user_id: user.id)

    workspace =
      insert_workspace(
        user_id: user.id,
        environment_id: env.id,
        vault_id: vault.id,
        implicit: false,
        name: "work",
        status: "ready"
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        workspace_id: workspace.id,
        environment_id: env.id,
        vault_id: vault.id,
        status: "ready"
      )

    agent = insert_agent(user_id: user.id, runtime: "claude")

    a =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        workspace_id: workspace.id,
        cwd: "/home/sprite/a",
        status: "idle"
      )

    b =
      insert_conversation(
        user_id: user.id,
        agent: insert_agent(user_id: user.id, runtime: "gemini"),
        sandbox: sandbox,
        workspace_id: workspace.id,
        status: "idle"
      )

    _ended =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        workspace_id: workspace.id,
        cwd: "/home/sprite/gone",
        status: "terminated"
      )

    _failed =
      insert_conversation(
        user_id: user.id,
        agent: agent,
        sandbox: sandbox,
        workspace_id: workspace.id,
        cwd: "/home/sprite/broken",
        status: "failed"
      )

    {:ok,
     user: user,
     env: env,
     raw_key: raw_key,
     sprite_key: sprite_key,
     workspace: workspace,
     sandbox: sandbox,
     a: a,
     b: b}
  end

  defp exec_returns(output, code \\ 0) do
    test = self()

    expect(Managoat.Sandbox, :exec, fn _handle,
                                       "bash",
                                       ["-c", _script, "fountain-files" | args],
                                       _opts ->
      send(test, {:exec_args, args})
      {:ok, output, code}
    end)
  end

  defp get_api(ctx, path, key \\ nil),
    do: ctx.conn |> authed_with_key(key || ctx.raw_key) |> get(path)

  # The roots a script is handed after its own arguments, as `path_roots/1`
  # spells them: the home and every live conversation's working directory,
  # the gemini one's default included and the terminated one's left out.
  defp roots do
    Enum.flat_map([@home, "/home/sprite/a", "/tmp/gemini-workspace"], &[&1, "sandbox:" <> &1])
  end

  test "lists from the home by default, with every live conversation's directory as a root",
       ctx do
    exec_returns("file\t5\tREADME\0")

    data =
      ctx
      |> get_api("/api/workspaces/#{ctx.workspace.id}/files")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["path"] == @home
    assert_received {:exec_args, [@home | rest]}
    assert Enum.sort(rest) == Enum.sort(roots())
  end

  test "a relative path resolves from the home, and one outside every root is refused", ctx do
    exec_returns("")

    ctx |> get_api("/api/workspaces/#{ctx.workspace.id}/files?path=a/src") |> json_response(200)
    assert_received {:exec_args, ["/home/sprite/a/src" | _]}

    exec_returns("")

    ctx
    |> get_api("/api/workspaces/#{ctx.workspace.id}/files?path=/tmp/gemini-workspace")
    |> json_response(200)

    reject(&Managoat.Sandbox.exec/4)

    for path <- ["/etc", "/home/sprite/../../etc"] do
      assert %{"error" => "path_outside_sandbox"} =
               ctx
               |> get_api("/api/workspaces/#{ctx.workspace.id}/files?path=#{path}")
               |> json_response(422)
    end
  end

  test "a file is redacted with the workspace's vault and every live conversation's values",
       ctx do
    Fountain.Conversations.Redaction.put(ctx.b.id, ["conversation-b-token-99"])
    on_exit(fn -> Fountain.Conversations.Redaction.delete(ctx.b.id) end)

    body = "vault=vault-secret-1234 conv=conversation-b-token-99\n"
    exec_returns("#{byte_size(body)}\n" <> Base.encode64(body))

    data =
      ctx
      |> get_api("/api/workspaces/#{ctx.workspace.id}/file?path=a/.env")
      |> json_response(200)
      |> Map.fetch!("data")

    assert data["content"] == "vault=[REDACTED] conv=[REDACTED]\n"
  end

  test "another account's workspace is 404, and a sandbox's own key is 403", ctx do
    other = insert_verified_user()
    foreign = insert_workspace(user_id: other.id, implicit: false, name: "x")
    # A machine that would answer, so a 404 is the scoping's and not the
    # missing machine's.
    insert_sandbox(user_id: other.id, workspace_id: foreign.id, status: "ready")

    # And one of the caller's own being deleted: taken from its owner first.
    deleting = insert_workspace(user_id: ctx.user.id, implicit: false, name: "going")
    insert_sandbox(user_id: ctx.user.id, workspace_id: deleting.id, status: "ready")

    {1, _} =
      Fountain.Repo.update_all(
        from(w in Fountain.Workspaces.Workspace, where: w.id == ^deleting.id),
        set: [user_id: nil]
      )

    reject(&Managoat.Sandbox.exec/4)

    for route <- ["files", "file?path=x", "diff", "git-status"],
        id <- [foreign.id, deleting.id] do
      assert %{"error" => "not_found"} =
               ctx |> get_api("/api/workspaces/#{id}/#{route}") |> json_response(404)
    end

    for route <- ["files", "file?path=x", "diff", "git-status"] do
      assert %{"error" => "insufficient_scope", "required_scope" => "full"} =
               ctx
               |> get_api("/api/workspaces/#{ctx.workspace.id}/#{route}", ctx.sprite_key)
               |> json_response(403)
    end
  end

  test "a parked machine is not woken, and a lost one is not read", ctx do
    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
    reject(&Managoat.Sandbox.exec/4)

    assert %{"error" => "sandbox_not_ready"} =
             ctx |> get_api("/api/workspaces/#{ctx.workspace.id}/files") |> json_response(409)

    {:ok, _} = update_sandbox(ctx.sandbox, %{status: "terminated"})

    ctx |> get_api("/api/workspaces/#{ctx.workspace.id}/git-status") |> json_response(409)
  end

  # #2999: the repositories of the workspace's environment are roots too,
  # as far as `ConfigHome.eligible_mounts/1` keeps them.
  defp mount_repositories(env, mounts) do
    env
    |> Ecto.Changeset.change(
      repositories:
        Enum.map(mounts, &%{"url" => "https://github.com/example/app", "mount_path" => &1})
    )
    |> Fountain.Repo.update!()
  end

  test "the environment's eligible repository mounts are roots, and nothing beside them", ctx do
    mount_repositories(ctx.env, ["/work/app/", "/etc", "/", "/home/sprite/.managoat", "/var/www"])
    exec_returns("")

    ctx
    |> get_api("/api/workspaces/#{ctx.workspace.id}/files?path=/work/app/src")
    |> json_response(200)

    assert_received {:exec_args, ["/work/app/src" | rest]}
    assert Enum.sort(rest) == Enum.sort(roots() ++ ["/work/app", "mount:/work/app"])

    reject(&Managoat.Sandbox.exec/4)

    for path <- ["/work", "/work/application", "/work/app/../etc", "/etc/passwd", "/var/www", "/"] do
      assert %{"error" => "path_outside_sandbox"} =
               ctx
               |> get_api("/api/workspaces/#{ctx.workspace.id}/file?path=#{path}")
               |> json_response(422),
             path
    end
  end

  test "another account's environment never lends its mounts", ctx do
    # A sandbox row naming an environment that is not its owner's (it cannot
    # happen through a launch; the read is scoped regardless).
    other = insert_verified_user()
    foreign_env = insert_env(user_id: other.id)
    mount_repositories(foreign_env, ["/work/theirs"])

    {1, _} =
      Fountain.Repo.update_all(
        from(s in Fountain.Conversations.Sandbox, where: s.id == ^ctx.sandbox.id),
        set: [environment_id: foreign_env.id]
      )

    reject(&Managoat.Sandbox.exec/4)

    assert %{"error" => "path_outside_sandbox"} =
             ctx
             |> get_api("/api/workspaces/#{ctx.workspace.id}/files?path=/work/theirs")
             |> json_response(422)
  end

  test "an implicit sandbox reads under its environment's repository mount", ctx do
    env = insert_env(user_id: ctx.user.id)
    mount_repositories(env, ["/work/app"])

    implicit_sandbox =
      insert_sandbox(user_id: ctx.user.id, environment_id: env.id, status: "ready")

    insert_conversation(
      user_id: ctx.user.id,
      agent: insert_agent(user_id: ctx.user.id, runtime: "codex"),
      sandbox: implicit_sandbox,
      cwd: "/work/app",
      status: "idle"
    )

    exec_returns("")

    ctx |> get_api("/api/sandboxes/#{implicit_sandbox.id}/files") |> json_response(200)
    assert_received {:exec_args, ["/work/app" | rest]}
    assert rest == ["/home/sprite", "sandbox:/home/sprite", "/work/app", "mount:/work/app"]
  end

  test "an implicit workspace's sandbox keeps its conversation's directory as the base", ctx do
    # The factory gives a sandbox an implicit workspace of its own.
    implicit_sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

    assert Fountain.Repo.get!(Fountain.Workspaces.Workspace, implicit_sandbox.workspace_id).implicit

    insert_conversation(
      user_id: ctx.user.id,
      agent: insert_agent(user_id: ctx.user.id, runtime: "claude"),
      sandbox: implicit_sandbox,
      cwd: "/home/sprite/solo",
      status: "idle"
    )

    exec_returns("")

    ctx |> get_api("/api/sandboxes/#{implicit_sandbox.id}/files") |> json_response(200)
    assert_received {:exec_args, ["/home/sprite/solo" | _]}
  end
end
