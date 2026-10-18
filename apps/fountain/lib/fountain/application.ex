defmodule Fountain.Application do
  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("rollout startup phase=begin")
    FountainWeb.StreamDrain.reset()
    FountainWeb.Plugs.RateLimit.ensure_table()
    Fountain.Telemetry.attach_default_logger()
    Fountain.Conversations.ResponseTiming.attach()
    attach_sentry_handler()

    # OpenTelemetry instrumentation (prod only — deps not compiled in dev/test).
    # apply/3 defers symbol resolution past compile time so dev/test compiles
    # don't warn about modules that aren't in their build.
    if Application.spec(:opentelemetry_phoenix) do
      apply(OpentelemetryPhoenix, :setup, [[adapter: :bandit]])
      apply(OpentelemetryEcto, :setup, [[:fountain, :repo]])
    end

    # The proxy's request-log handler. Attached here rather than from
    # `children/0` so that function stays a pure reading of the configuration,
    # which is what pins its order in `application_children_test.exs`. A
    # listener started without it would proxy correctly and write no
    # `broker_requests` row, so `/api/conversations/:id/egress` would go quiet
    # with nothing failing anywhere.
    Fountain.Broker.Native.attach_telemetry()

    # This boot's id, which every machine lease taken from now on names
    # (`Fountain.Machines.Lease`, ADR 0072). Drawn before any child starts.
    Fountain.Machines.Lease.init_boot()

    opts = [strategy: :one_for_one, name: Fountain.Supervisor]

    case Supervisor.start_link(children(), opts) do
      {:ok, sup} ->
        Logger.info("rollout startup phase=endpoint_started")
        # Rehydrate ConversationServers for non-terminal conversations whose
        # sprite was fully provisioned at the last clean stop. Done in a
        # detached process so a failure here doesn't block app boot.
        unless skip_rehydrate?(),
          do: Task.start(fn -> Fountain.Conversations.Rehydrator.run() end)

        {:ok, sup}

      err ->
        err
    end
  end

  @impl true
  def prep_stop(state) do
    FountainWeb.StreamDrain.begin()

    Logger.info(
      "rollout shutdown phase=begin monotonic_ms=#{System.monotonic_time(:millisecond)}"
    )

    state
  end

  # The supervision tree, in start order. A `:one_for_one` supervisor
  # terminates in reverse, so this one list decides two separate things: what
  # is up before the endpoint serves its first request, and what is still up
  # while the endpoint drains its last.
  #
  # Public for the test that pins both ends of that order; not part of the
  # app's API.
  @doc false
  def children do
    [
      FountainWeb.Telemetry,
      Fountain.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:fountain, :ecto_repos), skip: skip_migrations?()},
      # Straight after the schema is current and before anything that could
      # claim a machine: clears every lease and abandoned stamp an earlier boot
      # left (ADR 0072). Does its work in `start_link` and keeps no process.
      Fountain.Machines.BootSweep
    ] ++
      broker_children() ++
      [
        {Phoenix.PubSub, name: Fountain.PubSub},
        # Fire-and-forget work started from a request and never awaited: the
        # `last_used_at` stamp on an API key, the password-reset email. These
        # used to be `Task.async`, which *links* to the caller — so a transient
        # failure in a write nobody wants the result of could take down the
        # request process that started it, or the test that made the request
        # (#1040). Supervised and unlinked, a crash here is a log line.
        {Task.Supervisor, name: Fountain.TaskSupervisor},
        FountainWeb.Plugs.RateLimit.Sweeper,
        Fountain.Conversations.Redaction,
        # The sandbox-files reads in flight (`Fountain.Machines.Reads`): before
        # the machine owners, whose park and destroy drain it, and the endpoint,
        # whose requests are admitted into it.
        Fountain.Machines.Reads.Table,
        {Oban, Application.fetch_env!(:fountain, Oban)}
      ] ++
      [
        # Fountain runs as one node (ADR 0072), so these are plain local
        # registries and supervisors: a server is registered before
        # `start_child` returns, and a lookup that finds nothing means there is
        # nothing.
        #
        # The per-workspace machine owner (ADR 0058, 0097) comes before the conversation pair,
        # and that is the draining end again: reverse termination stops it
        # *after* the conversation supervisor, so a server shutting down can
        # still ask its machine who is here.
        #
        # One `Fountain.Machines.Machine` per *active* machine, registered
        # under the sandbox id and idle-stopping when nothing has asked it
        # anything.
        {Fountain.ShutdownCheckpoint, :machines_stopped},
        {Registry, [name: Fountain.MachineRegistry, keys: :unique]},
        {DynamicSupervisor,
         [
           name: Fountain.MachineSupervisor,
           strategy: :one_for_one,
           # Sized in stage 7a, for the reason the pair below was sized
           # (#2348's review said to do it "when the owner starts doing
           # work", and with `destroy`, `park` and `ensure_up` behind it the
           # owner now does). The default is 3 restarts in 5s, and that
           # budget is SHARED by every machine owner: one machine whose owner
           # crashes deterministically exhausts it in under a second, and
           # exceeding it terminates this supervisor and with it every other
           # machine's owner. That is every destroy, park, resume and
           # admission failing at once, which is the opposite of what a
           # per-machine owner is for.
           #
           # 100/10s for the same shape of burst: a provider outage failing
           # many operations at the same moment must not read as a loop, while
           # a genuine loop still stops. The protocols themselves rescue their
           # adapters and answer rather than raising, so a crash here is a
           # defect rather than a provider having a bad day — which is why the
           # budget can be generous without hiding anything.
           max_restarts: 100,
           max_seconds: 10
         ]},
        {Fountain.ShutdownCheckpoint, :conversations_stopped},
        {Registry, [name: Fountain.ConversationRegistry, keys: :unique]},
        {DynamicSupervisor,
         [
           name: Fountain.ConversationSupervisor,
           strategy: :one_for_one,
           # Explicit, and sized to the fleet: the default (3 restarts in
           # 5s) is a budget SHARED by every ConversationServer — one child
           # that crashes deterministically on start exhausts it in under a
           # second, and exceeding it terminates this supervisor and with it
           # every running conversation. 100/10s tolerates a correlated
           # transient burst (a Sprites outage failing many provisions at
           # once) while still stopping a genuine infinite loop. The known
           # deterministic crash paths (rows deleted before
           # handle_continue(:provision)) are also guarded in the server
           # itself.
           max_restarts: 100,
           max_seconds: 10
         ]},
        # Last, and it has to stay there: it starts only once everything it
        # can reach is up, and it stops before any of that goes away.
        Fountain.Conversations.PromptReceipt,
        {Fountain.ShutdownCheckpoint, :endpoint_stopped},
        FountainWeb.Endpoint
      ]
  end

  # The native egress proxy (ADR 0019, #1340) listens on BROKER_LISTEN_PORT
  # on every deployment: brokerage is unconditional (amendment of
  # 2026-10-15). The writer it casts rows to starts first, so no request
  # finds it missing; `start/2` attaches the telemetry handler that does the
  # casting before any of this starts.
  #
  # Where these sit in `children/0` is not cosmetic: third, straight after
  # `Fountain.Repo` and `Ecto.Migrator`, which between them are everything the
  # listener needs — the repo its session store and request log read and
  # write, and the migration that created their tables. `listener_spec/0`
  # reads three application-environment keys and nothing else;
  # `Managoat.Broker.init/1` builds an ETS certificate cache, a
  # `:persistent_term` entry and a ThousandIsland child spec;
  # `RequestLog.init/1` returns a static map and reaches the repo only when it
  # flushes. None of them touches PubSub, Oban, the registries or the endpoint, so
  # nothing is skipped by starting this early.
  #
  # Being third puts them **last but two** to stop, which is the point. They
  # sat *after* `FountainWeb.Endpoint` until #1726, and
  # reverse termination meant the listener stopped **first** on every
  # rollout — the endpoint went on serving, and the conversation servers
  # under `Fountain.ConversationSupervisor` went on reattaching, for the
  # whole termination grace period, each one failing with `:listener_down`.
  # One pod nine minutes into its life failed 41 seconds after its
  # replacement appeared: draining, not starting. Readiness cannot close that
  # end, because a terminating pod does not get to re-advertise itself
  # unready in time. Ordering can, and it closes the starting end too.
  #
  # Oban is the same trap one layer down, which is why these moved above it
  # rather than merely above the endpoint. A job that runs in the tail of a
  # drain would otherwise meet a listener that had already stopped.
  #
  # The starting end matters to CI as well as to kubelet. All three `probe()`
  # helpers that curl `/health/ready` (two in ci.yml, one in
  # scripts/compose-boot-check.sh) treat the first non-200 as a verdict and
  # do not retry it, and every fixture runs the listener, so a listener
  # started late would fail the build on a transient 503. Started here, the
  # listener is up before the endpoint answers at all, so there is no
  # transient 503 to catch.
  defp broker_children do
    [
      Fountain.Broker.Native.MaterializedRules,
      Fountain.Broker.Native.RequestLog,
      Fountain.Broker.Native.listener_spec()
    ]
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    FountainWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  # Migrations run at boot in a release and nowhere else — dev and test manage
  # their own schema through mix, and RELEASE_NAME is how a release announces
  # itself.
  #
  # MIGRATE_ON_BOOT=false opts a release out (#610), for the deployment that
  # runs migrations once in a Job and lets its pods only serve. This gate and
  # the image's CMD (`Fountain.Release.migrate_on_boot/0`) read the one
  # switch, so turning it off leaves no path here that migrates — the switch
  # would be a decoration if it closed only one of the two.
  #
  # Public for the test that pins that pairing; not part of the app's API.
  @doc false
  def skip_migrations? do
    System.get_env("RELEASE_NAME") == nil or not Fountain.Release.migrate_on_boot?()
  end

  # Tests opt out via config; everything else (mix phx.server, releases,
  # iex -S mix phx.server) should rehydrate so we recover from a clean
  # BEAM stop.
  defp skip_rehydrate? do
    Application.get_env(:fountain, :skip_rehydrate, false)
  end

  # Crash reports from any process — ConversationServer, workers, bare Tasks —
  # become Sentry error events. That non-router surface is the whole point:
  # router exceptions already show up in metrics, while a ConversationServer
  # crash mid-provision used to produce a log line and nothing else (#211).
  #
  # Error events only, no structured-log forwarding, and rate-limited so an
  # error loop cannot burn the event quota. Attached only when a DSN is
  # configured, so the default install reports nothing anywhere.
  defp attach_sentry_handler do
    if Application.get_env(:sentry, :dsn) do
      :logger.add_handler(:sentry, Sentry.LoggerHandler, %{
        config: %{
          metadata: [:request_id],
          rate_limiting: [max_events: 20, interval: 60_000]
        }
      })
    end

    :ok
  end
end
