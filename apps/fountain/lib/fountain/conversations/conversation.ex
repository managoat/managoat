defmodule Fountain.Conversations.Conversation do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Agents.Agent
  alias Fountain.Conversations.{Sandbox, Turn}
  alias Fountain.Environments.Environment
  alias Fountain.Vaults.Vault

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # No `completed`. It was in this list, three query sites filtered on it, and
  # nothing ever wrote it — production has 247 terminated, 5 idle, 3 failed and
  # zero completed, so every filter keyed on it was silently always empty.
  #
  # There is also no state it could describe. A conversation is either usable
  # (pending/running/idle) or finished with (failed/terminated), and #167
  # settled the ambiguous case: reclaiming an idle sandbox leaves the
  # conversation `idle` and resumable rather than closing it. "Done" is the
  # user's decision, and that is `terminated`.
  @statuses ~w(pending running idle failed terminated)
  @sources ~w(ui api agent)
  @sandbox_api_access_modes ~w(owner none)

  @type t :: %__MODULE__{}

  schema "conversations" do
    field :runtime, :string
    field :status, :string, default: "pending"
    field :runtime_session_id, :string
    field :source, :string, default: "api"
    field :parent_conversation_id, :binary_id
    # How many conversations started this one (#1269, ADR 0083): 0 for a
    # start from outside any sandbox, the starting conversation's depth plus
    # one for a start from inside one. Set once by `Launch.start_conversation/2`,
    # which refuses a start past `Launch.max_depth/0`.
    field :depth, :integer, default: 0
    field :callback_api_key_id, :binary_id
    # The key a server that stopped gracefully mid-turn handed to the server
    # that reattaches the turn (#2835, ADR 0086): the running adapter still
    # holds it. Written and cleared only by `CallbackKey`, never cast.
    field :handover_callback_api_key_id, :binary_id
    # Immutable launch boundary: none never mints a sandbox callback credential.
    field :sandbox_api_access, :string, default: "owner"
    field :title, :string
    # Internal provenance: ACP may revise its own titles, never an owner's name.
    # Existing titles are treated as user-owned because their origin is unknown.
    field :title_source, :string, default: "user"
    field :last_read_at, :utc_datetime_usec
    # Client-supplied key for the external channel this conversation is bound
    # to (a chat thread id via ACP `session/new` `_meta.channelId`, #774).
    # `start_or_resume_conversation/2` resumes by it. Opaque to Fountain.
    field :channel_id, :string
    # Running sums of the turns' `usage.input` / `usage.output` (#827), kept
    # by `Conversations._unsafe_record_turn_usage/2` as each turn ends. Not
    # in `changeset/2`: nothing user-facing writes them.
    field :usage_input_tokens, :integer, default: 0
    field :usage_output_tokens, :integer, default: 0

    # Per-launch permission override (#939). nil means "this launch had no
    # opinion" and the agent's policy stands alone. Set, it is merged with the
    # agent's by `Permissions.effective/2`, which takes the stricter of the two
    # per tool — so this can only ever narrow, and an agent that tightens later
    # tightens this conversation too. The widening case is rejected at the door
    # in `start_conversation/2` rather than silently clamped.
    field :permission_policy, :map
    # `caller_tools` was the retired tool bridge's registry (#1202). The field
    # went with the bridge (ADR 0057, #2252) and the column with #2273, one
    # release later, so that v0.18.0 could be the non-reader a rolling
    # deployment needed before the drop.
    # Free-form `key => value` strings (#1637). Set at launch, merged by the
    # labels route and by the agent's own `_fountain/labels` ACP notification,
    # and filtered on with jsonb containment. `Conversations.Labels` owns the
    # limits and the merge; writes here go through `Labels.changeset/1` below,
    # which is why every door enforces the same rule.
    field :labels, :map, default: %{}

    # Populated by list_conversations_by_activity/1 — not persisted.
    field :turn_count, :integer, virtual: true, default: 0
    field :last_active_at, :utc_datetime_usec, virtual: true

    belongs_to :user, User
    belongs_to :sandbox, Sandbox
    # The workspace its sandbox belongs to (ADR 0097). Set with `sandbox_id`
    # at launch and on a wake that provisions a fresh sandbox; nil on a
    # conversation whose sandbox was already terminal when step 2 shipped.
    # Nothing reads it yet.
    belongs_to :workspace, Fountain.Workspaces.Workspace
    belongs_to :agent, Agent
    belongs_to :vault, Vault
    # Per-launch environment override (#783). nil means "the agent's
    # environment" — resolved at provision, so a conversation whose agent
    # later changes environments follows the agent, as before. Set, it is the
    # baseline this conversation's sandboxes are provisioned from instead,
    # every time (a wake provisions a fresh sandbox from it too).
    belongs_to :environment, Environment
    field :inference_source, :map
    # Per-conversation model override (ADR 0061). nil follows the agent's
    # model; set, it is the model every turn of this conversation runs. Set at
    # launch and fixed for the conversation's life; read through `with_model/2`.
    field :model, :string
    # The agent's ACP session config options (ADR 0062) as they were at
    # launch: what every turn of this conversation requests. Copied from the
    # agent once, like the model is resolved once, so an edit to the agent
    # reaches new conversations only (ADR 0062, addendum of 2026-10-15; #2664).
    # A conversation has no `session_config` of its own (addendum of
    # 2026-10-15, agent only); the column was dropped one release later.
    field :agent_session_config, :map, default: %{}
    # The option list the adapter advertised before the latest prompt, as it
    # sent it. Written by the turn machine; nil until a turn reports one.
    field :session_config_options, {:array, :map}

    # Which shape of the agent this conversation launched under, like the
    # snapshotted `runtime`. The live agent row still drives the sandbox. Not
    # only provenance: `Skills.previous_skills/1` reads the version's skills to
    # tell which entries on an unrecorded disk are Fountain's (ADR 0029,
    # addendum of 2026-10-15).
    belongs_to :agent_version, Fountain.Agents.AgentVersion

    belongs_to :parent_conversation, __MODULE__,
      foreign_key: :parent_conversation_id,
      references: :id,
      type: :binary_id,
      define_field: false

    has_many :child_conversations, __MODULE__, foreign_key: :parent_conversation_id
    has_many :turns, Turn
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  The agent as this conversation runs it: its `model` replaced by the
  conversation's override when there is one (ADR 0061).

  Applied where a conversation loads its agent for the runtime path, so the
  turn, the inference resolution and the runtime module all read one model.
  Never persist the result: it is a view of the agent, not the agent.
  """
  @spec with_model(agent, map()) :: agent when agent: map() | nil
  def with_model(nil, _conv), do: nil
  def with_model(agent, %{model: model}) when is_binary(model), do: %{agent | model: model}
  def with_model(agent, _conv), do: agent
  def sources, do: @sources
  def sandbox_api_access_modes, do: @sandbox_api_access_modes

  defp validate_sandbox_api_access_immutable(changeset) do
    if changeset.data.__meta__.state == :loaded and
         get_change(changeset, :sandbox_api_access) do
      add_error(changeset, :sandbox_api_access, "cannot change after launch")
    else
      changeset
    end
  end

  def changeset(conv, attrs) do
    conv
    |> cast(attrs, [
      :runtime,
      :status,
      :inference_source,
      :runtime_session_id,
      :source,
      :parent_conversation_id,
      :depth,
      :callback_api_key_id,
      :sandbox_api_access,
      :title,
      :user_id,
      :sandbox_id,
      :workspace_id,
      :agent_id,
      :agent_version_id,
      :vault_id,
      :environment_id,
      :channel_id,
      :permission_policy,
      :model,
      :agent_session_config,
      :labels
    ])
    |> validate_required([:runtime, :status, :sandbox_id, :user_id])
    |> Fountain.Changeset.validate_ids([
      :parent_conversation_id,
      :callback_api_key_id,
      :user_id,
      :sandbox_id,
      :workspace_id,
      :agent_id,
      :agent_version_id,
      :vault_id,
      :environment_id
    ])
    |> validate_length(:channel_id, max: 255)
    |> validate_number(:depth, greater_than_or_equal_to: 0)
    |> validate_length(:title, max: 120)
    |> Fountain.Agents.SessionConfig.validate(:agent_session_config)
    |> mark_user_title()
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:source, @sources)
    |> validate_inclusion(:sandbox_api_access, @sandbox_api_access_modes)
    |> validate_sandbox_api_access_immutable()
    |> Fountain.Conversations.Labels.changeset()
    |> foreign_key_constraint(:sandbox_id)
    |> foreign_key_constraint(:workspace_id)
    |> foreign_key_constraint(:agent_id)
    |> foreign_key_constraint(:agent_version_id)
    |> foreign_key_constraint(:vault_id)
    |> foreign_key_constraint(:environment_id)
    |> foreign_key_constraint(:parent_conversation_id)
  end

  defp mark_user_title(changeset) do
    if Map.has_key?(changeset.params || %{}, "title") do
      # The harness can update the row after the owner loaded it. Always
      # write both fields, even when the submitted title matches that snapshot.
      changeset
      |> force_change(:title, get_field(changeset, :title))
      |> force_change(:title_source, "user")
    else
      changeset
    end
  end
end
