defmodule Fountain.Workspaces.SetupLog do
  @moduledoc """
  The last setup's output of an explicit workspace (#3009), as
  `GET /api/workspaces/:id/setup-log` reads it.

  One row per workspace, **replaced by each setup**: the create's, a retry's,
  a rebuild after a loss and the rebuild a caller asks for. The question a
  reader has is "what did the setup that built (or failed to build) this
  machine print", and the previous attempt's answer describes a machine that
  is gone; a workspace's `error` still names a failed attempt's step. One row
  also keeps the storage bounded however often a workspace is rebuilt.

  **In the database, not on the machine**, so it outlives the machine it
  describes: a lost, destroyed or never-created machine's setup is still
  readable, and reading it never wakes a parked one. The row goes with the
  workspace (`ON DELETE CASCADE`) and with its account.

  What is kept is written only by `Fountain.Workspaces.SetupOutput`, which
  frames it into whole lines, redacts it and bounds it before it gets here:
  at most 64 KiB per step (its last lines) and 256 KiB in all. Each write of
  a setup is conditional on the row still being that setup's
  (`sandbox_id`) and still `running`, so a setup that has been replaced, or
  settled from outside (a deadline, the reaper), writes nothing more.

  `status` is the setup's own: `running` while it runs, then `succeeded` or
  `failed`. `step` is the step running, or the last one that ran.
  """

  use Ecto.Schema

  import Ecto.Query, only: [from: 2]

  require Logger

  alias Fountain.Repo

  @primary_key {:workspace_id, :binary_id, autogenerate: false}
  @foreign_key_type :binary_id

  @statuses ~w(running succeeded failed)

  @typedoc "A setup's log as stored."
  @type t :: %__MODULE__{}

  schema "workspace_setup_logs" do
    field :user_id, :binary_id
    field :sandbox_id, :binary_id
    field :status, :string
    field :step, :string
    # One map per step that ran, in order: `step`, `status`, `started_at`,
    # `finished_at`, `output`, `omitted_lines`, `omitted_bytes`.
    field :steps, {:array, :map}, default: []
    field :started_at, :utc_datetime_usec
    field :finished_at, :utc_datetime_usec

    timestamps(type: :utc_datetime)
  end

  def statuses, do: @statuses

  @doc """
  `user_id`'s workspace `workspace_id`'s last setup log, or `nil` if none was
  kept (an implicit workspace, whose setup is its conversation's transcript,
  or a workspace whose setup has not started). The caller has fetched the
  workspace scoped to `user_id`; the read is scoped again.
  """
  @spec get(Ecto.UUID.t(), Ecto.UUID.t()) :: t() | nil
  def get(workspace_id, user_id) when is_binary(workspace_id) and is_binary(user_id),
    do:
      Repo.one(
        from(l in __MODULE__, where: l.workspace_id == ^workspace_id and l.user_id == ^user_id)
      )

  @doc """
  The step each of `workspace_ids` is running, for those whose setup is
  running: `%{workspace_id => step}`. One query, scoped to `user_id`.
  """
  @spec running_steps([Ecto.UUID.t()], Ecto.UUID.t()) :: %{Ecto.UUID.t() => String.t()}
  def running_steps([], _user_id), do: %{}

  def running_steps(workspace_ids, user_id) when is_list(workspace_ids) and is_binary(user_id) do
    from(l in __MODULE__,
      where: l.workspace_id in ^workspace_ids and l.user_id == ^user_id and l.status == "running",
      select: {l.workspace_id, l.step}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc false
  # A setup begins: its row replaces whatever the workspace had. Best effort,
  # like every write here: a log that cannot be written never fails a setup.
  @spec begin(map()) :: :ok
  def begin(%{workspace_id: workspace_id} = row) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    entry =
      Map.merge(row, %{status: "running", finished_at: nil, inserted_at: now, updated_at: now})

    Repo.insert_all(__MODULE__, [entry],
      on_conflict:
        {:replace,
         [:user_id, :sandbox_id, :status, :step, :steps, :started_at, :finished_at, :updated_at]},
      conflict_target: :workspace_id
    )

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: setup log not begun: #{Exception.message(error)}"
      )

      :ok
  end

  @doc false
  # The running setup's row, as it now stands: written only while the row is
  # still this setup's and still `running`.
  @spec put(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) :: :ok
  def put(workspace_id, sandbox_id, set) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    from(l in __MODULE__,
      where:
        l.workspace_id == ^workspace_id and l.sandbox_id == ^sandbox_id and l.status == "running"
    )
    |> Repo.update_all(set: Keyword.put(set, :updated_at, now))

    :ok
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: setup log not written: #{Exception.message(error)}"
      )

      :ok
  end

  @doc """
  Settle a setup that is still `running` once its machine has settled from
  outside it (`Fountain.Workspaces.settle_provision/2`): a deadline that
  killed it, or the reaper failing a row nobody is building. Its running
  step is marked `failed` too. A setup that settled itself, or a row that is
  another setup's, is left alone.
  """
  @spec close_running(Ecto.UUID.t(), Ecto.UUID.t(), String.t()) :: :ok
  def close_running(workspace_id, sandbox_id, status) when status in ["succeeded", "failed"] do
    query =
      from(l in __MODULE__,
        where:
          l.workspace_id == ^workspace_id and l.sandbox_id == ^sandbox_id and
            l.status == "running"
      )

    case Repo.one(query) do
      %__MODULE__{steps: steps} ->
        now = DateTime.utc_now()

        steps =
          Enum.map(steps, fn
            %{"status" => "running"} = step ->
              %{step | "status" => status, "finished_at" => DateTime.to_iso8601(now)}

            step ->
              step
          end)

        Repo.update_all(query,
          set: [
            status: status,
            steps: steps,
            finished_at: now,
            updated_at: DateTime.truncate(now, :second)
          ]
        )

        :ok

      nil ->
        :ok
    end
  rescue
    error in [Postgrex.Error, DBConnection.ConnectionError] ->
      Logger.warning(
        "workspace #{workspace_id}: setup log not settled: #{Exception.message(error)}"
      )

      :ok
  end
end
