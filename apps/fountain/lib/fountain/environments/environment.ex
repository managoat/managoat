defmodule Fountain.Environments.Environment do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Environments.Secret

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @networking ~w(unrestricted limited)

  # Fields of features that were removed. A caller still sending one is told
  # so rather than having it silently ignored. Environment disk checkpoints
  # went on 2026-10-15; the portable environment layer cache (ADR 0090) on
  # 2026-10-17, its columns unmapped until the migration that drops them.
  @removed_fields %{
    checkpoint_id: "was removed: environment checkpoints no longer exist",
    cache_enabled: "was removed: the environment layer cache no longer exists",
    build_script: "was removed: put reusable setup in setup_script"
  }

  schema "environments" do
    field :inference_revision, Ecto.UUID, read_after_writes: true
    # Replaced by a trigger on every update that changes a provision-time
    # field (`Fountain.Workspaces.Staleness.fields/0`), and only then: a
    # sandbox records the one it was built from (#2987). Never cast.
    field :revision, Ecto.UUID, read_after_writes: true
    field :name, :string
    field :packages, :map, default: %{}
    field :env_vars, :map, default: %{}
    field :setup_script, :string, default: ""
    field :setup_timeout_seconds, :integer, default: 120
    field :networking_type, :string, default: "unrestricted"
    field :networking_config, :map, default: %{}
    field :repositories, {:array, :map}, default: []
    # Free-form caller bookkeeping.
    field :metadata, :map, default: %{}

    # Populated by the *_with_counts reads — not persisted. "Is this
    # environment in use / safe to delete" is the question these answer.
    field :secret_count, :integer, virtual: true, default: 0
    field :agent_count, :integer, virtual: true, default: 0

    belongs_to :user, User
    has_many :secrets, Secret
    timestamps(type: :utc_datetime)
  end

  @doc """
  Where this environment's repositories are cloned: each entry's `mount_path`,
  in order. A runtime whose sandbox limits writes to its own working directory
  is handed these as writable roots (#1684), since a clone the agent cannot
  branch from or commit to is rarely what the environment's author meant.
  """
  @spec repository_mounts(t() | nil) :: [String.t()]
  def repository_mounts(nil), do: []

  def repository_mounts(%__MODULE__{repositories: repos}) do
    for %{"mount_path" => mount} <- repos || [], is_binary(mount), uniq: true, do: mount
  end

  def networking, do: @networking

  @doc false
  def cast_fields,
    do: [
      :name,
      :packages,
      :env_vars,
      :setup_script,
      :setup_timeout_seconds,
      :networking_type,
      :networking_config,
      :repositories,
      :metadata,
      :user_id
    ]

  def changeset(env, attrs) do
    env
    |> cast(attrs, cast_fields())
    |> reject_removed_fields(attrs)
    |> validate_required([:name, :setup_timeout_seconds])
    |> validate_number(:setup_timeout_seconds,
      greater_than_or_equal_to: 1,
      less_than_or_equal_to: 900
    )
    |> validate_inclusion(:networking_type, @networking)
    |> validate_length(:name, min: 1, max: 200)
    |> validate_change(:networking_config, &validate_networking_config/2)
    |> validate_change(:repositories, &validate_repositories/2)
    |> unique_constraint(:name, name: :environments_user_id_name_index)
  end

  # A 422 naming the field, the way `sandbox_mode: "persistent"` is refused
  # since persistent sandboxes went: a client that set it learns it does
  # nothing now. A manifest spec refuses it already as an unsupported key.
  defp reject_removed_fields(changeset, attrs) when is_map(attrs) do
    Enum.reduce(@removed_fields, changeset, fn {field, message}, cs ->
      if Map.has_key?(attrs, field) or Map.has_key?(attrs, Atom.to_string(field)) do
        add_error(cs, field, message)
      else
        cs
      end
    end)
  end

  defp validate_repositories(_field, list) when is_list(list) do
    Enum.flat_map(list, fn
      %{"url" => url, "mount_path" => mount}
      when is_binary(url) and is_binary(mount) and url != "" and mount != "" ->
        if String.starts_with?(mount, "/") and String.starts_with?(url, "https://") do
          []
        else
          [repositories: "url must be https:// and mount_path must be absolute"]
        end

      _ ->
        [repositories: "each entry needs `url` (https://...) and `mount_path` (/abs/path)"]
    end)
  end

  defp validate_repositories(_, _), do: []

  # networking_config's only honored key is "allowed_hosts" (see
  # Fountain.Broker.network_for/1 — under `limited` it becomes the broker's
  # host allowlist). Unknown keys stay allowed for forward
  # compat, but a malformed allowed_hosts fails here instead of silently
  # producing a policy the author didn't intend.
  defp validate_networking_config(_field, %{} = config) do
    case Map.get(config, "allowed_hosts") || Map.get(config, :allowed_hosts) do
      nil ->
        []

      hosts when is_list(hosts) ->
        if Enum.all?(hosts, fn h -> is_binary(h) and h != "" end) do
          []
        else
          [networking_config: "allowed_hosts entries must be non-empty strings"]
        end

      _ ->
        [networking_config: "allowed_hosts must be a list of hostnames"]
    end
  end

  defp validate_networking_config(_, _), do: []
end
