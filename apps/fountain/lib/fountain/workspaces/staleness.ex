defmodule Fountain.Workspaces.Staleness do
  @moduledoc """
  Whether a workspace's sandbox still matches its environment (#2987).

  An environment's `revision` changes on every edit of a provision-time field
  (`fields/0`), by a trigger on the row, and on nothing else: not its `name`
  or `metadata`, and not its secrets, which reach a live sandbox through the
  broker (#2548). Every provision records on the sandbox row what it read
  (`built_from/1`): the revision, and a digest of each provision-time field.
  A reader compares the two (`of/2`) and reports `stale` and the names of the
  fields that differ (`changed_fields`).

  ## Why digests, and which

  `changed_fields` needs to know which fields differ without keeping the
  values the sandbox was built from: `env_vars` may hold anything, and no
  copy of it belongs on the sandbox row. So the row keeps, per field, an
  HMAC-SHA256 of the field's value (in a canonical JSON form, so key order
  does not matter), truncated to 128 bits.

  The key is derived from `MASTER_SECRETS_KEY` for this one purpose
  (`Fountain.Crypto.derived_key/1`), and the message names the environment
  and the field. A plain hash of a low-entropy value (`networking_type`, a
  `setup_timeout_seconds`, a short `env_vars` map) could be reversed by
  hashing guesses; without the key nobody holding only the database can test
  a guess, and anybody holding the key can already decrypt every secret. The
  environment's id in the message keeps equal values in two environments
  from having equal digests. The digests never leave the server: the API and
  the event carry only field names.

  ## Stale

  `stale` is true when the revision differs **and** at least one field's
  digest does: an edit that is then reverted moves the revision but leaves
  the sandbox matching, and is not stale. A sandbox with no record (built
  before this was recorded, or from no environment) is not stale, since
  nothing is known about it; nor is a workspace with no live sandbox, whose
  next prompt builds from the environment as it is then.
  """

  alias Fountain.Conversations.Sandbox
  alias Fountain.Environments.Environment

  @fields ~w(repositories packages setup_script setup_timeout_seconds env_vars
             networking_type networking_config)a

  @key_info "managoat environment field digest v1"

  @live ~w(pending starting ready suspended)

  @type t :: %{
          revision: Ecto.UUID.t() | nil,
          built_from_revision: Ecto.UUID.t() | nil,
          stale: boolean(),
          changed_fields: [String.t()]
        }

  @doc "The provision-time fields, in the order `changed_fields` lists them."
  @spec fields() :: [atom()]
  def fields, do: @fields

  @doc """
  What a provision records on the sandbox row it builds from `env`: the
  revision and each field's digest, as the columns' attrs. Both nil for no
  environment.
  """
  @spec built_from(Environment.t() | nil) :: %{
          built_from_revision: Ecto.UUID.t() | nil,
          built_from_digests: %{String.t() => String.t()} | nil
        }
  def built_from(%Environment{revision: revision} = env) when is_binary(revision),
    do: %{built_from_revision: revision, built_from_digests: digests(env)}

  def built_from(_none), do: %{built_from_revision: nil, built_from_digests: nil}

  @doc """
  How `sandbox` (the workspace's current one, or nil) stands against `env`
  (the workspace's environment as it is now, or nil). See the moduledoc.
  """
  @spec of(Sandbox.t() | nil, Environment.t() | nil) :: t()
  def of(sandbox, env) do
    revision = env && env.revision

    case recorded(sandbox) do
      nil ->
        %{revision: revision, built_from_revision: nil, stale: false, changed_fields: []}

      %Sandbox{built_from_revision: built} = sandbox ->
        changed = if env && revision != built, do: changed(sandbox, env), else: []

        %{
          revision: revision,
          built_from_revision: built,
          stale: changed != [],
          changed_fields: changed
        }
    end
  end

  # A live machine that recorded what it was built from.
  defp recorded(%Sandbox{status: status, built_from_revision: built} = sandbox)
       when status in @live and is_binary(built),
       do: sandbox

  defp recorded(_none_ended_or_unrecorded), do: nil

  # Every field whose digest differs. A record missing a field's digest
  # counts it as changed rather than hiding it.
  defp changed(%Sandbox{built_from_digests: recorded}, %Environment{} = env) do
    recorded = recorded || %{}
    now = digests(env)

    for field <- @fields,
        name = Atom.to_string(field),
        Map.get(recorded, name) != Map.fetch!(now, name),
        do: name
  end

  defp digests(%Environment{id: env_id} = env) do
    key = Fountain.Crypto.derived_key(@key_info)

    Map.new(@fields, fn field ->
      name = Atom.to_string(field)
      message = [env_id, 0, name, 0, canonical(Map.get(env, field))]

      digest =
        :crypto.mac(:hmac, :sha256, key, IO.iodata_to_binary(message))
        |> binary_part(0, 16)
        |> Base.encode16(case: :lower)

      {name, digest}
    end)
  end

  # JSON with every object's keys sorted and keys taken as strings, so a map
  # read back from `jsonb` and the same map as a caller wrote it (atom keys,
  # another order) give the same bytes.
  defp canonical(map) when is_map(map) and not is_struct(map) do
    pairs =
      map
      |> Enum.map(fn {k, v} -> {to_string(k), v} end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {k, v} -> [Jason.encode!(k), ?:, canonical(v)] end)
      |> Enum.intersperse(?,)

    [?{, pairs, ?}]
  end

  defp canonical(list) when is_list(list),
    do: [?[, list |> Enum.map(&canonical/1) |> Enum.intersperse(?,), ?]]

  defp canonical(value), do: Jason.encode!(value)
end
