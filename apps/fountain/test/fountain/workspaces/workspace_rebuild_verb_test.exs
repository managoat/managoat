defmodule Fountain.Workspaces.WorkspaceRebuildVerbTest do
  @moduledoc """
  #2986: `Workspaces.rebuild_workspace/2`, the "Sandbox lost" transition done
  on purpose. The machine is replaced through its owner, every live
  conversation follows with its transcript kept and its session cleared,
  the old machine is destroyed, the workspace's own provision builds the new
  one from the environment as it is now, and `stale` clears. A running turn
  refuses it unless `interrupt: true`; a second rebuild is refused while one
  builds; an implicit workspace is not found.
  """

  use Fountain.DataCase, async: false
  use Mimic

  import ExUnit.CaptureLog

  alias Fountain.Audit
  alias Fountain.Conversations.{Sandbox, Turn}
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Provisioner
  alias Fountain.Workspaces.Workspace
  alias Managoat.Sandbox.Handle

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id, setup_script: "make setup")
    test = self()

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn handle ->
      send(test, {:destroyed, handle.name})
      :ok
    end)

    stub(Managoat.Sandbox, :write_file, fn _h, _p, _b, _o -> :ok end)
    stub(Managoat.Sandbox, :apply_network_policy, fn _h, _p -> :ok end)
    stub(Fountain.Broker.TransportRelay, :ensure, fn _h, _o -> :ok end)
    stub(Managoat.Sandbox, :exec, fn _h, _c, _a, _o -> {:ok, "", 0} end)

    # The provision is driven synchronously where a test needs it.
    stub(Provisioner, :start, fn workspace, sandbox_id ->
      send(test, {:provision_started, workspace.id, sandbox_id})
      {:ok, self()}
    end)

    {:ok, workspace} =
      Workspaces.create_workspace(user.id, %{"name" => "w", "environment_id" => env.id},
        actor: "api"
      )

    assert_receive {:provision_started, _, first_id}
    capture_log(fn -> {:ok, :provisioned, :set_up} = Provisioner.run(workspace.id, first_id) end)

    {:ok,
     user: user, env: env, workspace: Repo.reload!(workspace), old: Repo.get!(Sandbox, first_id)}
  end

  defp conversation(ctx, status \\ "idle") do
    conv = insert_conversation(user_id: ctx.user.id, sandbox: ctx.old, status: status)
    conv |> Ecto.Changeset.change(runtime_session_id: "old-session") |> Repo.update!()
  end

  defp rebuild(ctx, opts \\ []) do
    capture_log(fn ->
      send(self(), {:result, Workspaces.rebuild_workspace(ctx.workspace, opts ++ [actor: "api"])})
    end)

    assert_received {:result, result}
    result
  end

  test "replaces the machine, moves every conversation, and builds from the environment now",
       ctx do
    first = conversation(ctx)
    second = conversation(ctx)
    insert_log_event(first)
    old_name = ctx.old.machine_name
    :ok = Workspaces.subscribe(ctx.user.id)

    {:ok, edited} =
      Fountain.Environments.update_environment(ctx.env, %{setup_script: "make other"})

    assert_receive {:workspace_status, %{stale: true, changed_fields: ["setup_script"]}}

    assert {:ok, %Workspace{status: "provisioning"}} = rebuild(ctx)
    assert_receive {:workspace_status, %{status: "provisioning"}}
    assert_received {:destroyed, ^old_name}
    assert_received {:provision_started, _, next_id}

    assert Repo.reload!(ctx.old).status == "terminated"
    next = Repo.get!(Sandbox, next_id)
    assert next.workspace_id == ctx.workspace.id
    assert next.status == "pending"
    assert next.machine_name != old_name

    for conv <- [first, second] do
      moved = Repo.reload!(conv)
      assert moved.sandbox_id == next.id
      assert moved.workspace_id == ctx.workspace.id
      assert moved.runtime_session_id == nil
      assert moved.status == "idle"
    end

    # The transcript is kept.
    assert Fountain.Conversations._unsafe_list_log_events(first.id) != []

    # The workspace's own provision builds it, from the environment as edited.
    capture_log(fn ->
      {:ok, :provisioned, :set_up} = Provisioner.run(ctx.workspace.id, next.id)
    end)

    assert %Workspace{status: "ready"} = Repo.reload!(ctx.workspace)
    assert Repo.reload!(next).built_from_revision == edited.revision

    assert_receive {:workspace_status,
                    %{status: "ready", stale: false, changed_fields: [], revision: rev}}

    assert rev == edited.revision

    assert [event] = Audit.list_for_user(ctx.user.id, action_prefix: "workspace.rebuilt")
    assert event.actor == "api"
    assert event.metadata["previous_sandbox_id"] == ctx.old.id
    assert event.metadata["sandbox_id"] == next.id

    assert [destroyed] = Audit.list_for_user(ctx.user.id, action_prefix: "sandbox.destroyed")
    assert destroyed.actor == "api"
    assert destroyed.metadata["reason"] == "replaced"
  end

  test "a running turn refuses it, and nothing moves", ctx do
    conv = conversation(ctx, "running")
    turn = insert_turn(conv, status: "running")

    assert {:error, {:turns_running, [id]}} = rebuild(ctx)
    assert id == conv.id

    assert Repo.reload!(ctx.old).status == "ready"
    assert Repo.reload!(conv).sandbox_id == ctx.old.id
    assert Repo.reload!(turn).status == "running"
    assert %Workspace{status: "ready"} = Repo.reload!(ctx.workspace)
    refute_received {:destroyed, _}
    refute_received {:provision_started, _, _}
    assert Audit.list_for_user(ctx.user.id, action_prefix: "workspace.rebuilt") == []
  end

  test "interrupt: true ends the running turns as interrupted and keeps the transcripts", ctx do
    conv = conversation(ctx, "running")
    turn = insert_turn(conv, status: "running")

    assert {:ok, %Workspace{status: "provisioning"}} = rebuild(ctx, interrupt: true)

    assert %Turn{status: "interrupted"} = Repo.reload!(turn)
    moved = Repo.reload!(conv)
    assert moved.status == "idle"
    assert moved.sandbox_id != ctx.old.id

    # A client following the turn hears it end, and the caller is on the trail.
    assert Enum.any?(Fountain.Conversations._unsafe_list_log_events(conv.id), fn e ->
             e.kind == "stage" and e.stage == "turn" and e.state == "interrupted" and
               Jason.decode!(e.data)["reason"] == "machine_destroyed"
           end)

    assert [orphaned] =
             Audit.list_for_user(ctx.user.id, action_prefix: "conversation.turn.orphaned")

    assert orphaned.actor == "api"
    assert orphaned.resource_id == turn.id
  end

  test "interrupt: true with a refusal (a full fleet) ends no turn", ctx do
    conv = conversation(ctx, "running")
    turn = insert_turn(conv, status: "running")
    fill_fleet(-1)

    assert {:error, :fleet_full} = rebuild(ctx, interrupt: true)
    assert Repo.reload!(turn).status == "running"
    assert Repo.reload!(conv).sandbox_id == ctx.old.id
    assert Repo.reload!(ctx.old).status == "ready"
  end

  test "a workspace left provisioning with nobody building is rebuilt by starting its build",
       ctx do
    stub(Provisioner, :start, fn _workspace, _id -> {:error, :boom} end)
    assert {:ok, _} = rebuild(ctx)
    workspace = Repo.reload!(ctx.workspace)
    assert workspace.status == "provisioning"

    test = self()

    stub(Provisioner, :start, fn w, id ->
      send(test, {:resumed, w.id, id})
      {:ok, self()}
    end)

    assert {:ok, %Workspace{status: "provisioning"}} = rebuild(%{ctx | workspace: workspace})
    assert_received {:resumed, _, pending_id}
    assert Repo.get!(Sandbox, pending_id).status == "pending"

    assert ctx.user.id
           |> Audit.list_for_user(action_prefix: "workspace.rebuilt")
           |> Enum.any?(&(&1.metadata["resumed"] == true))
  end

  test "a second rebuild while one builds is rebuild_in_progress", ctx do
    assert {:ok, _} = rebuild(ctx)
    workspace = Repo.reload!(ctx.workspace)
    # Its provision is running (the stubbed start ran nothing).
    stub(Provisioner, :running?, fn id -> id == workspace.id end)
    assert {:error, :rebuild_in_progress} = rebuild(%{ctx | workspace: workspace})
  end

  test "two at once rebuild once", ctx do
    test = self()

    results =
      for _ <- 1..2 do
        Task.async(fn ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test, self())
          Workspaces.rebuild_workspace(ctx.workspace, actor: "api")
        end)
      end
      |> Enum.map(&Task.await(&1, 15_000))

    assert Enum.count(results, &match?({:ok, _}, &1)) == 1
    assert Enum.count(results, &(&1 == {:error, :rebuild_in_progress})) == 1

    assert Repo.aggregate(
             from(s in Sandbox,
               where:
                 s.workspace_id == ^ctx.workspace.id and s.status not in ~w(terminated failed)
             ),
             :count
           ) == 1
  end

  test "rebuilds a failed workspace, with nothing left to destroy at the provider", ctx do
    {1, _} =
      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.old.id), set: [status: "failed"])

    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
        set: [status: "failed", error: "the environment's setup script exited 1"]
      )

    conv = conversation(ctx)
    workspace = Repo.reload!(ctx.workspace)

    assert {:ok, %Workspace{status: "provisioning", error: nil}} =
             rebuild(%{ctx | workspace: workspace})

    refute_received {:destroyed, _}
    assert_received {:provision_started, _, next_id}
    assert Repo.reload!(conv).sandbox_id == next_id
  end

  test "a full fleet refuses it and moves nothing", ctx do
    conv = conversation(ctx)

    {1, _} =
      Repo.update_all(from(s in Sandbox, where: s.id == ^ctx.old.id), set: [status: "failed"])

    {1, _} =
      Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
        set: [status: "failed"]
      )

    fill_fleet()

    assert {:error, :fleet_full} = rebuild(%{ctx | workspace: Repo.reload!(ctx.workspace)})
    assert Repo.reload!(conv).sandbox_id == ctx.old.id
  end

  test "an implicit workspace, or one being deleted, is not found", ctx do
    implicit = insert_workspace(user_id: ctx.user.id)
    assert {:error, :not_found} = Workspaces.rebuild_workspace(implicit, actor: "api")

    ownerless = %{ctx.workspace | user_id: nil}
    assert {:error, :not_found} = Workspaces.rebuild_workspace(ownerless, actor: "api")
  end

  test "a machine another operation holds is sandbox_unavailable", ctx do
    stub(Fountain.Machines.Machine, :replace, fn _id, _opts -> {:error, :machine_busy} end)
    assert {:error, :sandbox_unavailable} = rebuild(ctx)
  end

  test "never touches the vault", ctx do
    vault = insert_vault(user_id: ctx.user.id)
    before = Repo.reload!(vault)
    assert {:ok, _} = rebuild(ctx)
    assert Repo.reload!(vault) == before

    assert ctx.user.id
           |> Audit.list_for_user(action_prefix: "vault.")
           |> Enum.map(& &1.action) == ["vault.created"]
  end

  test "each moved conversation's transcript is told the workspace is being rebuilt", ctx do
    conv = conversation(ctx)
    assert {:ok, _} = rebuild(ctx)

    assert Enum.any?(Fountain.Conversations._unsafe_list_log_events(conv.id), fn e ->
             e.kind == "stage" and e.stage == "sandbox" and
               Jason.decode!(e.data)["message"] =~ "being rebuilt"
           end)
  end
end
