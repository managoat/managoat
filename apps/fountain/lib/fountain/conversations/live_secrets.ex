defmodule Fountain.Conversations.LiveSecrets do
  @moduledoc """
  Tells the live conversations on a vault or an environment that one of its
  secrets was written or deleted (#2548), so a brokered secret reaches a turn
  that is already running: each server rewrites its broker session's rules
  in place (`Fountain.Conversations.Egress.refresh_live/1`), and the
  sandbox's next tunnel through the broker carries the new value. An
  explicit workspace's setup session, live while its provision on create
  runs, is rewritten the same way (`Fountain.Workspaces.Network.refresh_live/3`).

  Best effort. A cast, through the cluster-wide registry; a conversation
  with no live server, or one whose server a registry miss hides, reads the
  rows again before its next turn (`Egress.refresh_before_turn/1`), as it
  did before this existed. An unbrokered conversation's server ignores the
  cast: its secrets are in the sandbox's env, and only a new process reads
  them.
  """

  import Ecto.Query

  alias Fountain.Agents.Agent
  alias Fountain.Conversations.Conversation
  alias Fountain.Conversations.ConversationServer
  alias Fountain.Repo

  @doc """
  Called by the vault and environment contexts after a secret write or
  delete has committed. `user_id` is the source's owner, and every
  conversation read is that user's.
  """
  @spec secrets_changed(:vault | :environment, String.t(), String.t()) :: :ok
  def secrets_changed(kind, source_id, user_id) do
    kind
    |> conversation_ids(source_id, user_id)
    |> Enum.each(fn id ->
      case ConversationServer.whereis(id) do
        nil -> :ok
        pid -> GenServer.cast(pid, :refresh_secrets)
      end
    end)

    # An explicit workspace's conversations name its environment and vault
    # (they are fixed by it), so the casts above reach them. Its provision on
    # create runs before any of them, under a session of the workspace's own,
    # which is rewritten here too (ADR 0097 step 5).
    Fountain.Workspaces.Network.refresh_live(kind, source_id, user_id)
  end

  defp conversation_ids(kind, source_id, user_id) do
    from(c in Conversation,
      where: c.user_id == ^user_id and c.status not in ["terminated", "failed"],
      select: c.id
    )
    |> on_source(kind, source_id)
    |> Repo.all()
  end

  defp on_source(query, :vault, vault_id), do: from(c in query, where: c.vault_id == ^vault_id)

  # The server's own rule: the conversation's environment, else its agent's.
  defp on_source(query, :environment, env_id) do
    from(c in query,
      left_join: a in Agent,
      on: a.id == c.agent_id,
      where:
        c.environment_id == ^env_id or
          (is_nil(c.environment_id) and a.environment_id == ^env_id)
    )
  end
end
