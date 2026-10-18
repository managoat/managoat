defmodule Fountain.Quotas do
  @moduledoc """
  The fleet ceilings: the most live sandboxes the deployment runs at once on
  each provider. Every provider has its own (`SANDBOX_FLEET_CEILING_SPRITES`,
  `SANDBOX_FLEET_CEILING_E2B`), each defaulting to `SANDBOX_FLEET_CEILING`,
  which defaults to 20 — the Sprites plan's limit (#2667).

  `with_sandbox_reservation/2` checks the ceiling of the provider the machine
  runs on, counting only that provider's sandboxes, under that provider's
  advisory lock, and refuses with `:fleet_full` when every slot on it is in
  use, whoever holds them. A full Sprites fleet does not refuse an E2B start,
  nor the reverse. There is no per-account cap and no queue: a self-hosted
  deployment's accounts share each provider bill by choice, and a refused
  start is retried by its caller (ADR 0042, as amended 2026-10-13 and
  2026-10-15).

  ## What counts

  A sandbox counts while it is compute: `pending`, `starting` and `ready`.
  `pending` and `starting` count because a sprite is being paid for from the
  moment provisioning begins, and counting only `ready` would let a burst of
  concurrent starts sail past the ceiling before any of them settle. `suspended`
  deliberately does NOT count — a parked sprite is scaled to zero and costs
  ~nothing (decisions/0017) — which means this set is narrower than the admin
  sandbox view's "anything non-terminal": the admin table will list a suspended
  sandbox that the counter ignores. Waking one re-runs the ceiling check
  (`Fountain.Machines.Resume`). Unconfirmed resets also count,
  even on parked machines, and cannot use the replacement exclusion.

  **A machine being woken counts from the moment it is admitted** (ADR 0058
  stage 7a): a row stamped `transition: "resuming"` under a *live* lease is
  compute that has been paid for and is on its way up, and it counts even while
  its status still says `suspended`. That stamp is written inside
  `with_sandbox_reservation/2`'s own transaction, which is what makes the
  reservation a reservation rather than a read — without it, two wakes of two
  parked machines would each pass a check the other was invisible to and both
  come up past a ceiling with room for one.

  The live-lease half is what keeps it honest in the other direction. A resume
  whose owner died leaves the stamp behind, and counting *that* would hold a
  slot until some later sweep cleared it. So a `resuming` row counts only while
  its lease is held by this boot (ADR 0072): the boot sweep clears every
  earlier boot's, and the next claim on the machine clears one whose holder
  died in this boot. SQL cannot ask whether that holder is still alive, so in
  between a resume that crashed in this boot holds its slot; a crash there is a
  defect, since the protocol rescues its adapter.

  **A machine being destroyed counts until its row is terminal** (stage 9a),
  and this one takes no lease reading at all. `transition: "destroying"` is
  durable intent rather than an operation in flight: an owner that died between
  the fence and the finalize left a machine that is still at the provider and
  still billing, and the driver that ends it runs on a cron. So the slot is held
  for as long as the row is. `reset_requested_at` did the same for a reset
  until stage 9b, which stopped reading it: both fences write this stamp.
  """

  import Ecto.Query

  alias Fountain.Conversations.Sandbox
  alias Fountain.Machines.Lease
  alias Fountain.Repo

  @active_statuses ~w(pending starting ready)

  @doc """
  Active-sandbox counts for every user with at least one, in a single query —
  for the admin view, which refreshes on a timer and must not run a count per
  row.

  Returns `%{user_id => count}`; users with no active sandboxes are absent.
  """
  @spec active_sandbox_counts() :: %{optional(binary()) => non_neg_integer()}
  def active_sandbox_counts do
    from(s in active_sandboxes(),
      group_by: s.user_id,
      select: {s.user_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Live sandboxes across every tenant: on one provider with `provider:` (the
  count that provider's ceiling is checked against), or on every provider
  without it.

  Pass `exclude: sandbox_id` to leave a machine that is being replaced out of
  the count, as `check_fleet_ceiling/1` does. A machine being destroyed is
  never left out: its slot is held until the row is terminal.
  """
  @spec fleet_count(keyword()) :: non_neg_integer()
  def fleet_count(opts \\ []) do
    query = from(s in active_sandboxes(), select: count(s.id))

    query =
      case Keyword.get(opts, :provider) do
        nil -> query
        provider -> from s in query, where: s.provider == ^provider_key(provider)
      end

    query =
      case Keyword.get(opts, :exclude) do
        nil ->
          query

        excluded ->
          from [s, w] in query,
            where: s.id != ^excluded or w.transition == "destroying"
      end

    Repo.one(query) || 0
  end

  # The `resuming` half reads `Lease.live?/1` in SQL, as far as SQL can: the
  # holder is a lease of this boot. This is a `count(*)` under an advisory
  # lock, so it cannot ask each holder whether its process is alive; see the
  # moduledoc for what that leaves.
  #
  # The transition and the lease are the sandbox's workspace's (ADR 0097,
  # step 3b), and count only while the sandbox itself is live: a workspace
  # names one machine's operation, not its retired sandboxes'.
  defp active_sandboxes do
    from s in Sandbox,
      left_join: w in Fountain.Workspaces.Workspace,
      on: w.id == s.workspace_id,
      where:
        s.status in @active_statuses or
          (s.status not in ["terminated", "failed"] and
             (w.transition == "destroying" or
                (w.transition == "resuming" and
                   like(w.lease_node, ^"#{Lease.boot_prefix()}%"))))
  end

  @doc """
  The fleet ceiling in force for `provider` (`"sprites"` or `:sprites`): its
  own `SANDBOX_FLEET_CEILING_<PROVIDER>` when set, else
  `SANDBOX_FLEET_CEILING`.
  """
  @spec fleet_ceiling(String.t() | atom()) :: non_neg_integer()
  def fleet_ceiling(provider) do
    config = Application.get_env(:fountain, :sandboxes, [])

    case config |> Keyword.get(:fleet_ceilings, %{}) |> Map.get(provider_key(provider)) do
      nil -> Keyword.get(config, :fleet_ceiling, 20)
      ceiling -> ceiling
    end
  end

  @doc """
  Check the deployment against the fleet ceiling of `opts[:provider]`, which
  is required. `:ok`, or `{:error, :fleet_full}` — every slot on that provider
  is in use, whoever holds them. Takes `exclude:` as `fleet_count/1` does.
  """
  @spec check_fleet_ceiling(keyword()) :: :ok | {:error, :fleet_full}
  def check_fleet_ceiling(opts) when is_list(opts) do
    provider = Keyword.fetch!(opts, :provider)

    if fleet_count(opts) < fleet_ceiling(provider), do: :ok, else: {:error, :fleet_full}
  end

  # Advisory-lock keys for sandbox reservations: one per provider, so each
  # provider's ceiling is counted by one reservation at a time, and a start on
  # one provider never waits on a start on another — their counts share no
  # rows. Sprites keeps key 0, the key the whole fleet shared before #2667.
  @lock_namespace 4315
  @provider_lock_keys %{"sprites" => 0, "e2b" => 1}

  # A provider without a fixed key (a test adapter) still gets a stable key of
  # its own, clear of the fixed ones.
  defp lock_key(provider) do
    key = provider_key(provider)
    Map.get_lazy(@provider_lock_keys, key, fn -> 1_000 + :erlang.phash2(key, 1_000_000) end)
  end

  defp provider_key(provider) when is_atom(provider), do: Atom.to_string(provider)
  defp provider_key(provider) when is_binary(provider), do: provider

  @doc """
  Check the fleet ceiling of `opts[:provider]` and run `fun` (which must
  create or stamp a sandbox row on that provider) atomically, under that
  provider's Postgres advisory lock.

  A check alone is check-then-insert: concurrent starts at the last slot could
  each read "room" before any row landed, and each go on to provision a paid
  machine (#330). The lock serializes check and insert, so the second start
  re-counts after the first has committed. One lock per provider is enough
  because each check counts only its own provider's rows.

  `opts` requires `provider:` (the machine's, a string or an atom) and takes
  `exclude: sandbox_id` (see `check_fleet_ceiling/1`). `fun` must return
  `{:ok, value}` or `{:error, reason}`; any error — the ceiling's or `fun`'s —
  rolls the whole reservation back.
  """
  @spec with_sandbox_reservation(keyword(), (-> {:ok, term()} | {:error, term()})) ::
          {:ok, term()} | {:error, term()}
  def with_sandbox_reservation(opts, fun) when is_list(opts) do
    lock_key = opts |> Keyword.fetch!(:provider) |> lock_key()

    Repo.transaction(fn ->
      Repo.query!("SELECT pg_advisory_xact_lock($1, $2)", [@lock_namespace, lock_key])

      with :ok <- check_fleet_ceiling(opts),
           {:ok, value} <- fun.() do
        value
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end
end
