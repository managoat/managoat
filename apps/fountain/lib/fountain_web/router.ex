defmodule FountainWeb.Router do
  @moduledoc false
  use FountainWeb, :router

  ## ─── Pipelines ──────────────────────────────────────────────────────────────────────────────────

  # Public JSON — spec rendering, health, public auth endpoints
  pipeline :api_public do
    plug :accepts, ["json"]
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
  end

  # Authenticated API — TenantAPIAuth gate for all resource endpoints.
  #
  # Content negotiation is deliberately NOT part of this pipeline. Every
  # authenticated route pipes through `:accepts_json` as well, except the SSE
  # stream, which cannot: a real EventSource client sends
  # `Accept: text/event-stream`, and `plug :accepts, ["json"]` refuses that with
  # 406 before the action ever runs. Keeping the auth chain in one pipeline
  # means the stream route cannot drift out of it — a second copy of these
  # plugs would be one forgotten line away from an unauthenticated endpoint.
  pipeline :api do
    plug FountainWeb.Plugs.PutApiSpec, module: FountainWeb.ApiSpec
    # A coarse pre-auth ceiling protects the lookup work (#316). It is ten
    # key budgets, so one key using its allowance does not exhaust a shared
    # ingress address (#1771). Every attempt counts toward this ceiling.
    plug FountainWeb.Plugs.RateLimit, bucket: "api", max: 6_000
    # Refused authentication has its own 600/min address bucket inside auth;
    # it cannot consume a valid key's allowance.
    plug FountainWeb.Plugs.TenantAPIAuth
    # The key an `"auth": "conversation"` MCP server holds reads its own
    # conversation and nothing else (#2934). Here, not per scope, so a route
    # added later is closed to it by default.
    plug FountainWeb.Plugs.ConversationKeyScope
    # Authenticated clients keep independent 600/min budgets per replica.
    plug FountainWeb.Plugs.RateLimit, bucket: "api-key", max: 600, key: :api_key
    plug FountainWeb.Plugs.Audit
    # A sandbox's own key reaches its conversation tree and the read-only
    # inputs to spawn, nothing else (#2981, ADR 0096). After Audit, so a
    # refused write is on the trail; here, so a route added later is closed
    # to it by default.
    plug FountainWeb.Plugs.SandboxKeyScope
  end

  pipeline :accepts_json do
    plug :accepts, ["json"]
  end

  # As tight as the current asset setup allows: the root layout runs Tailwind
  # and Phoenix/LiveView off CDNs and carries large inline scripts and
  # onclick handlers, so script-src needs 'unsafe-inline' plus the two CDN
  # hosts (a nonce scheme can't cover inline event handlers). That means this
  # CSP does NOT block javascript: URLs. The markdown renderer that filtered
  # them (#323) left with the manual for site/ (decisions/0081), and the
  # server renders no markdown now, so a page that ever renders a URL it did
  # not write must filter it itself. What it does pin down: no framing, no
  # <object>, no off-origin form posts, fetch/websocket restricted to self + the LV
  # socket, images to self + the data: URLs the image picker and avatars use.
  @csp [
         "default-src 'self'",
         "base-uri 'self'",
         "frame-ancestors 'self'",
         "form-action 'self'",
         "object-src 'none'",
         "img-src 'self' data:",
         "style-src 'self' 'unsafe-inline'",
         "script-src 'self' 'unsafe-inline' https://cdn.tailwindcss.com https://cdn.jsdelivr.net",
         "connect-src 'self' ws: wss:"
       ]
       |> Enum.join("; ")

  # Base browser pipeline — session, flash, CSRF, secure headers
  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {FountainWeb.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers, %{"content-security-policy" => @csp}
  end

  # Authenticated browser routes — loads current_user from session
  pipeline :browser_authenticated do
    plug FountainWeb.Plugs.TenantSessionAuth
  end

  # Optional browser auth — loads current_user if session exists, no redirect if absent
  pipeline :browser_optional_auth do
    plug FountainWeb.Plugs.OptionalSessionAuth
  end

  # Layered on top of :api for routes that manage API keys themselves.
  pipeline :require_key_management do
    plug FountainWeb.Plugs.RequireKeyManagement
  end

  # Layered on top of :api for account-level writes. Same rule as
  # :require_key_management, wider remit: a leaked per-conversation sprite token
  # must not be able to replace the tenant's inference credentials any more than
  # it can mint a second API key.
  pipeline :require_full_scope do
    plug FountainWeb.Plugs.RequireFullScope
  end

  # Layered on top of :api + :require_full_scope for the operator surface.
  pipeline :require_admin_api do
    plug FountainWeb.Plugs.RequireAdminApi
  end

  ## ─── Public routes ────────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through :api_public
    # Liveness: static. Readiness: checks the dependencies this instance cannot
    # serve without. See FountainWeb.HealthController for why they are separate.
    get "/health", HealthController, :show
    get "/health/ready", HealthController, :ready
  end

  # The manual and its llms.txt files and skill are a static build in site/,
  # published at DOCS_URL (decisions/0081). Each path the server used to serve
  # is a permanent redirect to the same path there. No pipeline: no auth, no
  # session, nothing rendered. Distinct from /api/docs (Swagger).
  scope "/", FountainWeb do
    get "/docs", DocsRedirectController, :show
    get "/docs/*page", DocsRedirectController, :show
    get "/llms.txt", DocsRedirectController, :show
    get "/llms-full.txt", DocsRedirectController, :show
    get "/skill", DocsRedirectController, :show
    get "/skills/managoat/SKILL.md", DocsRedirectController, :show
    # The skill's path before ADR 0082 renamed it; the site serves both.
    get "/skills/fountain/SKILL.md", DocsRedirectController, :show
  end

  # Managoat's client ID metadata document (ADR 0085): its URL is the client
  # id a provider fetches it by, so it is public and carries nothing secret.
  scope "/", FountainWeb do
    get "/connections/client.json", ConnectionCallbackController, :client_metadata
  end

  scope "/api" do
    pipe_through :api_public
    get "/openapi.json", OpenApiSpex.Plug.RenderSpec, []
    get "/docs", OpenApiSpex.Plug.SwaggerUI, path: "/api/openapi.json"
  end

  ## ─── Public browser routes ────────────────────────────────────────────────────────────────────────

  # `/` sends a person to the console (sign-in when signed out).
  scope "/", FountainWeb do
    pipe_through [:browser, :browser_optional_auth]
    get "/", FrontDoorController, :home
    # The in-app help was folded into the manual (ADR 0076); old links land
    # on the page that took each topic.
    get "/help", HelpRedirectController, :show
    get "/help/:topic", HelpRedirectController, :show
  end

  # Auth routes (no session auth required)
  scope "/auth", FountainWeb do
    pipe_through [:browser]

    get "/login", SessionController, :new
    post "/login", SessionController, :create
    get "/logout", SessionController, :delete

    get "/register", RegistrationController, :new
    post "/register", RegistrationController, :create
    get "/check-email", RegistrationController, :check_email

    get "/resend-verification", RegistrationController, :resend_form
    post "/resend-verification", RegistrationController, :resend

    get "/forgot-password", PasswordResetController, :forgot_form
    get "/reset/:token", PasswordResetController, :reset_form
    post "/reset", PasswordResetController, :reset

    # Ueberauth OAuth routes
    get "/oauth/:provider", UeberauthController, :request
    get "/oauth/:provider/callback", UeberauthController, :callback
  end

  # Email verification (token in path)
  scope "/users", FountainWeb do
    pipe_through [:browser]
    get "/confirm/:token", EmailVerificationController, :confirm
  end

  # OAuth 2.0 consent page (#818): the browser half of Fountain as an
  # authorization server for its own apps. Optional session auth — the
  # controller stashes the request and sends a signed-out user to login.
  scope "/oauth", FountainWeb do
    pipe_through [:browser, :browser_optional_auth]

    get "/authorize", OAuthAuthorizeController, :show
    post "/authorize", OAuthAuthorizeController, :create
  end

  ## ─── Public JSON auth endpoints ───────────────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through :api_public

    post "/token", AuthTokenController, :create

    # Device authorization (#1305): the CLI login path for accounts that have
    # no password ("Sign up with GitHub"). Unauthenticated by design — the
    # approval happens in a signed-in browser at /device; rate-limited in the
    # controller.
    post "/device", DeviceAuthController, :create
    post "/device/token", DeviceAuthController, :token

    post "/register", RegistrationController, :api_create
    post "/resend-verification", RegistrationController, :api_resend
    post "/forgot", PasswordResetController, :api_forgot

    # Completions (#522). Authenticated by the emailed token itself, so an
    # account can be activated and a password reset without a browser. The
    # links in the mail keep pointing at the browser routes above.
    post "/verify", EmailVerificationController, :api_verify
    post "/reset", PasswordResetController, :api_reset
  end

  ## ─── Authenticated JSON resource endpoints ──────────────────────────────────────────────────────────────

  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api]

    get "/me", AuthMeController, :show
  end

  # OAuth token endpoint (#818): unauthenticated by design — the code, the
  # PKCE verifier and the exact redirect_uri are the proof; rate-limited in
  # the controller. Revoke needs the token it revokes.
  scope "/api/oauth", FountainWeb do
    pipe_through :api_public
    post "/token", OAuthTokenController, :token
  end

  scope "/api/oauth", FountainWeb do
    pipe_through [:accepts_json, :api]
    post "/revoke", OAuthTokenController, :revoke
  end

  # OAuth clients an account registers for itself (#1125). Full scope because
  # a client is a standing path to a full-scope key after consent.
  scope "/api/oauth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/clients", OAuthClientController, :index
    post "/clients", OAuthClientController, :create
    get "/clients/:id", OAuthClientController, :show
    patch "/clients/:id", OAuthClientController, :update
    delete "/clients/:id", OAuthClientController, :delete
  end

  # Key management is scope-gated: the per-conversation token a sprite holds
  # must not be able to mint a second key that survives conversation teardown.
  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_key_management]

    get "/api-keys", ApiKeyController, :index
    post "/api-keys", ApiKeyController, :create
    delete "/api-keys/:id", ApiKeyController, :delete
  end

  # Connections (ADR 0085). Full scope: a conversation-scoped token must not
  # be able to connect the account to a server, or list or drop its grants.
  scope "/api/connections", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", ConnectionController, :index
    post "/", ConnectionController, :create
    get "/:id", ConnectionController, :show
    post "/:id/authorize", ConnectionController, :authorize
    delete "/:id", ConnectionController, :delete
  end

  # Secret bindings (ADR 0019 gate 1b). Full scope: a conversation-scoped
  # token must not be able to redirect the account's credentials to another
  # host.
  scope "/api/secret-bindings", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/", SecretBindingController, :index
    get "/presets", SecretBindingController, :presets
    post "/", SecretBindingController, :create
    patch "/:id", SecretBindingController, :update
    delete "/:id", SecretBindingController, :delete
  end

  # What left the sandbox through the egress broker (ADR 0019 gate 4). Full
  # scope, like the bindings that put the credentials there: the log names
  # which secrets went to which host, and a sandbox's per-conversation token
  # must not be able to map another conversation's traffic (#1152).
  scope "/api/conversations/:conversation_id", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/egress", ConversationController, :egress, as: :conversation_egress
  end

  # A sandbox's disk, read-only (ADR 0039): a listing, a file, `git status`
  # and `git diff`.
  # Full scope for the same reason as the egress log: a sandbox's own
  # `sprite` token must not read another sandbox of the tenant, whose disk
  # was built from a different vault.
  scope "/api/sandboxes/:sandbox_id", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    get "/files", SandboxFilesController, :index, as: :sandbox_files
    get "/file", SandboxFilesController, :show, as: :sandbox_file
    get "/diff", SandboxFilesController, :diff, as: :sandbox_diff

    # `git-status`, not `status`: a sandbox already has a `status` of its own
    # (`ready`, `suspended`), and that is what a caller reading the route
    # would expect back from it.
    get "/git-status", SandboxFilesController, :git_status, as: :sandbox_git_status
  end

  # Password change (#521) — same gate, same reason: a conversation-scoped
  # sprite token must not be able to rotate the account password. It requires
  # the current password on top of the bearer token.
  scope "/api/auth", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    post "/password", AccountSecurityController, :api_change_password
  end

  # Account-level configuration. Inference credentials are what a conversation
  # actually runs on, so a sprite token replacing them is the same class of
  # escalation as minting an API key — hence the full-scope gate (#518).
  scope "/api/account", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    # Deletion (#523) is irreversible and takes the tenant key with it, so it
    # wants the strongest credential the account has.
    delete "/", AccountDataController, :delete_account

    get "/inference-credentials", InferenceCredentialController, :index
    put "/inference-credentials/:provider", InferenceCredentialController, :update
    delete "/inference-credentials/:provider", InferenceCredentialController, :delete
  end

  # What an agent is, and what its sandbox is built from: agents,
  # environments, vaults and their secrets, and the bulk apply that writes all
  # of them.
  # Full scope, because a sandbox's own `sprite` token could otherwise rewrite
  # the configuration that the next launch runs — give an agent any
  # `runtime_command`, or add a setup script — and start it (ADR 0039's
  # 2026-10-14 amendment).
  # Reads stay in the open scope below; starting conversations of the agents
  # the owner configured stays open too.
  scope "/api", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope]

    resources "/environments", EnvironmentController, only: [:create, :update, :delete] do
      resources "/secrets", SecretController, only: [:create, :delete]
    end

    # A server-side copy: secret values are write-only over the API, so a
    # client cannot build a vault holding another vault's secrets itself.
    post "/vaults/:id/copy", VaultController, :copy

    resources "/vaults", VaultController, only: [:create, :update, :delete] do
      patch "/secrets/:id", VaultSecretController, :update
      resources "/secrets", VaultSecretController, only: [:create, :delete]
    end

    resources "/agents", AgentController, only: [:create, :update, :delete]

    # Bulk apply for compiled managoat.yml manifests (`managoat apply`).
    post "/apply", ApplyController, :create

    # Workspaces (ADR 0097): machines the owner keeps and launches
    # conversations into. Reads too are full scope: a sandbox's own key may not
    # create, list or delete them, and a conversation it starts gets a
    # sandbox of its own.
    resources "/workspaces", WorkspaceController, only: [:index, :show, :create, :delete]
  end

  # No `:accepts_json`, for the same reason as the conversation stream below.
  scope "/api", FountainWeb do
    pipe_through :api

    # Every conversation of the caller on one connection (#813).
    get "/events/stream", EventsController, :stream, as: :events_stream
  end

  scope "/api", FountainWeb do
    pipe_through [:accepts_json, :api]

    # The tenant's own trail (#526). Cross-tenant listing is an admin concern.
    get "/audit", AuditController, :index

    # Full-text search across the caller's conversations (#826).
    get "/search", SearchController, :index

    # Reads only: the writes are in the full-scope scope above. A sandbox's
    # own token lists agents to fan out to (the bundled `managoat` skill).
    resources "/environments", EnvironmentController, only: [:index, :show] do
      resources "/secrets", SecretController, only: [:index]
    end

    resources "/vaults", VaultController, only: [:index, :show] do
      resources "/secrets", VaultSecretController, only: [:index]
    end

    resources "/agents", AgentController, only: [:index, :show]

    # Config history (ADR 0029, #1051): read-only.
    get "/agents/:id/versions", AgentVersionController, :index
    get "/agents/:id/versions/:version", AgentVersionController, :show
    # The form vocabulary, for clients that build
    # the agent/environment forms elsewhere (#815).
    get "/catalog", CatalogController, :show

    # The machines conversations run on (ADR 0023 gate 3). Read-only: a
    # sandbox is made by creating a conversation, belongs to that conversation
    # alone, and is destroyed when it ends (ADR 0073).
    get "/sandboxes", SandboxController, :index
    get "/sandboxes/:id", SandboxController, :show

    resources "/conversations", ConversationController, only: [:index, :show, :create, :delete] do
      post "/prompts", ConversationController, :prompt, as: :prompt
      post "/wake", ConversationController, :wake, as: :wake
      post "/interrupt", ConversationController, :interrupt, as: :interrupt
      post "/terminate", ConversationController, :terminate, as: :terminate
      get "/turns", ConversationController, :turns, as: :turns
      # The JSON read-model for the log feed; /stream below is the tail (#519).
      get "/events", ConversationController, :events, as: :events
      post "/read", ConversationController, :read, as: :read
      # Labels (#1637). Not behind :require_full_scope on purpose: the point
      # of the route is that a sandbox stamps its own conversation.
      # `Conversations.set_conversation_labels/4` is what refuses a sandbox
      # token naming a different one. The other place a request can change a
      # conversation's labels is a create that resumes by `channel_id`, which
      # applies the same rule through `Conversations.resume_labels/3`.
      patch "/labels", ConversationController, :labels, as: :labels
      # Answer a permission request the agent is blocked on (#940). Nested so
      # the conversation is tenant-scoped before the request id is looked at.
      post "/requests/:request_id", ConversationController, :answer_request, as: :answer_request
      get "/tree", ConversationController, :tree, as: :tree
    end
  end

  # Image bytes over a bearer token. Outside the :accepts_json scope for the
  # same reason the SSE route is: a client fetching an image sends
  # `Accept: image/*`, which `plug :accepts, ["json"]` would refuse with 406
  # before the action ran. The JSON responses on the write paths are explicit,
  # so nothing here depends on negotiation.
  #
  # Avatars (#528) were written here from the start. Turn images were not —
  # they sat in the :accepts_json conversations scope and 406'd on
  # `Accept: image/png` until #578 moved them here, which is also what let
  # them be specced: one action per route, so `:api_show` can carry an
  # operation without dragging the browser route into the spec with it.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/agents/:id/avatar", AgentAvatarController, :api_show

    get "/conversations/:conversation_id/turns/:turn_id/images/:position",
        TurnImageController,
        :api_show
  end

  # An avatar is part of the agent, so writing one wants the same full scope
  # as the rest of the agent's writes above.
  scope "/api", FountainWeb do
    pipe_through [:api, :require_full_scope]

    put "/agents/:id/avatar", AgentAvatarController, :api_update
    delete "/agents/:id/avatar", AgentAvatarController, :api_delete
  end

  # Server-sent events. Same auth chain as the rest of /api, minus content
  # negotiation — see the `:api` pipeline. The action sets its own
  # `text/event-stream` content-type and its error paths go through
  # FallbackController's `json/2`, which does not consult the negotiated
  # format, so there is nothing here for `:accepts` to decide.
  scope "/api", FountainWeb do
    pipe_through :api

    get "/conversations/:conversation_id/stream", ConversationController, :stream,
      as: :conversation_stream
  end

  # Operator surface (#527). Three gates in order: :api authenticates the key,
  # :require_full_scope keeps a sandbox's per-conversation token out, and
  # :require_admin_api demands the role — the bearer-token analogue of
  # Live.Hooks.require_admin.
  scope "/api/admin", FountainWeb do
    pipe_through [:accepts_json, :api, :require_full_scope, :require_admin_api]

    get "/users", AdminController, :index_users
    post "/users", AdminController, :create_user
    get "/users/:id", AdminController, :show_user
    post "/users/:id/role", AdminController, :set_role

    delete "/users/:id", AdminController, :delete_user

    get "/sandboxes", AdminController, :index_sandboxes
    post "/sandboxes/:id/reap", AdminController, :reap_sandbox

    get "/audit", AdminController, :index_audit
  end

  ## ─── Authenticated browser / LiveView routes ──────────────────────────────────────────────────────────────────

  scope "/", FountainWeb do
    pipe_through [:browser, :browser_authenticated]

    # ── Where a provider sends the browser back after connecting a remote MCP
    # server (ADR 0085). Signed in, so only the user who started the login
    # can finish it ─────────────────────────────────────────────────────────
    get "/connections/callback", ConnectionCallbackController, :callback

    post "/account/security/password", AccountSecurityController, :change_password

    get "/account/inference-credentials", AccountRedirectController, :section,
      assigns: %{account_section: "inference-credentials"}

    get "/account/bindings", AccountRedirectController, :section,
      assigns: %{account_section: "bindings"}

    # ── Pages that became sections of /account: redirect, section open ───────
    get "/api-keys", AccountRedirectController, :section, assigns: %{account_section: "api-keys"}

    get "/account/oauth-apps", AccountRedirectController, :section,
      assigns: %{account_section: "oauth-apps"}

    get "/account/security", AccountRedirectController, :section,
      assigns: %{account_section: "password"}

    # ── The console ───────────────────────────────────────────────────────────
    # What Fountain's own UI is for: the dashboard, the account, its keys and
    # credentials, and the audit log. Agents, environments and vaults are
    # configured in the Conversations app, the CLI and the API (ADR 0076).
    live_session :authenticated,
      on_mount: [{FountainWeb.Live.Hooks, :require_authenticated_user}] do
      live "/account", Live.AccountLive, :index
      live "/dashboard", DashboardLive.Index, :index
      live "/audit", AuditLive.Index, :index
      # Device-authorization approval (#1305): where `managoat auth login
      # --device` sends the human. Authenticated so the key lands on the
      # signed-in account.
      live "/device", DeviceLive, :index
    end

    live_session :admin,
      on_mount: [
        {FountainWeb.Live.Hooks, :require_authenticated_user},
        {FountainWeb.Live.Hooks, :require_admin}
      ] do
      # One section per page. `/admin` was a single LiveView stacking all of
      # these, whose mount and 10s refresh ran every query behind every
      # section no matter which one was on screen.
      live "/admin", AdminLive.Index, :index
      live "/admin/users", AdminLive.Users, :index
      live "/admin/sandboxes", AdminLive.Sandboxes, :index
      live "/admin/broker", AdminLive.Broker, :index
      live "/admin/users/:id", AdminLive.UserDetail, :show
    end
  end

  ## ─── Unmatched /api paths ───────────────────────────────────────────────────────────────────────────

  # Declared LAST, after every core route, because Phoenix matches in
  # declaration order: this only ever sees a request core routing had no
  # answer for.
  #
  # `/api/<unknown>` answers 404 JSON rather than raising NoRouteError, and
  # only after the ordinary `:api` pipeline has run, so an unauthenticated
  # caller gets the same 401 on a path that does not exist as on one that does.
  scope "/api" do
    pipe_through [:accepts_json, :api]

    forward "/", FountainWeb.Plugs.ApiNotFound
  end

  ## ─── Dev dashboard ──────────────────────────────────────────────────────────────────────────────────

  if Application.compile_env(:fountain, :dev_routes) do
    import Phoenix.LiveDashboard.Router

    scope "/dev" do
      pipe_through [:browser]
      live_dashboard "/dashboard", metrics: FountainWeb.Telemetry
    end
  end
end
