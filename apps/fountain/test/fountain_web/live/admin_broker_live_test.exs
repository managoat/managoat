defmodule FountainWeb.AdminBrokerLiveTest do
  @moduledoc """
  `/admin/broker` renders what `Fountain.Broker.Native.Insights` hands it.
  The figures are that module's tests; this file covers the door, the
  window control, and that each section shows its rows and links them.
  """

  use FountainWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Fountain.Accounts
  alias Fountain.Broker.Native.Request

  defp insert_admin do
    user = insert_active_user()
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  defp log!(user, conv, attrs) do
    base = %{
      conversation_id: conv.id,
      user_id: user.id,
      method: "GET",
      host: "api.example.com",
      path: "/v1/things",
      outcome: "passthrough",
      credential_keys: [],
      inserted_at: DateTime.utc_now()
    }

    Fountain.Repo.insert!(struct!(Request, Map.merge(base, Map.new(attrs))))
  end

  # `assert_redirect/2` asserts the path and drops the rest. Both halves matter
  # here: sending a demoted operator to the login form and sending them to the
  # dashboard are different bugs, and both are a redirect to somewhere.
  # `push_navigate` reaches the test proxy as a `:redirect` carrying
  # `kind: :push` (the target lives in another `live_session`); a plain
  # `redirect` carries no `:kind`.
  defp assert_navigated(lv, kind, to) do
    %{proxy: {ref, topic, _}} = lv
    assert_receive {^ref, {:redirect, ^topic, %{to: ^to} = opts}}
    assert Map.get(opts, :kind) == kind
  end

  describe "access control" do
    test "an admin can open it and the tab is in the bar", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, _lv, html} = live(conn, ~p"/admin/broker")

      assert html =~ "Broker"
      assert html =~ "Health"
      assert html =~ "Live sessions"
      assert html =~ ~s(href="/admin/broker")
    end

    test "a regular user is sent to the dashboard", %{conn: conn} do
      conn = login_user(conn, insert_active_user())
      assert {:error, {:live_redirect, _}} = live(conn, ~p"/admin/broker")
    end

    test "an anonymous visitor is sent to login", %{conn: conn} do
      assert {:error, {:redirect, %{to: path}}} = live(conn, ~p"/admin/broker")
      assert path =~ "/auth/login"
    end
  end

  # `require_admin` runs at mount only, so every read rechecks. Where it
  # sends an operator matters: the hook distinguishes the three cases
  # (`FountainWeb.Live.Hooks`), and a demoted operator still holding a valid
  # session gets a login form that reads as a failed login if this does not.
  describe "authorization after mount" do
    for {change, redirect} <- [
          {:demotion, {:push, "/dashboard"}},
          {:session, {nil, "/auth/login"}},
          {:verification, {nil, "/auth/login"}}
        ],
        action <- [:timer, :window, :refresh] do
      test "#{change} prevents fresh data on #{action}", %{conn: conn} do
        admin = insert_admin()
        {:ok, lv, _html} = conn |> login_user(admin) |> live(~p"/admin/broker")

        attrs =
          case unquote(change) do
            :demotion -> [role: "user"]
            :session -> [session_version: admin.session_version + 1]
            :verification -> [email_verified_at: nil]
          end

        admin |> Ecto.Changeset.change(attrs) |> Fountain.Repo.update!()
        tenant = insert_active_user()
        conv = insert_conversation(user_id: tenant.id)
        log!(tenant, conv, outcome: "denied", host: "after-revocation.example")

        test_pid = self()
        handler = {__MODULE__, make_ref()}

        :telemetry.attach(
          handler,
          [:fountain, :repo, :query],
          fn _, _, meta, _ ->
            if self() == lv.pid and String.contains?(meta.query, "broker_") do
              send(test_pid, :unauthorized_broker_query)
            end
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler) end)

        case unquote(action) do
          :timer -> send(lv.pid, :refresh)
          :window -> render_patch(lv, ~p"/admin/broker?window=168")
          :refresh -> lv |> element("button[phx-click=refresh]") |> render_click()
        end

        {kind, to} = unquote(redirect)
        assert_navigated(lv, kind, to)
        refute_received :unauthorized_broker_query
      end
    end
  end

  describe "content" do
    test "an empty window says so in each section", %{conn: conn} do
      conn = login_user(conn, insert_admin())
      {:ok, _lv, html} = live(conn, ~p"/admin/broker")

      refute html =~ "This deployment does not broker"
      assert html =~ "Nothing was denied in this window"
      assert html =~ "No sandbox holds a proxy token"
      assert html =~ "No sandbox is cutting streams in this window"
    end

    # #2503: a machine that drops quiet connections cuts most streamed
    # replies; the page names the sandbox, its owner and the remedy: an
    # operator's reap, or the owner's new conversation.
    test "a sandbox cutting most of its streams is listed with its owner", %{conn: conn} do
      admin = insert_admin()
      tenant = insert_active_user()
      conv = insert_conversation(user_id: tenant.id, agent: insert_agent(user_id: tenant.id))

      for _ <- 1..8, do: log!(tenant, conv, latency_ms: 5_000, error: "client_closed")
      for _ <- 1..2, do: log!(tenant, conv, latency_ms: 5_000, status: 200)

      {:ok, _lv, html} = conn |> login_user(admin) |> live(~p"/admin/broker")

      refute html =~ "No sandbox is cutting streams"
      assert html =~ String.slice(conv.sandbox_id, 0, 8)
      assert html =~ "8 (80%)"
      assert html =~ "POST /api/admin/sandboxes/:id/reap"
      assert html =~ "start a new conversation"
      refute html =~ "sandbox reset"
      assert html =~ ~s(href="/admin/users/#{tenant.id}")
      assert html =~ ~s(href="/admin/sandboxes")
    end

    test "shows the traffic split, the hosts, and links denied rows to their conversation", %{
      conn: conn
    } do
      admin = insert_admin()
      tenant = insert_active_user()
      conv = insert_conversation(user_id: tenant.id, agent: insert_agent(user_id: tenant.id))

      log!(tenant, conv,
        outcome: "injected",
        service: "github",
        credential_keys: ["GITHUB_TOKEN"]
      )

      log!(tenant, conv, outcome: "denied", host: "blocked.example", path: "/secret")
      log!(tenant, conv, outcome: "passthrough", error: "upstream_closed", status: nil)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/broker")

      assert html =~ "blocked.example"
      assert html =~ "GITHUB_TOKEN"
      assert html =~ "upstream_closed"
      assert html =~ tenant.email
      assert html =~ String.slice(conv.id, 0, 8)
      assert html =~ ~s(href="/admin/users/#{tenant.id}")
    end

    test "timer refreshes health without querying traffic; explicit refresh loads new rows", %{
      conn: conn
    } do
      admin = insert_admin()
      {:ok, lv, _html} = conn |> login_user(admin) |> live(~p"/admin/broker")
      tenant = insert_active_user()
      conv = insert_conversation(user_id: tenant.id)
      log!(tenant, conv, outcome: "denied", host: "new-traffic.example")

      test_pid = self()
      handler = {__MODULE__, make_ref()}

      :telemetry.attach(
        handler,
        [:fountain, :repo, :query],
        fn _, _, meta, _ ->
          if self() == lv.pid and String.contains?(meta.query, "broker_requests") do
            send(test_pid, :traffic_query)
          end
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      send(lv.pid, :refresh)
      refute render(lv) =~ "new-traffic.example"
      refute_received :traffic_query

      html = lv |> element("button[phx-click=refresh]") |> render_click()
      assert html =~ "new-traffic.example"
      assert_received :traffic_query
    end

    # A `502 credential_missing` is the broker failing to hold a credential, not
    # policy deciding, and it is the fault this page exists to catch. It has to
    # be legible as that, and it must not be counted twice.
    test "a refusal for a missing credential is named, and counted only once", %{conn: conn} do
      admin = insert_admin()
      tenant = insert_active_user()
      conv = insert_conversation(user_id: tenant.id, agent: insert_agent(user_id: tenant.id))

      log!(tenant, conv,
        outcome: "denied",
        error: "credential_missing",
        status: 502,
        host: "api.github.com"
      )

      {:ok, _lv, html} = conn |> login_user(admin) |> live(~p"/admin/broker")

      assert html =~ "for a missing credential"
      assert html =~ "credential_missing"
      assert html =~ "Nothing failed in this window."
    end

    test "a workspace's setup session, which has no conversation, is listed as the workspace's",
         %{conn: conn} do
      admin = insert_admin()
      tenant = insert_active_user()
      workspace = insert_workspace(user_id: tenant.id, implicit: false, name: "work")

      {:ok, _} =
        Fountain.Broker.Native.Sessions.create_workspace(%{
          workspace_id: workspace.id,
          user_id: tenant.id,
          rules: [],
          meta: %{},
          ttl_seconds: 600
        })

      {:ok, _lv, html} = conn |> login_user(admin) |> live(~p"/admin/broker")
      assert html =~ "workspace " <> String.slice(workspace.id, 0, 8)
    end

    test "the live-session table says when it is short of the true total", %{conn: conn} do
      admin = insert_admin()
      tenant = insert_active_user()
      {:ok, _lv, html} = conn |> login_user(admin) |> live(~p"/admin/broker")
      refute html =~ "do not fit"

      # More live rows than the table shows. One conversation can hold them
      # all: `Sessions.create/1` mints per provision and reattach.
      conv = insert_conversation(user_id: tenant.id, agent: insert_agent(user_id: tenant.id))

      for _ <- 1..51 do
        {:ok, _} =
          Fountain.Broker.Native.Sessions.create(%{
            conversation_id: conv.id,
            user_id: tenant.id,
            rules: [],
            meta: %{},
            ttl_seconds: 600
          })
      end

      {:ok, _lv, html} = conn |> login_user(admin) |> live(~p"/admin/broker")
      assert html =~ "The 51 live sessions do not fit"
      assert html =~ "most recently minted"
    end

    test "the window comes from the URL and only the chosen one is current", %{conn: conn} do
      admin = insert_admin()
      tenant = insert_active_user()
      conv = insert_conversation(user_id: tenant.id, agent: insert_agent(user_id: tenant.id))
      old = DateTime.add(DateTime.utc_now(), -48, :hour)
      log!(tenant, conv, outcome: "denied", host: "two-days-ago.example", inserted_at: old)

      conn = login_user(conn, admin)
      {:ok, lv, html} = live(conn, ~p"/admin/broker")
      refute html =~ "two-days-ago.example"

      html = lv |> element("a[href='/admin/broker?window=168']") |> render_click()
      assert html =~ "two-days-ago.example"
      assert html =~ "Traffic, last 7d"

      # A window the page does not offer falls back to a day.
      {:ok, _lv, html} = live(conn, ~p"/admin/broker?window=5")
      assert html =~ "Traffic, last 24h"
    end
  end
end
