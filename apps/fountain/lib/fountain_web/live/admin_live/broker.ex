defmodule FountainWeb.AdminLive.Broker do
  @moduledoc """
  `/admin/broker` — the egress credential broker (ADR 0019): is it up, who
  is it brokering, what did brokered sandboxes reach, and what did it refuse.

  The broker has fronted every tenant's sandbox since 2026-09-04, which made
  it the one component whose failure looks, from inside a sandbox, like the
  internet being down. Its state was on Grafana and in the per-conversation
  egress endpoint and nowhere an operator could glance at. This page is the
  glance, from `Fountain.Broker.Native.Insights`: the health tiles first,
  then the traffic over a window, then the lists that call for action —
  what was denied, what failed, and which sandboxes keep cutting streams —
  and finally the live sessions.

  Nothing here decrypts a rule, shows a credential value or names a header.
  The credential column is the *names* of the variables the proxy attached,
  which is what the audit trail records for a secret too.
  """

  use FountainWeb, :live_view

  import FountainWeb.AdminLive.Helpers
  import FountainWeb.AdminLive.Shell

  alias Fountain.Broker.Native.Insights

  @refresh_ms 30_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Process.send_after(self(), :refresh, @refresh_ms)

    {:ok,
     socket
     |> assign(:page_title, "Admin · Broker")
     |> assign(:window, 24)}
  end

  # The window lives in the URL so a refresh, a reload and a shared link all
  # keep it.
  @impl true
  def handle_params(params, _uri, socket) do
    window =
      case Integer.parse(params["window"] || "") do
        {hours, ""} -> if hours in Insights.windows(), do: hours, else: 24
        _ -> 24
      end

    {:noreply, socket |> assign(:window, window) |> assign_overview()}
  end

  @impl true
  def handle_info(:refresh, socket) do
    socket = refresh_overview(socket, :health)
    unless socket.redirected, do: Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, assign_overview(socket)}
  end

  defp assign_overview(socket), do: refresh_overview(socket, :all)

  # A conversation's session, or an explicit workspace's setup session, which
  # has no conversation (ADR 0097).
  defp session_owner(%{conversation_id: id}) when is_binary(id), do: String.slice(id, 0, 8)

  defp session_owner(%{workspace_id: id}) when is_binary(id),
    do: "workspace " <> String.slice(id, 0, 8)

  defp session_owner(_session), do: "—"

  # `require_admin` runs once, at mount; a role or a session can be revoked
  # while the tab is open, so every read rechecks before it queries. The three
  # ineligible cases land where `FountainWeb.Live.Hooks` would have sent them
  # — an operator who was only demoted still holds a valid session, and a
  # login form in front of them reads as a failed login (#533).
  defp refresh_overview(socket, scope) do
    mounted = socket.assigns.current_user

    case Fountain.Accounts.get_user(mounted.id) do
      %{session_version: version} = user when version == mounted.session_version ->
        eligible(socket, user, scope)

      # No such user any more, or the session was revoked out from under it.
      _ ->
        redirect(socket, to: ~p"/auth/login")
    end
  end

  defp eligible(socket, %{email_verified_at: nil}, _scope),
    do: redirect(socket, to: ~p"/auth/login")

  defp eligible(socket, %{role: role}, _scope) when role != "admin",
    do: push_navigate(socket, to: ~p"/dashboard")

  defp eligible(socket, _user, scope) do
    overview =
      case scope do
        :all -> Insights._unsafe_overview_admin(socket.assigns.window)
        :health -> Map.merge(socket.assigns.overview, Insights._unsafe_health_admin())
      end

    assign(socket, :overview, overview)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <.admin_header title="Broker" current={:broker}>
        <:subtitle>
          Health refreshes every 30s. Traffic and session details refresh on request.
        </:subtitle>
        <:actions>
          <button type="button" phx-click="refresh" class="px-2 py-1 rounded border text-xs">
            Refresh data
          </button>
          <nav class="flex items-center gap-1 text-xs" aria-label="Window">
            <.link
              :for={hours <- Insights.windows()}
              patch={~p"/admin/broker?window=#{hours}"}
              aria-current={if hours == @window, do: "page"}
              class={[
                "px-2 py-1 rounded border",
                if(hours == @window,
                  do:
                    "bg-[var(--color-text-primary)] text-[var(--color-bg-1)] border-[var(--color-text-primary)]",
                  else:
                    "bg-[var(--color-bg-1)] text-[var(--color-text-secondary)] border-[var(--color-border-strong)] hover:text-[var(--color-text-primary)]"
                )
              ]}
            >
              {window_label(hours)}
            </.link>
          </nav>
        </:actions>
      </.admin_header>

      <p class="text-xs text-[var(--color-text-secondary)]">
        Counts describe recorded requests. Dropped log rows are absent; check
        <code>FountainBrokerLogDropping</code>
        in Grafana before treating counts as complete.
      </p>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Health</h2>
        <div class="grid grid-cols-2 sm:grid-cols-4 gap-3">
          <.tile label="Listener">
            <span class={[
              "inline-flex items-center rounded px-1.5 py-0.5 text-sm font-medium border",
              if(@overview.listener_up,
                do:
                  "bg-[var(--color-success-bg)] text-[var(--color-success-text)] border-[var(--color-success)]",
                else:
                  "bg-[var(--color-error-bg)] text-[var(--color-error-text)] border-[var(--color-error)]"
              )
            ]}>
              {if @overview.listener_up, do: "up", else: "down"}
            </span>
          </.tile>
          <.tile label="Live sessions">
            {@overview.sessions.live}
            <:note>
              {@overview.sessions.conversations} conversations · {@overview.sessions.expired} expired, unswept
            </:note>
          </.tile>
          <.tile label="CA expires">
            {if @overview.ca_expires_at, do: format_date(@overview.ca_expires_at), else: "—"}
            <:note>the root every sandbox trusts</:note>
          </.tile>
          <.tile label="Log retention">
            {@overview.retention_hours}h
            <:note>rows older are swept daily</:note>
          </.tile>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Traffic, last {window_label(@window)}</h2>
        <div class="grid grid-cols-2 sm:grid-cols-6 gap-3">
          <.tile label="Requests">
            {@overview.window.requests}
            <:note>
              {@overview.window.conversations} conversations · {@overview.window.tenants} tenants
            </:note>
          </.tile>
          <.tile label="Credential attached">
            {@overview.window.injected}
            <:note>{share(@overview.window.injected, @overview.window.requests)}</:note>
          </.tile>
          <.tile label="Passed through">
            {@overview.window.passthrough}
            <:note>{share(@overview.window.passthrough, @overview.window.requests)}</:note>
          </.tile>
          <.tile label="Denied" alert={@overview.window.denied > 0}>
            {@overview.window.denied}
            <:note>
              {share(@overview.window.denied, @overview.window.requests)}
              <span :if={@overview.window.no_credential > 0}>
                · {@overview.window.no_credential} for a missing credential
              </span>
            </:note>
          </.tile>
          <.tile label="Failed" alert={@overview.window.failed > 0}>
            {@overview.window.failed}
            <:note>
              {Enum.map_join(@overview.errors, " · ", &"#{&1.error} #{&1.requests}")}
            </:note>
          </.tile>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
          <.admin_table rows={@overview.hosts} empty="Nothing in this window.">
            <:title>Hosts</:title>
            <:col :let={h} label="Host">{h.host}</:col>
            <:col :let={h} label="Requests" numeric>{h.requests}</:col>
            <:col :let={h} label="Credential" numeric>{h.injected}</:col>
            <:col :let={h} label="Denied" numeric>
              <span class={h.denied > 0 && "text-[var(--color-warning-text)] font-medium"}>
                {h.denied}
              </span>
            </:col>
            <:col :let={h} label="Failed" numeric>
              <span class={h.failed > 0 && "text-[var(--color-error-text)] font-medium"}>
                {h.failed}
              </span>
            </:col>
          </.admin_table>

          <.admin_table
            rows={@overview.services}
            empty="No credential was attached in this window."
          >
            <:title>Credentials attached, by binding</:title>
            <:col :let={s} label="Binding">{s.service}</:col>
            <:col :let={s} label="Variables" muted>{Enum.join(s.credential_keys, ", ")}</:col>
            <:col :let={s} label="Requests" numeric>{s.requests}</:col>
            <:col :let={s} label="Conversations" numeric>{s.conversations}</:col>
          </.admin_table>
        </div>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Denied</h2>
        <p class="text-xs text-[var(--color-text-secondary)]">
          Requests the broker answered itself; the <span class="font-medium">Ended</span>
          column says which kind. A <code>403</code>
          is policy: a host outside a limited environment's allowed list. A
          <code>502 credential_missing</code>
          is the broker lacking a credential a rule names (a tenant's secret missing,
          undecryptable or not yet granted), so it refused rather than send the request
          without one; this window holds <span class={
            @overview.window.no_credential > 0 && "text-[var(--color-error-text)] font-medium"
          }>{@overview.window.no_credential}</span>. A <code>413</code>
          is a body over the size limit. Unresolved proxy tokens are refused before a row
          exists, so look for them in <code>fountain.broker.session_lookup</code>
          and the <code>FountainBrokerSessionsUnresolvable</code>
          alert.
        </p>
        <.request_table rows={@overview.denied} empty="Nothing was denied in this window." />
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Failed</h2>
        <p class="text-xs text-[var(--color-text-secondary)]">
          Forwarded requests that did not complete. <code class="font-mono">client_closed</code>
          is the sandbox hanging up first, usually a cancelled turn; a run of them on one
          sandbox is listed under Sandboxes cutting streams. <code class="font-mono">upstream_*</code>
          is the origin, and a run of them on one host is that host, not the broker.
          Refusals never forwarded and are counted under Denied.
        </p>
        <.request_table rows={@overview.failed} empty="Nothing failed in this window." />
      </section>

      <section class="space-y-3" id="cut-sandboxes">
        <h2 class="text-lg font-medium">Sandboxes cutting streams</h2>
        <p class="text-xs text-[var(--color-text-secondary)]">
          Sandboxes where at least half of the streamed requests (a second or longer, at least
          ten in this window) ended <code class="font-mono">client_closed</code>. Healthy traffic
          stays under 1%. A share like this is a machine that drops any connection left quiet
          for about a second, so every model reply that pauses to think is cut.
          Managoat cannot repair the machine, only replace it. An operator reaps it from
          <.link navigate={~p"/admin/sandboxes"} class="underline">Sandboxes</.link>
          (<code class="font-mono">POST /api/admin/sandboxes/:id/reap</code>): a conversation
          with a live process on it is terminated, and one without keeps its transcript and
          builds a new sandbox on its next prompt, without what was on the old disk. The owner
          cannot replace a conversation's sandbox; they start a new conversation, which gets a
          new machine.
        </p>
        <.admin_table
          rows={@overview.cut_sandboxes}
          empty="No sandbox is cutting streams in this window."
        >
          <:col :let={s} label="Sandbox">
            <span title={s.sandbox_id}>{String.slice(s.sandbox_id, 0, 8)}</span>
            <span class="text-[var(--color-text-secondary)]">{s.status}</span>
          </:col>
          <:col :let={s} label="Machine" muted>{s.provider}:{s.machine_name}</:col>
          <:col :let={s} label="Owner"><.owner user_id={s.user_id} email={s.email} /></:col>
          <:col :let={s} label="Streams" numeric>{s.streams}</:col>
          <:col :let={s} label="Cut" numeric class="text-[var(--color-error-text)] font-medium">
            {s.cut} ({round(s.share * 100)}%)
          </:col>
          <:col :let={s} label="Conversations" numeric>{s.conversations}</:col>
          <:col :let={s} label="Last seen" muted class="whitespace-nowrap">
            {format_ts(s.last_seen_at)}
          </:col>
        </.admin_table>
      </section>

      <section class="space-y-3">
        <h2 class="text-lg font-medium">Live sessions</h2>
        <p
          :if={@overview.live_sessions_total > length(@overview.live_sessions)}
          class="text-xs text-[var(--color-warning-text)]"
        >
          The {@overview.live_sessions_total} live sessions do not fit: these are the {length(
            @overview.live_sessions
          )} most recently minted. A conversation holds one per provision and reattach until each
          expires, so a conversation can appear more than once.
        </p>
        <.admin_table
          rows={@overview.live_sessions}
          empty="No sandbox holds a proxy token right now."
        >
          <:col :let={s} label="Conversation">
            <span class="font-mono">{session_owner(s)}</span>
          </:col>
          <:col :let={s} label="Owner"><.owner user_id={s.user_id} email={s.email} /></:col>
          <:col :let={s} label="Unmatched host">{s.policy}</:col>
          <:col :let={s} label="Brokered variables" muted>
            {if s.credential_keys == [], do: "—", else: Enum.join(s.credential_keys, ", ")}
          </:col>
          <:col :let={s} label="Minted" muted class="whitespace-nowrap">
            {format_ts(s.inserted_at)}
          </:col>
          <:col :let={s} label="Expires" muted class="whitespace-nowrap">
            {format_ts(s.expires_at)}
          </:col>
        </.admin_table>
      </section>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :alert, :boolean, default: false
  slot :inner_block, required: true
  slot :note

  defp tile(assigns) do
    ~H"""
    <div class={[
      "bg-[var(--color-bg-1)] rounded shadow border px-4 py-3",
      if(@alert, do: "border-[var(--color-warning)]", else: "border-[var(--color-border)]")
    ]}>
      <div class="text-xs text-[var(--color-text-secondary)]">{@label}</div>
      <div class="text-2xl font-semibold tabular-nums">{render_slot(@inner_block)}</div>
      <div :if={@note != []} class="text-xs text-[var(--color-text-secondary)] truncate">
        {render_slot(@note)}
      </div>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :empty, :string, required: true

  defp request_table(assigns) do
    ~H"""
    <.admin_table rows={@rows} empty={@empty}>
      <:col :let={r} label="When" muted class="whitespace-nowrap">{format_ts(r.inserted_at)}</:col>
      <:col :let={r} label="Request">
        {r.method} {r.host}<span class="text-[var(--color-text-secondary)]">{String.slice(
          r.path,
          0,
          60
        )}</span>
      </:col>
      <:col :let={r} label="Ended" muted>
        {[r.status, r.error] |> Enum.reject(&is_nil/1) |> Enum.join(" ")}
      </:col>
      <:col :let={r} label="Conversation">
        <span class="font-mono">{String.slice(r.conversation_id, 0, 8)}</span>
      </:col>
      <:col :let={r} label="Owner"><.owner user_id={r.user_id} email={r.email} /></:col>
    </.admin_table>
    """
  end

  attr :user_id, :string, default: nil
  attr :email, :string, default: nil

  defp owner(assigns) do
    ~H"""
    <.link :if={@email} navigate={~p"/admin/users/#{@user_id}"} class="hover:underline">
      {@email}
    </.link>
    <span :if={is_nil(@email)} class="text-[var(--color-text-muted)]">deleted</span>
    """
  end

  defp window_label(1), do: "1h"
  defp window_label(24), do: "24h"
  defp window_label(168), do: "7d"
  defp window_label(hours), do: "#{hours}h"

  defp share(_part, 0), do: "—"
  defp share(part, whole), do: "#{round(part / whole * 100)}% of requests"
end
