defmodule Fountain.Conversations.InferenceBinding do
  @moduledoc """
  Durable admission of a conversation's inference source.

  Every preparing or resumable conversation reserves its resolved identity and
  revision under the admission locks. Until #2676 this also bound the
  machine's shared `~/.codex/auth.json` to one source across every codex
  conversation on it; with one conversation per machine there is nothing to
  share, and the conversation's own pinned source is the whole check.
  """
  import Ecto.Query
  alias Fountain.{InferenceCredentials, Repo}
  alias Fountain.Conversations.Conversation
  alias Fountain.InferenceCredentials.Source

  @configuration_fields ~w(sandbox_id agent_id agent_version_id runtime environment_id vault_id)a

  @doc """
  Re-read a caller's configuration under the admission locks before resolving
  or reserving inference. The callback may access the database, never a provider.
  A stale actor must reload or stop without failing the newer configuration.
  """
  def with_current(conv, fun) do
    InferenceCredentials.with_source_lock(conv.user_id, fn ->
      if conv.sandbox_id do
        # Match turn admission and teardown before any row lock.
        Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [
          4316,
          Fountain.Conversations.sandbox_lock_key(conv.sandbox_id)
        ])
      end

      current =
        Repo.one(
          from c in Conversation,
            where: c.id == ^conv.id and c.user_id == ^conv.user_id,
            lock: "FOR UPDATE"
        )

      cond do
        is_nil(current) ->
          {:error, :configuration_changed}

        Map.take(current, @configuration_fields) != Map.take(conv, @configuration_fields) ->
          {:error, :configuration_changed}

        true ->
          fun.(current)
      end
    end)
  end

  def reserve(conv, %Source{} = source) do
    with_current(conv, fn current ->
      with :ok <- current_source(current, source),
           :ok <- InferenceCredentials.validate_source(current.user_id, source) do
        case current
             |> Ecto.Changeset.change(inference_source: Source.dump(source))
             |> Repo.update() do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end
    end)
  end

  # A nil snapshot does not authorize replacing a binding committed while the
  # actor was doing provider I/O. Initial legacy binding remains supported;
  # an idempotent reservation must match the persisted source in full, or be
  # the same source rotated in place (#2602), whose new revision the
  # reservation then records.
  defp current_source(%{inference_source: nil}, _source), do: :ok

  defp current_source(current, source) do
    fresh = Source.dump(source)

    if current.inference_source == fresh or Source.rotation?(current.inference_source, fresh),
      do: :ok,
      else: {:error, :inference_source_changed}
  end
end
