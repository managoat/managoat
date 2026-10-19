import Config

# Fixture password hashes run on the dirty CPU schedulers. At production cost
# they starved the docs guardrails, which shared those schedulers with MDEx and
# Lumis while the manual was compiled into the server, past their timeout
# (#1701). Keep real hashing and verification at bcrypt's recommended test cost.
config :bcrypt_elixir, :log_rounds, 4

config :fountain, Fountain.Repo,
  url:
    System.get_env("DATABASE_URL", "postgres://postgres:postgres@localhost:5432/fountain_test"),
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 20,
  # The sandbox gives a test *one* connection, which every process the test
  # fans work out to shares: `Task.async_stream` in a test body, a supervised
  # task under `Fountain.TaskSupervisor`, and Ecto's own parallel preloader,
  # which fans out over `Task.async_stream` whenever two or more associations
  # are still to fetch. Those are not parallel under the sandbox — they are a
  # queue on one connection, and four 200 ms transactions measured 814 ms.
  #
  # DBConnection then drops a waiter once the queue has been slow for a whole
  # `queue_interval`, and the 50 ms / 1 s defaults are sized for a pool with
  # spare connections rather than for a queue that is a queue by construction.
  # On a loaded workstation that dropped real tests: #1524 (Ecto's preloader,
  # waits of 121-160 ms) and #1568 (a concurrent-post test, 263 ms), neither of them a defect in the code under test.
  #
  # 200 ms / 5 s tolerates about 5 s of continuous backlog on one connection,
  # against the ~250 ms the real failures waited. A genuinely stuck connection
  # still surfaces — as the test's own timeout, with the stack of whatever is
  # holding it, which says more than a dropped checkout does. Measured with a
  # 40-task probe: 30 of 40 dropped at the defaults, 0 of 40 here.
  queue_target: 200,
  queue_interval: 5_000

config :fountain, FountainWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "c4S1HEBb+LhhInAgMbEJdXVBSKK65S7Mk9oeXrPTn65slnwVQU5zFqCT3p2wqWaR",
  server: false

config :fountain, :skip_rehydrate, true

# A wake that resumes an explicit workspace's machine tidies ended
# conversations' config homes in a task (`Termination.tidy_after_resume/2`),
# an exec the suite's wake tests do not stub. Off here; its own tests turn it
# on or call the sweep directly.
config :fountain, :tidy_homes_after_resume, false

# The machine boot sweep (ADR 0072) clears every lease an earlier boot left;
# the suite drives `Fountain.Machines.Lease.sweep_boot/0` itself.
config :fountain, :machine_boot_sweep, false

# The machine owner (ADR 0058) serves each call as its caller, so a test's SQL
# sandbox connection and Mimic stubs reach it. Test-only by design: production
# must not put `$callers` in the owner (`Fountain.Machines.Machine.handle_call/3`
# says why).
config :fountain, :owner_adopts_callers, true

# Skip the Ueberauth plug so tests can set :ueberauth_auth/:ueberauth_failure
# directly without triggering a real OAuth network round-trip.
config :fountain, :ueberauth_test_mode, true

# A fake client id so FountainWeb.OAuth.github_configured?/0 is true and the
# "Continue with GitHub" button renders in tests (#336). Inert: the test mode
# above means no real OAuth round-trip ever happens.
config :ueberauth, Ueberauth.Strategy.Github.OAuth,
  client_id: "test-github-client-id",
  client_secret: "test-github-client-secret"

# Key rate limit buckets by calling process PID instead of IP, so async
# ExUnit tests don't share counters. Each test runs in its own process.
config :fountain, :rate_limit_test_isolation, true

# The gauge telemetry poller queries the DB outside any test's SQL Sandbox
# ownership; keep it off here (Fountain.OpsGauges is tested directly).
config :fountain, :gauge_poller_enabled, false

# Managoat.Sandbox.Retry sleeps between attempts; 1ms keeps retry-path tests
# fast without changing the retry logic under test.
config :fountain, Managoat.Sandbox.Retry, base_ms: 1

# The registry settle window (#800) is a real-time wait; keep tests brisk.
config :fountain, :conversation_registry_settle_ms, 150

# How long an interrupt waits for the cancelled prompt's usage (#2821). Most
# fake adapters never answer, so every interrupt test pays this once.
config :fountain, :acp_cancel_grace_ms, 300

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix, sort_verified_routes_query_params: true

# Swoosh test adapter — use Swoosh.TestAssertions in tests
config :fountain, Fountain.Mailer, adapter: Swoosh.Adapters.Test

# Pinned so a developer's shell (MIGRATE_ON_BOOT) can't change suite
# behavior; tests toggle these through the application env.
config :fountain, :email_enabled, true
# The first-admin bootstrap (ADR 0011) has no variable and is always on
# outside the suite. Every test's sandbox is an instance that has never had
# an admin, so it is off here and its own tests turn it on.
config :fountain, :first_admin_bootstrap, false
# Explicitly open: under the :auto default any test that holds an admin
# would close registration for the rest of its body.
config :fountain, :registration_enabled, true
config :fountain, :migrate_on_boot, true

# Jobs are asserted with Oban.Testing rather than executed as a side effect.
config :fountain, Oban, testing: :manual

# OAuth clients (#818) the controller tests register against.
config :fountain, Fountain.OAuth,
  clients: [
    %{
      id: "test-app",
      name: "Test App",
      redirect_uris: ["https://app.test/callback", "http://localhost:5173/"]
    }
  ]

# ChatGPT subscriptions (ADR 0070): every call to auth.openai.com goes to a
# Req.Test plug, so a test that forgets to stub it fails rather than dialling
# out.
config :fountain, :chatgpt_req_options, plug: {Req.Test, Fountain.ChatGPT.OAuth}

# Connections (ADR 0085): every request to a remote MCP server or its
# authorization server goes to a Req.Test plug, and names resolve through a
# fixed table (`Fountain.Connections.TestResolver`), so nothing dials out.
config :fountain, :connections_req_options, plug: {Req.Test, Fountain.Connections.OAuth}
config :fountain, :connections_resolver, Fountain.Connections.TestResolver

# A pinned adapter bundle the host pushes into a sandbox (ACP.preload/2) is
# read from a directory the suite writes, never the release's priv/.
config :fountain, :acp_bundle_dir, Path.join(System.tmp_dir!(), "managoat-acp-bundles-test")

# Every conversation is brokered (ADR 0019, amendment of 2026-10-15), so the
# suite runs the listener too. Port 0 lets the OS pick one, so concurrent
# suites on one host do not collide; nothing in the suite dials the proxy URL.
config :fountain, :broker_listen_port, 0
config :fountain, :broker_proxy_url, "http://broker.test:14322"

# Record real spans in tests; never send test telemetry over the network.
config :opentelemetry,
  processors: [{:otel_simple_processor, %{exporter: :none}}],
  traces_exporter: :none
