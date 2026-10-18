defmodule Fountain.Factory do
  @moduledoc """
  Test factories for AoD. Lean and explicit — no factory_bot magic.

  Each `*_attrs/1` returns a map suitable for the corresponding context's
  create function. `insert_*/1` writes the row through the regular
  changeset so tests have realistic data, but factories accept *both*
  keyword lists and atom-keyed maps for ergonomics in tests.
  """

  import Ecto.Query, only: [from: 2]

  alias Fountain.Repo
  require Ecto.Query
  alias Fountain.Conversations.{Conversation, LogEvent, Sandbox, Turn}

  defp uniq, do: System.unique_integer([:positive, :monotonic]) |> Integer.to_string()

  # ── users ─────────────────────────────────────────────────────────────────

  def user_attrs(overrides \\ %{}) do
    Map.merge(
      %{"email" => "user#{uniq()}@example.com", "password" => "password123"},
      to_string_map(overrides)
    )
  end

  def insert_user(overrides \\ %{}) do
    attrs = user_attrs(overrides)
    {:ok, user} = Fountain.Accounts.register_user(attrs)
    user
  end

  @doc "A verified user."
  def insert_verified_user(overrides \\ %{}) do
    user = insert_user(overrides)
    {:ok, verified} = Fountain.Accounts.verify_email(user)
    verified
  end

  @doc """
  A verified user. The same as `insert_verified_user/1` since ADR 0031 — there
  is no subscription to be active — kept so the many tests that reach for
  "an account that may spend" keep reading.
  """
  def insert_active_user(overrides \\ %{}), do: insert_verified_user(overrides)

  def insert_api_key(user, name \\ nil, opts \\ []) do
    name = name || "key-#{uniq()}"
    {:ok, {key_record, raw_key}} = Fountain.Accounts.create_api_key(user.id, name, opts)
    {key_record, raw_key}
  end

  @doc """
  A key with the narrow scope handed to sandboxes — the credential an agent
  running inside a sprite actually holds.
  """
  def insert_sprite_api_key(user, opts \\ []) do
    insert_api_key(user, "sprite:#{uniq()}", Keyword.put_new(opts, :scopes, ["sprite"]))
  end

  # ── OAuth clients (#1125) ─────────────────────────────────────────────────

  def oauth_client_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "app-#{uniq()}", "redirect_uris" => ["https://app-#{uniq()}.test/callback"]},
      to_string_map(overrides)
    )
  end

  @doc """
  A registered OAuth client. `published: true` is written straight to the row
  because publishing is an operator flip with no self-serve path -- there is
  no context function that would do it.
  """
  def insert_oauth_client(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    {user_id, overrides} = Map.pop_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {published, overrides} = Map.pop(overrides, "published", false)

    {:ok, client} = Fountain.OAuth.create_client(user_id, oauth_client_attrs(overrides))

    if published do
      client
      |> Ecto.Changeset.change(published: true)
      |> Fountain.Repo.update!()
    else
      client
    end
  end

  # ── environments ──────────────────────────────────────────────────────────

  def env_attrs(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "env-#{uniq()}",
        "packages" => %{},
        "env_vars" => %{},
        "setup_script" => "",
        "networking_type" => "unrestricted",
        "networking_config" => %{},
        "repositories" => []
      },
      to_string_map(overrides)
    )
  end

  def insert_env(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, env} = Fountain.Environments.create_environment(env_attrs(overrides))
    env
  end

  def insert_secret(env, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, dek} = Fountain.Crypto.load_tenant_key(env.user_id)
    {:ok, secret} = Fountain.Environments.upsert_secret(env, attrs, dek)
    secret
  end

  # ── vaults ────────────────────────────────────────────────────────────────

  def vault_attrs(overrides \\ %{}) do
    Map.merge(
      %{"name" => "vault-#{uniq()}", "description" => ""},
      to_string_map(overrides)
    )
  end

  def insert_vault(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, vault} = Fountain.Vaults.create_vault(vault_attrs(overrides))
    vault
  end

  def insert_vault_secret(vault, overrides \\ %{}) do
    attrs =
      %{"key" => "TEST_KEY_#{uniq()}", "value" => "test-value-#{uniq()}"}
      |> Map.merge(to_string_map(overrides))

    {:ok, dek} = Fountain.Crypto.load_tenant_key(vault.user_id)
    {:ok, secret} = Fountain.Vaults.upsert_secret(vault, attrs, dek)
    secret
  end

  # ── agents ────────────────────────────────────────────────────────────────

  def agent_attrs(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    runtime = Map.get(overrides, "runtime", "claude")

    Map.merge(
      %{
        "name" => "agent-#{uniq()}",
        # The changeset requires the provider prefix to match the runtime
        # (#553), so a call site that overrides only :runtime still gets a
        # model its runtime can actually reach. The acp runtime is the
        # inverse: no model at all, and a command instead (#1634).
        "model" => default_model_for(runtime),
        "runtime" => runtime,
        "skills" => [],
        "mcp_servers" => %{},
        "metadata" => %{}
      }
      |> Map.merge(default_command_for(runtime)),
      overrides
    )
  end

  defp default_model_for("codex"), do: "openai/gpt-5.3-codex"
  defp default_model_for("gemini"), do: "google/gemini-3.1-pro-preview"
  defp default_model_for("acp"), do: nil
  defp default_model_for(_runtime), do: "anthropic/claude-sonnet-4-6"

  defp default_command_for("acp"), do: %{"runtime_command" => "fixture-agent"}
  defp default_command_for(_runtime), do: %{}

  def insert_agent(overrides \\ %{}) do
    overrides = to_string_map(overrides)
    overrides = Map.put_new_lazy(overrides, "user_id", fn -> insert_verified_user().id end)
    {:ok, agent} = Fountain.Agents.create_agent(agent_attrs(overrides))
    agent
  end

  # ── conversations / sandboxes / turns ─────────────────────────────────────

  @doc """
  Put an existing sandbox row into the state a test needs.

  A fixture, not a door. Until ADR 0058 stage 9b this was
  `Conversations.update_sandbox/2`, the context's general sandbox write; by then
  nothing in `lib/` called it any more — every status change is the machine
  owner's, through `Fountain.Machines.Lease.cas_update/4` — so it moved here.

  It keeps what a fixture relies on: the write applies to the row as it is now
  (not the struct the test holds) and `terminated_at` is filled in on the way
  into a terminal status. It does **not** keep the guards the context write had — refusing
  a revival and a fenced machine — because a fixture that refused would only
  hide the state a test is trying to build. The owner's own write refuses both.
  """
  def update_sandbox(%Sandbox{id: id}, attrs) do
    current = Repo.get!(Sandbox, id)
    changeset = Sandbox.changeset(current, attrs)

    changeset =
      if Ecto.Changeset.get_field(changeset, :status) in ~w(terminated failed) and
           is_nil(Ecto.Changeset.get_field(changeset, :terminated_at)),
         do:
           Ecto.Changeset.put_change(
             changeset,
             :terminated_at,
             DateTime.utc_now() |> DateTime.truncate(:second)
           ),
         else: changeset

    Repo.update(changeset)
  end

  @doc """
  An implicit workspace (ADR 0097), owned by `user_id` or a fresh user.
  `status` and the other fields may be overridden; `insert_sandbox/1` does not
  make one, so a test that wants the pair passes `workspace_id:` there.
  """
  def insert_workspace(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)
    user_id = Map.get(overrides_map, :user_id) || insert_verified_user().id

    {:ok, workspace} =
      %{provider: "sprites"}
      |> Map.merge(overrides_map)
      |> Map.put(:user_id, user_id)
      |> Fountain.Workspaces.insert_implicit()

    case Map.take(overrides_map, [:status, :name, :implicit, :error]) do
      sets when map_size(sets) == 0 -> workspace
      sets -> workspace |> Ecto.Changeset.change(sets) |> Repo.update!()
    end
  end

  @doc """
  Make the workspace of `sandbox` explicit (ADR 0097): one a caller created,
  which keeps its machine when a conversation ends and parks it at the
  ceiling. Explicit workspaces have no API before step 5, so a test makes
  one by flipping the flag. Returns the sandbox.
  """
  def explicit_workspace!(%Sandbox{workspace_id: workspace_id} = sandbox)
      when is_binary(workspace_id) do
    {1, _} =
      Repo.update_all(
        from(w in Fountain.Workspaces.Workspace, where: w.id == ^workspace_id),
        set: [implicit: false, name: "workspace-#{uniq()}"]
      )

    sandbox
  end

  def insert_sandbox(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)
    user_id = Map.get(overrides_map, :user_id) || insert_verified_user().id

    # Every sandbox is born in a workspace (ADR 0097), which holds its
    # machine's lease, so one is made unless the test names its own, or
    # `workspace_id: nil` for a row from before workspaces.
    overrides_map =
      if Map.has_key?(overrides_map, :workspace_id),
        do: overrides_map,
        else: Map.put(overrides_map, :workspace_id, insert_workspace(user_id: user_id).id)

    attrs =
      %{machine_name: "test-sprite-#{uniq()}", status: "pending", user_id: user_id}
      |> Map.merge(overrides_map)

    # A provider since removed (`runner`) is history the changeset no longer
    # accepts, so such a row is written the way the release before left it.
    {removed_provider, attrs} =
      if is_binary(attrs[:provider]) and
           attrs[:provider] not in Fountain.SandboxProviders.known_providers(),
         do: {attrs[:provider], Map.put(attrs, :provider, "sprites")},
         else: {nil, attrs}

    sandbox =
      %Sandbox{}
      |> Sandbox.changeset(attrs)
      |> Repo.insert!()

    sandbox =
      if removed_provider,
        do: sandbox |> Ecto.Changeset.change(provider: removed_provider) |> Repo.update!(),
        else: sandbox

    # `inserted_at` is when a sandbox started, so anything testing sandbox
    # time or listing order has to be able to place one in the past. The
    # changeset does not cast it (nothing in the app sets it), so back-date the
    # row directly.
    case Map.get(overrides_map, :inserted_at) do
      nil -> sandbox
      at -> sandbox |> Ecto.Changeset.change(inserted_at: at) |> Repo.update!()
    end
  end

  @doc """
  Set a machine's lease columns (`lease_epoch`, `lease_node`, `transition`,
  `transition_reason`) as a test fixture: on its workspace, where the owner
  reads them (ADR 0097), and on the sandbox's own copy, as
  `Fountain.Machines.Lease` keeps it. A sandbox with no workspace has only its
  own written. Any other key in `attrs` is written to the sandbox. Returns the
  sandbox as `Lease.get/1` reads it.
  """
  #
  # Given a struct, like `Ecto.Changeset.change/2` it writes only the keys whose
  # value differs from the struct's, so a fixture that names a field it means
  # to leave alone leaves it.
  def put_lease(sandbox_or_id, attrs) do
    id = if is_binary(sandbox_or_id), do: sandbox_or_id, else: sandbox_or_id.id
    attrs = attrs |> to_atom_map() |> Enum.to_list()

    attrs =
      case sandbox_or_id do
        %Sandbox{} = given -> Enum.reject(attrs, fn {k, v} -> Map.get(given, k) == v end)
        _id -> attrs
      end

    {lease, rest} =
      Keyword.split(attrs, [:lease_epoch, :lease_node, :transition, :transition_reason])

    sandbox = Repo.get!(Sandbox, id)

    if lease != [] and sandbox.workspace_id do
      {1, _} =
        Repo.update_all(
          from(w in Fountain.Workspaces.Workspace, where: w.id == ^sandbox.workspace_id),
          set: lease
        )
    end

    sets = lease ++ rest

    if sets != [] do
      {1, _} = Repo.update_all(from(s in Sandbox, where: s.id == ^id), set: sets)
    end

    Fountain.Machines.Lease.get(id)
  end

  @doc """
  Fill one provider's fleet ceiling with `ready` sandboxes of a throwaway
  account, leaving `free` slots open. The provider is the deployment default
  (the one a launch picks) unless `provider` names another. Safe in an async
  test: the count runs inside the test's own SQL sandbox transaction. Returns
  the sandboxes it inserted.
  """
  def fill_fleet(free \\ 0, provider \\ nil) do
    provider = to_string(provider || Fountain.SandboxProviders.default_provider())
    owner = insert_verified_user()

    n =
      Fountain.Quotas.fleet_ceiling(provider) - Fountain.Quotas.fleet_count(provider: provider) -
        free

    if n > 0,
      do:
        for(
          _ <- 1..n,
          do: insert_sandbox(user_id: owner.id, status: "ready", provider: provider)
        ),
      else: []
  end

  @doc """
  How many of `user_id`'s sandboxes hold a fleet slot, read from
  `Fountain.Quotas.active_sandbox_counts/0` (the admin view's count).
  """
  def active_sandbox_count(user_id),
    do: Map.get(Fountain.Quotas.active_sandbox_counts(), user_id, 0)

  def insert_conversation(overrides \\ %{}) do
    overrides_map = to_atom_map(overrides)

    agent =
      Map.get(overrides_map, :agent) ||
        case Map.get(overrides_map, :agent_id) do
          nil -> nil
          agent_id -> Repo.get(Fountain.Agents.Agent, agent_id)
        end

    user_id =
      Map.get(overrides_map, :user_id) ||
        (agent && agent.user_id) ||
        insert_verified_user().id

    sandbox = Map.get(overrides_map, :sandbox) || insert_sandbox(user_id: user_id)

    base = %{
      sandbox_id: sandbox.id,
      agent_id: agent && agent.id,
      user_id: user_id,
      # A conversation's runtime is snapshotted from its agent in production;
      # a factory row that disagrees with its own agent misleads every test
      # that branches on it.
      runtime: (agent && agent.runtime) || "claude",
      # Copied from the agent at launch in production (#2664), likewise.
      agent_session_config: Fountain.Agents.SessionConfig.for_launch(agent),
      # In its sandbox's workspace, as a launch puts it (ADR 0097).
      workspace_id: conversation_workspace(overrides_map, sandbox),
      status: "pending"
    }

    attrs = Map.merge(base, Map.drop(overrides_map, [:sandbox, :agent]))

    %Conversation{}
    |> Conversation.changeset(attrs)
    |> Repo.insert!()
    |> Repo.preload([:sandbox, :agent])
  end

  defp conversation_workspace(%{sandbox: %Sandbox{workspace_id: id}}, _sandbox), do: id
  defp conversation_workspace(%{sandbox_id: nil}, _sandbox), do: nil

  defp conversation_workspace(%{sandbox_id: id}, _sandbox) when is_binary(id),
    do: Repo.one(from(s in Sandbox, where: s.id == ^id, select: s.workspace_id))

  defp conversation_workspace(_overrides, %Sandbox{workspace_id: id}), do: id
  defp conversation_workspace(_overrides, _sandbox), do: nil

  def insert_turn(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        turn_number: Fountain.Conversations._unsafe_next_turn_number(conv.id),
        prompt: "test prompt",
        status: "pending"
      }
      |> Map.merge(to_atom_map(overrides))

    %Turn{}
    |> Turn.changeset(attrs)
    |> Repo.insert!()
  end

  def insert_log_event(conv, overrides \\ %{}) do
    attrs =
      %{
        conversation_id: conv.id,
        kind: "output",
        stream: "stdout",
        data: "test data",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }
      |> Map.merge(to_atom_map(overrides))

    %LogEvent{}
    |> LogEvent.changeset(attrs)
    |> Repo.insert!()
  end

  # ── key helpers ───────────────────────────────────────────────────────────

  # Always return a map keyed by strings.
  def to_string_map(input) when is_list(input), do: input |> Map.new() |> to_string_map()

  def to_string_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {Atom.to_string(k), v}
      {k, v} -> {k, v}
    end)
  end

  # Always return a map keyed by atoms (where atoms exist).
  def to_atom_map(input) when is_list(input), do: input |> Map.new() |> to_atom_map()

  def to_atom_map(input) when is_map(input) do
    Map.new(input, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {safe_to_existing_atom(k, k), v}
    end)
  end

  defp safe_to_existing_atom(s, fallback) do
    String.to_existing_atom(s)
  rescue
    ArgumentError -> fallback
  end

  @doc """
  A `lease_node` a live process of this boot holds: the calling test process,
  which outlives everything the test does (`Fountain.Machines.Lease`, ADR 0072).
  """
  def live_lease_holder, do: Fountain.Machines.Lease.holder(self())

  @doc """
  A `lease_node` whose holder is gone: a process of an earlier boot, the shape
  a lease has after a deploy and before the boot sweep.
  """
  def dead_lease_holder, do: "0000000000000000/<0.1.0>"
end
