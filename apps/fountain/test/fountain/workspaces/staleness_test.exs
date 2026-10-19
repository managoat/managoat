defmodule Fountain.Workspaces.StalenessTest do
  @moduledoc """
  #2987: an environment's `revision` moves on every edit of a provision-time
  field and on nothing else; every provision records the revision it built
  from and a keyed digest per field, never a value; a workspace reads as
  `stale` with the names of the fields that differ; and an edit that moves
  the revision tells each ready explicit workspace's clients.
  """

  use Fountain.DataCase, async: false
  use Mimic

  alias Fountain.Conversations.Sandbox
  alias Fountain.Environments
  alias Fountain.Environments.Environment
  alias Fountain.Machines.Provision
  alias Fountain.Workspaces
  alias Fountain.Workspaces.Staleness
  alias Managoat.Sandbox.Handle

  setup :set_mimic_global

  setup do
    user = insert_verified_user()

    env =
      insert_env(
        user_id: user.id,
        setup_script: "make setup",
        env_vars: %{"REGION" => "eu", "FLAG" => "1"},
        packages: %{"apt" => ["jq"]}
      )

    stub(Managoat.Sandbox, :create, fn provider, name ->
      {:ok, %Handle{provider: provider, name: name}}
    end)

    stub(Managoat.Sandbox, :destroy, fn _handle -> :ok end)

    {:ok, user: user, env: env}
  end

  defp edit!(env, attrs) do
    {:ok, env} = Environments.update_environment(env, attrs)
    env
  end

  # A machine built from `env`, as a provision records it, in a workspace of
  # the given kind.
  defp built_sandbox(user, env, opts \\ []) do
    workspace =
      insert_workspace(
        user_id: user.id,
        environment_id: env.id,
        implicit: Keyword.get(opts, :implicit, false),
        name: "w-#{System.unique_integer([:positive])}",
        status: Keyword.get(opts, :status, "ready")
      )

    sandbox =
      insert_sandbox(
        user_id: user.id,
        workspace_id: workspace.id,
        environment_id: env.id,
        status: Keyword.get(opts, :sandbox_status, "ready")
      )

    sandbox =
      sandbox
      |> Ecto.Changeset.change(Staleness.built_from(Repo.reload!(env)))
      |> Repo.update!()

    {workspace, sandbox}
  end

  describe "an environment's revision" do
    test "moves on each provision-time field and on nothing else", ctx do
      env = ctx.env
      assert is_binary(env.revision)

      for {field, value} <- [
            repositories: [%{"url" => "https://example.com/r.git", "mount_path" => "/r"}],
            packages: %{"apt" => ["jq", "curl"]},
            setup_script: "make other",
            setup_timeout_seconds: 300,
            env_vars: %{"REGION" => "us"},
            networking_type: "limited",
            networking_config: %{"allowed_hosts" => ["example.com"]}
          ] do
        before = Repo.reload!(env).revision
        edited = edit!(Repo.reload!(env), %{field => value})
        assert edited.revision != before, "#{field} did not move the revision"
        assert Repo.reload!(env).revision == edited.revision
      end

      before = Repo.reload!(env).revision
      edit!(Repo.reload!(env), %{name: "renamed", metadata: %{"k" => "v"}})
      assert Repo.reload!(env).revision == before

      insert_secret(Repo.reload!(env), %{"key" => "TOKEN", "value" => "s3cret"})
      assert Repo.reload!(env).revision == before

      # Saving the same values again moves nothing.
      same = Repo.reload!(env)
      edit!(same, %{setup_script: same.setup_script, env_vars: same.env_vars})
      assert Repo.reload!(env).revision == before
    end

    test "moves for a write that goes around the context, and cannot be written", ctx do
      before = ctx.env.revision

      {1, _} =
        Repo.update_all(from(e in Environment, where: e.id == ^ctx.env.id),
          set: [setup_script: "raw"]
        )

      moved = Repo.reload!(ctx.env).revision
      assert moved != before

      {1, _} =
        Repo.update_all(from(e in Environment, where: e.id == ^ctx.env.id),
          set: [revision: Ecto.UUID.generate()]
        )

      assert Repo.reload!(ctx.env).revision == moved
    end
  end

  describe "of/2" do
    test "a machine built from the environment as it is is not stale", ctx do
      {_workspace, sandbox} = built_sandbox(ctx.user, ctx.env)

      assert %{stale: false, changed_fields: [], built_from_revision: rev, revision: rev} =
               Staleness.of(sandbox, Repo.reload!(ctx.env))

      assert rev == ctx.env.revision
    end

    test "names the fields that differ, and a revert is not stale", ctx do
      {_workspace, sandbox} = built_sandbox(ctx.user, ctx.env)

      edited = edit!(ctx.env, %{setup_script: "make other", env_vars: %{"REGION" => "us"}})

      assert %{stale: true, changed_fields: ["setup_script", "env_vars"]} =
               Staleness.of(sandbox, edited)

      reverted = edit!(edited, %{setup_script: "make setup", env_vars: ctx.env.env_vars})
      assert reverted.revision != sandbox.built_from_revision

      assert %{stale: false, changed_fields: [], built_from_revision: built} =
               Staleness.of(sandbox, reverted)

      assert built == sandbox.built_from_revision
    end

    test "says nothing for no record, no live machine or no machine", ctx do
      {_workspace, sandbox} = built_sandbox(ctx.user, ctx.env)
      edited = edit!(ctx.env, %{setup_script: "changed"})

      unrecorded = %{sandbox | built_from_revision: nil, built_from_digests: nil}
      ended = %{sandbox | status: "terminated"}

      for machine <- [unrecorded, ended, nil] do
        assert %{stale: false, changed_fields: [], built_from_revision: nil} =
                 Staleness.of(machine, edited)
      end
    end

    test "key order and atom keys do not read as a change", ctx do
      {_workspace, sandbox} = built_sandbox(ctx.user, ctx.env)
      env = Repo.reload!(ctx.env)

      reordered = %{
        env
        | revision: Ecto.UUID.generate(),
          env_vars: %{FLAG: "1", REGION: "eu"},
          packages: %{apt: ["jq"]}
      }

      assert %{stale: false} = Staleness.of(sandbox, reordered)
    end
  end

  describe "the digests" do
    test "hold no value and are keyed, and are not comparable across environments", ctx do
      %{built_from_digests: digests} = Staleness.built_from(ctx.env)
      stored = Jason.encode!(digests)

      assert Map.keys(digests) |> Enum.sort() ==
               Staleness.fields() |> Enum.map(&Atom.to_string/1) |> Enum.sort()

      for value <- ["eu", "REGION", "make setup", "jq"] do
        refute stored =~ value
      end

      # Not a plain hash of the value a guess could be checked against.
      plain = :crypto.hash(:sha256, ~s({"FLAG":"1","REGION":"eu"})) |> Base.encode16(case: :lower)
      refute stored =~ binary_part(plain, 0, 32)

      # The same contents in another environment digest differently.
      twin =
        insert_env(
          user_id: ctx.user.id,
          setup_script: "make setup",
          env_vars: ctx.env.env_vars,
          packages: ctx.env.packages
        )

      %{built_from_digests: twin_digests} = Staleness.built_from(twin)
      assert twin_digests["env_vars"] != digests["env_vars"]

      # And under another key, differently again.
      key = Application.fetch_env!(:fountain, :master_secrets_key)
      on_exit(fn -> Application.put_env(:fountain, :master_secrets_key, key) end)
      Application.put_env(:fountain, :master_secrets_key, :crypto.strong_rand_bytes(32))
      %{built_from_digests: rekeyed} = Staleness.built_from(ctx.env)
      assert rekeyed["env_vars"] != digests["env_vars"]
    end
  end

  describe "a provision" do
    test "records what it built from with its stamp", ctx do
      {_workspace, sandbox} = built_sandbox(ctx.user, ctx.env, sandbox_status: "pending")

      {1, _} =
        Repo.update_all(from(s in Sandbox, where: s.id == ^sandbox.id),
          set: [built_from_revision: nil, built_from_digests: nil]
        )

      env = edit!(ctx.env, %{setup_script: "newer"})

      assert {:ok, :provisioned, :built} =
               Provision.run(sandbox.id, fn _handle, _epoch -> {:ok, :built} end,
                 actor: "system:conversation_server",
                 environment: env
               )

      ready = Repo.reload!(sandbox)
      assert ready.status == "ready"
      assert ready.built_from_revision == env.revision
      assert ready.built_from_digests == Staleness.built_from(env).built_from_digests
    end

    test "a rebuild records it on the new machine", ctx do
      {workspace, old} = built_sandbox(ctx.user, ctx.env, sandbox_status: "terminated")
      env = edit!(ctx.env, %{packages: %{"apt" => ["curl"]}})

      assert {:ok, :rebuilt, %Sandbox{} = next, :built} =
               Provision.rebuild(old.id, fn _handle, _epoch -> {:ok, :built} end,
                 actor: "system:conversation_server",
                 attrs: %{machine_name: "rebuilt-#{System.unique_integer([:positive])}"},
                 provider: :already_gone,
                 environment: env
               )

      assert next.workspace_id == workspace.id
      assert Repo.reload!(next).built_from_revision == env.revision
      assert %{stale: false} = Staleness.of(Repo.reload!(next), env)
    end
  end

  describe "an edit's event" do
    test "tells each ready explicit workspace on the environment, once, by name only", ctx do
      {first, _} = built_sandbox(ctx.user, ctx.env)
      {second, _} = built_sandbox(ctx.user, ctx.env)
      {_implicit, _} = built_sandbox(ctx.user, ctx.env, implicit: true)
      {_building, _} = built_sandbox(ctx.user, ctx.env, status: "provisioning")
      {_lost, _} = built_sandbox(ctx.user, ctx.env, sandbox_status: "terminated")
      other_env = insert_env(user_id: ctx.user.id)
      {_elsewhere, _} = built_sandbox(ctx.user, other_env)

      :ok = Workspaces.subscribe(ctx.user.id)
      edited = edit!(ctx.env, %{env_vars: %{"REGION" => "ap-southeast"}})

      for workspace <- [first, second] do
        id = workspace.id

        assert_receive {:workspace_status,
                        %{workspace_id: ^id, status: "ready", stale: true} = payload}

        assert payload.changed_fields == ["env_vars"]
        assert payload.revision == edited.revision
        refute inspect(payload) =~ "ap-southeast"
      end

      refute_receive {:workspace_status, _}, 100
    end

    test "is not sent for an edit that moves no revision", ctx do
      {_workspace, _} = built_sandbox(ctx.user, ctx.env)
      :ok = Workspaces.subscribe(ctx.user.id)

      edit!(ctx.env, %{name: "renamed", metadata: %{"a" => "b"}})
      refute_receive {:workspace_status, _}, 100
    end

    test "says a reverted edit is no longer stale", ctx do
      {workspace, _} = built_sandbox(ctx.user, ctx.env)
      :ok = Workspaces.subscribe(ctx.user.id)
      id = workspace.id

      edited = edit!(ctx.env, %{setup_script: "other"})
      assert_receive {:workspace_status, %{workspace_id: ^id, stale: true}}

      edit!(edited, %{setup_script: "make setup"})
      assert_receive {:workspace_status, %{workspace_id: ^id, stale: false, changed_fields: []}}
    end

    test "another account's workspaces are not told", ctx do
      other = insert_verified_user()
      :ok = Workspaces.subscribe(other.id)
      {_workspace, _} = built_sandbox(ctx.user, ctx.env)

      edit!(ctx.env, %{setup_script: "other"})
      refute_receive {:workspace_status, _}, 100
    end
  end
end
