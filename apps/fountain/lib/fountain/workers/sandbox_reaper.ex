defmodule Fountain.Workers.SandboxReaper do
  @moduledoc """
  The one periodic reconciler: every Oban sweep that notices something stuck
  and puts it right. Its passes, by cadence (`config/config.exs` has the two
  cron entries):

  | Cadence | `pass` arg | What it reconciles |
  |---|---|---|
  | hourly, at :07 | none | rows stuck mid-provision, `ready` machines past an idle or lifetime bound with no server, terminal rows whose sprite still exists, and sprites with no row (counted only) |
  | every 5 minutes | `"teardowns"` | destroys that were asked for and then abandoned (`sweep_fenced_teardowns/0`), then turns left `running` with no server (`sweep_stuck_turns/0`) |

  The in-process backstops are not here, because each needs the process it
  guards: `Fountain.Conversations.ProvisionWatchdog` monitors one provision
  and acts the moment it dies, and a live server's idle and lifetime ticks
  (`Fountain.Conversations.Lifecycle`) run in that server. The hourly pass is
  their durable twin for machines whose server is gone.

  Most of this moduledoc is about the sandbox passes, which reconcile the
  `sandboxes` table against what actually exists at sprites.dev.

  ## What leaks, and how

  Both destroy call sites in `ConversationServer` discard the result —
  `_ = Managoat.Sandbox.destroy(handle)` — and then mark the row `terminated` or
  `failed` regardless. So any destroy that fails for a transient reason leaves a
  sprite alive with a database row that says it is gone, and nothing ever looks
  again. This does not need a hard BEAM crash; the ordinary path is enough.

  Measured against production when this was written: 114 sprites existed at
  sprites.dev, 7 of them with a terminal sandbox row. The rest of the drift is
  historical (102 sprites with no row at all, from the pre-rename `aod-*` era)
  and 443 rows whose sprite is already gone.

  The other half is quota. `Fountain.Quotas` counts `pending`, `starting` and
  `ready` toward the deployment's fleet ceiling, deliberately — a sprite bills
  from the moment provisioning starts. A row stuck in `pending` because the
  BEAM died mid-provision therefore holds a slot forever, and enough of those
  leave the whole deployment unable to start a conversation, with no
  self-serve way out.

  ## Three passes, in descending order of confidence

  1. **Release stuck rows.** `pending`/`starting` past the grace period with no
     live `ConversationServer` become `failed`. This frees quota and is safe:
     the row already cannot be used for anything. A sibling runs with it:
     `ready` rows past a lifetime bound are parked or expired. A third, the
     destroys that were asked for and then abandoned, has a five-minute run of
     its own (`sweep_fenced_teardowns/0`, ADR 0058 stage 9b).

  2. **Destroy sprites we know are dead.** A sandbox row in a terminal state
     whose sprite still exists at sprites.dev. Unambiguously ours,
     unambiguously finished.

  3. **Count sprites we do not recognise, and touch nothing.** Reported as a
     log line and a telemetry measurement.

  Pass 3 is deliberately inert. A sprite with no row is not proof of a leak: a
  sprite created seconds ago may simply not have committed its row yet, and an
  organization shared with something else — unsupported since ADR 0005's
  2026-10-15 addendum, but a mistake an operator can make — holds sprites this
  instance never made.
  Destroying by absence-of-evidence would eventually delete someone's live work,
  and unlike a missed sprite that mistake cannot be undone. Cleaning up the
  legacy `aod-*` sprites is a one-off an operator can do by hand, having looked
  at the list.
  """

  # `unique:` since ADR 0058 stage 6b, matching `SandboxResetReconciler`'s
  # (deleted in stage 9b). Oban keys it on the args too, so the hourly run,
  # the five-minute teardown run are unique apart. A tick queued behind a long
  # hourly run on the one-slot `:maintenance` queue is dropped rather than
  # piled up behind it; the next free tick does the same work.
  # Contention used to be rare here — the sweeps wrote rows nobody else wanted
  # — and it is ordinary now that every park and every expiry asks the
  # machine's owner and can be made to wait for a lease. A run that spends its
  # attempt budget on busy waits can outlast the hour between crons, and two
  # reapers sweeping the same fleet would spend their whole time queueing
  # behind each other's leases. At most one incomplete job at a time.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 3,
    unique: [period: :infinity, states: :incomplete]

  import Ecto.Query

  require Logger

  alias Fountain.Conversations

  alias Fountain.Conversations.{
    ConversationServer,
    Lifecycle,
    LogEvent,
    Sandbox,
    Termination,
    Turn
  }

  alias Fountain.Machines.Destroy
  alias Fountain.Machines.Lease
  alias Fountain.Machines.Machine
  alias Fountain.Machines.Occupancy
  alias Fountain.Repo

  # Long enough to clear the slowest legitimate provision: package installs get
  # 300s per command and a clone gets 600s, and several can run in sequence.
  # Being late to release a stuck row costs a little quota; being early kills a
  # sandbox that was still starting.
  @stuck_after_minutes 60

  # A cap per run, so a large backlog drains over several hours instead of
  # firing hundreds of destroy calls at sprites.dev in one burst.
  #
  # It is the budget for the *whole run*, not for pass 2 alone (ADR 0058
  # stage 5b). It used to be pass 2's, because pass 2 made every provider
  # destroy the reaper made: pass 1 only wrote rows terminal and left the
  # machines to be collected. Now an expiry destroys its machine in the call,
  # so an uncapped pass 1 would fire one destroy per abandoned row and the
  # constraint written here would be gone — reachable on stock configuration,
  # because `idle_sweep/1` expires whenever an explicit suspend fails, so a
  # provider suspend outage would put the entire idle backlog through the
  # destroy path in one hourly pass. Pass 1 spends from this first and pass 2
  # gets the remainder; a row that finds it spent is left for the next run,
  # which is the draining this number is for.
  #
  # "The remainder" can be nothing, and that is a real ordering decision rather
  # than an accident: 30 abandoned rows and 5 terminal rows whose sprites are
  # still at the provider means 25 destroys in pass 1 and none in pass 2, and
  # the 5 leaked sprites keep billing invisibly — their rows already read as
  # finished, so no other pass looks at them. Before ADR 0058 stage 5b the two
  # populations shared one `Enum.take/2` here; now pass 1 has strict priority.
  # That is the right way round — a live-status row with no server holds a fleet slot *and* bills, where a terminal row only bills — and the starvation
  # is bounded by the same backlog that causes it.
  @destroy_limit 25

  @doc false
  # Overridable the same way `owner_attempt_limit/0` is, and for the same
  # reason: `sandbox_reaper_test.exs` drives the budget with two rows instead of
  # twenty-six, which is the only way to see one run's budget being *shared*
  # between the expiries and the teardown driver (ADR 0058 stage 9a). Nothing
  # in `lib/` sets it.
  # `|| @destroy_limit` rather than a default argument: the test helper that
  # sets this restores it by writing `nil` back, which `Application.get_env/3`
  # hands straight through as a value.
  def destroy_limit, do: Application.get_env(:fountain, :reaper_destroy_limit) || @destroy_limit

  # The trickle `pass_two_budget/1` guarantees pass 2 when pass 1 saturates.
  # Small on purpose: it is an anti-starvation floor, not a second budget.
  @pass_two_floor 5

  # How many machines one run may *ask an owner about* — parks and expiries
  # together (ADR 0058 stage 6b; the 5b round-3 note that named this).
  #
  # `@destroy_limit` bounds provider destroys and deliberately does not charge
  # a refusal, because the refusal that matters is decided before any provider
  # call. That was the right trade while contention was rare, and it leaves the
  # *attempt* count unbounded: since stage 6b every idle park goes through the
  # owner too, so a fleet with two hundred contended machines would spend
  # `Park.busy_wait_ms/0` on each one and turn an hourly sweep into a
  # seventeen-minute one, holding a `:maintenance` slot for the whole of it.
  #
  # A hundred is a sweep that finishes inside eight minutes even if every
  # single attempt waits out its full five seconds, which is a shape only an
  # outage produces. Machines over the cap are deferred exactly as a spent
  # destroy budget defers them: nothing is written, the row is unchanged, and
  # the next run sees it again.
  #
  # Overridable so `sandbox_reaper_park_test.exs` can drive the cap with two
  # rows instead of a hundred and one. Nothing in `lib/` sets it.
  @owner_attempt_limit 100

  @doc false
  def owner_attempt_limit,
    do: Application.get_env(:fountain, :reaper_owner_attempt_limit, @owner_attempt_limit)

  @terminal_statuses ~w(terminated failed)
  @active_statuses ~w(pending starting)

  # The durable transition of ADR 0058 stage 9a. Every pass here reads it.
  @destroying "destroying"

  # A row whose server died mid-wake looks identical to an abandoned one, so
  # `updated_at` — which the wake path touches when it flips `suspended ->
  # ready` — gets fifteen minutes before a row counts as unheld. A wake that
  # finds the row already `ready` writes nothing, and needs no grace: it starts
  # its server under the machine's lock, in the local registry, before the
  # lock is released (ADR 0072), so `Lifecycle.any_server_alive?/1` sees it.
  @abandoned_grace_minutes 15

  @doc false
  def abandoned_grace_minutes, do: @abandoned_grace_minutes

  # The five-minute run: pass 1c alone (ADR 0058 stage 9b). See
  # `sweep_fenced_teardowns/0` for why it has a cron entry of its own.
  @impl Oban.Worker

  def perform(%Oban.Job{args: %{"pass" => "teardowns"}}) do
    {reconciled, refused} = sweep_fenced_teardowns()

    Logger.info("reaper: teardowns reconciled=#{reconciled} refused=#{refused}")

    # Its own event rather than the hourly run's, because the two runs are
    # different jobs on different clocks: a sum over `[:fountain, :reaper,
    # :run]` would otherwise read an hourly gauge twelve times an hour.
    # `reconciled` counts abandoned destroys this pass finished, which is a
    # defect upstream rather than routine reclamation; `refused` counts the
    # ones an owner would not take, which are machines still standing.
    :telemetry.execute(
      [:fountain, :reaper, :teardowns],
      %{reconciled: reconciled, refused: refused},
      %{}
    )

    # The stuck-turn sweep shares this clock (it had a five-minute cron entry
    # of its own until the backstops were consolidated). It runs after the
    # teardowns and is idempotent, so a retry of a run whose teardowns raised
    # repeats nothing it already did.
    reaped = sweep_stuck_turns()

    Logger.info("autonomous_turn_reaper: reaped=#{reaped}")

    :ok
  end

  def perform(_job) do
    released = release_stuck_sandboxes()
    {parked, expired, refused, skipped} = sweep_abandoned_sandboxes()

    listings = list_by_provider()
    ok_listings = for {p, {:ok, names}} <- listings, into: %{}, do: {p, names}
    # One budget of provider destroys for the whole run, spent by pass 1 first
    # (ADR 0058 stage 5b). See `@destroy_limit` and `pass_two_budget/1`.
    destroyed = destroy_dead_sprites(ok_listings, pass_two_budget(expired))
    untracked = report_untracked(ok_listings)

    live = ok_listings |> Map.values() |> Enum.map(&MapSet.size/1) |> Enum.sum()

    Logger.info(
      "reaper: released=#{released} parked=#{parked} expired=#{expired} " <>
        "refused=#{refused} skipped=#{skipped} " <>
        "destroyed=#{destroyed} untracked=#{untracked} live=#{live}"
    )

    result =
      case for {p, {:error, reason}} <- listings, do: {p, reason} do
        [] ->
          :ok

        [{provider, reason} | _] = failures ->
          # Every pass that could run already did — per-provider isolation
          # means one backend's listing failure does not stop another's
          # destroys. Returning an error lets Oban retry the rest.
          Enum.each(failures, fn {p, r} ->
            Logger.warning("reaper: could not list #{p} sandboxes: #{inspect(r)}")
          end)

          _ = provider
          {:error, reason}
      end

    # `parked` is its own measurement: parks are reversible bookkeeping, and
    # folding them into `expired` would silently change what that metric means.
    # (`reconciled`, the abandoned teardowns, was measured here until stage 9b
    # moved that pass to a run of its own; it is `[:fountain, :reaper,
    # :teardowns]` now.)
    #
    # `skipped` is the one added in stage 6b, and it exists to keep `refused`
    # honest. Since the park revalidates under the machine's lease, the sweep
    # now has a whole class of outcomes that are constraint 1 *working*: a
    # machine somebody started using between the scan and the claim, one that
    # is no longer past a bound, one being torn down, one whose
    # abandoned park was cleared. None of those is a machine the reaper failed
    # to reclaim, and counting them in `refused` — a gauge whose whole job is
    # to say "these machines are still there and something is wrong" — would
    # make an ordinary busy fleet look like an outage.
    #
    # `refused` is its own for both reasons at once (ADR 0058 stage 5b). An
    # expiry now destroys the machine through its owner and that can be
    # refused, so `expired` had to stop meaning "rows the sweep decided to
    # expire" and go back to meaning "machines actually reclaimed" — it is an
    # operator's gauge ("rows expired by the reaper"), and counting
    # still-billing machines in it would report healthy reclamation through an
    # outage that reclaims nothing. What is left over goes here, where a
    # non-zero value says the machines are still there.
    :telemetry.execute(
      [:fountain, :reaper, :run],
      %{
        released: released,
        parked: parked,
        expired: expired,
        refused: refused,
        skipped: skipped
      },
      %{}
    )

    result
  end

  # What is left of the run's budget for pass 2, with a floor under it.
  #
  # Pass 1 has priority (`@destroy_limit` says why), and a backlog big enough
  # to saturate it would otherwise leave pass 2 exactly nothing, run after run,
  # for as long as the backlog lasts. The rows pass 2 collects are already
  # terminal, so no other pass looks at them and nobody would notice: their
  # machines would bill until the backlog cleared. The floor keeps that pass
  # making progress at a trickle whatever pass 1 is doing.
  #
  # It means a saturated run makes at most `@destroy_limit + @pass_two_floor`
  # provider calls rather than `@destroy_limit` — 30 rather than 25. That is the
  # intended reading: the number is a drain rate that keeps a backlog from
  # arriving at the provider all at once, not a hard ceiling, and starving a
  # whole pass indefinitely is the worse failure. (Stage 9a made it 35 with a
  # second floor for pass 1c's driver; stage 9b gave that pass a run of its own
  # and took both the floor and the sharing away.)
  defp pass_two_budget(spent), do: max(@pass_two_floor, destroy_limit() - spent)

  # ── pass 1: rows stuck mid-provision ──────────────────────────────────────

  @doc false
  def release_stuck_sandboxes do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@stuck_after_minutes * 60, :second)

    Lease.machines()
    |> where(
      [s],
      s.status in ^@active_statuses and s.updated_at < ^cutoff
    )
    # Not a machine somebody has asked to be destroyed: the `destroying` stamp
    # (stage 9a; 9b stopped reading the `reset_requested_at` column beside it).
    # A fenced row belongs to `sweep_fenced_teardowns/0`'s driver, which
    # finishes the destroy the fence asked for, where this pass would write
    # `failed` over it and leave the stamp and the sprite behind.
    |> where(^not_destroying())
    |> Repo.all()
    |> Repo.preload(:conversations)
    |> Enum.reject(&Lifecycle.any_server_alive?/1)
    |> Enum.count(&release_stuck/1)
  end

  # Through the owner since ADR 0058 stage 9b: `Machine.fail_provision/2`, the
  # verb for a machine whose provisioning is not going to happen, whose
  # population (`pending`, `starting`) is exactly this pass's. It claims the
  # machine's lease — a provision still at work past this pass's cutoff holds
  # its lease, answers `{:ok, :claimed_elsewhere}` and is left alone, which
  # the bare write this replaced could not tell — revalidates the status under
  # it, writes `failed` by compare-and-set (`terminated_at` with it) and
  # records `sandbox.provision_failed` with this worker as the actor. The
  # reaper's own `sandbox.released_stuck` stays beside it, as `expire/3`'s
  # reason stays beside `sandbox.destroyed`: the protocol's event says the
  # machine failed, this one says why it was the reaper that said so.
  #
  # Not matched with `{:ok, _} =`: a sweep over failure leftovers that crashes
  # on one refused row stops the pass for every row after it (#2329, the rule
  # ADR 0058 records). Anything but `:failed` is logged and left for the next
  # pass — settled by somebody else, held by an owner, or refused.
  defp release_stuck(%Sandbox{} = sandbox) do
    was = sandbox.status

    # ownership: `sandbox` came from this worker's own fleet-wide scan; the
    # reaper is a system sweep with no tenant of its own (`contributing/server.md`).
    case Machine.fail_provision(sandbox.id, actor: "system:sandbox_reaper", reason: :stuck) do
      {:ok, :failed} ->
        Logger.info(
          "reaper: released stuck sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
            "after #{@stuck_after_minutes}m in #{was}"
        )

        record_reap(sandbox, "sandbox.released_stuck", %{
          "previous_status" => was,
          "stuck_after_minutes" => @stuck_after_minutes
        })

        true

      {:ok, outcome} ->
        Logger.info(
          "reaper: stuck sandbox #{sandbox.id} (#{sandbox.machine_name}) settled as " <>
            "#{outcome}; nothing to release"
        )

        false

      {:error, reason} ->
        Logger.warning(
          "reaper: could not release stuck sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(reason)}; left for the next pass"
        )

        false
    end
  end

  # The durable-intent half of "is this machine already spoken for", as a
  # composable condition, so the two liveness passes ask it in exactly the same
  # words — the shape stage 6a gave the marker below, for the reason it gave
  # it: two readings of one rule drift.
  #
  # The stamp is the workspace's (ADR 0097, step 3b), read through
  # `Lease.machines/0`'s `:workspace` binding (a sandbox with no workspace off
  # its own row, as `Lease.machines/0` reads it).
  defp not_destroying do
    dynamic(
      [s, workspace: w],
      is_nil(fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.transition, w.transition)) or
        fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.transition, w.transition) !=
          ^@destroying
    )
  end

  # A live ConversationServer means provisioning is still in flight, however
  # long it has taken. `Lifecycle.any_server_alive?/1` is the one scan for it (#2255 decision 2), shared with `Termination.reap_sandbox/1`,
  # which used to scan for the same thing itself.
  # A sandbox the tenant did not stop, ending for a reason only the reaper
  # knows. Attributed to the worker so "my agent's sandbox vanished" has an
  # answer in the tenant's own trail rather than only in the server log —
  # `admin.sandbox.reaped` covered the admin-clicked path and nothing covered
  # this one (#551).
  defp record_reap(%Sandbox{} = sandbox, action, metadata) do
    Fountain.Audit.record(%{
      user_id: sandbox.user_id,
      action: action,
      resource_type: "sandbox",
      resource_id: sandbox.id,
      actor: "system:sandbox_reaper",
      metadata:
        metadata
        |> Map.put("machine_name", sandbox.machine_name)
        # The old key, kept beside machine_name until #2776.
        |> Map.put("sprite_name", sandbox.machine_name)
        |> Map.put("provider", sandbox.provider)
    })
  end

  # ── pass 1b: ready sandboxes nobody is holding ────────────────────────────

  @doc """
  Sweeps `ready` sandboxes with no live server past a lifetime bound: past the
  idle bound they are parked to `suspended` (the sprite stays, scaled to zero,
  and the next prompt reattaches — decisions/0017); past the max-lifetime
  ceiling they are destroyed through the machine's owner, sprite and all
  (ADR 0058 stage 5b; it used to be the row here and the sprite on pass 2).

  This is the half of #167 that the ConversationServer cannot do. The server
  enforces its own bounds while it is alive, but a sandbox whose server
  died — a crash, a deploy that happened to land
  between the rehydrator's scan and a reattach — has nothing watching it. The
  83-day-old sandbox in production was exactly that: `ready`, no server, alive
  since 2026-05-10.

  `suspended` rows deliberately match no pass: that is the durable resting
  state, aged out by nothing (decisions/0017).

  Activity includes turn insertion, start, completion and the last wake rather
  than `sandboxes.updated_at` or `conversations.updated_at`, both of which get
  touched by bookkeeping the user had nothing to do with — the rehydrator moves
  `conversations.updated_at` on every boot, which would make an abandoned
  conversation look freshly active after each deploy.

  Returns `{parked, expired, refused, skipped}` — machines parked, machines
  reclaimed, machines the owner could not reach, and machines it deliberately
  left alone. The third is separate because `expired` is an operator's gauge
  and must keep meaning "reclaimed"; the fourth because the third is a defect
  gauge and must keep meaning "still there, and wrong". See `perform/1`'s
  telemetry comment (ADR 0058 stages 5b and 6b).
  """
  def sweep_abandoned_sandboxes do
    idle = Lifecycle.idle_timeout_seconds()
    max_lifetime = Lifecycle.max_lifetime_seconds()

    if is_nil(idle) and is_nil(max_lifetime) do
      {0, 0, 0, 0}
    else
      now = DateTime.utc_now()
      grace_cutoff = DateTime.add(now, -@abandoned_grace_minutes * 60, :second)

      candidates =
        Lease.machines()
        |> where(
          [s],
          s.status == "ready" and s.updated_at < ^grace_cutoff
        )
        # And not a machine on its way out, in the words that outlive the
        # column beside them (stage 9a). Idle-parking or expiring a fenced
        # machine would be this sweep deciding the end of a machine whose end
        # somebody else already decided.
        |> where(^not_destroying())
        |> Repo.all()
        |> Repo.preload(:conversations)
        |> Enum.reject(&Lifecycle.any_server_alive?/1)

      # A machine whose owner holds a live lease is mid-operation, and asking
      # it would mean waiting out `Park.busy_wait_ms/0` — five seconds — for an
      # answer already on the row. `sweep_fenced_teardowns/0` has read the
      # lease this way since 5a; since 6b, when a park takes one on every
      # sweep, this pass had to as well, or a busy fleet would spend most of
      # its run asleep. It is not a correctness check — the claim is, and it
      # re-reads everything — it is the cost of asking.
      #
      # Counted rather than dropped. `skipped` means "decided to act, then
      # deliberately left the machine alone", and this is exactly that one step
      # earlier; a machine that appears in no counter at all is one an operator
      # reading the summary cannot account for.
      {held, free} = Enum.split_with(candidates, &Lease.live?/1)

      Enum.each(held, fn sandbox ->
        Logger.info(
          "reaper: left sandbox #{sandbox.id} (#{sandbox.machine_name}) to its owner " <>
            "#{sandbox.lease_node}, which holds the lease"
        )
      end)

      {parked, expired, refused, skipped, _destroys_left, _attempts_left} =
        Enum.reduce(
          Enum.map(free, &{&1, check_bounds(&1, now)}),
          {0, 0, 0, length(held), destroy_limit(), owner_attempt_limit()},
          &sweep_verdict/2
        )

      {parked, expired, refused, skipped}
    end
  end

  # One verdict, against the run's remaining destroy budget.
  #
  # `expired` counts machines this sweep actually reclaimed and `refused` the
  # ones it could not, because since ADR 0058 stage 5b `expire/3` goes through
  # the machine's owner and the owner can say no. Counting the verdict instead
  # of the outcome — which is what this did when `expire/2` could not fail —
  # reports a still-running, still-billing machine as expired.
  #
  # **A refusal does not spend the budget**, and that asymmetry is deliberate.
  # The budget exists to bound calls to the provider, and the refusal that
  # matters in practice — `:machine_busy`, another owner holding the lease —
  # is decided before the fence and makes no call at all. Charging it anyway
  # meant a run of 25 refusals left pass 2 with nothing, so an outage that
  # reclaimed no machines *also* stopped the leftover-sprite pass collecting
  # the ones already known dead, and those keep billing with no other pass
  # looking at them. A refusal from the *finalize* does follow a provider call,
  # so this can undercount by that much; over-counting a handful of calls
  # during an outage is the better error than locking out the pass that cleans
  # up after one.
  #
  # The run's *attempt* budget is spent by every verdict that reaches an owner,
  # whatever the owner says, because what it bounds is the waiting rather than
  # the writing. See `@owner_attempt_limit`.
  defp sweep_verdict({sandbox, {:expired, :idle}}, {p, e, r, s, left, attempts})
       when attempts > 0 do
    case idle_sweep(sandbox, left) do
      :parked -> {p + 1, e, r, s, left, attempts - 1}
      :expired -> {p, e + 1, r, s, left - 1, attempts - 1}
      :refused -> {p, e, r + 1, s, left, attempts - 1}
      :skipped -> {p, e, r, s + 1, left, attempts - 1}
      :deferred -> {p, e, r, s, left, attempts - 1}
    end
  end

  defp sweep_verdict({sandbox, {:expired, :max_lifetime}}, {p, e, r, s, left, attempts})
       when left > 0 and attempts > 0 do
    case expire(sandbox, :max_lifetime, "past max lifetime") do
      :expired -> {p, e + 1, r, s, left - 1, attempts - 1}
      :refused -> {p, e, r + 1, s, left, attempts - 1}
    end
  end

  defp sweep_verdict({sandbox, {:expired, _bound}}, acc) do
    defer(sandbox, acc)
    acc
  end

  defp sweep_verdict({_sandbox, :ok}, acc), do: acc

  # The run has spent one of its two budgets. The row keeps its live status and
  # no fence, so the next run sees it unchanged and deals with it then — which
  # is exactly what a budget is for. Counted as neither expired nor refused:
  # nothing was attempted and nothing went wrong.
  defp defer(%Sandbox{} = sandbox, {_p, _e, _r, _s, _left, attempts}) do
    spent =
      if attempts > 0,
        do: "its #{destroy_limit()} provider destroys",
        else: "its #{owner_attempt_limit()} owner attempts"

    Logger.info(
      "reaper: deferred sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "this run has spent #{spent}"
    )

    :deferred
  end

  # Same clock as ConversationServer.sandbox_clock_start/1: the max-lifetime
  # ceiling measures a continuous run, restarting on a wake from `suspended`.
  #
  # The activity fold is `Occupancy.last_activity_at/1` since ADR 0058 stage
  # 6b, where it used to be a copy of it here. `Machines.Park` re-runs this
  # verdict under the machine's lease before it parks anything (#2307
  # constraint 1), and a recheck that asks a subtly different question from the
  # one the scan asked would refuse parks the scan was right about. One fold.
  defp check_bounds(sandbox, now) do
    Lifecycle.check(
      Lifecycle.clock_start(sandbox),
      Occupancy.last_activity_at(sandbox),
      false,
      now
    )
  end

  # Idle with no server: park through the machine's owner (ADR 0058 stage 6b),
  # which re-reads everything this scan decided on — the status, both fences,
  # the provider's `:suspend` capability, who is on the machine, and this
  # verdict — under the machine's lease, then checkpoints, suspends and writes
  # the row. The sweep no longer suspends anything or writes anything itself;
  # what is left here is the scan, the budget and the counters.
  #
  # The two degradations are unchanged and now come back as answers rather than
  # being decided here: a provider that cannot park and a suspend call that
  # failed both expire the machine instead, because an unparked sandbox keeps
  # billing (decisions/0017).
  defp idle_sweep(sandbox, destroys_left) do
    case Machine.park(sandbox.id,
           actor: "system:sandbox_reaper",
           reason: :idle,
           # No `requesting_conversation_id`: the reaper is on nobody's behalf,
           # so *any* live server on the machine refuses this park — which is
           # the liveness rule this sweep has always had, now applied under the
           # lease instead of before it.
           #
           # No `notify` either: an abandoned machine's conversations were
           # never told it had been parked, and a park is reversible — the next
           # prompt wakes it through the ordinary reattach path.
           verdict: {:expired, :idle}
         ) do
      {:ok, :parked} ->
        Logger.info(
          "reaper: parked idle sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
            "ready with no live server past the idle bound"
        )

        :parked

      # The machine ended up parked, just not by this call — another owner got
      # there first. Counted, because `parked` is a gauge of machines at rest.
      {:ok, :already_parked} ->
        :parked

      # An abandoned park cleared off a machine that is still running, or a row
      # somebody else finished. Nothing was reclaimed and nothing was refused;
      # the next pass looks again at a row that now says what it means.
      {:ok, outcome} when outcome in [:recovered, :already_terminal] ->
        Logger.info(
          "reaper: idle sandbox #{sandbox.id} (#{sandbox.machine_name}) settled as #{outcome}"
        )

        :skipped

      {:error, :cannot_park} ->
        expire_within(sandbox, destroys_left, "idle on a provider without suspend")

      {:error, :suspend_failed} ->
        expire_within(sandbox, destroys_left, "idle; suspend call failed")

      # A teardown landed between this scan's `where` clause and the
      # lease. Somebody else owns the end of this machine, and
      # `sweep_fenced_teardowns/0` is already the backstop for a fence whose
      # owner dies, so this is neither a reclamation nor a failure to report.
      {:error, :fenced} ->
        :skipped

      # Constraint 1 doing its job: somebody started using this machine, or it
      # is no longer past a bound, between this sweep's scan and the claim. The
      # sweep was wrong and the owner said so — that is not a machine it failed
      # to reclaim, so it does not go on the defect gauge.
      {:error, refusal} when refusal in [:machine_occupied, :not_expired] ->
        Logger.info(
          "reaper: left idle sandbox #{sandbox.id} (#{sandbox.machine_name}) alone: " <>
            "#{refusal}"
        )

        :skipped

      {:error, refusal} ->
        Logger.warning(
          "reaper: could not park idle sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(refusal)}"
        )

        :refused
    end
  end

  # Both of these arms destroy a machine at the provider, so both spend from
  # the run's budget — the suspend-failure one especially, since a provider
  # whose suspend is down sends every idle row here at once.
  defp expire_within(sandbox, destroys_left, reason) when destroys_left > 0,
    do: expire(sandbox, :idle, reason)

  defp expire_within(sandbox, _spent, _reason) do
    Logger.info(
      "reaper: deferred expiry of sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
        "this run has spent its #{destroy_limit()} provider destroys"
    )

    :deferred
  end

  # A machine past a lifetime bound with nobody holding it. Since ADR 0058
  # stage 5b this goes through the machine's owner rather than writing the row
  # itself, so the provider machine dies **in this call** instead of on pass 2
  # of the same run. Pass 2 is still the safety net and still sees this row:
  # it lists terminal rows whose sprite is still at the provider, and a machine
  # this destroy reached is no longer in that listing, so there is no second
  # provider call for it.
  #
  # `terminating_conversation_id: nil`: no conversation is ending here. An
  # abandoned `ready` row usually still has its conversation bound to it —
  # that is what makes it abandoned rather than empty — and that conversation
  # stays resumable, so the fence takes no binding into account and the
  # machine goes whatever is bound to it.
  #
  # Two events, deliberately. `sandbox.expired` is the reaper's own record of
  # *why* the machine was taken away — the bound it crossed, in the tenant's
  # trail where "my agent's sandbox vanished" gets an answer (#551) — and
  # `sandbox.destroyed` from the protocol is the record that it *was*. Kept on
  # the same success-only rule the rest of this worker follows: a refusal
  # records nothing, because nothing happened to the tenant's machine.
  #
  # A refusal is logged and the sweep carries on. These are machines the fleet
  # has already lost track of; one that cannot be reached right now must not
  # stop the other passes, and `sweep_fenced_teardowns/0` finishes a row whose
  # fence committed and whose destroy did not.
  defp expire(sandbox, reason_atom, reason) do
    # ownership: `sandbox` came from this worker's own fleet-wide scan; the
    # reaper is a system sweep with no tenant of its own (`contributing/server.md`).
    case Termination._unsafe_destroy_machine(sandbox.id,
           actor: "system:sandbox_reaper",
           destroy_reason: reason_atom,
           reason: "sandbox_expired",
           terminating_conversation_id: nil
         ) do
      {:ok, outcome} ->
        Logger.info(
          "reaper: expired abandoned sandbox #{sandbox.id} (#{sandbox.machine_name}) — " <>
            "ready with no live server, #{reason} (#{outcome})"
        )

        record_reap(sandbox, "sandbox.expired", %{"reason" => reason})

        # The conversation is deliberately left alone. It stays resumable, and
        # the next prompt provisions a fresh sandbox (the runtime session on
        # the destroyed disk is lost — the price of the ceiling, see
        # decisions/0017).
        :expired

      {:error, refusal} ->
        Logger.warning(
          "reaper: could not expire abandoned sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(refusal)}"
        )

        :refused
    end
  end

  # ── pass 1c: destroys that were asked for and then abandoned ──────────────

  # A destroy is asked for before it is done. The fence
  # (`Lifecycle.fence_sandbox_for_teardown/2`) commits `transition: "destroying"` in
  # its own transaction, before any provider I/O, and the machine's owner
  # finishes the destroy after it. Anything in between can lose: the provider
  # call raises or never confirms, the owner's node dies, an account deletion
  # halts mid-fence.
  #
  # What is left is a live row stamped `destroying` with no owner working on
  # it. Every reader refuses it (ADR 0058 stage 9a: `destroying` is the one
  # durable transition), `Quotas` counts it against the fleet ceiling, and the machine bills. This pass is the only thing that
  # finishes it, and it never *starts* a destroy: the stamp is the request, so
  # a row only reaches here because a caller already decided this machine was
  # to go away.
  #
  # **One driver since stage 9b, on its own five-minute run** (`perform/1`'s
  # `"teardowns"` clause, `config/config.exs`). Until then there were two:
  # this pass, hourly and sharing the run's destroy budget with the expiries,
  # and `SandboxResetReconciler`, every five minutes and unbudgeted, for the
  # fences the since-removed per-sandbox reset and forced teardowns left.
  # Folding the reconciler into the hourly pass would have made a forced
  # teardown whose caller died wait up to an hour and a quarter instead of
  # five minutes, so the pass moved to the reconciler's clock instead, took
  # its rows, and stopped sharing a budget. Its cap is `@owner_attempts_per_sweep` — the attempts
  # one run may make, whatever the owners answer — and the `:maintenance`
  # queue runs one job at a time, so a backlog drains one machine at a time
  # rather than arriving at the provider at once.
  #
  # Each is finished through the owner after `@fenced_teardown_grace_minutes`
  # and only once no server holds the machine. A row still stamped by a
  # per-sandbox reset (`transition_reason: "reset"`) from a release before
  # ADR 0073 removed it is finished the same way: the reset was a destroy.
  @fenced_teardown_grace_minutes 15

  # How many machines one run of this pass may ask an owner about, whatever
  # the owner says. `@owner_attempt_limit`'s argument: a refusal costs
  # `Destroy.busy_wait_ms/0`, so without this a fleet of contended fences would
  # spend the whole of a `:maintenance` slot refusing. With no destroy budget
  # since stage 9b, it is also the cap on provider calls per run.
  @owner_attempts_per_sweep 100

  @doc false
  # Overridable like `owner_attempt_limit/0` and `destroy_limit/0`, so the cap
  # can be driven with two rows instead of a hundred and one. Nothing in `lib/`
  # sets it.
  def owner_attempts_per_sweep,
    do: Application.get_env(:fountain, :reaper_sweep_attempt_limit) || @owner_attempts_per_sweep

  @doc """
  Drives to completion the destroys that were asked for and then abandoned.

  A live row stamped `destroying` is refused by every reader and holds its fleet slot for as long as it stands, so this is the only thing that can free
  it. A row whose machine lease is live is skipped: an owner is working on it,
  and this pass would be finishing a destroy that has not failed. An expired
  lease, or none, is the abandonment this pass is for.

  It is finished by **asking the machine's owner**
  (`Termination._unsafe_destroy_machine/2`), which claims a lease, continues
  from the stamp, destroys at the provider and finalizes under its epoch — and
  only after the grace window, measured from the stamp, and once no server
  holds the machine.

  Returns `{reconciled, refused}` — destroys driven to terminal, and rows that
  were refused or could not be confirmed. See `perform/1`.
  """
  def sweep_fenced_teardowns do
    now = DateTime.utc_now()
    cutoff = DateTime.add(now, -@fenced_teardown_grace_minutes * 60, :second)

    # Over the workspaces' stamps (ADR 0097, step 3b), each with its live
    # sandbox: the stamp is the workspace's, the machine to destroy the
    # sandbox's.
    Lease.machines()
    |> where(
      [s, workspace: w],
      s.status not in ^@terminal_statuses and
        fragment("CASE WHEN ? IS NULL THEN ? ELSE ? END", w.id, s.transition, w.transition) ==
          ^@destroying
    )
    # The grace window runs from the row's last write, which for a stamped row
    # is the stamp: every reader refuses a `destroying` row, and a
    # `cas_update/4` moves `updated_at` with a state change and not with a
    # claim, so nothing writes it again until the destroy finishes.
    |> where([s], s.updated_at < ^cutoff)
    # Oldest stamp first, and deterministically. With a cap on attempts the
    # *order* of a sweep is part of its behaviour — with more rows than
    # attempts, whichever rows come last are deferred to the next run — and an
    # unordered scan would pick a different set each time. `id` breaks ties so
    # two stamps committed in one transaction have an order at all.
    |> order_by([s], asc: s.updated_at, asc: s.id)
    # A machine whose owner holds a live lease is not an abandoned destroy; it
    # is one in flight (ADR 0058). Asked in Elixir, through `Lease.live?/1`,
    # because whether the holder is alive is a question SQL cannot ask.
    |> Repo.all()
    |> Repo.preload(:conversations)
    # `or` short-circuits, so a row a lease is holding costs no registry scan.
    |> Enum.reject(fn sandbox ->
      Lease.live?(sandbox) or Lifecycle.any_server_alive?(sandbox)
    end)
    |> Enum.reduce({0, 0, owner_attempts_per_sweep()}, &drive_teardown/2)
    |> then(fn {reconciled, refused, _attempts} -> {reconciled, refused} end)
  end

  # One verdict, against this run's attempt cap. Every answer charges an
  # attempt, whatever it was.
  defp drive_teardown(sandbox, {reconciled, refused, attempts}) when attempts > 0 do
    case finish_teardown(sandbox) do
      :ok -> {reconciled + 1, refused, attempts - 1}
      :refused -> {reconciled, refused + 1, attempts - 1}
      :noop -> {reconciled, refused, attempts - 1}
    end
  end

  # The cap is spent. The row keeps its stamp, so the next run sees it
  # unchanged — which is what a cap is for, and why this is counted as neither:
  # nothing was attempted and nothing went wrong.
  defp drive_teardown(%Sandbox{} = sandbox, acc) do
    Logger.info(
      "reaper: deferred the abandoned destroy of sandbox #{sandbox.id} " <>
        "(#{sandbox.machine_name}) — this run has spent its " <>
        "#{owner_attempts_per_sweep()} owner attempts"
    )

    acc
  end

  # Ask the machine's owner to finish what the fence started (ADR 0058 stage
  # 9a). `Machines.Destroy` claims a lease, re-reads the row, continues from
  # the `destroying` stamp, destroys at the provider and finalizes by
  # compare-and-set, and `sandbox.destroyed` records who did it.
  #
  # `terminating_conversation_id: nil`, for `expire/3`'s reason and more
  # plainly: an abandoned teardown is a machine somebody already decided was to
  # go, whatever conversation is still bound to it.
  #
  # The call has **no deadline**, where 8a's `ensure_up` and 8b's attach and
  # detach carry one. A late destroy is idempotent (stage 5a), and there is no
  # caller to be late for — this is a cron sweep, and the next run would do the
  # same thing.
  #
  # A refusal is logged and the sweep carries on, and a raise cannot reach
  # `perform/1` from here: these rows are already the leftovers of a failure,
  # and one bad row must not block machine cleanup for the whole fleet.
  defp finish_teardown(%Sandbox{} = sandbox) do
    # ownership: `sandbox` came from this worker's own fleet-wide scan; the
    # reaper is a system sweep with no tenant of its own (`contributing/server.md`).
    case Termination._unsafe_destroy_machine(sandbox.id,
           actor: "system:sandbox_reaper",
           destroy_reason: destroy_reason(sandbox),
           reason: "teardown_reconciled",
           terminating_conversation_id: nil
         ) do
      {:ok, :destroyed} ->
        report_finished_teardown(sandbox)

      # Somebody else finished this row between the scan and the claim. Nothing
      # was reclaimed by this pass and nothing was refused, so it goes on
      # neither gauge — `idle_sweep/2`'s reading of the same outcome.
      {:ok, outcome} ->
        Logger.info(
          "reaper: abandoned teardown of sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}) settled as #{outcome}"
        )

        :noop

      {:error, :sandbox_unavailable} = refusal ->
        contended_or_refused(sandbox, refusal)

      {:error, reason} ->
        Logger.error(
          "reaper: could not finish abandoned teardown of sandbox #{sandbox.id} " <>
            "(#{sandbox.machine_name}): #{inspect(reason)}; left for the next pass"
        )

        :refused
    end
  end

  # `:sandbox_unavailable` is the answer to "an owner holds this machine's
  # lease", and also to a database fault or an unreachable owner. The first is
  # not a failure to reclaim: another run of this pass, or the destroy's own
  # caller come back, is finishing the machine right now — two runs overlapping
  # is ordinary, and counting it in `refused`, whose meaning is "still standing
  # and billing", would read as an outage on a healthy fleet (stage 9b round 1,
  # protocol review). So the row is read again: a live lease, or a row that has
  # gone terminal meanwhile, is somebody else's reclamation and counts on
  # neither gauge. Anything else is a refusal.
  defp contended_or_refused(%Sandbox{} = sandbox, refusal) do
    case Lease.get(sandbox.id) do
      %Sandbox{status: status} when status in @terminal_statuses ->
        :noop

      %Sandbox{} = now ->
        if Lease.live?(now) do
          Logger.info(
            "reaper: abandoned destroy of sandbox #{sandbox.id} (#{sandbox.machine_name}) " <>
              "is held by another owner; leaving it to them"
          )

          :noop
        else
          Logger.warning(
            "reaper: could not finish abandoned destroy of sandbox #{sandbox.id} " <>
              "(#{sandbox.machine_name}): #{inspect(refusal)}; left for the next pass"
          )

          :refused
        end

      nil ->
        :noop
    end
  end

  # The reason the fence recorded, handed back to the protocol so that the row
  # it writes and the `sandbox.destroyed` it records say what the caller who
  # asked for this teardown said — rather than a word this sweep invented for a
  # decision it did not make. `Machines.Destroy` owns that vocabulary and the
  # conversion (`reason_from_string/1`), a total match over a closed set.
  defp destroy_reason(%Sandbox{transition_reason: reason}),
    do: Destroy.reason_from_string(reason)

  defp report_finished_teardown(sandbox) do
    was = sandbox.status

    Logger.warning(
      "reaper: finished abandoned teardown of sandbox #{sandbox.id} " <>
        "(#{sandbox.machine_name}) — stamped at #{inspect(sandbox.updated_at)}, " <>
        "still #{was} #{@fenced_teardown_grace_minutes}m later"
    )

    # Two events, as `expire/3` has two and for its reason: `sandbox.destroyed`
    # from the protocol is the record that the machine *was* destroyed, and
    # this one is the reaper's own record of **why** it was this pass that did
    # it — a fence whose owner never came back, which is a defect upstream and
    # the thing an operator reading the trail needs to see.
    #
    # The conversations are left alone for the same reason `expire/3` leaves
    # them: reclaiming a machine is not deleting the thread that ran on it.
    record_reap(sandbox, "sandbox.teardown_reconciled", %{
      "previous_status" => was,
      "transition_reason" => sandbox.transition_reason,
      "grace_minutes" => @fenced_teardown_grace_minutes
    })

    :ok
  end

  # ── pass 2: terminal rows whose sprite is still there ─────────────────────

  defp destroy_dead_sprites(_live_by_provider, budget) when budget <= 0, do: 0

  defp destroy_dead_sprites(live_by_provider, budget) do
    Sandbox
    |> where([s], s.status in ^@terminal_statuses)
    |> select([s], {s.id, s.machine_name, s.provider})
    |> Repo.all()
    |> Enum.filter(fn {_id, name, provider} ->
      case Map.fetch(live_by_provider, provider_atom(provider)) do
        # Rows on a provider whose listing failed (or that is disabled) are
        # skipped, not destroyed — the next run with credentials converges.
        {:ok, live_names} -> MapSet.member?(live_names, name)
        :error -> false
      end
    end)
    |> Enum.take(budget)
    |> Enum.count(fn {id, name, provider} -> destroy(id, name, provider_atom(provider)) end)
  end

  defp provider_atom(provider), do: Conversations.sandbox_provider_atom(%{provider: provider})

  defp destroy(sandbox_id, machine_name, provider) do
    # build_handle/2 is pure — we already know the sandbox exists (it came
    # out of the listing), so there is nothing to look up first.
    case Managoat.Sandbox.destroy(Managoat.Sandbox.build_handle(provider, machine_name)) do
      :ok ->
        Logger.info("reaper: destroyed leaked sprite #{machine_name} (sandbox #{sandbox_id})")
        true

      {:error, reason} ->
        # Left for the next run rather than retried here; the row stays terminal
        # either way, so nothing is lost by being slow about it.
        Logger.warning("reaper: destroy failed for #{machine_name}: #{inspect(reason)}")
        false
    end
  end

  # ── pass 3: sprites with no row — counted, never touched ──────────────────

  @doc false
  def report_untracked(live_by_provider) do
    Enum.reduce(live_by_provider, 0, fn {provider, live_names}, total ->
      known =
        Sandbox
        |> where([s], s.provider == ^Atom.to_string(provider))
        |> select([s], s.machine_name)
        |> Repo.all()
        |> MapSet.new()

      untracked = MapSet.difference(live_names, known)
      count = MapSet.size(untracked)

      if count > 0 do
        sample = untracked |> Enum.sort() |> Enum.take(10) |> Enum.join(", ")

        Logger.info(
          "reaper: #{count} #{provider} sandbox(es) have no sandbox row and were " <>
            "left alone (sample: #{sample})"
        )
      end

      :telemetry.execute([:fountain, :reaper, :untracked], %{count: count}, %{
        provider: provider
      })

      total + count
    end)
  end

  # ── sprites.dev ───────────────────────────────────────────────────────────

  # One listing per provider, isolated: one backend being down must not stop
  # another's reconciliation. Sprites is always attempted (the historical
  # default may hold rows even when its credential was pulled); other
  # providers only when enabled. Pagination is the adapter's problem — a
  # first-page-only listing looks complete, which for a function that decides
  # what to delete is the worst possible shape of wrong, so adapters return
  # {:error, :truncated} rather than a partial view.
  defp list_by_provider do
    [:sprites | Fountain.SandboxProviders.enabled_providers()]
    |> Enum.uniq()
    |> Map.new(fn provider -> {provider, safe_list(provider)} end)
  end

  defp safe_list(provider) do
    Managoat.Sandbox.list_all_names(provider)
  rescue
    e -> {:error, e}
  end

  # ── turns left running with no server ─────────────────────────────────────
  #
  # The in-process autonomous quiet timer disappears with its server. This is
  # the durable backstop for hard crashes and restarts. It only considers
  # old turns that are not waiting on a permission and have produced no recent
  # output, because output is written to the database whether or not a
  # server is registered for the conversation.
  #
  # A conversation that reached its durable output budget can appear quiet
  # even while its runtime is active. The server liveness check remains a
  # second guard for that case. The oldest candidates are capped per run so a
  # historical backlog cannot fan out an unbounded burst of events.

  @stuck_after_minutes_turns 30
  @quiet_grace_minutes 15
  @reap_limit 25

  @doc false
  def sweep_stuck_turns do
    now = DateTime.utc_now()
    started_cutoff = DateTime.add(now, -@stuck_after_minutes_turns * 60, :second)
    quiet_cutoff = DateTime.add(now, -@quiet_grace_minutes * 60, :second)

    last_output =
      from(l in LogEvent,
        where: l.turn_id == parent_as(:turn).id and l.kind == "output",
        select: max(l.inserted_at)
      )

    Turn
    |> from(as: :turn)
    |> where([t], t.status == "running" and t.started_at < ^started_cutoff)
    |> where([t], is_nil(t.pending_permission))
    |> where([t], coalesce(subquery(last_output), t.started_at) < ^quiet_cutoff)
    |> order_by([t], asc: t.started_at)
    |> limit(^@reap_limit)
    |> Repo.all()
    |> Enum.count(&reap_turn_if_unowned/1)
  end

  defp reap_turn_if_unowned(%Turn{} = turn) do
    if ConversationServer.whereis(turn.conversation_id) do
      false
    else
      # Through the owner's door (ADR 0058 stage 8a), with no `:sandbox_id`:
      # the reaper recovers on nobody's behalf, so there is no binding to fence
      # on, and the write is the same one it has always made.
      case Machine.end_turn(turn, {:orphan, "stuck_running_no_server"},
             actor: "system:autonomous_turn_reaper"
           ) do
        {:ok, _, _} ->
          Logger.info(
            "autonomous_turn_reaper: reaped turn #{turn.id} " <>
              "(conversation #{turn.conversation_id}) started #{turn.started_at}"
          )

          true

        :noop ->
          false

        {:error, reason} ->
          Logger.warning(
            "autonomous_turn_reaper: could not reap turn #{turn.id}: #{inspect(reason)}"
          )

          false
      end
    end
  end
end
