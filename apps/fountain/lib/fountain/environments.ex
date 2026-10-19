defmodule Fountain.Environments do
  @moduledoc "Context for environments and their secrets."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
  alias Fountain.Audit
  alias Fountain.Conversations.LiveSecrets
  alias Fountain.Environments.{Environment, Secret}
  alias Fountain.InferenceCredentials
  alias Fountain.Repo

  # ── environments ──────────────────────────────────────────────────────────

  @doc "List environments scoped to user."
  def list_environments(user_id) when is_binary(user_id) do
    Repo.all(
      from e in Environment,
        where: e.user_id == ^user_id,
        order_by: [desc: e.inserted_at, desc: e.id]
    )
  end

  @doc """
  List environments scoped to user, with `:secret_count` and `:agent_count`
  attached as virtual fields via two lightweight aggregation queries.
  """
  def list_environments_with_counts(user_id) when is_binary(user_id) do
    secret_counts_query =
      from s in Secret,
        join: e in Environment,
        on: s.environment_id == e.id,
        where: e.user_id == ^user_id,
        group_by: s.environment_id,
        select: %{environment_id: s.environment_id, count: count(s.id)}

    agent_counts_query =
      from a in Agent,
        where: a.user_id == ^user_id,
        where: not is_nil(a.environment_id),
        group_by: a.environment_id,
        select: %{environment_id: a.environment_id, count: count(a.id)}

    envs =
      Repo.all(
        from e in Environment,
          where: e.user_id == ^user_id,
          order_by: [desc: e.inserted_at, desc: e.id]
      )

    secret_map =
      secret_counts_query
      |> Repo.all()
      |> Map.new(&{&1.environment_id, &1.count})

    agent_map =
      agent_counts_query
      |> Repo.all()
      |> Map.new(&{&1.environment_id, &1.count})

    Enum.map(envs, fn env ->
      env
      |> Map.put(:secret_count, Map.get(secret_map, env.id, 0))
      |> Map.put(:agent_count, Map.get(agent_map, env.id, 0))
    end)
  end

  @doc "Get environment scoped to user. A foreign, missing or malformed id reads as nil."
  def get_environment(id, user_id) when is_binary(user_id) do
    case Ecto.UUID.dump(id) do
      {:ok, _} -> Repo.get_by(Environment, id: id, user_id: user_id)
      :error -> nil
    end
  end

  @doc """
  Scoped fetch plus the counts the list read-model carries — how many secrets
  the environment holds and how many agents reference it. The second is the
  "is this safe to delete" answer, which callers otherwise N+1 client-side.
  """
  def get_environment_with_counts(id, user_id) when is_binary(user_id) do
    case get_environment(id, user_id) do
      nil ->
        nil

      env ->
        secret_count =
          Repo.aggregate(from(s in Secret, where: s.environment_id == ^env.id), :count)

        agent_count =
          Repo.aggregate(
            from(a in Agent, where: a.user_id == ^user_id and a.environment_id == ^env.id),
            :count
          )

        %{env | secret_count: secret_count, agent_count: agent_count}
    end
  end

  @doc "Get environment scoped to user. Raises Ecto.NoResultsError on wrong owner."
  def get_environment!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Environment, id: id, user_id: user_id)
  end

  @doc "Get environment by name scoped to user. Returns nil when missing."
  def get_environment_by_name(name, user_id) when is_binary(name) and is_binary(user_id) do
    Repo.get_by(Environment, name: name, user_id: user_id)
  end

  @doc """
  Create an environment.

  `opts` carries the audit attribution — `:actor` and `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface. Recording here rather
  than at each caller is what makes the UI, the API and manifest apply all leave the same trail (#543).
  """
  def create_environment(attrs, opts \\ []) do
    changeset = Environment.changeset(%Environment{}, attrs)

    if changeset.valid? do
      user_id = Ecto.Changeset.get_field(changeset, :user_id)
      InferenceCredentials.with_source_lock(user_id, fn -> Repo.insert(changeset) end)
    else
      {:error, changeset}
    end
    |> audited("environment.created", opts)
  end

  @doc """
  Update an environment. See `create_environment/2` for `opts`.
  """
  def update_environment(%Environment{} = env, attrs, opts \\ []) do
    changeset = Environment.changeset(env, attrs)
    result = InferenceCredentials.with_source_lock(env.user_id, fn -> Repo.update(changeset) end)

    # A save that moves nothing is not a change, and records nothing
    # (CLAUDE.md, "Only record what happened"). `Repo.update` already skips
    # the SQL for an empty changeset, so an idempotent re-apply of a manifest
    # left a trail of `environment.updated` rows with an empty changed list
    # against a row nobody had touched (#1680).
    if changeset.changes == %{} do
      result
    else
      result
      |> audited("environment.updated", merge_metadata(opts, Audit.changed_fields(changeset)))
      |> revision_moved(env)
    end
  end

  # An edit of a provision-time field gives the row a new `revision` (its
  # trigger), which every explicit workspace built from it is now behind:
  # their clients are told, after the commit (#2987).
  defp revision_moved({:ok, %Environment{revision: new} = updated} = ok, %Environment{
         revision: old
       })
       when new != old do
    :ok = Fountain.Workspaces.environment_changed(updated)
    ok
  end

  defp revision_moved(other, _env), do: other

  @doc """
  Delete an environment. See `create_environment/2` for `opts`.

  A sandbox built from it is its conversation's own and is left to that
  conversation; `sandboxes.environment_id` is `ON DELETE SET NULL`.
  """
  def delete_environment(%Environment{} = env, opts \\ []) do
    Fountain.Agents.delete_source_and_version_agents(env, opts)
    |> audited("environment.deleted", opts)
  end

  # See the note in `Fountain.Agents.audited/3`: this runs outside any
  # enclosing transaction, because best-effort audit recording is only
  # best-effort outside one.
  defp audited({:ok, %Environment{} = env} = ok, action, opts) do
    Audit.record_resource(action, "environment", env, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other

  defp merge_metadata(opts, extra) do
    Keyword.update(opts, :metadata, extra, &Map.merge(&1, extra))
  end

  # ── secrets ───────────────────────────────────────────────────────────────

  def _unsafe_list_secrets(%Environment{id: env_id}) do
    Repo.all(from s in Secret, where: s.environment_id == ^env_id, order_by: [asc: s.key])
  end

  def _unsafe_get_secret(env_id, key) do
    Repo.get_by(Secret, environment_id: env_id, key: key)
  end

  @doc """
  Insert or update an environment secret. The plaintext `attrs["value"]` is
  encrypted with the supplied per-tenant `dek` before persisting.

  Audited as `environment.secret.write`. Recorded here rather than by each
  caller: five surfaces wrote this same event independently — both LiveView
  forms, both API controllers, and `managoat apply` — and a sixth would have
  been one forgotten call from silence (#593). The key is recorded, never the
  value; that is the whole point of a write-only secret.
  """
  def upsert_secret(%Environment{} = env, %{"key" => key} = attrs, dek, opts \\ [])
      when is_binary(dek) do
    InferenceCredentials.with_source_lock(env.user_id, fn ->
      case _unsafe_get_secret(env.id, key) do
        nil ->
          %Secret{}
          |> Secret.changeset(Map.put(attrs, "environment_id", env.id), dek)
          |> Repo.insert()

        existing ->
          existing
          |> Secret.changeset(attrs, dek)
          |> Repo.update()
      end
    end)
    |> audited_secret(env, key, "environment.secret.write", opts)
    |> secrets_changed(env)
  end

  @doc """
  Delete an environment secret.

  Takes the owning environment as well as the secret: `secrets` carries no
  `user_id`, so without it the audit event could not be attributed without a
  second query — and every call site already has the environment in hand.
  """
  def delete_secret(%Environment{} = env, %Secret{} = secret, opts \\ []) do
    InferenceCredentials.with_source_lock(env.user_id, fn -> Repo.delete(secret) end)
    |> audited_secret(env, secret.key, "environment.secret.delete", opts)
    |> secrets_changed(env)
  end

  # `resource_id` is the environment, not the secret row: a deleted secret's id
  # points at nothing, and "which environment" is the question a reader of the
  # trail is actually asking. Matches the shape the five call sites emitted
  # before this moved, so existing trails stay readable.
  defp audited_secret({:ok, _} = ok, %Environment{} = env, key, action, opts) do
    Audit.record(%{
      user_id: env.user_id,
      action: action,
      resource_type: "secret",
      resource_id: env.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: Map.merge(%{"key" => key}, Keyword.get(opts, :metadata, %{}))
    })

    ok
  end

  defp audited_secret(other, _env, _key, _action, _opts), do: other

  # After the commit, so a server that reads the rows again sees this write:
  # the live conversations on this environment rewrite their broker rules (#2548).
  defp secrets_changed({:ok, _} = ok, %Environment{} = env) do
    LiveSecrets.secrets_changed(:environment, env.id, env.user_id)
    ok
  end

  defp secrets_changed(other, _env), do: other

  @doc """
  Returns a flat map `%{"KEY" => "plaintext"}` of all decrypted secrets
  attached to the given environment. Caller must supply the per-tenant `dek`
  (load via `Fountain.Crypto.load_tenant_key/1`).
  """
  def decrypted_env(%Environment{} = env, dek) when is_binary(dek) do
    env
    |> _unsafe_list_secrets()
    |> Enum.reduce(%{}, fn secret, acc ->
      case Secret.decrypt(secret, dek) do
        {:ok, plain} -> Map.put(acc, secret.key, plain)
        :error -> acc
      end
    end)
  end
end
