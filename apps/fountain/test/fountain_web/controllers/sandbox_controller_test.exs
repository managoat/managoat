defmodule FountainWeb.SandboxControllerTest do
  use FountainWeb.ConnCase, async: true

  setup do
    user = insert_active_user()
    {_key_record, raw_key} = insert_api_key(user)
    agent = insert_agent(user_id: user.id, runtime: "claude")

    sandbox = insert_sandbox(user_id: user.id, status: "ready", agent_id: agent.id)
    idle = insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "idle")

    busy =
      insert_conversation(user_id: user.id, agent: agent, sandbox: sandbox, status: "running")

    {:ok, user: user, raw_key: raw_key, agent: agent, sandbox: sandbox, idle: idle, busy: busy}
  end

  describe "GET /api/sandboxes" do
    test "lists the caller's machines with the conversations on each", ctx do
      _foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")

      assert [row] =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes")
               |> json_response(200)
               |> Map.fetch!("data")

      assert row["id"] == ctx.sandbox.id
      assert row["agent_id"] == ctx.agent.id
      assert row["status"] == "ready"
      assert Map.fetch!(row, "transition") == nil

      by_id = Map.new(row["conversations"], &{&1["id"], &1})
      assert by_id[ctx.busy.id]["mid_turn"] == true
      assert by_id[ctx.idle.id]["mid_turn"] == false
    end

    test "filters by status and refuses an unknown one", ctx do
      assert [] =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes?status=terminated,failed")
               |> json_response(200)
               |> Map.fetch!("data")

      assert %{"error" => "invalid_status"} =
               ctx.conn
               |> authed_with_key(ctx.raw_key)
               |> get("/api/sandboxes?status=bogus")
               |> json_response(400)
    end
  end

  describe "GET /api/sandboxes/:id" do
    test "exposes unfinished readiness even on a previously ready row", ctx do
      ctx.sandbox
      |> put_lease(transition: "resuming")

      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["status"] == "ready"
      assert data["transition"] == "resuming"
    end

    test "shows one, and a foreign one is not found", ctx do
      data =
        ctx.conn
        |> authed_with_key(ctx.raw_key)
        |> get("/api/sandboxes/#{ctx.sandbox.id}")
        |> json_response(200)
        |> Map.fetch!("data")

      assert data["id"] == ctx.sandbox.id
      assert length(data["conversations"]) == 2

      foreign = insert_sandbox(user_id: insert_active_user().id, status: "ready")

      assert ctx.conn
             |> authed_with_key(ctx.raw_key)
             |> get("/api/sandboxes/#{foreign.id}")
             |> json_response(404)
    end
  end
end
