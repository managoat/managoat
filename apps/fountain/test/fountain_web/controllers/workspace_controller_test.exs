defmodule FountainWeb.WorkspaceControllerTest do
  @moduledoc """
  `/api/workspaces` (ADR 0097, step 5): create, list, show and delete,
  scoped by the caller and refused to a sandbox's own key; and the `409` on
  deleting an environment or vault a workspace names.
  """

  use FountainWeb.ConnCase, async: false
  use Mimic

  import Ecto.Query, only: [from: 2]
  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.Workspace

  setup do
    user = insert_active_user()
    {_record, raw_key} = insert_api_key(user)
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)

    # The provision on create runs in `workspace_provision_test.exs`'s terms;
    # here it is started and nothing more.
    stub(Provisioner, :start, fn _workspace, _sandbox_id -> {:ok, self()} end)
    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    {:ok, user: user, raw_key: raw_key, env: env, vault: vault}
  end

  defp api(ctx, key \\ nil), do: ctx.conn |> authed_with_key(key || ctx.raw_key)

  defp create!(ctx, extra \\ %{}) do
    api(ctx)
    |> post_json(
      "/api/workspaces",
      Map.merge(%{"name" => "work", "environment_id" => ctx.env.id}, extra)
    )
    |> json_response(201)
    |> Map.fetch!("data")
  end

  describe "POST /api/workspaces" do
    test "answers 201 provisioning and audits the caller", ctx do
      data = create!(ctx, %{"vault_id" => ctx.vault.id})

      assert data["status"] == "provisioning"
      assert data["implicit"] == false
      assert data["name"] == "work"
      assert data["environment_id"] == ctx.env.id
      assert data["vault_id"] == ctx.vault.id
      assert data["sandbox_provider"] == "sprites"
      assert data["error"] == nil
      assert data["sandbox_status"] == "pending"
      assert is_binary(data["sandbox_id"])

      assert [event] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.created")
      assert event.actor == "api"
    end

    test "another account's environment or vault is 404", ctx do
      other = insert_active_user()
      foreign_env = insert_env(user_id: other.id)
      foreign_vault = insert_vault(user_id: other.id)

      assert %{"error" => "environment_not_found"} =
               api(ctx)
               |> post_json("/api/workspaces", %{
                 "name" => "w",
                 "environment_id" => foreign_env.id
               })
               |> json_response(404)

      assert %{"error" => "vault_not_found"} =
               api(ctx)
               |> post_json("/api/workspaces", %{
                 "name" => "w",
                 "environment_id" => ctx.env.id,
                 "vault_id" => foreign_vault.id
               })
               |> json_response(404)

      assert Workspaces.list_workspaces(ctx.user.id) == []
    end

    test "a name and an environment are required", ctx do
      api(ctx) |> post_json("/api/workspaces", %{"name" => "w"}) |> json_response(422)

      api(ctx)
      |> post_json("/api/workspaces", %{"environment_id" => ctx.env.id})
      |> json_response(422)
    end

    test "a provider this instance has not enabled is 422, about the workspace's provider",
         ctx do
      refute Fountain.SandboxProviders.enabled?(:e2b)

      assert %{"error" => "sandbox_provider_disabled", "message" => message} =
               api(ctx)
               |> post_json("/api/workspaces", %{
                 "name" => "w",
                 "environment_id" => ctx.env.id,
                 "sandbox_provider" => "e2b"
               })
               |> json_response(422)

      assert message =~ "sandbox provider e2b"
      assert message =~ "create the workspace with another sandbox_provider"
      refute message =~ "agent"
      assert Workspaces.list_workspaces(ctx.user.id) == []
    end

    test "a full fleet is 503 fleet_full", ctx do
      fill_fleet()

      assert %{"error" => "fleet_full"} =
               api(ctx)
               |> post_json("/api/workspaces", %{"name" => "w", "environment_id" => ctx.env.id})
               |> json_response(503)
    end
  end

  describe "GET /api/workspaces" do
    test "lists the caller's explicit workspaces, and implicit ones when asked", ctx do
      data = create!(ctx)
      implicit = insert_workspace(user_id: ctx.user.id)
      _foreign = insert_workspace(user_id: insert_active_user().id, implicit: false, name: "x")

      assert [%{"id" => id}] =
               api(ctx) |> get("/api/workspaces") |> json_response(200) |> Map.fetch!("data")

      assert id == data["id"]

      ids =
        api(ctx)
        |> get("/api/workspaces?implicit=true")
        |> json_response(200)
        |> Map.fetch!("data")
        |> Enum.map(& &1["id"])
        |> MapSet.new()

      assert ids == MapSet.new([data["id"], implicit.id])
    end
  end

  describe "GET /api/workspaces/:id" do
    test "shows the caller's, and another account's is 404", ctx do
      data = create!(ctx)
      foreign = insert_workspace(user_id: insert_active_user().id, implicit: false, name: "x")

      assert %{"data" => %{"id" => id}} =
               api(ctx) |> get("/api/workspaces/#{data["id"]}") |> json_response(200)

      assert id == data["id"]

      assert %{"error" => "not_found"} =
               api(ctx) |> get("/api/workspaces/#{foreign.id}") |> json_response(404)

      api(ctx) |> get("/api/workspaces/not-a-uuid") |> json_response(404)
    end

    test "a failed workspace carries its error, and a lost machine reads as none", ctx do
      data = create!(ctx)
      sandbox = Repo.get!(Sandbox, data["sandbox_id"])
      {:ok, _} = update_sandbox(sandbox, %{status: "failed"})

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^data["id"]),
          set: [status: "failed", error: "the environment's setup script exited 1"]
        )

      body =
        api(ctx)
        |> get("/api/workspaces/#{data["id"]}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert body["status"] == "failed"
      assert body["error"] =~ "exited 1"
      assert body["sandbox_status"] == nil
      assert body["sandbox_id"] == nil
      assert body["built_from_revision"] == nil
      assert body["stale"] == false
    end

    test "says which revision its machine was built from and which fields moved since (#2987)",
         ctx do
      data = create!(ctx)
      assert data["revision"] == ctx.env.revision
      # Not built yet: nothing recorded.
      assert data["built_from_revision"] == nil
      assert data["stale"] == false
      assert data["changed_fields"] == []

      sandbox = Repo.get!(Sandbox, data["sandbox_id"])

      sandbox
      |> Ecto.Changeset.change(
        Map.put(Fountain.Workspaces.Staleness.built_from(ctx.env), :status, "ready")
      )
      |> Repo.update!()

      {:ok, edited} =
        Fountain.Environments.update_environment(ctx.env, %{
          env_vars: %{"API_TOKEN" => "tok-very-private-value"},
          name: "renamed"
        })

      raw = api(ctx) |> get("/api/workspaces/#{data["id"]}") |> response(200)
      refute raw =~ "tok-very-private-value"
      refute raw =~ "API_TOKEN"

      body = Jason.decode!(raw)["data"]
      assert body["built_from_revision"] == ctx.env.revision
      assert body["revision"] == edited.revision
      assert body["stale"] == true
      assert body["changed_fields"] == ["env_vars"]

      assert %{"data" => [listed]} =
               api(ctx) |> get("/api/workspaces") |> json_response(200)

      assert Map.take(listed, ~w(revision built_from_revision stale changed_fields)) ==
               Map.take(body, ~w(revision built_from_revision stale changed_fields))
    end
  end

  describe "DELETE /api/workspaces/:id" do
    test "ends its conversations and destroys its machine", ctx do
      data = create!(ctx)
      sandbox = Repo.get!(Sandbox, data["sandbox_id"])
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})
      agent = insert_agent(user_id: ctx.user.id)

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: agent,
          sandbox: sandbox,
          workspace_id: data["id"],
          status: "idle"
        )

      capture_log(fn ->
        assert api(ctx) |> delete("/api/workspaces/#{data["id"]}") |> response(204)
      end)

      assert Repo.reload!(conv).status == "terminated"
      assert Repo.reload!(sandbox).status == "terminated"
      refute Repo.get(Workspace, data["id"])
      api(ctx) |> get("/api/workspaces/#{data["id"]}") |> json_response(404)

      assert [%{actor: "api"}] =
               Audit.list_for_user(ctx.user.id, action_prefix: "workspace.deleted")
    end

    test "another account's workspace, and an implicit one, are 404", ctx do
      foreign = insert_workspace(user_id: insert_active_user().id, implicit: false, name: "x")
      implicit = insert_workspace(user_id: ctx.user.id)

      api(ctx) |> delete("/api/workspaces/#{foreign.id}") |> json_response(404)
      api(ctx) |> delete("/api/workspaces/#{implicit.id}") |> json_response(404)
      assert Repo.get(Workspace, foreign.id)
      assert Repo.get(Workspace, implicit.id)
    end
  end

  describe "POST /api/workspaces/:id/rebuild" do
    # A workspace whose setup finished, with a conversation on its machine.
    setup ctx do
      data = create!(ctx)
      sandbox = Repo.get!(Sandbox, data["sandbox_id"])
      {:ok, sandbox} = update_sandbox(sandbox, %{status: "ready"})

      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^data["id"]), set: [status: "ready"])

      conv =
        insert_conversation(
          user_id: ctx.user.id,
          agent: insert_agent(user_id: ctx.user.id),
          sandbox: sandbox,
          workspace_id: data["id"],
          status: "idle"
        )

      {:ok, workspace: data, sandbox: sandbox, conv: conv}
    end

    defp rebuild!(ctx, body, status) do
      capture_log(fn ->
        send(
          self(),
          {:body,
           api(ctx)
           |> post_json("/api/workspaces/#{ctx.workspace["id"]}/rebuild", body)
           |> json_response(status)}
        )
      end)

      assert_received {:body, body}
      body
    end

    test "answers 202 provisioning, moves the conversation and audits the caller", ctx do
      assert %{"data" => data} = rebuild!(ctx, %{}, 202)
      assert data["status"] == "provisioning"
      assert data["sandbox_status"] == "pending"
      assert data["sandbox_id"] != ctx.sandbox.id

      assert Repo.reload!(ctx.conv).sandbox_id == data["sandbox_id"]
      assert Repo.reload!(ctx.sandbox).status == "terminated"

      assert [%{actor: "api"}] =
               Audit.list_for_user(ctx.user.id, action_prefix: "workspace.rebuilt")

      # A second one while it builds.
      assert %{"error" => "rebuild_in_progress"} = rebuild!(ctx, %{}, 409)
    end

    test "a running turn is 409 turns_running, and interrupt: true gets past it", ctx do
      {:ok, conv} = Fountain.Conversations.update_conversation(ctx.conv, %{status: "running"})
      turn = insert_turn(conv, status: "running")

      assert %{"error" => "turns_running", "conversation_ids" => [id], "message" => _} =
               rebuild!(ctx, %{}, 409)

      assert id == conv.id
      assert Repo.reload!(ctx.sandbox).status == "ready"

      assert %{"data" => %{"status" => "provisioning"}} =
               rebuild!(ctx, %{"interrupt" => true}, 202)

      assert Repo.reload!(turn).status == "interrupted"
    end

    test "another account's workspace, and an implicit one, are 404", ctx do
      foreign = insert_workspace(user_id: insert_active_user().id, implicit: false, name: "x")
      implicit = insert_workspace(user_id: ctx.user.id)

      for id <- [foreign.id, implicit.id, "not-a-uuid"] do
        assert %{"error" => "not_found"} =
                 api(ctx) |> post_json("/api/workspaces/#{id}/rebuild", %{}) |> json_response(404)
      end
    end
  end

  describe "a sandbox's own key" do
    test "may not create, list, show or delete workspaces", ctx do
      data = create!(ctx)
      {_record, sprite} = insert_sprite_api_key(ctx.user)

      for {method, path, body} <- [
            {:post, "/api/workspaces", %{"name" => "w", "environment_id" => ctx.env.id}},
            {:get, "/api/workspaces", nil},
            {:get, "/api/workspaces/#{data["id"]}", nil},
            {:delete, "/api/workspaces/#{data["id"]}", nil},
            {:post, "/api/workspaces/#{data["id"]}/rebuild", %{"interrupt" => true}}
          ] do
        conn =
          api(ctx, sprite)
          |> put_req_header("content-type", "application/json")
          |> dispatch(@endpoint, method, path, body && Jason.encode!(body))

        assert %{
                 "error" => "insufficient_scope",
                 "reason" => "insufficient_scope",
                 "required_scope" => "full",
                 "message" => <<_, _::binary>>
               } = json_response(conn, 403),
               "#{method} #{path}"
      end

      assert Repo.get(Workspace, data["id"])
    end
  end

  describe "POST /api/conversations with workspace_id" do
    setup ctx do
      data = create!(ctx)
      {:ok, _} = update_sandbox(Repo.get!(Sandbox, data["sandbox_id"]), %{status: "ready"})

      stub(Fountain.Conversations, :register_server, fn _sandbox_id, _spec ->
        {:ok, spawn(fn -> Process.sleep(:infinity) end)}
      end)

      %{workspace: data, agent: insert_agent(user_id: ctx.user.id)}
    end

    test "runs the conversation on the workspace's machine", ctx do
      body =
        api(ctx)
        |> post_json("/api/conversations", %{
          "agent_id" => ctx.agent.id,
          "workspace_id" => ctx.workspace["id"]
        })
        |> json_response(201)
        |> Map.fetch!("data")

      assert body["workspace_id"] == ctx.workspace["id"]
      assert body["sandbox_id"] == ctx.workspace["sandbox_id"]
      assert body["environment_id"] == ctx.env.id
    end

    test "is refused to a sandbox's own key, a differing environment, and none", ctx do
      {_record, sprite} = insert_sprite_api_key(ctx.user)
      body = %{"agent_id" => ctx.agent.id, "workspace_id" => ctx.workspace["id"]}

      assert %{
               "error" => "insufficient_scope",
               "reason" => "insufficient_scope",
               "required_scope" => "full",
               "message" => "This API key is not permitted to use workspaces"
             } = api(ctx, sprite) |> post_json("/api/conversations", body) |> json_response(403)

      other_env = insert_env(user_id: ctx.user.id)

      assert %{"error" => "workspace_fixes_environment"} =
               api(ctx)
               |> post_json("/api/conversations", Map.put(body, "environment_id", other_env.id))
               |> json_response(422)

      assert %{"error" => "invalid_sandbox_api_access"} =
               api(ctx)
               |> post_json("/api/conversations", Map.put(body, "sandbox_api_access", "none"))
               |> json_response(422)

      foreign = insert_workspace(user_id: insert_active_user().id, implicit: false, name: "x")

      assert %{"error" => "not_found"} =
               api(ctx)
               |> post_json("/api/conversations", Map.put(body, "workspace_id", foreign.id))
               |> json_response(404)
    end

    test "sandbox_id still says to use a workspace", ctx do
      assert %{"error" => "sandbox_attach_unsupported", "message" => message} =
               api(ctx)
               |> post_json("/api/conversations", %{
                 "agent_id" => ctx.agent.id,
                 "sandbox_id" => ctx.workspace["sandbox_id"]
               })
               |> json_response(422)

      assert message =~ "workspace_id"
    end
  end

  describe "deleting what a workspace was created from" do
    test "an environment or vault a workspace names is 409 while it exists", ctx do
      data = create!(ctx, %{"vault_id" => ctx.vault.id})

      assert %{"error" => "source_in_use_by_workspace"} =
               api(ctx) |> delete("/api/environments/#{ctx.env.id}") |> json_response(409)

      assert %{"error" => "source_in_use_by_workspace"} =
               api(ctx) |> delete("/api/vaults/#{ctx.vault.id}") |> json_response(409)

      capture_log(fn -> api(ctx) |> delete("/api/workspaces/#{data["id"]}") |> response(204) end)

      assert api(ctx) |> delete("/api/environments/#{ctx.env.id}") |> response(204)
      assert api(ctx) |> delete("/api/vaults/#{ctx.vault.id}") |> response(204)
    end

    test "an implicit workspace does not hold its environment", ctx do
      _implicit = insert_workspace(user_id: ctx.user.id, environment_id: ctx.env.id)
      assert api(ctx) |> delete("/api/environments/#{ctx.env.id}") |> response(204)
    end
  end
end
