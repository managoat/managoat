defmodule Fountain.Agents do
  @moduledoc "Context for agent definitions."

  import Ecto.Query, only: [from: 2]

  alias Fountain.Agents.Agent
  alias Fountain.Agents.AgentAvatar
  alias Fountain.Agents.AgentVersion
  alias Fountain.Audit
  alias Fountain.Conversations.Conversation
  alias Fountain.Environments
  alias Fountain.Repo

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_agent(id), do: Repo.get(Agent, id) |> Repo.preload(:environment)

  @doc "WARNING: lookup by id without owner check. Admin/internal use only."
  def _unsafe_get_agent!(id), do: Repo.get!(Agent, id) |> Repo.preload(:environment)

  @doc """
  Get agent scoped to user. A foreign, missing or malformed id reads as nil.

  Malformed is part of that promise for the same reason it is on
  `Fountain.Conversations.get_conversation/2` (#1679): a route that hands this
  function a raw path segment would otherwise raise out of the query on an id
  that is not a uuid, instead of producing the 404 the route declares. The
  route that first needed it was `/api/agui/:agent_id`, retired by ADR 0057;
  the promise stays because it belongs to every such caller, not to that one.
  """
  def get_agent(id, user_id) when is_binary(user_id) do
    with {:ok, _} <- Ecto.UUID.dump(id),
         agent when not is_nil(agent) <- Repo.get_by(Agent, id: id, user_id: user_id) do
      Repo.preload(agent, :environment)
    else
      _ -> nil
    end
  end

  @doc """
  Scoped fetch plus the `conversation_count` the list read-model carries.

  Separate from `get_agent/2`, which is on the conversation-start path and
  does not need the count. Serving the struct default (0) from a read that
  advertises the field would report "no conversations" for a busy agent.
  """
  def get_agent_with_counts(id, user_id) when is_binary(user_id) do
    case get_agent(id, user_id) do
      nil ->
        nil

      agent ->
        count =
          Repo.aggregate(
            from(c in Conversation, where: c.user_id == ^user_id and c.agent_id == ^agent.id),
            :count
          )

        %{agent | conversation_count: count}
    end
  end

  @doc "Get agent scoped to user. Raises Ecto.NoResultsError if wrong owner."
  def get_agent!(id, user_id) when is_binary(user_id) do
    Repo.get_by!(Agent, id: id, user_id: user_id) |> Repo.preload(:environment)
  end

  @doc "List agents for user_id with optional keyword filters."
  def list_agents(user_id, filters) when is_binary(user_id) and is_list(filters) do
    from(a in Agent,
      where: a.user_id == ^user_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      preload: [:environment]
    )
    |> apply_search(Keyword.get(filters, :search, ""))
    |> apply_runtimes(Keyword.get(filters, :runtimes, []))
    |> apply_env_ids(Keyword.get(filters, :env_ids, []))
    |> apply_has_skills(Keyword.get(filters, :has_skills, false))
    |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
    |> Repo.all()
  end

  @doc "List agents for user_id with total conversation counts. Accepts same filters as list_agents/2."
  def list_agents_with_counts(user_id, filters) when is_binary(user_id) and is_list(filters) do
    counts_subquery =
      from c in Conversation,
        where: c.user_id == ^user_id,
        group_by: c.agent_id,
        select: %{agent_id: c.agent_id, count: count(c.id)}

    from(a in Agent,
      where: a.user_id == ^user_id,
      order_by: [desc: a.inserted_at, desc: a.id],
      left_join: counts in subquery(counts_subquery),
      on: counts.agent_id == a.id,
      select_merge: %{conversation_count: fragment("COALESCE(?, 0)", counts.count)}
    )
    |> apply_search(Keyword.get(filters, :search, ""))
    |> apply_runtimes(Keyword.get(filters, :runtimes, []))
    |> apply_env_ids(Keyword.get(filters, :env_ids, []))
    |> apply_has_skills(Keyword.get(filters, :has_skills, false))
    |> apply_has_mcp(Keyword.get(filters, :has_mcp, false))
    |> Repo.all()
    # Preload done post-query (not inline in `from`) because select_merge is
    # incompatible with Ecto's inline preload compilation.
    |> Repo.preload(:environment)
  end

  @doc "Get agent by name scoped to user. Returns nil when missing."
  def get_agent_by_name(name, user_id) when is_binary(name) and is_binary(user_id) do
    Repo.get_by(Agent, name: name, user_id: user_id)
  end

  @doc """
  Create an agent.

  `opts` carries the audit attribution — `:actor` and `:request_ip`, from
  `FountainWeb.Audited.attribution/2` on a web surface. Recording here rather
  than at each caller is what makes the UI, the API and manifest apply all leave the same trail (#543).
  """
  def create_agent(attrs, opts \\ []) do
    changeset =
      %Agent{}
      |> Agent.changeset(attrs)
      |> validate_environment_owner()

    # The version snapshot shares the transaction with the insert: an agent
    # with no version 1 would break the invariant every conversation and the
    # history page lean on. The audit call stays outside (see audited/3).
    Repo.transaction(fn ->
      with {:ok, agent} <- Repo.insert(changeset),
           {:ok, _} <- Repo.insert(version_changeset(agent, 1)) do
        agent
      else
        {:error, invalid} -> Repo.rollback(invalid)
      end
    end)
    |> audited("agent.created", opts)
  end

  @doc "Update an agent. See `create_agent/2` for `opts`."
  def update_agent(%Agent{} = agent, attrs, opts \\ []) do
    changeset =
      agent
      |> Agent.changeset(attrs)
      |> validate_environment_owner()

    do_update_agent(changeset, opts)
  end

  defp do_update_agent(changeset, opts) do
    result =
      if snapshot_needed?(changeset) do
        Repo.transaction(fn ->
          # Environment deletion locks the source before the referencing agents.
          # Match that order before an edit takes the agent row lock and asks
          # PostgreSQL to validate a new environment FK.
          if Map.has_key?(changeset.changes, :environment_id),
            do: Fountain.InferenceCredentials.lock_source(changeset.data.user_id)

          # The caller may hold an older struct. RETURNING snapshots the
          # persisted row, including fields changed by another edit, while
          # this update holds the row lock through the version insert.
          with {:ok, updated} <- Repo.update(changeset, returning: true),
               {:ok, _} <-
                 Repo.insert(version_changeset(updated, next_version_number(updated.id))) do
            updated
          else
            # A concurrent edit racing the [agent_id, version] unique index
            # fails on the *version* changeset — but every caller expects
            # an Agent changeset back, so keep the
            # contract and say what happened.
            {:error, %Ecto.Changeset{data: %AgentVersion{}}} ->
              Repo.rollback(
                Ecto.Changeset.add_error(
                  changeset,
                  :base,
                  "the agent was updated by someone else at the same moment — retry"
                )
              )

            {:error, invalid} ->
              Repo.rollback(invalid)
          end
        end)
      else
        # No config field moved (a no-op save): no version row, same as no
        # audit metadata worth recording twice.
        Repo.update(changeset)
      end

    # A save that moves nothing records nothing, the same rule
    # `Fountain.Environments.update_environment/3` follows (#1680).
    result =
      if changeset.changes == %{} do
        result
      else
        audited(result, "agent.updated", merge_metadata(opts, Audit.changed_fields(changeset)))
      end

    result
  end

  # An agent may only reference an environment owned by the same tenant —
  # the environment's secrets materialise inside the
  # agent's sprite. The error mirrors a nonexistent id so a foreign
  # environment UUID can't be confirmed by probing.
  # A changeset that has already failed is not worth a database round trip, and
  # the id it carries may be a value the query cannot dump: a name where an id
  # belongs raises `Ecto.Query.CastError` out of `Repo`, which reaches the
  # caller as a 500 rather than the 422 the changeset was about to return
  # (#1679). The ownership rule below still runs on every changeset that could
  # otherwise succeed, which is the only one whose answer changes anything.
  defp validate_environment_owner(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_environment_owner(changeset) do
    env_id = Ecto.Changeset.get_change(changeset, :environment_id)
    user_id = Ecto.Changeset.get_field(changeset, :user_id)

    cond do
      is_nil(env_id) ->
        changeset

      is_binary(user_id) && Environments.get_environment(env_id, user_id) ->
        changeset

      true ->
        Ecto.Changeset.add_error(changeset, :environment_id, "does not exist")
    end
  end

  @doc "Delete an agent. See `create_agent/2` for `opts`."
  def delete_agent(%Agent{} = agent, opts \\ []) do
    # Its conversations keep their own sandboxes, as they outlive the agent.
    delete_agent_row(agent, opts)
  end

  defp delete_agent_row(agent, opts) do
    # Unpin the agent's conversations from its versions before the row goes.
    # Deleting the agent cascades to `agent_versions`, and Postgres re-checks
    # `conversations.agent_version_id` while it is still setting
    # `conversations.agent_id` to NULL in the same statement — before its own
    # SET NULL for the version has run — so the delete failed with a
    # foreign-key violation for every agent that had a versioned
    # conversation (found building ADR 0023 gate 6; versioning is #1049).
    # The version is provenance only, so clearing it here loses nothing the
    # cascade would not have cleared anyway.
    Repo.transaction(fn ->
      Repo.update_all(
        from(c in Fountain.Conversations.Conversation, where: c.agent_id == ^agent.id),
        set: [agent_version_id: nil]
      )

      case Repo.delete(agent) do
        {:ok, deleted} -> deleted
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> audited("agent.deleted", opts)
  end

  @doc """
  Upload or replace the avatar for an agent.

  The media type is validated against `Fountain.Images.valid_media_types/0`:
  it is echoed back verbatim by the avatar endpoint, and LiveView's upload
  `accept:` list does not constrain it — `accepted?/2` passes an entry whose
  *filename extension* matches even when the declared MIME type does not, so
  a crafted client can declare `text/html` with a `.png` name.
  """
  def upload_avatar(%Agent{} = agent, data, media_type, opts \\ [])
      when is_binary(data) and is_binary(media_type) do
    if Fountain.Images.valid_media_type?(media_type) do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.transaction(fn ->
        Repo.insert!(
          %AgentAvatar{agent_id: agent.id, data: data, inserted_at: now},
          on_conflict: {:replace, [:data, :inserted_at]},
          conflict_target: :agent_id
        )

        agent
        |> Ecto.Changeset.change(%{avatar_media_type: media_type})
        |> Repo.update!()
      end)
      # Outside the transaction on purpose. `Audit.record/1` is best-effort by
      # rescuing, but that guarantee does not hold inside a transaction: a
      # failed insert there aborts the enclosing one, so a lost audit row
      # would take the avatar write with it.
      |> audited("agent.avatar.set", merge_metadata(opts, %{"media_type" => media_type}))
    else
      {:error, :invalid_media_type}
    end
  end

  @doc "Remove the avatar for an agent. See `create_agent/2` for `opts`."
  def delete_avatar(%Agent{} = agent, opts \\ []) do
    Repo.transaction(fn ->
      Repo.delete_all(from(av in AgentAvatar, where: av.agent_id == ^agent.id))

      agent
      |> Ecto.Changeset.change(%{avatar_media_type: nil})
      |> Repo.update!()
    end)
    |> audited("agent.avatar.removed", opts)
  end

  # Audits a successful mutation and passes the result through untouched, so a
  # context function stays a one-liner and the failure case cannot accidentally
  # record a change that did not happen.
  defp audited({:ok, %Agent{} = agent} = ok, action, opts) do
    Audit.record_resource(action, "agent", agent, opts)
    ok
  end

  defp audited(other, _action, _opts), do: other

  defp merge_metadata(opts, extra) do
    Keyword.update(opts, :metadata, extra, &Map.merge(&1, extra))
  end

  @doc "Fetch the raw avatar blob for an agent. Returns nil if none uploaded."
  def get_avatar(%Agent{id: agent_id}), do: Repo.get(AgentAvatar, agent_id)

  # ── versions ──────────────────────────────────────────────────────────────

  # The config fields a version captures — everything `Agent.changeset/2`
  # casts except ownership (`user_id`) and the avatar, which is a blob with
  # its own lifecycle, not config.
  @snapshot_fields [
    :name,
    :description,
    :system,
    :model,
    :runtime,
    :runtime_command,
    :sandbox_provider,
    :skills,
    :mcp_servers,
    :metadata,
    :allowed_vault_ids,
    :allowed_environment_ids,
    :permission_policy,
    :session_config,
    :environment_id
  ]

  @doc """
  The string-keyed config payload a version stores for `agent`.

  Public so tests assert the same shape the context writes; the backfill in
  the create_agent_versions migration mirrors it in SQL.
  """
  def snapshot_config(%Agent{} = agent) do
    Map.new(@snapshot_fields, fn field -> {Atom.to_string(field), Map.get(agent, field)} end)
  end

  @doc "List an agent's versions, newest first, scoped to user."
  def list_agent_versions(agent_id, user_id) when is_binary(user_id) do
    Repo.all(
      from v in AgentVersion,
        where: v.agent_id == ^agent_id and v.user_id == ^user_id,
        order_by: [desc: v.version]
    )
  end

  @doc "Get one version of an agent by number, scoped to user. Nil when missing."
  def get_agent_version(agent_id, version, user_id)
      when is_integer(version) and is_binary(user_id) do
    Repo.get_by(AgentVersion, agent_id: agent_id, version: version, user_id: user_id)
  end

  @doc """
  WARNING: no owner check. The id of an agent's newest version, for stamping
  onto a conversation directly after a tenant-scoped agent fetch.
  """
  def _unsafe_current_version_id(agent_id) do
    Repo.one(
      from v in AgentVersion,
        where: v.agent_id == ^agent_id,
        order_by: [desc: v.version],
        limit: 1,
        select: v.id
    )
  end

  @doc """
  Delete an owned environment or vault, versioning each agent whose references change.

  Used by the source contexts after their home teardown, never for provider I/O.
  The source lock, reference cleanup, snapshots and source deletion share a
  transaction; the agent audit records only committed changes afterwards.
  """
  def delete_source_and_version_agents(source, opts \\ [])

  def delete_source_and_version_agents(%Environments.Environment{} = source, opts),
    do: delete_source_and_version_agents(source, :environment, opts)

  def delete_source_and_version_agents(%Fountain.Vaults.Vault{} = source, opts),
    do: delete_source_and_version_agents(source, :vault, opts)

  defp delete_source_and_version_agents(source, kind, opts) do
    result =
      Fountain.InferenceCredentials.with_source_lock(source.user_id, fn ->
        # Ownership: the source was fetched scoped by its context's caller.
        # Lock it before the agent scan so a concurrent new environment FK
        # either commits before this scan or fails after the source is gone.
        locked =
          Repo.one!(
            from s in source.__struct__,
              where: s.id == ^source.id and s.user_id == ^source.user_id,
              lock: "FOR UPDATE"
          )

        # An explicit workspace fixes its environment and vault for its life
        # (ADR 0097, Data), so deleting one it names is refused while it
        # exists. Under the tenant lock `Workspaces.create_workspace/3` takes,
        # so a workspace either commits first and is seen here or finds the
        # source gone. An implicit workspace's foreign key still nilifies.
        if Fountain.Workspaces.names_source?(kind, source.id, source.user_id),
          do: Repo.rollback(:source_in_use_by_workspace)

        changes =
          source_referencing_agents(source, kind)
          |> Repo.all()
          |> Enum.map(fn agent ->
            changeset =
              Ecto.Changeset.change(agent, removed_source_references(agent, source, kind))

            # Narrow cleanup must also work for historical configurations
            # whose runtime/provider is no longer enabled. RETURNING includes
            # database-derived authorization fields in the persisted struct.
            with {:ok, updated} <- Repo.update(changeset, returning: true),
                 {:ok, _} <-
                   Repo.insert(version_changeset(updated, next_version_number(updated.id))) do
              {updated, Audit.changed_fields(changeset)}
            else
              {:error, invalid} -> Repo.rollback(invalid)
            end
          end)

        with {:ok, deleted} <- Repo.delete(locked), do: {:ok, {deleted, changes}}
      end)

    case result do
      {:ok, {deleted, changes}} ->
        Enum.each(changes, fn {agent, fields} ->
          audited({:ok, agent}, "agent.updated", merge_metadata(opts, fields))
        end)

        {:ok, deleted}

      error ->
        error
    end
  end

  defp source_referencing_agents(source, :environment) do
    from a in Agent,
      where: a.user_id == ^source.user_id,
      where: a.environment_id == ^source.id or ^source.id in a.allowed_environment_ids,
      order_by: a.id,
      lock: "FOR UPDATE"
  end

  defp source_referencing_agents(source, :vault) do
    from a in Agent,
      where: a.user_id == ^source.user_id and ^source.id in a.allowed_vault_ids,
      order_by: a.id,
      lock: "FOR UPDATE"
  end

  defp removed_source_references(agent, source, :environment) do
    %{
      environment_id: if(agent.environment_id == source.id, do: nil, else: agent.environment_id),
      allowed_environment_ids: without_source(agent.allowed_environment_ids, source.id)
    }
  end

  defp removed_source_references(agent, source, :vault),
    do: %{allowed_vault_ids: without_source(agent.allowed_vault_ids, source.id)}

  # nil permits all tenant sources; an emptied allowlist continues to permit none.
  defp without_source(nil, _id), do: nil
  defp without_source(ids, id), do: Enum.reject(ids, &(&1 == id))

  defp version_changeset(%Agent{} = agent, number) do
    AgentVersion.changeset(%AgentVersion{}, %{
      version: number,
      config: snapshot_config(agent),
      agent_id: agent.id,
      user_id: agent.user_id
    })
  end

  # Runs inside the update transaction; the unique index on
  # [agent_id, version] turns a concurrent-edit race into a changeset error
  # rather than two rows with the same number.
  defp next_version_number(agent_id) do
    current =
      Repo.one(from v in AgentVersion, where: v.agent_id == ^agent_id, select: max(v.version))

    (current || 0) + 1
  end

  defp snapshot_needed?(%Ecto.Changeset{changes: changes}) do
    Enum.any?(@snapshot_fields, &Map.has_key?(changes, &1))
  end

  defp apply_search(query, ""), do: query

  defp apply_search(query, search) do
    # ilike, not like: a case-sensitive search box is a broken one, and this
    # backs both the agents list in the UI and the documented ?search= param.
    term = "%#{search}%"
    from a in query, where: ilike(a.name, ^term)
  end

  defp apply_runtimes(query, []), do: query

  defp apply_runtimes(query, runtimes) do
    from a in query, where: a.runtime in ^runtimes
  end

  defp apply_env_ids(query, []), do: query

  defp apply_env_ids(query, env_ids) do
    {none, real_ids} = Enum.split_with(env_ids, &(&1 == "none"))

    cond do
      none != [] and real_ids != [] ->
        from a in query,
          where: is_nil(a.environment_id) or a.environment_id in ^real_ids

      none != [] ->
        from a in query, where: is_nil(a.environment_id)

      true ->
        from a in query, where: a.environment_id in ^real_ids
    end
  end

  defp apply_has_skills(query, false), do: query

  defp apply_has_skills(query, true) do
    from a in query, where: fragment("cardinality(?)", a.skills) > 0
  end

  defp apply_has_mcp(query, false), do: query

  defp apply_has_mcp(query, true) do
    from a in query, where: fragment("? != '{}'", a.mcp_servers)
  end
end
