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

    {:ok,
     user: user,
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
    foreign = insert_workspace(user_id: insert_verified_user().id, implicit: false, name: "x")
    reject(&Managoat.Sandbox.exec/4)

    for route <- ["files", "file?path=x", "diff", "git-status"] do
      assert %{"error" => "not_found"} =
               ctx |> get_api("/api/workspaces/#{foreign.id}/#{route}") |> json_response(404)

      assert %{"reason" => "insufficient_scope", "required_scope" => "full"} =
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

  test "an implicit workspace's sandbox keeps its conversation's directory as the base", ctx do
    implicit_sandbox = insert_sandbox(user_id: ctx.user.id, status: "ready")

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
