defmodule Fountain.Conversations.Sandbox do
  use Ecto.Schema
  import Ecto.Changeset

  alias Fountain.Accounts.User
  alias Fountain.Conversations.Conversation
  alias Fountain.Environments.Environment

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  # `suspended`: the sprite still exists at sprites.dev (scaled to zero on its
  # own) but no ConversationServer is attached. The durable resting state of an
  # idle conversation — not counted toward the concurrency quota, woken by the
  # next prompt via the reattach path. See decisions/0017.
  @statuses ~w(pending starting ready suspended terminated failed)

  # The in-flight states of ADR 0058. A `transition` is durable intent, not a
  # lock: the machine's owner writes it before any provider I/O, does the I/O
  # outside every transaction, and clears it by compare-and-set on the same
  # lease epoch. A reader that finds one sees what is being done to the
  # machine rather than racing it.
  #
  # Four of the five are *abandonable*: a stamp whose holder has died is an
  # owner that died, and the next reader clears it so the machine can be used
  # again (`Conversations.register_server/2`, `Machines.Resume.under_lease/3`,
  # `Machines.Provision.clear_foreign_stamp/2`).
  #
  # `destroying` is the one that is not (stage 9a). It is a request that
  # somebody made of this machine, and an owner dying halfway through does not
  # withdraw it, so every reader refuses such a row whatever its lease says,
  # `Machines.Lease.cas_update/4` keeps the stamp through any write that does
  # not retire the row, and `SandboxReaper.sweep_fenced_teardowns/0` drives it
  # to terminal. It is the whole record that a machine was asked to be
  # destroyed: stage 9b stopped reading and writing `reset_requested_at` and
  # `teardown_requested_at`, whose job this column had taken over in 9a.
  @transitions ~w(provisioning resuming parking destroying retargeting)

  @type t :: %__MODULE__{}

  schema "sandboxes" do
    # Provider-scoped sandbox identity: the name Fountain mints
    # (`fountain-<tenant-prefix>-<hex>`) and uses as the primary external ref.
    # The API answers it as `machine_name`, and as the deprecated
    # `sprite_name` until the Fountain-name aliases go (#2108, #2776).
    field :machine_name, :string
    field :status, :string, default: "pending"
    # Which sandbox backend owns this row. Stamped at creation and never
    # re-resolved: a parked sandbox wakes on the provider that holds its
    # disk, whatever the instance default is by then.
    field :provider, :string, default: "sprites"
    # Adapter-opaque state (e.g. a server-assigned id). Never tenant-visible.
    field :provider_meta, :map, default: %{}
    field :terminated_at, :utc_datetime
    field :last_resumed_at, :utc_datetime
    # `reset_requested_at` and `teardown_requested_at` were the fence until
    # ADR 0058 stage 9a moved the intent onto the `destroying` stamp above.
    # Stage 9b-i stopped reading them and 9b-ii dropped the columns.
    # The skill selection this machine was last reconciled to, so the next
    # reconciliation knows which entries under its conversation's skills root
    # are ours. `nil` is "unknown", not "none": the reconciliation then falls
    # back to the conversation's Agent version
    # (`Fountain.Conversations.Skills.previous_skills/1`). One list per machine,
    # because a machine carries one conversation and so one runtime (ADR 0073);
    # it was keyed by runtime while machines hosted mixed-runtime guests
    # (#2514). Written through `Fountain.Machines.Machine.record_skills/2`.
    field :applied_skills, {:array, :map}
    # The machine owner's lease and its in-flight state (ADR 0058).
    # `lease_epoch` is monotonic and never reused; `lease_node` names the
    # process of this boot that holds the machine (ADR 0072); `transition` and
    # `transition_reason` are the durable intent behind a provider round trip.
    # The three `lease_*` columns are written only by
    # `Fountain.Machines.Lease`, and every state write an owner makes is a
    # compare-and-set on the epoch. All five are deliberately absent from
    # `changeset/2` — an owner's write is not something a caller's attrs may
    # reach.
    #
    # `transition` has **two writers**, and the second is the point of stage
    # 9a. A *fence* stamps `destroying`, holding no lease —
    # `Lifecycle.do_fence_sandbox_for_teardown/2`, through
    # `Machines.Destroy.stamp_intent!/2` rather than `changeset/2`. (Until
    # stage 9b the fence wrote two columns beside the stamp, in the same
    # commit; 9b-ii dropped them.) A fence is by definition written by somebody
    # who does not own the machine; the protocol's own stamp, one step later
    # and under its epoch, restates it with the destroy's reason. Nothing
    # writes any other transition from outside `Machines`.
    field :lease_epoch, :integer, default: 0
    field :lease_node, :string
    field :transition, :string
    field :transition_reason, :string
    belongs_to :environment, Environment
    # The identity the disk was materialized from, with the environment:
    # env vars, packages, repos and setup scripts are written at provision.
    # Nilified when the agent or vault is deleted, like a conversation's own
    # pointers — the row outlives them as history.
    belongs_to :agent, Fountain.Agents.Agent
    belongs_to :vault, Fountain.Vaults.Vault
    belongs_to :user, User
    # The workspace that owns this machine (ADR 0097). Every sandbox created
    # since step 2 is born with an implicit one, in its reservation's
    # transaction; a terminal row from before then has none. At most one
    # non-terminal sandbox per workspace (`sandboxes_live_workspace_index`).
    # Nilified when the workspace is deleted, as the row outlives its user.
    # Nothing reads it yet.
    belongs_to :workspace, Fountain.Workspaces.Workspace
    has_many :conversations, Conversation
    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc "The in-flight states a machine's owner may stamp (ADR 0058)."
  def transitions, do: @transitions

  def changeset(sandbox, attrs) do
    sandbox
    |> cast(attrs, [
      :machine_name,
      :status,
      :provider,
      :provider_meta,
      :terminated_at,
      :last_resumed_at,
      :applied_skills,
      :environment_id,
      :agent_id,
      :vault_id,
      :user_id,
      :workspace_id
    ])
    |> validate_required([:machine_name, :status, :provider])
    |> validate_owner()
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:provider, Fountain.SandboxProviders.known_providers())
    |> unique_constraint(:machine_name,
      name: :sandboxes_live_machine_name_index,
      message: "is already assigned to a live sandbox on this provider"
    )
    |> unique_constraint(:workspace_id,
      name: :sandboxes_live_workspace_index,
      message: "already has a live sandbox"
    )
    |> foreign_key_constraint(:workspace_id)
  end

  # Deleting a user nilifies `sandboxes.user_id` (the row is kept for billing
  # and audit), and account deletion carries on past a destroy that raised, so
  # a live row can outlive its owner. Retiring that row must still be possible
  # — otherwise the only write that frees its fleet slot and lets the reaper
  # destroy its machine is refused forever. Anything short of a terminal write
  # still needs an owner, as does every new row.
  defp validate_owner(changeset) do
    orphan_retiring? =
      changeset.data.__meta__.state == :loaded and is_nil(changeset.data.user_id) and
        not Map.has_key?(changeset.changes, :user_id) and
        get_field(changeset, :status) in ~w(terminated failed)

    if orphan_retiring?, do: changeset, else: validate_required(changeset, :user_id)
  end
end
