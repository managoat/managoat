defmodule Fountain.Conversations.Skills do
  @moduledoc """
  The skills a conversation's config home carries, kept in step with its
  agent.

  A fresh provision mounts them (`Fountain.SandboxSkills.mount_fresh/4`) and
  records what it mounted (`record/2`). A wake reconciles them with
  `mount/4`, because the agent's skill selection can change while its
  conversation sleeps: a skill the agent no longer names is removed, and a new
  one is installed. A GitHub skill already on the disk is left as it is unless
  its `ref` changed.

  The record of what the disk carries is the conversation's `applied_skills`,
  since the skills live in the conversation's own config home
  (`Fountain.Conversations.ConfigHome`, ADR 0097). It was the machine's
  (`sandboxes.applied_skills`) while a machine's skills root was a
  directory of the machine's; the migration that moved it copied each
  machine's record onto its conversation, so a conversation from before keeps
  the record that describes its legacy skills root.
  """

  import Ecto.Query

  alias Fountain.Conversations.{ConfigHome, Conversation}
  alias Fountain.Repo

  @doc """
  Reconcile the config home's skills with the conversation's current
  selection, then record what is now on it.

  The skills root is the conversation's own runtime's, under its config home.

  Run on every wake. A disk from before the manifest existed gets one on its
  first pass. The recorded set is only advanced when the reconciliation
  succeeded, so a failed pass leaves the next one the same work rather than a
  wrong picture of the disk. A GitHub skill whose fetch failed in a pass that
  otherwise succeeded is recorded as it was before, so a failed re-pin is
  retried on the next wake.

  `sprite_env` is the conversation's process environment; only its proxy and
  CA variables reach a GitHub install (`Fountain.Broker.egress_env/1`).
  """
  @spec mount(Managoat.Sandbox.Handle.t(), map(), map() | nil, [{String.t(), String.t()}]) ::
          :ok | {:error, term()}
  def mount(handle, conv, agent, sprite_env \\ []) do
    skills = (agent && agent.skills) || []
    runtime = runtime(conv, agent)
    applied = recorded(conv)

    with {:ok, failed} <-
           Fountain.SandboxSkills.reconcile(
             handle,
             runtime,
             skills,
             applied || previous_skills(conv),
             config_home: ConfigHome.home(conv),
             env: Fountain.Broker.egress_env(sprite_env),
             refresh: repinned(skills, applied)
           ) do
      record(conv, installed(skills, failed, applied))
    end
  end

  @doc """
  Record `skills` as what the conversation's config home now carries.
  `{:error, :not_found}` when the conversation is gone.
  """
  @spec record(map(), [map()]) :: :ok | {:error, :not_found}
  def record(%{id: id, user_id: user_id}, skills) when is_list(skills) do
    # ownership: the conversation's own server, which established it at init.
    case Repo.update_all(
           from(c in Conversation, where: c.id == ^id and c.user_id == ^user_id),
           set: [applied_skills: skills]
         ) do
      {1, _} -> :ok
      {0, _} -> {:error, :not_found}
    end
  end

  # The record as it is now, not as the caller's copy of the row had it: a
  # fresh provision earlier in this server's life may have written it.
  defp recorded(%{id: id, user_id: user_id}) do
    Repo.one(
      from c in Conversation,
        where: c.id == ^id and c.user_id == ^user_id,
        select: c.applied_skills
    )
  end

  # What to record: the selection, except that a remote skill whose fetch
  # failed keeps the entry recorded before it, or none if it had none. Its
  # old ref is what the disk still carries, so the next wake sees the new one
  # as moved and fetches it again (#2971).
  defp installed(skills, [], _applied), do: skills

  defp installed(skills, failed, applied) do
    failed = MapSet.new(failed, &slot/1)
    previous = Map.new(applied || [], &{slot(&1), &1})

    Enum.flat_map(skills, fn skill ->
      if MapSet.member?(failed, slot(skill)),
        do: previous |> Map.get(slot(skill)) |> List.wrap(),
        else: [skill]
    end)
  end

  # A skill's place in the selection, whatever its ref.
  defp slot(skill), do: Tuple.delete_at(pin(skill), 2)

  @doc """
  The skills the conversation's recorded Agent version named.

  The seed for a disk that predates the manifest: it is the selection that
  was installed when the machine was built, so it is the best available
  answer to "which entries under the skills root are ours". Missing history
  returns `nil`, not an empty selection: absence cannot establish ownership.
  """
  @spec previous_skills(map()) :: [map()] | nil
  def previous_skills(%{agent_version_id: nil}), do: nil

  def previous_skills(conv) do
    # The conversation's own version; ownership was checked at the API door.
    case Repo.one(
           from v in Fountain.Agents.AgentVersion,
             where: v.id == ^conv.agent_version_id and v.user_id == ^conv.user_id
         ) do
      nil -> nil
      version -> version.config["skills"] || []
    end
  end

  # The selected GitHub skills whose ref is not the one the conversation
  # recorded installing. Without a record there is nothing to compare: what
  # is on the disk stays, and only a missing directory is installed again.
  defp repinned(_skills, nil), do: []

  defp repinned(skills, applied) do
    recorded = MapSet.new(applied, &pin/1)

    Enum.filter(skills, fn skill ->
      Fountain.SandboxSkills.remote?([skill]) and not MapSet.member?(recorded, pin(skill))
    end)
  end

  defp pin(skill) do
    skill = Map.new(skill, fn {k, v} -> {to_string(k), v} end)
    {skill["source"], blank(skill["name"]), blank(skill["ref"])}
  end

  defp blank(""), do: nil
  defp blank(value), do: value

  # The runtime whose skills root a conversation's skills go under: its own,
  # which is validated-required and outlives its agent.
  defp runtime(conv, agent), do: conv.runtime || (agent && agent.runtime) || "claude"
end
