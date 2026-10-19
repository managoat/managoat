defmodule Fountain.Broker.Native.Session do
  @moduledoc """
  One native proxy session row: the hash of the token a sandbox dials the
  broker with, the conversation and tenant it belongs to, and the rules
  the proxy may apply, as ciphertext under the tenant's DEK. See
  `Fountain.Broker.Native.Sessions`.

  A session belongs to exactly one owner: a conversation, or a workspace
  whose provision on create runs before any conversation exists (ADR 0097,
  step 5; `Fountain.Workspaces.Network`). The database checks the pair
  (`broker_session_one_owner`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id
  schema "broker_sessions" do
    field :token_hash, :binary
    field :conversation_id, :binary_id
    field :workspace_id, :binary_id
    field :user_id, :binary_id
    field :rules_ciphertext, :binary
    field :unmatched_host_policy, :string, default: "passthrough"
    field :meta, :map, default: %{}
    field :expires_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @doc false
  def changeset(session, attrs) do
    session
    |> cast(attrs, [
      :token_hash,
      :conversation_id,
      :workspace_id,
      :user_id,
      :rules_ciphertext,
      :unmatched_host_policy,
      :meta,
      :expires_at
    ])
    |> validate_required([
      :token_hash,
      :user_id,
      :rules_ciphertext,
      :expires_at
    ])
    |> validate_one_owner()
    |> validate_inclusion(:unmatched_host_policy, ["passthrough", "deny"])
    |> unique_constraint(:token_hash)
    |> check_constraint(:conversation_id, name: :broker_session_one_owner)
  end

  defp validate_one_owner(changeset) do
    case {get_field(changeset, :conversation_id), get_field(changeset, :workspace_id)} do
      {nil, nil} ->
        add_error(changeset, :conversation_id, "or a workspace must own the session")

      {conv, ws} when is_binary(conv) and is_binary(ws) ->
        add_error(changeset, :workspace_id, "must be empty for a conversation's session")

      _one ->
        changeset
    end
  end
end
