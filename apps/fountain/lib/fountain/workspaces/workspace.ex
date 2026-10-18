defmodule Fountain.Workspaces.Workspace do
  @moduledoc """
  A workspace: `{user_id, environment_id, vault_id}` plus a provider and a
  name, fixed at create, which owns the sandbox (ADR 0097).

  **Not read by anything yet** (ADR 0097, step 2). Every sandbox created from
  this release on is born with an *implicit* workspace, made in the same
  transaction as its row, and the live sandboxes were backfilled with one.
  The lease moves here in step 3 and the lifecycle reads it in step 4;
  explicit workspaces, made through `/api/workspaces`, come in step 5.

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
    belongs_to :user, User
    belongs_to :environment, Environment
    belongs_to :vault, Vault
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  The changeset for a new implicit workspace: the launch's resolved
  environment and vault, its provider and its owner. Not for request params:
  every field comes from a launch that has already checked them.
  """
  def implicit_changeset(attrs) do
    %__MODULE__{implicit: true, status: "provisioning"}
    |> cast(attrs, [:user_id, :environment_id, :vault_id, :provider])
    |> validate_required([:user_id, :provider])
    |> validate_inclusion(:provider, Fountain.SandboxProviders.known_providers())
    |> foreign_key_constraint(:user_id)
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:vault_id)
  end
end
