defmodule Fountain.Workspaces.Workspace do
  @moduledoc """
  A workspace: `{user_id, environment_id, vault_id}` plus a provider and a
  name, fixed at create, which owns the sandbox (ADR 0097).

  **The machine's owner is the workspace's** (ADR 0097, step 3b): the
  owner process is registered under its id and its lease is on this row
  (`Fountain.Machines.Lease`). Every sandbox is born with an *implicit*
  workspace, made in the same transaction as its row, and every live sandbox
  is given one at boot if it has none
  (`Fountain.Workspaces._unsafe_reconcile_live/0`). The lifecycle reads the
  workspace in step 4, and explicit workspaces, made through
  `/api/workspaces`, come in step 5.

  `user_id` is `nil` only on a workspace whose sandbox outlived its account's
  deletion, as `sandboxes.user_id` is (#2329).

  `status` is the provision's outcome, not the machine's state:
  `provisioning` until the provision of the workspace's sandbox settles, then
  `ready` or `failed`. A park or a destroy does not move it; the sandbox row
  says that. `error` is unused until explicit workspaces ship, where it
  carries a failed provision's redacted reason.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @statuses ~w(provisioning ready failed)

  @type t :: %__MODULE__{}

  schema "workspaces" do
    # Which sandbox backend its machines run on. Fixed at create: a workspace
    # never moves provider (ADR 0097).
    field :provider, :string
    field :name, :string
    field :implicit, :boolean, default: false
    field :status, :string, default: "provisioning"
    field :error, :string
    # The machine owner's lease and its in-flight state (ADR 0058), moved here
    # from `sandboxes` (ADR 0097, step 3b), and written only by
    # `Fountain.Machines.Lease`.
    # Deliberately absent from every changeset: an owner's write is not
    # something a caller's attrs may reach.
    field :lease_epoch, :integer, default: 0
    field :lease_node, :string
    field :transition, :string
    field :transition_reason, :string
    # Nilified, not cascaded, when the user is deleted (step 3a): a workspace
    # whose sandbox outlived its account's deletion keeps that machine's
    # lease and `destroying` stamp. See `Fountain.Workspaces.delete_for_account/1`.
    belongs_to :user, User
    belongs_to :environment, Environment
    belongs_to :vault, Vault
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  The changeset for a new implicit workspace: the launch's resolved
  environment and vault, its provider and its owner. Not for request params:
  every field comes from a launch that has already checked them. No
  `foreign_key_constraint/2`, like `Sandbox.changeset/2`: an environment or
  vault deleted between the launch's resolution and this insert raises, as the
  sandbox insert did before this row came first.
  """
  def implicit_changeset(attrs) do
    %__MODULE__{implicit: true, status: "provisioning"}
    |> cast(attrs, [:user_id, :environment_id, :vault_id, :provider])
    |> validate_required([:user_id, :provider])
    |> validate_inclusion(:provider, Fountain.SandboxProviders.known_providers())
  end
end
