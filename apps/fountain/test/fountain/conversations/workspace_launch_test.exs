defmodule Fountain.Conversations.WorkspaceLaunchTest do
  @moduledoc """
  ADR 0097, step 5: `POST /api/conversations` with a `workspace_id`. The
  conversation is bound to the workspace's current machine, with the
  workspace's environment and vault, and no new sandbox; the refusals; its
  server attaching now on an awake machine and its prompt waiting for one
  that is not; and the channel resume staying inside the workspace.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations
  alias Fountain.Conversations.{Conversation, Launch, Rebuild, Sandbox, Wake}
  alias Fountain.Workspaces.Workspace

  setup :set_mimic_global

  setup do
    user = insert_verified_user()
    env = insert_env(user_id: user.id)
    vault = insert_vault(user_id: user.id)
    agent = insert_agent(user_id: user.id, runtime: "claude")

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

    {:ok,
     user: user, env: env, vault: vault, agent: agent, workspace: workspace, sandbox: sandbox}
  end

  defp attrs(ctx, extra \\ %{}) do
    Map.merge(
      %{"agent_id" => ctx.agent.id, "user_id" => ctx.user.id, "workspace_id" => ctx.workspace.id},
      extra
    )
  end

  defp started(test) do
    stub(Conversations, :register_server, fn sandbox_id, _spec ->
      send(test, {:started, sandbox_id})
      {:ok, spawn(fn -> Process.sleep(:infinity) end)}
    end)
  end

  describe "into a ready workspace" do
    test "binds the conversation to the workspace's machine, environment and vault", ctx do
      started(self())
      fill_fleet()

      assert {:ok, %Conversation{} = conv} = Launch.start_conversation(attrs(ctx))

      assert conv.sandbox_id == ctx.sandbox.id
      assert conv.workspace_id == ctx.workspace.id
      assert conv.environment_id == ctx.env.id
      assert conv.vault_id == ctx.vault.id
      assert conv.status == "pending"
      assert is_binary(conv.config_home)

      # No machine of its own: the workspace's is the one.
      assert Repo.aggregate(
               from(s in Sandbox, where: s.workspace_id == ^ctx.workspace.id),
               :count
             ) ==
               1

      assert_received {:started, sandbox_id}
      assert sandbox_id == ctx.sandbox.id

      assert [event] =
               Fountain.Audit.list_for_user(ctx.user.id, action_prefix: "conversation.created")

      assert event.metadata["workspace_id"] == ctx.workspace.id
    end

    test "accepts the workspace's own environment and vault named again", ctx do
      started(self())

      assert {:ok, _} =
               Launch.start_conversation(
                 attrs(ctx, %{"environment_id" => ctx.env.id, "vault_id" => ctx.vault.id})
               )
    end

    test "two conversations share the one machine, each with its own config home", ctx do
      started(self())
      {:ok, a} = Launch.start_conversation(attrs(ctx))
      {:ok, b} = Launch.start_conversation(attrs(ctx, %{"cwd" => "/home/sprite/b"}))

      assert a.sandbox_id == b.sandbox_id
      assert a.config_home != b.config_home
      assert b.cwd == "/home/sprite/b"
    end

    # #2999: the workspace's environment's mounts, never the agent's own.
    test "a cwd may lie under the workspace's environment's repository mount", ctx do
      started(self())
      repo = fn mount -> [%{"url" => "https://github.com/example/app", "mount_path" => mount}] end

      ctx.env
      |> Ecto.Changeset.change(repositories: repo.("/work/app"))
      |> Repo.update!()

      own = insert_env(user_id: ctx.user.id, repositories: repo.("/work/agent"))

      agent =
        insert_agent(
          user_id: ctx.user.id,
          runtime: "codex",
          environment_id: own.id,
          allowed_environment_ids: [ctx.env.id]
        )

      ctx = %{ctx | agent: agent}

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"cwd" => "/work/app/web"}))
      assert conv.cwd == "/work/app/web"

      assert {:error, %Ecto.Changeset{errors: [cwd: _]}} =
               Launch.start_conversation(attrs(ctx, %{"cwd" => "/work/agent"}))
    end
  end

  describe "into a workspace that is not ready" do
    test "a provisioning one takes no server yet, and the launch's prompt goes to its wake",
         ctx do
      test = self()
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "pending"})
      reject(&Conversations.register_server/2)

      stub(Wake, :wake_in_background, fn conv_id, {prompt, _meta}, _images ->
        send(test, {:wake, conv_id, prompt})
        :ok
      end)

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"prompt" => "hi"}))
      assert conv.sandbox_id == ctx.sandbox.id
      assert_received {:wake, id, "hi"}
      assert id == conv.id
    end

    test "a failed one is left to the first prompt's wake, which the rebuild path takes", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "failed"})
      reject(&Conversations.register_server/2)
      stub(Wake, :wake_in_background, fn _conv_id, _prompt, _images -> :ok end)

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"prompt" => "hi"}))
      assert conv.sandbox_id == ctx.sandbox.id

      assert {:rebuild, %Sandbox{id: id}} = Rebuild.wake_target(conv, ctx.agent)
      assert id == ctx.sandbox.id
      assert Rebuild.target(conv, Repo.reload!(ctx.sandbox), ctx.agent) == :rebuild
    end

    test "a parked one is not resumed by a launch without a prompt", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      reject(&Conversations.register_server/2)
      reject(&Wake.wake_in_background/3)
      reject(&Fountain.Machines.Machine.ensure_up/2)

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx))
      assert conv.sandbox_id == ctx.sandbox.id
    end

    test "a parked one is woken by the launch's prompt", ctx do
      test = self()
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "suspended"})
      reject(&Conversations.register_server/2)

      stub(Wake, :wake_in_background, fn conv_id, _prompt, _images ->
        send(test, {:wake, conv_id})
        :ok
      end)

      assert {:ok, conv} = Launch.start_conversation(attrs(ctx, %{"prompt" => "hi"}))
      assert_received {:wake, id}
      assert id == conv.id
    end

    test "without a prompt nothing is woken", ctx do
      {:ok, _} = update_sandbox(ctx.sandbox, %{status: "pending"})
      reject(&Conversations.register_server/2)
      reject(&Wake.wake_in_background/3)

      assert {:ok, _} = Launch.start_conversation(attrs(ctx))
    end
  end

  describe "refusals" do
    test "another account's workspace, an implicit one, and a malformed id are not found", ctx do
      other = insert_verified_user()
      foreign = insert_workspace(user_id: other.id, implicit: false, name: "x")
      implicit = insert_workspace(user_id: ctx.user.id)
      reject(&Conversations.register_server/2)

      for id <- [foreign.id, implicit.id, "nope"] do
        assert {:error, :not_found} =
                 Launch.start_conversation(attrs(ctx, %{"workspace_id" => id}))
      end

      refute Repo.exists?(from(c in Conversation, where: c.user_id == ^ctx.user.id))
    end

    test "an environment or vault other than the workspace's", ctx do
      other_env = insert_env(user_id: ctx.user.id)
      other_vault = insert_vault(user_id: ctx.user.id)

      assert {:error, :workspace_fixes_environment} =
               Launch.start_conversation(attrs(ctx, %{"environment_id" => other_env.id}))

      assert {:error, :workspace_fixes_environment} =
               Launch.start_conversation(attrs(ctx, %{"vault_id" => other_vault.id}))
    end

    test "the agent's allowlists apply to the workspace's environment and vault", ctx do
      locked =
        insert_agent(
          user_id: ctx.user.id,
          environment_access: "allowlist",
          allowed_environment_ids: [],
          vault_access: "allowlist",
          allowed_vault_ids: []
        )

      assert {:error, :environment_not_allowed} =
               Launch.start_conversation(attrs(ctx, %{"agent_id" => locked.id}))

      env_only =
        insert_agent(
          user_id: ctx.user.id,
          environment_access: "allowlist",
          allowed_environment_ids: [ctx.env.id],
          vault_access: "allowlist",
          allowed_vault_ids: []
        )

      assert {:error, :vault_not_allowed} =
               Launch.start_conversation(attrs(ctx, %{"agent_id" => env_only.id}))
    end

    test "sandbox_api_access none, a machine name, and a sandbox_id", ctx do
      assert {:error, :invalid_sandbox_api_access} =
               Launch.start_conversation(attrs(ctx, %{"sandbox_api_access" => "none"}))

      assert {:error, :machine_name_with_workspace} =
               Launch.start_conversation(attrs(ctx, %{"machine_name" => "mine"}))

      assert {:error, :sandbox_attach_unsupported} =
               Launch.start_conversation(attrs(ctx, %{"sandbox_id" => ctx.sandbox.id}))
    end

    test "a sandbox's own key may not name a workspace", ctx do
      {key, _raw} = insert_sprite_api_key(ctx.user)

      assert {:error, :insufficient_scope} =
               Launch.start_conversation(attrs(ctx), sandbox_key_id: key.id)

      assert {:error, :insufficient_scope} =
               Launch.start_or_resume_conversation(attrs(ctx, %{"channel_id" => "c"}),
                 sandbox_key_id: key.id
               )
    end

    test "a workspace being deleted", ctx do
      {1, _} =
        Repo.update_all(from(w in Workspace, where: w.id == ^ctx.workspace.id),
          set: [user_id: nil]
        )

      assert {:error, :not_found} = Launch.start_conversation(attrs(ctx))
    end

    test "a machine being destroyed", ctx do
      put_lease(ctx.sandbox, transition: "destroying", transition_reason: "workspace_deleted")
      assert {:error, :sandbox_reset_pending} = Launch.start_conversation(attrs(ctx))
    end
  end

  describe "a channel" do
    test "resumes only a conversation in the workspace it names", ctx do
      started(self())

      {:ok, in_ws, :created} =
        Launch.start_or_resume_conversation(attrs(ctx, %{"channel_id" => "c1"}))

      assert {:ok, resumed, :resumed} =
               Launch.start_or_resume_conversation(attrs(ctx, %{"channel_id" => "c1"}))

      assert resumed.id == in_ws.id

      # The same channel without the workspace asks for a machine of its own,
      # and does not land in the workspace.
      assert {:ok, other, :created} =
               Launch.start_or_resume_conversation(%{
                 "agent_id" => ctx.agent.id,
                 "user_id" => ctx.user.id,
                 "channel_id" => "c1",
                 "environment_id" => ctx.env.id,
                 "vault_id" => ctx.vault.id
               })

      assert other.id != in_ws.id
      assert other.workspace_id != ctx.workspace.id
      assert other.sandbox_id != ctx.sandbox.id
    end

    test "a resume into the workspace refuses a machine name too", ctx do
      started(self())

      {:ok, _conv, :created} =
        Launch.start_or_resume_conversation(attrs(ctx, %{"channel_id" => "c3"}))

      assert {:error, :machine_name_with_workspace} =
               Launch.start_or_resume_conversation(
                 attrs(ctx, %{"channel_id" => "c3", "machine_name" => "mine"})
               )
    end

    test "a rotation replaces the binding under the workspace's lock", ctx do
      started(self())

      {:ok, old, :created} =
        Launch.start_or_resume_conversation(attrs(ctx, %{"channel_id" => "c4"}))

      assert {:ok, fresh, :created} =
               Launch.start_or_resume_conversation(
                 attrs(ctx, %{"channel_id" => "c4", "fresh" => true})
               )

      assert fresh.id != old.id
      assert Repo.reload!(old).channel_id == nil
      assert Repo.reload!(fresh).channel_id == "c4"
    end

    test "is refused a different environment than the workspace's", ctx do
      started(self())
      other_env = insert_env(user_id: ctx.user.id)

      assert {:error, :workspace_fixes_environment} =
               Launch.start_or_resume_conversation(
                 attrs(ctx, %{"channel_id" => "c2", "environment_id" => other_env.id})
               )
    end
  end
end
