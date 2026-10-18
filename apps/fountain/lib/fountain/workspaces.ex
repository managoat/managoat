defmodule Fountain.Workspaces do
  @moduledoc """
  Workspaces (ADR 0097). At step 2 of the ADR's sequence this is only the
  writes that keep a workspace beside every sandbox: the implicit workspace a
  sandbox is born with, and its status following that sandbox's provision.
  Nothing reads a workspace yet, so nothing here changes what a caller sees.

  Every query is scoped by `user_id`.

  **Nothing here is audited, deliberately.** An implicit workspace is made in
  the launch's transaction, where an audit event cannot be recorded (ADR 0013),
  and it is not a thing anybody asked for: it is the launch's own sandbox
  given an owner record, and `conversation.created` and
  `sandbox.provisioned` / `sandbox.provision_failed`, recorded after their
  commits, already describe it. `workspace.created` and `workspace.deleted`
  are for the explicit workspaces a caller creates and deletes by API (step 5).
  """

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Conversations.Sandbox
  alias Fountain.Repo
  alias Fountain.Workspaces.Workspace

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

  @doc """
  Move an implicit workspace out of `provisioning` once its sandbox's
  provision has settled: `ready` for a `ready` sandbox, `failed` for a
  `failed` one. Anything else is left alone, and so is a workspace that has
  already settled, so a park, a wake or a later destroy never moves it.

  Called by `Fountain.Machines.Provision` after its own write commits, outside
  every transaction. Best effort: a workspace that cannot be written is
  logged and the provision's answer stands, because nothing reads the status
  yet.
  """
  @spec settle_provision(Sandbox.t()) :: :ok
  def settle_provision(%Sandbox{workspace_id: workspace_id, user_id: user_id, status: status})
      when is_binary(workspace_id) and is_binary(user_id) and status in ["ready", "failed"] do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    _ =
      Repo.update_all(
        from(w in Workspace,
          where:
            w.id == ^workspace_id and w.user_id == ^user_id and w.implicit and
              w.status == "provisioning"
        ),
        set: [status: status, updated_at: now]
      )

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: could not record its provision as #{status}: " <>
          Exception.message(error)
      )

      :ok
  end

  def settle_provision(%Sandbox{}), do: :ok

  @doc """
  Delete every workspace `user_id` owns, for account deletion, inside its
  transaction and before the user row goes.

  The foreign keys alone usually do it (`workspaces.user_id` cascades), but
  one delete of the user then reaches each sandbox by two paths: its own
  `user_id`, nilified, and its workspace, deleted, whose `ON DELETE SET NULL`
  nilifies `workspace_id`. When the sandbox row was written in the deleting
  transaction (every SQL-sandboxed test, or a launch and a deletion in one
  transaction), PostgreSQL re-checks `sandboxes_workspace_id_fkey` on the
  first of those updates, and that check runs after the workspace is gone and
  before the second update, so the delete fails. Deleting the workspaces in a
  statement of their own first settles their sandboxes' and conversations'
  pointers before the user row goes, whatever the order. Not audited:
  `account.deleted`, recorded by `Fountain.Accounts.Deletion` outside the
  transaction, is the record.
  """
  @spec delete_for_account(Ecto.UUID.t()) :: :ok
  def delete_for_account(user_id) when is_binary(user_id) do
    {_count, _} = Repo.delete_all(from(w in Workspace, where: w.user_id == ^user_id))
    :ok
  end
end
