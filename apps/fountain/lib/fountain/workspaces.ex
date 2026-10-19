defmodule Fountain.Workspaces do
  @moduledoc """
  Workspaces (ADR 0097). The writes that keep a workspace beside every live
  sandbox: the implicit workspace a sandbox is born with, its status following
  that sandbox's provision, and `_unsafe_reconcile_live/0`, which repairs the
  pairing at every boot. The machine's owner and lease are the workspace's
  (step 3b), and `Fountain.Machines.Lease` reads and writes them. Since step 4
  the lifecycle reads the workspace's kind (`machine_kind/1`): a detach keeps
  an explicit workspace's machine, and the ceiling parks it.

  **Explicit workspaces** (step 5) are made and deleted by their owner:
  `create_workspace/3` reserves the workspace and its first sandbox in one
  commit and provisions it at once, with no conversation
  (`Fountain.Workspaces.Provisioner`), and `delete_workspace/2` ends every
  live conversation on it and destroys its machine. Each status change of an
  explicit workspace is broadcast on the owner's `workspaces:<user_id>`
  topic (`subscribe/1`), which the account event stream carries as
  `workspace.status`.

  Every query a caller can reach is scoped by `user_id`. `_unsafe_reconcile_live/0`
  and `_unsafe_sweep_ended/0` are sweeps over every account and say so.

  **An implicit workspace ends with its conversation** (step 4): once the
  conversation is terminal and its machine is gone, the row is deleted
  (`release_ended/1`, from the termination path; `_unsafe_sweep_ended/0`,
  hourly from `SandboxReaper`, for whatever that path missed). Deleted rather
  than kept with an ended status: once its machine is terminal nothing reads
  it, its lease guards nothing, and a kept row per launch would accumulate
  for ever. While its conversation lives it is kept, machine or no machine,
  because the conversation's next prompt builds its next machine in it. The
  same sweep deletes an ownerless workspace (account deletion keeps one beside
  a machine whose destroy failed, #2329) once that machine is terminal, and
  the `provisioning` rows a lost wake race left before step 4.

  **Nothing about an implicit workspace is audited, deliberately.** An
  implicit workspace is made in the launch's transaction, where an audit event
  cannot be recorded (ADR 0013), and it is not a thing anybody asked for: it
  is the launch's own sandbox given an owner record, and
  `conversation.created` and `sandbox.provisioned` / `sandbox.provision_failed`,
  recorded after their commits, already describe it. `workspace.created` and
  `workspace.deleted` are the explicit workspaces' a caller creates and
  deletes, recorded here after their commits with the caller's attribution.
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.Sandbox
  alias Fountain.Environments.Environment
  alias Fountain.Repo
  alias Fountain.Workspaces.Staleness
  alias Fountain.Workspaces.Workspace

  @terminal_statuses ~w(terminated failed)

  # `_unsafe_reconcile_live/0`'s fill. `20261018210000` keeps a frozen copy.
  @fill_sql """
  WITH live AS (
    SELECT s.id AS sandbox_id,
           gen_random_uuid() AS workspace_id,
           s.user_id, s.environment_id, s.vault_id, s.provider, s.status, s.inserted_at
      FROM sandboxes s
     WHERE s.status NOT IN ('terminated', 'failed')
       AND s.workspace_id IS NULL
     ORDER BY s.id
       FOR UPDATE OF s
  ),
  ws AS (
    INSERT INTO workspaces
      (id, user_id, environment_id, vault_id, provider, name, implicit, status,
       inserted_at, updated_at)
    SELECT workspace_id, user_id, environment_id, vault_id, provider, NULL, true,
           CASE WHEN status IN ('pending', 'starting') THEN 'provisioning' ELSE 'ready' END,
           inserted_at,
           date_trunc('second', timezone('UTC', now()))
      FROM live
    RETURNING id
  ),
  sb AS (
    UPDATE sandboxes s
       SET workspace_id = live.workspace_id
      FROM live
     WHERE s.id = live.sandbox_id
    RETURNING s.id
  ),
  cv AS (
    UPDATE conversations c
       SET workspace_id = COALESCE(live.workspace_id, s.workspace_id)
      FROM sandboxes s
      LEFT JOIN live ON live.sandbox_id = s.id
     WHERE c.sandbox_id = s.id
       AND s.status NOT IN ('terminated', 'failed')
       AND c.workspace_id IS DISTINCT FROM COALESCE(live.workspace_id, s.workspace_id)
    RETURNING c.id
  )
  SELECT (SELECT count(*) FROM ws), (SELECT count(*) FROM cv)
  """

  @doc """
  Insert the implicit workspace for a sandbox about to be reserved.

  `attrs` carries `:user_id`, `:provider` (a string), and the launch's resolved
  `:environment_id` and `:vault_id` — the same values the sandbox row is
  given. Runs inside the caller's reservation transaction, so a refused
  reservation takes the workspace with it.
  """
  @spec insert_implicit(map()) :: {:ok, Workspace.t()} | {:error, Ecto.Changeset.t()}
  def insert_implicit(attrs) when is_map(attrs) do
    attrs
    |> Map.take([:user_id, :environment_id, :vault_id, :provider])
    |> Workspace.implicit_changeset()
    |> Repo.insert()
  end

  # ── explicit workspaces (step 5) ──────────────────────────────────────────

  @doc """
  Create an explicit workspace for `user_id` and start provisioning it
  (ADR 0097, "The workspace API").

  `attrs` (string keys, as a request gives them): `"name"` and
  `"environment_id"`, required; `"vault_id"`, optional; and
  `"sandbox_provider"`, optional, the instance default when absent. The
  environment and vault are fetched scoped to `user_id` (another account's
  id is `:environment_not_found` / `:vault_not_found`, so it cannot be
  probed) and are fixed for the workspace's life, as the provider is.

  The workspace and its first sandbox are written in one commit, the
  sandbox inside the provider's fleet reservation, so a full fleet is the
  create's own `{:error, :fleet_full}` and leaves nothing behind. Under the
  tenant's source lock, as environment and vault deletion take it, so a
  workspace naming one cannot be created while it is being deleted, and its
  delete is refused while the workspace exists (`names_source?/3`, read by
  `Fountain.Agents.delete_source_and_version_agents/2`).

  Answers `{:ok, workspace}` with `status: "provisioning"`, once the
  provision is started (`Fountain.Workspaces.Provisioner`). Audits
  `workspace.created` with the caller's attribution after the commit.
  """
  @spec create_workspace(Ecto.UUID.t(), map(), keyword()) ::
          {:ok, Workspace.t()} | {:error, term()}
  def create_workspace(user_id, attrs, opts \\ []) when is_binary(user_id) and is_map(attrs) do
    # Its own commit, then an audit event and a task that reads it: neither
    # may run inside a caller's transaction.
    if Repo.in_transaction?(),
      do: {:error, :provider_transaction_open},
      else: do_create_workspace(user_id, attrs, opts)
  end

  defp do_create_workspace(user_id, attrs, opts) do
    with {:ok, provider} <- resolve_provider(attrs["sandbox_provider"]),
         {:ok, machine_name} <-
           Fountain.Conversations.mint_machine_name(provider, user_id, nil),
         {:ok, {workspace, sandbox}} <-
           reserve_explicit(user_id, attrs, Atom.to_string(provider), machine_name) do
      Fountain.Audit.record(%{
        user_id: user_id,
        action: "workspace.created",
        resource_type: "workspace",
        resource_id: workspace.id,
        actor: Keyword.get(opts, :actor, "self"),
        request_ip: Keyword.get(opts, :request_ip),
        metadata: %{
          "name" => workspace.name,
          "environment_id" => workspace.environment_id,
          "vault_id" => workspace.vault_id,
          "provider" => workspace.provider
        }
      })

      publish_status(workspace)

      case Fountain.Workspaces.Provisioner.start(workspace, sandbox.id) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          # The reservation stands; the reaper's pass over rows stuck
          # mid-provision fails it, and the workspace with it.
          Logger.error("workspace #{workspace.id}: provision did not start: #{inspect(reason)}")
      end

      {:ok, workspace}
    end
  end

  defp resolve_provider(nil), do: {:ok, Fountain.SandboxProviders.default_provider()}
  defp resolve_provider(""), do: resolve_provider(nil)

  defp resolve_provider(name) when is_binary(name) do
    if name in Fountain.SandboxProviders.known_providers() do
      provider = String.to_existing_atom(name)

      if Fountain.SandboxProviders.enabled?(provider),
        do: {:ok, provider},
        else: {:error, {:sandbox_provider_disabled, provider}}
    else
      {:error, field_error(:sandbox_provider, "is not a sandbox provider this instance knows")}
    end
  end

  defp resolve_provider(_other),
    do: {:error, field_error(:sandbox_provider, "is not a sandbox provider this instance knows")}

  defp field_error(field, message) do
    %Workspace{}
    |> Ecto.Changeset.change()
    |> Ecto.Changeset.add_error(field, message)
  end

  defp reserve_explicit(user_id, attrs, provider, machine_name) do
    Repo.transaction(fn ->
      # The tenant lock environment and vault deletion take (and the launch):
      # a workspace naming a source either commits before the delete's check
      # or finds the source gone.
      :ok = Fountain.InferenceCredentials.lock_source(user_id)

      with {:ok, environment_id} <-
             owned_source(
               Fountain.Environments.Environment,
               attrs["environment_id"],
               user_id,
               :environment_not_found
             ),
           {:ok, vault_id} <-
             owned_source(Fountain.Vaults.Vault, attrs["vault_id"], user_id, :vault_not_found),
           {:ok, workspace} <-
             %{
               user_id: user_id,
               environment_id: environment_id,
               vault_id: vault_id,
               provider: provider,
               name: attrs["name"]
             }
             |> Workspace.create_changeset()
             |> Repo.insert(),
           {:ok, sandbox} <-
             Fountain.Quotas.with_sandbox_reservation([provider: provider], fn ->
               Fountain.Machines.Provision.reserve(%{
                 user_id: user_id,
                 workspace_id: workspace.id,
                 environment_id: environment_id,
                 vault_id: vault_id,
                 provider: provider,
                 machine_name: machine_name,
                 status: "pending"
               })
             end) do
        {workspace, sandbox}
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # A source named by id, which must be the caller's: read `FOR SHARE`, so a
  # delete that locked it first is waited out. A blank id is none, and a
  # missing environment is the changeset's required-field error.
  defp owned_source(_schema, id, _user_id, _not_found) when id in [nil, ""], do: {:ok, nil}

  defp owned_source(schema, id, user_id, not_found) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         found when not is_nil(found) <-
           Repo.one(
             from(s in schema,
               where: s.id == ^uuid and s.user_id == ^user_id,
               select: s.id,
               lock: "FOR SHARE"
             )
           ) do
      {:ok, found}
    else
      _ -> {:error, not_found}
    end
  end

  defp owned_source(_schema, _id, _user_id, not_found), do: {:error, not_found}

  @doc """
  One of `user_id`'s workspaces, explicit or implicit, or `nil`: another
  account's id reads exactly as a missing one.
  """
  @spec get_workspace(term(), Ecto.UUID.t()) :: Workspace.t() | nil
  def get_workspace(id, user_id) when is_binary(user_id) do
    case Ecto.UUID.cast(id) do
      {:ok, uuid} ->
        Repo.one(from(w in Workspace, where: w.id == ^uuid and w.user_id == ^user_id))

      :error ->
        nil
    end
  end

  @doc """
  `user_id`'s workspaces, newest first: the explicit ones, and the implicit
  ones too with `implicit: true` (ADR 0097: implicit workspaces "are not
  listed ... unless asked").
  """
  @spec list_workspaces(Ecto.UUID.t(), keyword()) :: [Workspace.t()]
  def list_workspaces(user_id, opts \\ []) when is_binary(user_id) do
    query =
      from(w in Workspace,
        where: w.user_id == ^user_id,
        order_by: [desc: w.inserted_at, desc: w.id]
      )

    query =
      if Keyword.get(opts, :implicit, false),
        do: query,
        else: from(w in query, where: not w.implicit)

    Repo.all(query)
  end

  @doc """
  The sandbox each of `workspaces` has now: its live one, else its newest,
  or none for a workspace that has never had one. One query for the lot,
  through `Fountain.Machines.Lease.machines/0`, so each carries its
  workspace's lease and transition (a launch into the workspace refuses a
  `destroying` one).
  """
  @spec current_sandboxes([Workspace.t()]) :: %{Ecto.UUID.t() => Sandbox.t()}
  def current_sandboxes([]), do: %{}

  def current_sandboxes(workspaces) when is_list(workspaces) do
    ids = Enum.map(workspaces, & &1.id)

    from(s in Fountain.Machines.Lease.machines(),
      where: s.workspace_id in ^ids,
      distinct: s.workspace_id,
      order_by: [
        asc: s.workspace_id,
        desc: fragment("? NOT IN ('terminated', 'failed')", s.status),
        # A row another was rebuilt from is not the newest, even in the same
        # second (#3013): timestamps are to the second.
        asc:
          fragment(
            "EXISTS (SELECT 1 FROM sandboxes p WHERE p.predecessor_id = ?)",
            s.id
          ),
        desc: s.inserted_at,
        desc: s.id
      ]
    )
    |> Repo.all()
    |> Map.new(&{&1.workspace_id, &1})
  end

  @doc "The sandbox `workspace` has now (`current_sandboxes/1`), or `nil`."
  @spec current_sandbox(Workspace.t()) :: Sandbox.t() | nil
  def current_sandbox(%Workspace{id: id} = workspace),
    do: Map.get(current_sandboxes([workspace]), id)

  @doc """
  Set a failed explicit workspace up again, with no prompt (#3013;
  `POST /api/workspaces/:id/retry`).

  `workspace` comes from the caller's scoped `get_workspace/2`. Refused, with
  nothing written, unless it is `failed` (`{:workspace_not_failed, status}`),
  when its provider is no longer enabled (`{:sandbox_provider_disabled,
  provider}`), and when its provider's fleet is full (`:fleet_full`). An
  implicit workspace, whose setup is its conversation's, is `:not_found`.

  Otherwise the workspace goes `failed` → `provisioning` in one conditional
  write, so of two retries one wins and the other is `:workspace_not_failed`,
  with its `error` cleared; `workspace.retried` is audited with the caller,
  the status is broadcast, and `Fountain.Workspaces.Provisioner.retry/2`
  rebuilds the machine from the failed row in the background, reading the
  environment and vault as they are then. That is the rebuild a prompt into
  the failed workspace starts (ADR 0097, step 4), under the same lease: a
  retry and a prompt set the workspace up once, and the prompt follows that
  setup, failing with it if it fails. The provision settles the workspace
  `ready` or `failed` as on create (`settle_provision/2`); a retry that never
  reached a new machine is put back to `failed` (`abandon_retry/3`).
  """
  @spec retry_workspace(Workspace.t(), keyword()) ::
          {:ok, Workspace.t()}
          | {:error,
             :not_found
             | :fleet_full
             | :sandbox_unavailable
             | :provider_transaction_open
             | {:workspace_not_failed, String.t()}
             | {:sandbox_provider_disabled, atom() | String.t(), :workspace}}
  def retry_workspace(workspace, opts \\ [])

  def retry_workspace(%Workspace{implicit: false, user_id: user_id} = workspace, opts)
      when is_binary(user_id) do
    # Its own commit, then an audit event and a task that reads it.
    if Repo.in_transaction?(),
      do: {:error, :provider_transaction_open},
      else: do_retry_workspace(workspace, opts)
  end

  def retry_workspace(%Workspace{}, _opts), do: {:error, :not_found}

  defp do_retry_workspace(%Workspace{} = workspace, opts) do
    with :ok <- failed?(workspace),
         {:ok, provider} <- enabled_provider(workspace),
         %Sandbox{} = failed <- current_sandbox(workspace) || {:error, :not_found},
         :ok <-
           Fountain.Quotas.check_fleet_ceiling(provider: workspace.provider, exclude: failed.id),
         {:ok, workspace} <- begin_retry(workspace) do
      # `provisioning` goes out before the task can settle the workspace, so
      # the events arrive in order.
      publish_status(workspace)

      case Fountain.Workspaces.Provisioner.retry(workspace, failed.id) do
        {:ok, _pid} ->
          audit_retried(workspace, failed, provider, opts)
          {:ok, workspace}

        # Nothing was started, so nothing is audited and the caller is not
        # told it was: the workspace is `failed` again, and a retry may follow.
        {:error, reason} ->
          Logger.error("workspace #{workspace.id}: retry did not start: #{inspect(reason)}")
          abandon_retry(workspace.id, failed.id, :setup_not_rebuilt)
          {:error, :sandbox_unavailable}
      end
    end
  end

  defp audit_retried(workspace, failed, provider, opts) do
    Fountain.Audit.record(%{
      user_id: workspace.user_id,
      action: "workspace.retried",
      resource_type: "workspace",
      resource_id: workspace.id,
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip),
      metadata: %{
        "failed_sandbox_id" => failed.id,
        "environment_id" => workspace.environment_id,
        "vault_id" => workspace.vault_id,
        "provider" => Atom.to_string(provider)
      }
    })
  end

  defp failed?(%Workspace{status: "failed"}), do: :ok
  defp failed?(%Workspace{status: status}), do: {:error, {:workspace_not_failed, status}}

  # The workspace's provider, fixed at create, must still be enabled, the
  # instance default included: a retry builds a machine there, as a rebuild
  # does (#3020's `rebuild_provider/1`), and on a disabled provider that
  # create could only fail.
  defp enabled_provider(%Workspace{provider: name}) do
    if name in Fountain.SandboxProviders.known_providers() do
      provider = String.to_existing_atom(name)

      if Fountain.SandboxProviders.enabled?(provider),
        do: {:ok, provider},
        else: {:error, {:sandbox_provider_disabled, provider, :workspace}}
    else
      {:error, {:sandbox_provider_disabled, name, :workspace}}
    end
  end

  defp begin_retry(%Workspace{id: id, user_id: user_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(
           from(w in Workspace,
             where:
               w.id == ^id and w.user_id == ^user_id and not w.implicit and
                 w.status == "failed",
             select: w
           ),
           set: [status: "provisioning", error: nil, updated_at: now]
         ) do
      {1, [workspace]} ->
        {:ok, workspace}

      {0, _} ->
        case get_workspace(id, user_id) do
          %Workspace{status: status} -> {:error, {:workspace_not_failed, status}}
          nil -> {:error, :not_found}
        end
    end
  end

  @doc """
  Put an explicit workspace back to `failed` when the retry from
  `failed_sandbox_id` set it `provisioning` and reached no new machine, with
  `reason` in words. Only while nothing has been built since: no live sandbox
  in the workspace and none newer than `failed_sandbox_id` (whoever made one
  settles the workspace, and a retry after that one is not this one's to
  undo). A settled workspace and an ownerless one are left alone too, so this
  is safe to call once after any retry, whatever it answered. Broadcasts the
  change. Best effort, like `settle_provision/2`.
  """
  @spec abandon_retry(Ecto.UUID.t(), Ecto.UUID.t(), term()) :: :ok
  def abandon_retry(workspace_id, failed_sandbox_id, reason)
      when is_binary(workspace_id) and is_binary(failed_sandbox_id) do
    from(w in stranded_retries(),
      where:
        w.id == ^workspace_id and
          not exists(
            from(s in Sandbox,
              join: f in Sandbox,
              on: f.id == ^failed_sandbox_id,
              where:
                s.workspace_id == parent_as(:workspace).id and s.id != f.id and
                  (s.predecessor_id == f.id or s.inserted_at > f.inserted_at),
              select: 1
            )
          )
    )
    |> fail_stranded(reason)
  end

  defp fail_stranded(query, reason) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(from(w in query, select: w),
           set: [status: "failed", error: retry_words(reason), updated_at: now]
         ) do
      {n, workspaces} when n > 0 ->
        Enum.each(workspaces, fn workspace ->
          Logger.warning("workspace #{workspace.id}: retry not set up: #{inspect(reason)}")
          publish_status(workspace)
        end)

      _ ->
        :ok
    end

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("workspaces: could not settle a retry: " <> Exception.message(error))
      :ok
  end

  # What a retry that reached no machine says. Words only, never a term's
  # inspection: nothing here was redacted.
  defp retry_words(:fleet_full),
    do: "the setup could not start again: every sandbox slot on its provider is in use"

  defp retry_words(:provision_deadline_exceeded), do: failure_words(:provision_deadline_exceeded)

  defp retry_words(:server_restarted),
    do: "the setup did not start again before the server restarted; retry it"

  defp retry_words(_reason), do: "the setup could not start again; retry it"

  @doc """
  At boot, put back to `failed` every explicit workspace a retry left
  `provisioning` with no machine being built: the server stopped between the
  retry's answer and its rebuild (`abandon_retry/3`'s condition, over every
  account). A create and a rebuild write their workspace's `provisioning` in
  the same commit as its new sandbox, so nothing else matches. Run by
  `Fountain.Machines.BootSweep`.
  """
  @spec _unsafe_settle_stranded_retries() :: :ok
  def _unsafe_settle_stranded_retries, do: fail_stranded(stranded_retries(), :server_restarted)

  # Explicit, owned, `provisioning`, and with no live sandbox: a retry nothing
  # is building.
  defp stranded_retries do
    from(w in Workspace,
      as: :workspace,
      where:
        not is_nil(w.user_id) and not w.implicit and w.status == "provisioning" and
          not exists(
            from(s in Sandbox,
              where:
                s.workspace_id == parent_as(:workspace).id and
                  s.status not in ^@terminal_statuses,
              select: 1
            )
          )
    )
  end

  @doc """
  Delete an explicit workspace (ADR 0097, Lifecycle): not refused while
  conversations are live.

  `workspace` comes from the caller's scoped `get_workspace/2`. In order:

    1. The workspace is taken from its owner under its row lock: its
       `user_id` is cleared, so from here it reads as gone to every scoped
       query (a `GET`, a launch into it, a wake's rebuild into it) and no
       successor machine can be built in it (`Lease.succeed/3`).
    2. A provision on create still running is stopped
       (`Fountain.Workspaces.Provisioner.stop/1`), which releases its setup
       session.
    3. The machine is fenced and destroyed through its owner
       (`Machines.Destroy`), recording `sandbox.teardown_requested` and
       `sandbox.destroyed` with the caller. A machine another operation holds
       (a conversation's rebuild or resume) keeps the fence, and that
       operation, or `SandboxReaper`'s driver, finishes the destroy.
    4. Every live conversation on it is terminated, with the caller as each
       `conversation.terminated`'s actor; transcripts are kept.
    5. The row is deleted once it has ended (no live sandbox, no live
       conversation, no lease held). One whose destroy is still pending stays
       ownerless until `SandboxReaper`'s hourly pass deletes it, as account
       deletion leaves one (#2329).

  Audits `workspace.deleted` with the caller, outside every transaction.
  """
  @spec delete_workspace(Workspace.t(), keyword()) ::
          {:ok, Workspace.t()} | {:error, :not_found | :provider_transaction_open}
  def delete_workspace(workspace, opts \\ [])

  def delete_workspace(%Workspace{implicit: false, user_id: user_id} = workspace, opts)
      when is_binary(user_id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      with :ok <- disown(workspace) do
        teardown(workspace, opts)
      end
    end
  end

  def delete_workspace(%Workspace{}, _opts), do: {:error, :not_found}

  defp disown(%Workspace{id: id, user_id: user_id}) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case Repo.update_all(
           from(w in Workspace, where: w.id == ^id and w.user_id == ^user_id and not w.implicit),
           set: [user_id: nil, updated_at: now]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  defp teardown(%Workspace{} = workspace, opts) do
    attribution = [
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip)
    ]

    :ok = Fountain.Workspaces.Provisioner.stop(workspace.id)
    destroyed = destroy_live_machine(workspace, attribution)
    terminated = terminate_live_conversations(workspace, attribution)
    :ok = Fountain.Workspaces.Network.release(workspace.id)
    _ = delete_ended([workspace.id])

    Fountain.Audit.record(%{
      user_id: workspace.user_id,
      action: "workspace.deleted",
      resource_type: "workspace",
      resource_id: workspace.id,
      actor: Keyword.fetch!(attribution, :actor),
      request_ip: Keyword.fetch!(attribution, :request_ip),
      metadata: %{
        "name" => workspace.name,
        "provider" => workspace.provider,
        "sandbox_destroyed" => destroyed,
        "conversations_terminated" => terminated
      }
    })

    {:ok, workspace}
  end

  # The machine first, so a conversation's server still on it is told
  # `machine_gone` and stops, and the terminations below take the dead-server
  # path rather than waiting out a server mid-operation. The fence is written
  # first, on its own: the destroy's own claim waits only briefly for a lease
  # another operation holds, and the fence is what makes that operation end
  # by destroying what it built.
  defp destroy_live_machine(%Workspace{id: id}, attribution) do
    # ownership: the workspace's own machine, the workspace the caller's
    # scoped fetch returned.
    case Repo.one(
           from(s in Sandbox,
             where: s.workspace_id == ^id and s.status not in ^@terminal_statuses
           )
         ) do
      nil ->
        false

      %Sandbox{} = sandbox ->
        fence =
          Fountain.Conversations.Lifecycle.fence_sandbox_for_teardown(
            sandbox,
            attribution ++
              [reason: "workspace_deleted", transition_reason: "workspace_deleted"]
          )

        # ownership: the workspace's own machine, read just above for the
        # workspace the caller's scoped fetch returned.
        destroyed =
          Fountain.Conversations.Termination._unsafe_destroy_machine(
            sandbox.id,
            attribution ++
              [
                destroy_reason: :workspace_deleted,
                reason: "workspace_deleted",
                terminating_conversation_id: nil
              ]
          )

        case {fence, destroyed} do
          {_, {:ok, _outcome}} ->
            true

          other ->
            Logger.warning(
              "workspace #{id}: machine #{sandbox.id} left to its fence: #{inspect(other)}"
            )

            false
        end
    end
  end

  defp terminate_live_conversations(%Workspace{id: id}, attribution) do
    from(c in Conversation,
      where: c.workspace_id == ^id and c.status not in ^@terminal_statuses,
      select: c.id
    )
    |> Repo.all()
    |> Enum.count(&terminate_one(&1, id, attribution))
  end

  # ownership: the conversations of the workspace the caller's scoped fetch
  # returned, whose owner it was.
  defp terminate_one(conv_id, workspace_id, attribution) do
    case Fountain.Conversations.Termination.terminate_conversation(conv_id, attribution) do
      :ok ->
        true

      {:ok, _} ->
        true

      # A server that stopped mid-call (the destroy above told it the machine
      # had gone), or one busy past the call's timeout (a rebuild, which the
      # fence now ends by destroying what it built): its conversation is
      # ended here instead, so it cannot outlive its workspace.
      {:error, reason} when reason in [:not_running, :provisioning] ->
        force_terminated(conv_id, workspace_id, reason, attribution)

      other ->
        Logger.warning(
          "workspace #{workspace_id}: conversation #{conv_id} not terminated: #{inspect(other)}"
        )

        false
    end
  end

  defp force_terminated(conv_id, workspace_id, why, attribution) do
    case Repo.update_all(
           from(c in Conversation,
             where:
               c.id == ^conv_id and c.workspace_id == ^workspace_id and
                 c.status not in ^@terminal_statuses
           ),
           set: [
             status: "terminated",
             updated_at: DateTime.utc_now() |> DateTime.truncate(:second)
           ]
         ) do
      {1, _} ->
        Logger.info(
          "workspace #{workspace_id}: conversation #{conv_id} ended with its workspace (#{why})"
        )

        Fountain.Conversations.Termination.audit_lifecycle(
          conv_id,
          "conversation.terminated",
          :ok,
          attribution,
          %{"reason" => "workspace_deleted"}
        )

        true

      {0, _} ->
        # Already ended by the time this ran.
        true
    end
  end

  @doc """
  Rebuild an explicit workspace's machine on purpose, from its environment as
  it is now (#2986): the "Sandbox lost" transition of ADR 0097, done eagerly.

  `workspace` comes from the caller's scoped `get_workspace/2`; an implicit
  one is `:not_found`, as for `delete_workspace/2`. In order:

    0. Refused before anything moves when the workspace's provider has been
       disabled since it was made: `{:sandbox_provider_disabled, provider,
       :workspace}`, which the API renders with the workspace's advice. This
       covers a stranded build too.
    1. Refused while the workspace is `provisioning` (its create, a retry, a
       rebuild after a loss, or an earlier rebuild is still building), or
       while a provision on create runs for it: `:rebuild_in_progress`.
    2. The current machine is replaced through its owner
       (`Fountain.Machines.Machine.replace/2`): with `interrupt: true` every
       running turn on it is ended as interrupted first, and without it a
       running turn refuses the rebuild, `{:turns_running, ids}`, with
       nothing written. Every live conversation moves to the new machine
       with its transcript kept and its runtime session cleared, and is
       re-attached on its next prompt. The old machine is destroyed, its
       disk with it, and the workspace goes `provisioning`.
    3. The new machine is built by the workspace's own provision
       (`Fountain.Workspaces.Provisioner`), as on create: it settles
       `ready` or `failed`, each a `workspace.status` event, and records the
       revision it was built from, so `stale` clears.

  The vault is not touched. Audits `workspace.rebuilt` with the caller's
  attribution, outside every transaction; the old machine's
  `sandbox.destroyed` carries the caller too.
  """
  @spec rebuild_workspace(Workspace.t(), keyword()) ::
          {:ok, Workspace.t()}
          | {:error,
             :not_found
             | :rebuild_in_progress
             | {:turns_running, [Ecto.UUID.t()]}
             | :sandbox_unavailable
             | :fleet_full
             | :provider_transaction_open
             | {:sandbox_provider_disabled, Managoat.Sandbox.provider(), :workspace}
             | term()}
  def rebuild_workspace(workspace, opts \\ [])

  def rebuild_workspace(%Workspace{implicit: false, user_id: user_id} = workspace, opts)
      when is_binary(user_id) do
    if Repo.in_transaction?() do
      {:error, :provider_transaction_open}
    else
      # The provider is checked before anything moves: a rebuild on one
      # disabled since the workspace was made would destroy the working
      # machine and then fail to build the next, and a stranded row's build
      # would fail the same way.
      with {:ok, provider} <- rebuild_provider(workspace) do
        case build_state(workspace) do
          :building -> {:error, :rebuild_in_progress}
          {:stranded, %Sandbox{} = pending} -> resume_build(workspace, pending, opts)
          :settled -> do_rebuild(workspace, provider, opts)
        end
      end
    end
  end

  def rebuild_workspace(%Workspace{}, _opts), do: {:error, :not_found}

  # Whether anybody is building the workspace's machine now: its provision on
  # create (or an earlier rebuild's) running here, or an owner holding the
  # lease of a row mid-provision (a conversation's rebuild after a loss). A
  # workspace `provisioning` on a `pending` row nobody holds is stranded (a
  # rebuild whose provision never started, a node lost mid-build), and a
  # rebuild starts its build rather than refusing until the reaper's hourly
  # pass (review of #2986).
  defp build_state(%Workspace{id: id, status: status} = workspace) do
    cond do
      Fountain.Workspaces.Provisioner.running?(id) ->
        :building

      status != "provisioning" ->
        :settled

      true ->
        case current_sandbox(workspace) do
          %Sandbox{status: s} = sandbox when s in ["pending", "starting"] ->
            if Fountain.Machines.Machine.busy?(sandbox), do: :building, else: {:stranded, sandbox}

          # `provisioning` over an ended machine (a retry, #3013, whose task
          # has not made its machine yet) may be rebuilt: the rebuild's own
          # provision waits for the retry's task, which follows the rebuild.
          _settled_or_none ->
            :settled
        end
    end
  end

  # The conversations already follow the stranded row: building it is the
  # rebuild, from the environment as it is now.
  defp resume_build(%Workspace{} = workspace, %Sandbox{} = pending, opts) do
    case Fountain.Workspaces.Provisioner.start(workspace, pending.id) do
      {:ok, _pid} ->
        Fountain.Audit.record(%{
          user_id: workspace.user_id,
          action: "workspace.rebuilt",
          resource_type: "workspace",
          resource_id: workspace.id,
          actor: Keyword.get(opts, :actor, "self"),
          request_ip: Keyword.get(opts, :request_ip),
          metadata: %{
            "name" => workspace.name,
            "interrupt" => Keyword.get(opts, :interrupt, false) == true,
            "resumed" => true,
            "sandbox_id" => pending.id
          }
        })

        {:ok, Repo.get(Workspace, workspace.id) || workspace}

      {:error, reason} ->
        Logger.error("workspace #{workspace.id}: rebuild did not start: #{inspect(reason)}")
        {:error, :sandbox_unavailable}
    end
  end

  defp do_rebuild(%Workspace{} = workspace, provider, opts) do
    attribution = [
      actor: Keyword.get(opts, :actor, "self"),
      request_ip: Keyword.get(opts, :request_ip)
    ]

    interrupt? = Keyword.get(opts, :interrupt, false) == true

    # ownership: the workspace the caller's scoped fetch returned.
    with %Sandbox{} = old <- current_sandbox(workspace),
         {:ok, name} <- Fountain.Conversations.mint_machine_name(provider, workspace.user_id, nil),
         {:ok, %Sandbox{} = next} <-
           Fountain.Machines.Machine.replace(
             old.id,
             attribution ++
               [
                 attrs: %{machine_name: name},
                 interrupt: interrupt?,
                 # A machine already ended (lost, or a failed setup) has
                 # nothing left at the provider to destroy.
                 provider:
                   if(old.status in @terminal_statuses, do: :already_gone, else: :destroy),
                 notice:
                   "This workspace is being rebuilt from its environment. Send another " <>
                     "prompt to continue — the transcript above is kept, but the disk was " <>
                     "wiped and the agent starts a fresh session."
               ]
           ) do
      Fountain.Audit.record(%{
        user_id: workspace.user_id,
        action: "workspace.rebuilt",
        resource_type: "workspace",
        resource_id: workspace.id,
        actor: Keyword.fetch!(attribution, :actor),
        request_ip: Keyword.fetch!(attribution, :request_ip),
        metadata: %{
          "name" => workspace.name,
          "interrupt" => interrupt?,
          "previous_sandbox_id" => old.id,
          "sandbox_id" => next.id
        }
      })

      case Fountain.Workspaces.Provisioner.start(workspace, next.id) do
        {:ok, _pid} ->
          :ok

        {:error, reason} ->
          # The reservation stands, as after a create whose task did not
          # start: the reaper's pass over stuck rows fails it, and the next
          # prompt retries.
          Logger.error("workspace #{workspace.id}: rebuild did not start: #{inspect(reason)}")
      end

      {:ok, Repo.get(Workspace, workspace.id) || workspace}
    else
      nil -> {:error, :not_found}
      {:error, reason} -> rebuild_refusal(workspace, reason)
    end
  end

  # The workspace's provider, fixed at create (ADR 0097), refused with the
  # workspace's advice when it has since been disabled, as a wake into the
  # workspace is (#3004).
  defp rebuild_provider(%Workspace{provider: provider}) do
    if provider in Fountain.SandboxProviders.known_providers() do
      provider = String.to_existing_atom(provider)

      if Fountain.SandboxProviders.enabled?(provider),
        do: {:ok, provider},
        else: {:error, {:sandbox_provider_disabled, provider, :workspace}}
    else
      {:error, :sandbox_unavailable}
    end
  end

  # The owner's refusals in the API's words. A machine somebody else holds is
  # a rebuild in progress when the workspace says it is building, and
  # otherwise another operation (a park, a wake) to wait out. A fenced
  # machine is one being destroyed: by a delete of this workspace (which has
  # already taken it from its owner, so it reads as gone), or by something
  # else that ends with it terminal, after which a rebuild may run.
  defp rebuild_refusal(%Workspace{id: id}, reason) do
    current = Repo.get(Workspace, id)

    case reason do
      {:turns_running, _ids} = refusal ->
        {:error, refusal}

      :fleet_full ->
        {:error, :fleet_full}

      _ when is_nil(current) or is_nil(current.user_id) ->
        {:error, :not_found}

      reason
      when reason in [:occupied, :machine_busy] or
             (is_tuple(reason) and elem(reason, 0) == :not_rebuildable) ->
        if current.status == "provisioning",
          do: {:error, :rebuild_in_progress},
          else: {:error, :sandbox_unavailable}

      other ->
        Logger.warning("workspace #{id}: not rebuilt: #{inspect(other)}")
        {:error, :sandbox_unavailable}
    end
  end

  @doc """
  Whether an explicit workspace of `user_id`'s names the environment or vault
  `source_id`: the reason its delete is refused, `409 source_in_use_by_workspace`
  (ADR 0097, Data). Read inside the delete's transaction
  (`Fountain.Agents.delete_source_and_version_agents/2`), under the tenant lock
  `create_workspace/3` takes. A workspace being deleted (ownerless) holds
  nothing.
  """
  @spec names_source?(:environment | :vault, Ecto.UUID.t(), Ecto.UUID.t()) :: boolean()
  def names_source?(kind, source_id, user_id) when kind in [:environment, :vault] do
    query = from(w in Workspace, where: w.user_id == ^user_id and not w.implicit)

    query =
      case kind do
        :environment -> from(w in query, where: w.environment_id == ^source_id)
        :vault -> from(w in query, where: w.vault_id == ^source_id)
      end

    Repo.exists?(query)
  end

  @doc """
  Stop every provision on create running for `user_id`'s workspaces, for
  account deletion: before it destroys the account's machines, so their
  destroys take leases those provisions would otherwise hold.
  """
  @spec stop_provisions(Ecto.UUID.t()) :: :ok
  def stop_provisions(user_id) when is_binary(user_id) do
    from(w in Workspace, where: w.user_id == ^user_id and not w.implicit, select: w.id)
    |> Repo.all()
    |> Enum.each(&Fountain.Workspaces.Provisioner.stop/1)
  end

  @doc """
  Move a workspace out of `provisioning` once its sandbox's provision has
  settled: `ready` for a `ready` sandbox, `failed` for a `failed` one.
  Anything else is left alone, and so is a workspace that has already
  settled, so a park, a wake or a later destroy never moves it. An explicit
  workspace is `provisioning` again only while a rebuild of its lost machine
  runs (`Lease.succeed/3`, ADR 0097 step 4), and settles the same way.

  A `failed` workspace carries an `error`: `reason`, the provision's own,
  described and redacted like the transcript (`describe_failure/2`). A
  `ready` one has none. An explicit workspace's change is broadcast as a
  `workspace.status` event (`subscribe/1`); an implicit one's is not, since
  its conversation's own stream already reports its provision.

  Called by `Fountain.Machines.Provision` after its own write commits, outside
  every transaction. Best effort: a workspace that cannot be written is
  logged and the provision's answer stands.
  """
  @spec settle_provision(Sandbox.t(), term()) :: :ok
  def settle_provision(sandbox, reason \\ nil)

  def settle_provision(
        %Sandbox{workspace_id: workspace_id, user_id: user_id, status: status} = sandbox,
        reason
      )
      when is_binary(workspace_id) and is_binary(user_id) and status in ["ready", "failed"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    error = if status == "failed", do: describe_failure(sandbox, reason)

    case Repo.update_all(
           from(w in Workspace,
             where:
               w.id == ^workspace_id and w.user_id == ^user_id and w.status == "provisioning",
             select: w
           ),
           set: [status: status, error: error, updated_at: now]
         ) do
      {1, [%Workspace{implicit: false} = workspace]} ->
        # A setup that ended without saying so (its deadline killed it, the
        # reaper failed its row) ends with its machine. One that finished
        # itself already has; another setup's log is not this one's.
        :ok =
          Fountain.Workspaces.SetupLog.close_running(
            workspace_id,
            sandbox.id,
            if(status == "ready", do: "succeeded", else: "failed")
          )

        publish_status(workspace)

      _ ->
        :ok
    end

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: could not record its provision as #{status}: " <>
          Exception.message(error)
      )

      :ok
  end

  def settle_provision(%Sandbox{}, _reason), do: :ok

  @error_limit 2_000
  @unredactable "the sandbox could not be provisioned"

  @doc """
  The `error` a failed workspace carries: what `reason` says went wrong, in
  words, with the end of what a step printed where the reason quotes it, and
  then redacted as a transcript is (ADR 0097: "redacted like the
  transcript"): every value of the workspace's environment and vault, and
  whatever a live conversation on the machine registered
  (`Fountain.SandboxFiles.redaction_values/1`), replaced with `[REDACTED]`.
  At most #{@error_limit} characters: past that, the failure in words and the
  end of what the step printed, which is the part a reader needs.

  A step's quoted output is cut by the step from its end, so when it was cut
  its first line may begin part-way through a value redaction would no
  longer recognise; that line is dropped before redaction runs. Output short
  enough not to have been cut is quoted whole.
  """
  @spec describe_failure(Sandbox.t(), term()) :: String.t()
  def describe_failure(%Sandbox{} = sandbox, reason) do
    case redaction_values(sandbox) do
      # The values as they are, and as a cleaned quote shows them.
      {:ok, values} ->
        (values ++ Fountain.Workspaces.SetupOutput.matchable(values))
        |> Enum.uniq()
        |> Enum.sort_by(&byte_size/1, :desc)
        |> redact(failure_words(reason))
        |> within_limit()

      :error ->
        @unredactable
    end
  rescue
    # Nothing to redact with is nothing safe to say.
    _ -> @unredactable
  end

  @doc """
  What a workspace's setup output is redacted with, longest first: the values
  `Fountain.SandboxFiles.redaction_values/1` gives for `sandbox` (its
  environment's and vault's, and what a live conversation on it registered),
  and each line of a value that spans lines (a PEM key, a JSON credential),
  since output read a line at a time, or a quoted tail that may begin
  part-way through such a value, would match no whole value. `:error` when
  the tenant's key cannot be loaded, since then the values cannot be read
  either: the caller withholds the output. Used for a failed workspace's
  `error` (`describe_failure/2`) and its setup log
  (`Fountain.Workspaces.SetupOutput`). `sandbox` is the machine's owner's.
  """
  @spec redaction_values(Sandbox.t()) :: {:ok, [String.t()]} | :error
  def redaction_values(%Sandbox{user_id: user_id} = sandbox) when is_binary(user_id) do
    case Fountain.Crypto.load_tenant_key(user_id) do
      {:ok, _dek} ->
        values = Fountain.SandboxFiles.redaction_values(sandbox)

        lines =
          values
          |> Enum.flat_map(&String.split(&1, ["\r\n", "\n"]))
          |> Enum.filter(&(byte_size(&1) >= Fountain.Conversations.Redaction.min_length()))

        {:ok, (values ++ lines) |> Enum.uniq() |> Enum.sort_by(&byte_size/1, :desc)}

      _ ->
        :error
    end
  end

  def redaction_values(%Sandbox{}), do: :error

  defp redact([], text), do: text

  defp redact(values, text),
    do: :binary.replace(text, values, Fountain.Conversations.Redaction.placeholder(), [:global])

  defp failure_words({:packages, code, tail}) when is_binary(tail),
    do: "installing the environment's packages exited #{code}" <> quoted(tail)

  defp failure_words({:packages_unreachable, _}),
    do: "the environment's packages could not be installed: the sandbox did not answer"

  defp failure_words({:setup_exit, code, tail}) when is_binary(tail),
    do: "the environment's setup script exited #{code}" <> quoted(tail)

  defp failure_words({:setup_exit, code}), do: "the environment's setup script exited #{code}"

  defp failure_words({:setup_unreachable, _}),
    do: "the environment's setup script could not be run: the sandbox did not answer"

  defp failure_words({:clone, url, code}) when is_binary(url),
    do: "cloning #{url} exited #{code}"

  defp failure_words({:clone_unreachable, url, _}) when is_binary(url),
    do: "cloning #{url} failed: the sandbox did not answer"

  defp failure_words({:clone_unsupported_url, url}) when is_binary(url),
    do: "#{url} is not an HTTPS repository URL"

  defp failure_words({:clone_invalid_spec, _}), do: "a repository in the environment is invalid"

  defp failure_words({:broker, :backend_lacks_network_policy}),
    do: "the sandbox provider cannot enforce the broker's network floor"

  defp failure_words({:broker, :unreachable, _}), do: "the egress broker is not answering"
  defp failure_words({:broker, :relay_unavailable}), do: "the broker relay did not start"
  defp failure_words({:broker, :relay_unreachable}), do: "the broker relay did not start"

  defp failure_words({:broker, :ca_install_exit, code, _}),
    do: "installing the broker CA exited #{code}"

  defp failure_words({:broker, _, _}), do: "the egress broker could not be set up"
  defp failure_words({:network_policy, _}), do: "the broker's network floor could not be applied"
  defp failure_words(:create_failed), do: "the sandbox provider could not create the machine"

  defp failure_words(:provision_deadline_exceeded),
    do: "the provision did not finish within its deadline"

  defp failure_words(nil), do: "the sandbox could not be provisioned"
  defp failure_words(reason) when is_atom(reason), do: "the provision failed (#{reason})"
  defp failure_words(reason), do: "the provision failed: " <> inspect(reason, limit: 20)

  # The cap, applied after redaction (a slice of redacted text cannot rebuild
  # a value): the words, then as much of the end of the output as fits.
  defp within_limit(text) do
    if String.length(text) <= @error_limit do
      text
    else
      case String.split(text, "\n", parts: 2) do
        [words, output] ->
          keep = max(@error_limit - String.length(words) - 3, 0)
          words <> "\n…" <> String.slice(output, -keep, keep)

        [words] ->
          String.slice(words, 0, @error_limit)
      end
    end
  end

  # The step's tail. When it was cut from a longer output (it is as long as
  # a tail is kept, `StageOutput.tail_bytes/0`), without its first line,
  # which the cut may have begun inside a value; otherwise it is all the
  # step printed, and whole.
  defp quoted(tail) do
    text =
      if byte_size(tail) >= Fountain.Conversations.StageOutput.tail_bytes() do
        case String.split(tail, "\n", parts: 2) do
          [_partial, rest] -> rest
          [_only_partial] -> ""
        end
      else
        tail
      end

    # Cleaned before it is redacted, never after, so a value split by a
    # colour code or a NUL is matched (as a setup log's lines are).
    case text |> Fountain.Workspaces.SetupOutput.clean_lines() |> String.trim_trailing() do
      "" -> ""
      text -> ":\n" <> text
    end
  end

  @doc """
  How each of `workspaces` stands against its environment as it is now
  (`Fountain.Workspaces.Staleness`, #2987), given `sandboxes`, each one's
  current sandbox (`current_sandboxes/1`). One query for the environments,
  each used only where its owner is the workspace's.
  """
  @spec staleness([Workspace.t()], %{Ecto.UUID.t() => Sandbox.t()}) ::
          %{Ecto.UUID.t() => Staleness.t()}
  def staleness(workspaces, sandboxes) when is_list(workspaces) and is_map(sandboxes) do
    envs = environments_of(workspaces)

    Map.new(workspaces, fn %Workspace{} = w ->
      env =
        case Map.get(envs, w.environment_id) do
          %Environment{user_id: user_id} = env when user_id == w.user_id -> env
          _ -> nil
        end

      {w.id, Staleness.of(Map.get(sandboxes, w.id), env)}
    end)
  end

  # Scoped by the workspaces' owners, and each environment is used above
  # only for a workspace of its own owner.
  defp environments_of(workspaces) do
    ids = workspaces |> Enum.map(& &1.environment_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()
    owners = workspaces |> Enum.map(& &1.user_id) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    if ids == [] or owners == [] do
      %{}
    else
      from(e in Environment, where: e.id in ^ids and e.user_id in ^owners)
      |> Repo.all()
      |> Map.new(&{&1.id, &1})
    end
  end

  @doc """
  Tell the account's clients how each of its ready explicit workspaces on
  `env` now stands, after an edit that moved the environment's `revision`
  (`Fountain.Environments.update_environment/3`, #2987): one
  `workspace.status` event per such workspace whose machine is live, with
  `stale` and `changed_fields` as `GET /api/workspaces/:id` gives them. Sent
  for every such edit, so a client also hears an edit that is reverted.

  Three queries however many workspaces share the environment (the
  workspaces, their current sandboxes and the environment as it is now) and
  one local broadcast each, all on the owner's one topic. An implicit
  workspace is not told: its conversation's own stream reports its machine.
  Best effort and outside every transaction: a fault is logged and the edit
  stands. Two edits committed at once may deliver their events in either
  order; each carries the standing its own read saw, and `GET` has the last
  word.
  """
  @spec environment_changed(Environment.t()) :: :ok
  def environment_changed(%Environment{id: env_id, user_id: user_id}) when is_binary(user_id) do
    workspaces =
      Repo.all(
        from(w in Workspace,
          where:
            w.user_id == ^user_id and w.environment_id == ^env_id and not w.implicit and
              w.status == "ready"
        )
      )

    if workspaces != [] do
      sandboxes = current_sandboxes(workspaces)
      standing = staleness(workspaces, sandboxes)

      for %Workspace{id: id} = workspace <- workspaces, live?(Map.get(sandboxes, id)) do
        publish_status(workspace, Map.fetch!(standing, id))
      end
    end

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "environment #{env_id}: its workspaces were not told of the edit: " <>
          Exception.message(error)
      )

      :ok
  end

  def environment_changed(%Environment{}), do: :ok

  defp live?(%Sandbox{status: status}), do: status not in @terminal_statuses
  defp live?(_none), do: false

  @doc """
  Subscribe the caller to `user_id`'s explicit workspaces' status changes:
  `{:workspace_status, %{workspace_id:, name:, status:, error:, revision:,
  built_from_revision:, stale:, changed_fields:}}`; and to their setups'
  output while it runs (#3009): `{:workspace_setup, %{workspace_id:,
  sandbox_id:, step:, status:, lines:, omitted_lines:, at:}}`, redacted and
  rate-bounded by `Fountain.Workspaces.SetupOutput`.
  """
  @spec subscribe(Ecto.UUID.t()) :: :ok | {:error, term()}
  def subscribe(user_id) when is_binary(user_id),
    do: Phoenix.PubSub.subscribe(Fountain.PubSub, topic(user_id))

  defp topic(user_id), do: "workspaces:" <> user_id

  @doc false
  # Broadcast an explicit workspace's status as it now stands, with how its
  # machine stands against its environment (#2987): read here unless the
  # caller has it already.
  @spec publish_status(Workspace.t(), Staleness.t() | nil) :: :ok
  def publish_status(workspace, standing \\ nil)

  def publish_status(%Workspace{implicit: false, user_id: user_id} = workspace, standing)
      when is_binary(user_id) do
    standing = standing || standing_of(workspace)

    Phoenix.PubSub.broadcast(
      Fountain.PubSub,
      topic(user_id),
      {:workspace_status,
       %{
         workspace_id: workspace.id,
         name: workspace.name,
         status: workspace.status,
         error: workspace.error,
         revision: standing.revision,
         built_from_revision: standing.built_from_revision,
         stale: standing.stale,
         changed_fields: standing.changed_fields
       }}
    )

    :ok
  end

  def publish_status(%Workspace{}, _standing), do: :ok

  @doc """
  `workspace`'s last setup log (`Fountain.Workspaces.SetupLog`, #3009), or
  `nil` when none is kept. `workspace` is the caller's, fetched scoped to its
  owner (`get_workspace/2`); the read is scoped to that owner again.
  """
  @spec setup_log(Workspace.t()) :: Fountain.Workspaces.SetupLog.t() | nil
  def setup_log(%Workspace{id: id, user_id: user_id, implicit: false}) when is_binary(user_id),
    do: Fountain.Workspaces.SetupLog.get(id, user_id)

  def setup_log(%Workspace{}), do: nil

  @doc """
  The setup step each of `workspaces` is running, for the explicit ones that
  are `provisioning` and whose setup has begun: `%{workspace_id => step}`
  (#3009). One query per owner; each workspace is its caller's.
  """
  @spec setup_steps([Workspace.t()]) :: %{Ecto.UUID.t() => String.t()}
  def setup_steps(workspaces) when is_list(workspaces) do
    workspaces
    |> Enum.filter(&(not &1.implicit and &1.status == "provisioning" and is_binary(&1.user_id)))
    |> Enum.group_by(& &1.user_id, & &1.id)
    |> Enum.reduce(%{}, fn {user_id, ids}, acc ->
      Map.merge(acc, Fountain.Workspaces.SetupLog.running_steps(ids, user_id))
    end)
  end

  @doc false
  # One `workspace.setup` event for `user_id`'s explicit workspace, from its
  # running setup (`Fountain.Workspaces.SetupOutput`, which has redacted and
  # bounded it). Local, never raises.
  @spec publish_setup(Ecto.UUID.t(), map()) :: :ok
  def publish_setup(user_id, %{workspace_id: _} = payload) when is_binary(user_id) do
    _ = Phoenix.PubSub.broadcast(Fountain.PubSub, topic(user_id), {:workspace_setup, payload})
    :ok
  end

  # A broadcast never raises (review of #2987): its callers run after their
  # commits, some with nothing to catch it. A read that fails says nothing is
  # known, and a client's next GET has the rest.
  defp standing_of(%Workspace{id: id} = workspace) do
    workspaces = [workspace]
    workspaces |> staleness(current_sandboxes(workspaces)) |> Map.fetch!(id)
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning("workspace #{id}: its standing was not read: " <> Exception.message(error))
      %{revision: nil, built_from_revision: nil, stale: false, changed_fields: []}
  end

  @doc """
  The machine's transport relay owner on the sandbox behind `sandbox_id`
  (`Fountain.Broker.TransportRelay`, which refuses a second owner): the
  conversation on an implicit workspace's machine, as it always was, and the
  workspace on an explicit one, so that every conversation in it, and the
  setup that ran before any of them, share one relay.
  """
  @spec relay_owner(Ecto.UUID.t() | nil, String.t()) :: String.t()
  def relay_owner(nil, conversation_id), do: conversation_id

  def relay_owner(sandbox_id, conversation_id) when is_binary(sandbox_id) do
    case Repo.one(from(s in Sandbox, where: s.id == ^sandbox_id, select: s.workspace_id)) do
      nil ->
        conversation_id

      workspace_id ->
        case machine_kind(%{workspace_id: workspace_id}) do
          :explicit -> workspace_id
          :implicit -> conversation_id
        end
    end
  end

  @doc """
  Delete the workspaces `user_id` owns, for account deletion, inside its
  transaction and before the user row goes: every one with no live sandbox.

  A workspace whose sandbox is still live is kept, and the user's delete
  nilifies its `user_id` (ADR 0097, step 3a). That sandbox is one whose
  destroy failed during the deletion (#2329), and its workspace carries the
  machine's lease and `destroying` stamp, which `SandboxReaper`'s driver needs
  to finish the destroy. Ordinarily there is none: the deletion has destroyed
  every machine by now.

  The explicit delete, rather than leaving it to the foreign key, is still
  needed for the others. One delete of the user would otherwise reach each
  terminal sandbox by two paths in one statement, its own `user_id` and its
  workspace's `ON DELETE SET NULL` on `workspace_id`; when the sandbox row was
  written in the deleting transaction (every SQL-sandboxed test, or a launch
  and a deletion in one transaction), PostgreSQL re-checks
  `sandboxes_workspace_id_fkey` between them and the delete fails.

  **The rows are taken in the machine layer's order: conversations, then
  workspaces, then sandboxes** (the teardown fence's and a turn admission's;
  `Fountain.Machines.Lease` locks a workspace before its sandbox, ADR 0097
  step 3b). So the conversations' pointers are cleared, the workspaces locked,
  the sandboxes' pointers cleared, and only then are the workspaces deleted,
  rather than leaving it to the foreign key's `ON DELETE SET NULL`, whose order
  is not this one. A deletion that went another way could deadlock against a
  lease release on a machine it had just destroyed (review of step 3a,
  reproduced).
  The user row's own delete, straight after, still cascades in the foreign
  keys' order, as it did before workspaces. The delete re-checks that no live
  sandbox has appeared. Not audited: `account.deleted`, recorded by
  `Fountain.Accounts.Deletion` outside the transaction, is the record.
  """
  @spec delete_for_account(Ecto.UUID.t()) :: :ok
  def delete_for_account(user_id) when is_binary(user_id) do
    # Every one of the user's conversations, then every one of its workspaces,
    # the kept ones included, locked before anything here or the user row's
    # cascade reaches a sandbox: the cascade nilifies `sandboxes.user_id`
    # before `workspaces.user_id` (the foreign keys' trigger order), and a
    # compare-and-set on a machine that outlived the deletion holds its
    # workspace's row while it waits for its sandbox's (review of step 3b,
    # reproduced).
    _ =
      Repo.all(
        from(c in Conversation,
          where: c.user_id == ^user_id,
          order_by: c.id,
          select: c.id,
          lock: "FOR UPDATE"
        )
      )

    _ =
      Repo.all(
        from(w in Workspace,
          where: w.user_id == ^user_id,
          order_by: w.id,
          select: w.id,
          lock: "FOR UPDATE"
        )
      )

    case Repo.all(from(w in without_live_sandbox(), where: w.user_id == ^user_id, select: w.id)) do
      [] ->
        :ok

      ids ->
        _ =
          Repo.update_all(from(c in Conversation, where: c.workspace_id in ^ids),
            set: [workspace_id: nil]
          )

        _ =
          Repo.update_all(from(s in Sandbox, where: s.workspace_id in ^ids),
            set: [workspace_id: nil]
          )

        {_count, _} = Repo.delete_all(from(w in without_live_sandbox(), where: w.id in ^ids))
        :ok
    end
  end

  defp without_live_sandbox do
    from(w in Workspace,
      as: :workspace,
      where:
        not exists(
          from(s in Sandbox,
            where:
              s.workspace_id == parent_as(:workspace).id and
                s.status not in ^@terminal_statuses
          )
        )
    )
  end

  @doc """
  The kind of workspace that owns the machine behind `sandbox`: `:implicit`,
  ended with its one conversation, or `:explicit`, which a caller made and
  which keeps its machine until it is deleted (ADR 0097, Lifecycle).

  A sandbox with no workspace (a row from before ADR 0097) or whose workspace
  has gone reads as `:implicit`: that is how every machine behaved before
  workspaces, and an explicit workspace is never deleted while it has a live
  sandbox. The flag is fixed at create, so an unlocked read is exact.
  """
  @spec machine_kind(Sandbox.t() | %{workspace_id: Ecto.UUID.t() | nil}) ::
          :implicit | :explicit
  def machine_kind(%{workspace_id: nil}), do: :implicit

  def machine_kind(%{workspace_id: workspace_id}) when is_binary(workspace_id) do
    case Repo.one(from(w in Workspace, where: w.id == ^workspace_id, select: w.implicit)) do
      false -> :explicit
      _implicit_or_gone -> :implicit
    end
  end

  @doc """
  Delete the workspace behind `sandbox_id` if it has ended: an implicit one
  (or one whose account was deleted) with no live sandbox and no live
  conversation (ADR 0097: an implicit workspace "is destroyed with the
  conversation").

  Called once a conversation's termination and its machine's destroy have
  both happened, from whichever of the two finishes last
  (`Fountain.Conversations.Termination`); whichever runs first finds the
  other still live and leaves the row, so one of them deletes it.
  `SandboxReaper` collects whatever neither reached (`_unsafe_sweep_ended/0`).
  Best effort and outside every transaction; nothing is audited, as nothing
  is for an implicit workspace (see the moduledoc).
  """
  @spec release_ended(Ecto.UUID.t() | nil) :: :ok
  def release_ended(nil), do: :ok

  def release_ended(sandbox_id) when is_binary(sandbox_id) do
    case Repo.one(from(s in Sandbox, where: s.id == ^sandbox_id, select: s.workspace_id)) do
      nil -> :ok
      workspace_id -> delete_ended([workspace_id])
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "sandbox #{sandbox_id}: ended workspace not released: " <> Exception.message(error)
      )

      :ok
  end

  @doc """
  Delete every ended workspace (see `release_ended/1`): the backstop
  `SandboxReaper` runs hourly over every account. It collects what the
  termination path did not reach: a destroy that finished after its
  conversation was already gone, the `provisioning` rows a lost wake race left
  before step 4, and the ownerless rows account deletion keeps beside a
  machine whose destroy failed (#2329), once that machine is terminal.
  Returns how many were deleted.
  """
  @spec _unsafe_sweep_ended() :: non_neg_integer()
  def _unsafe_sweep_ended do
    ids = Repo.all(from(w in ended(), select: w.id, limit: 500))
    if ids == [], do: 0, else: delete_ended(ids, :count)
  end

  # Ended: an implicit workspace, or one with no account left to own it, with
  # no live sandbox and no conversation that could still be prompted into it.
  # An explicit workspace with an owner lives until it is deleted (step 5).
  # A row whose lease is still held is not ended yet: a destroy writes its
  # machine terminal before it releases the lease, and deleting the row in
  # between would leave the release nothing to write and change the advisory
  # lock's key under an operation (review of step 4a). The sweep takes it
  # once the lease is released.
  defp ended do
    from(w in without_live_sandbox(),
      where:
        is_nil(w.lease_node) and (w.implicit or is_nil(w.user_id)) and
          not exists(
            from(c in Conversation,
              where:
                c.workspace_id == parent_as(:workspace).id and
                  c.status not in ^@terminal_statuses
            )
          )
    )
  end

  # In the machine layer's lock order, as `delete_for_account/1` takes it:
  # the conversations, then the workspaces, then the pointers cleared and the
  # rows deleted, each re-checked under those locks. A conversation can only
  # leave a workspace (a terminal one is never prompted again) and a live
  # sandbox only enters one through a live conversation's wake, so a row that
  # is ended under the locks stays ended.
  defp delete_ended(ids, answer \\ :ok) do
    {:ok, count} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '5s'")

        _ =
          Repo.all(
            from(c in Conversation,
              where: c.workspace_id in ^ids,
              order_by: c.id,
              select: c.id,
              lock: "FOR UPDATE"
            )
          )

        _ =
          Repo.all(
            from(w in Workspace,
              where: w.id in ^ids,
              order_by: w.id,
              select: w.id,
              lock: "FOR UPDATE"
            )
          )

        case Repo.all(from(w in ended(), where: w.id in ^ids, select: w.id)) do
          [] ->
            0

          ended_ids ->
            _ =
              Repo.update_all(from(c in Conversation, where: c.workspace_id in ^ended_ids),
                set: [workspace_id: nil]
              )

            _ =
              Repo.update_all(from(s in Sandbox, where: s.workspace_id in ^ended_ids),
                set: [workspace_id: nil]
              )

            {count, _} = Repo.delete_all(from(w in Workspace, where: w.id in ^ended_ids))
            count
        end
      end)

    if answer == :count, do: count, else: :ok
  end

  @doc """
  Give every live sandbox a workspace and point every conversation on a live
  sandbox at its sandbox's.

  Run by `Fountain.Machines.BootSweep` on every boot, before anything can
  claim a lease, and once by `20261018210000_add_machine_lease_to_workspaces`.
  A migration runs once, and a rollback to a release before ADR 0097 followed
  by this one again leaves sandboxes it made with no workspace and
  conversations it moved with a stale `workspace_id`. (Since the sandbox's
  lease columns were dropped, #3000, such a rollback needs that drop's `down`
  first.) Idempotent: on a deployment that never rolled back it writes
  nothing.

  The fill is `20261018190100`'s, plus a live sandbox with no user (account
  deletion nilifies `sandboxes.user_id`), which gets an ownerless workspace so
  its owner still has a lease to take. The repoint touches only conversations
  on a live sandbox: a terminal one's pointer is history. Nothing is carried
  from the sandbox row any more: it has no lease columns
  (`20261019150100_drop_sandbox_lease_columns` carried them once, before
  dropping them).

  One transaction under a ten-second `lock_timeout`, like the migrations: a
  stray session holding one of these rows makes the boot log a failure rather
  than wedge (`BootSweep` carries on to the lease sweep).

  Returns `{filled, repointed}`. Nothing is audited: an implicit workspace is
  not something anybody asked for (see the moduledoc).
  """
  @spec _unsafe_reconcile_live() :: {non_neg_integer(), non_neg_integer()}
  def _unsafe_reconcile_live do
    {:ok, {filled, repointed}} =
      Repo.transaction(fn ->
        Repo.query!("SET LOCAL lock_timeout = '10s'")
        %{rows: [[filled, repointed]]} = Repo.query!(@fill_sql)
        {filled, repointed}
      end)

    if filled + repointed > 0 do
      Logger.info("workspaces: #{filled} filled, #{repointed} conversation(s) repointed")
    end

    {filled, repointed}
  end
end
