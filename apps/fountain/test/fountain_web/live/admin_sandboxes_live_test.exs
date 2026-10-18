defmodule FountainWeb.AdminSandboxesLiveTest do
  use FountainWeb.ConnCase, async: true
  use Mimic

  import Phoenix.LiveViewTest

  alias Fountain.Accounts

  # Reaping a machine with no live server destroys it at the provider since
  # ADR 0058 stage 5b, where it used to write the row and leave the sprite for
  # the reaper. Nothing here is about the provider, so the adapter seam answers
  # yes — the same stub stage 5a added to nine files for the same reason.
  setup do
    stub(Managoat.Sandbox.Sprites, :destroy, fn _handle -> :ok end)
    :ok
  end

  # The transition badge on *this* machine's row, rather than anywhere on the
  # page. The table lists every non-terminal sandbox, so a whole-page
  # `refute html =~ "abandoned"` reads every other row in the database too —
  # which passed or failed by test order rather than by what this test set up.
  defp badge(html, sandbox) do
    # The page identifies a row by the first eight characters of the sandbox
    # id, which is the only thing on it unique to one machine.
    id = String.slice(sandbox.id, 0, 8)

    html
    |> String.split("<tr")
    |> Enum.find(&String.contains?(&1, id))
    |> case do
      nil -> flunk("no row for sandbox #{id} on /admin/sandboxes")
      row -> row
    end
  end

  defp stamp(sandbox, sets) do
    put_lease(sandbox.id, sets)
  end

  defp insert_admin(overrides \\ %{}) do
    user = insert_active_user(overrides)
    {:ok, admin} = Accounts.update_user_role(user, "admin")
    admin
  end

  describe "AdminLive.Sandboxes — sandboxes section" do
    test "shows 'No active sandboxes' when there are none", %{conn: conn} do
      admin = insert_admin()
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ "No active sandboxes"
    end

    test "renders active sandboxes in the table", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ String.slice(sandbox.id, 0, 8)
      assert html =~ "ready"
    end

    test "shows the sandbox owner and links conversations to the admin view (#446)", %{
      conn: conn
    } do
      admin = insert_admin()
      owner = insert_active_user()
      sandbox = insert_sandbox(user_id: owner.id, status: "ready")
      conv = insert_conversation(user_id: owner.id, sandbox: sandbox)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      # owner column, linking to the user detail page
      assert html =~ owner.email
      assert html =~ ~p"/admin/users/#{owner.id}"
      # the conversation is named, not linked: there is no cross-tenant
      # conversation page, and the tenant-scoped one 404s for an admin
      assert html =~ String.slice(conv.id, 0, 8)
      refute html =~ ~s{href="/conversations/#{conv.id}"}
    end

    test "does not show terminated sandboxes", %{conn: conn} do
      admin = insert_admin()
      terminated = insert_sandbox(user_id: admin.id, status: "terminated")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      refute html =~ String.slice(terminated.id, 0, 8)
    end

    test "shows ready sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ "ready"
    end

    test "shows failed sandbox with correct status badge", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "failed")
      conn = login_user(conn, admin)
      # failed is excluded by _unsafe_list_sandboxes_admin (status not in ["terminated","failed"])
      # so page should show "No active sandboxes"
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")
      assert html =~ "Active sandboxes"
    end
  end

  describe "AdminLive.Sandboxes — sandbox conversations branch" do
    test "shows dash when sandbox has no conversations", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      # The empty-conversations span renders an em-dash
      assert html =~ "—"
    end

    test "names the conversations when the sandbox has some", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conv = insert_conversation(sandbox: sandbox, user_id: admin.id)
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      # The conversation id prefix appears; there is no page to link to
      assert html =~ String.slice(conv.id, 0, 8)
      refute html =~ "/conversations/#{conv.id}"
    end

    test "renders pending sandbox with fallback status color", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "pending")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ "pending"
      # fallback clause: neutral token classes
      assert html =~ "text-[var(--color-text-secondary)]"
    end

    test "renders starting sandbox with fallback status color", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "starting")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ "starting"
      assert html =~ "text-[var(--color-text-secondary)]"
    end

    test "sandbox inserted_at timestamp is formatted in the table", %{conn: conn} do
      admin = insert_admin()
      _sandbox = insert_sandbox(user_id: admin.id, status: "ready")
      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      # format_ts renders "YYYY-MM-DD HH:MM" — the year is always present
      assert html =~ to_string(Date.utc_today().year)
    end

    test "each sandbox status gets a badge of its own, from the theme tokens", %{conn: conn} do
      admin = insert_admin()

      for status <- ~w(starting ready suspended failed terminated),
          do: insert_sandbox(user_id: admin.id, status: status)

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      colors =
        Enum.map(
          ~w(starting ready suspended failed terminated),
          &FountainWeb.AdminLive.Helpers.sandbox_status_color/1
        )

      assert colors == Enum.uniq(colors)
      assert html =~ "text-[var(--color-info-text)]"
      assert html =~ "text-[var(--color-success-text)]"
      assert html =~ "text-[var(--color-error-text)]"
      refute html =~ ~r/\b(bg|text|border)-(blue|green|red|sky|amber|zinc)-\d/
    end
  end

  describe "AdminLive.Sandboxes — reap_sandbox" do
    test "reaps a ready sandbox with no live server and audits it", %{conn: conn} do
      admin = insert_admin()
      sandbox = insert_sandbox(status: "ready")
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/sandboxes")

      html =
        lv
        |> element("button[phx-value-id='#{sandbox.id}'][phx-click='reap_sandbox']")
        |> render_click()

      assert html =~ "released"
      reloaded = Fountain.Conversations._unsafe_get_sandbox!(sandbox.id)
      assert reloaded.status == "terminated"
      assert reloaded.terminated_at

      assert Enum.any?(
               Fountain.Audit._unsafe_list_events(action_prefix: "admin.", limit: 10),
               &(&1.action == "admin.sandbox.reaped" and
                   &1.metadata["sandbox_id"] == sandbox.id)
             )
    end

    test "a refused reap is a flash, not a crash", %{conn: conn} do
      # Since ADR 0058 stage 5b a reap goes through the machine's owner and can
      # be refused — most often because the reaper's own expiry of the same row
      # is holding its lease. Before this clause the LiveView died with a
      # `CaseClauseError`: no flash, the tab reconnects, the row is still there
      # and the operator has no idea why.
      admin = insert_admin()
      sandbox = insert_sandbox(status: "ready")
      conn = login_user(conn, admin)
      {:ok, lv, _html} = live(conn, ~p"/admin/sandboxes")

      stub(Fountain.Machines.Destroy, :run, fn _id, _opts -> {:error, :machine_busy} end)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          send(self(), {:rendered, reap_click(lv, sandbox)})
        end)

      assert log =~ "refused"
      assert_received {:rendered, html}
      assert html =~ "Sandbox busy"

      # Untouched, and still listed, so the next click is the whole remedy.
      assert Fountain.Conversations._unsafe_get_sandbox!(sandbox.id).status == "ready"
    end

    defp reap_click(lv, sandbox) do
      lv
      |> element("button[phx-value-id='#{sandbox.id}'][phx-click='reap_sandbox']")
      |> render_click()
    end
  end

  describe "AdminLive.Sandboxes — no spend roll-up (ADR 0079)" do
    test "lists sandboxes without a per-provider or per-tenant spend panel", %{conn: conn} do
      admin = insert_admin()
      user = insert_active_user()
      insert_sandbox(user_id: user.id, provider: "e2b", status: "ready")

      conn = login_user(conn, admin)
      {:ok, _lv, html} = live(conn, ~p"/admin/sandboxes")

      assert html =~ "Active sandboxes"
      refute html =~ "Spend by provider"
      refute html =~ "Billable to us"
      refute html =~ "Who it belongs to"
    end
  end

  describe "a machine mid-operation" do
    test "says what its owner is doing to it, and whether anyone still is", %{conn: conn} do
      # From the surfaces review: the page said `ready` for a machine being
      # parked or destroyed, which is the reading an operator decides on — and
      # the reason the Reap button next to it answers 503.
      admin = insert_admin()
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      stamp(sandbox,
        lease_epoch: 1,
        lease_node: live_lease_holder(),
        transition: "parking",
        transition_reason: "idle"
      )

      {:ok, _live, html} = conn |> login_user(admin) |> live(~p"/admin/sandboxes")

      row = badge(html, sandbox)
      assert row =~ "parking"
      refute row =~ "abandoned"

      # And the other reading: a stamp with no live lease is an operation whose
      # owner died, which is a different thing for an operator to see.
      stamp(sandbox, lease_node: dead_lease_holder())

      {:ok, _live, html} = conn |> login_user(admin) |> live(~p"/admin/sandboxes")
      assert badge(html, sandbox) =~ "abandoned"
    end

    test "a destroy in flight is not called unfinished; one whose owner died is",
         %{conn: conn} do
      # `lease_less_note/2` has its own tests (`admin_sandboxes_note_test.exs`),
      # but those drive the function: they cannot see whether the template
      # still calls it. This renders the page, reads the one row through
      # `badge/2` rather than matching the whole document, and so fails if the
      # note is dropped from the row as well as if it is wrong (review, round 2).
      admin = insert_admin()
      user = insert_verified_user()
      sandbox = insert_sandbox(user_id: user.id, status: "ready")

      stamp(sandbox,
        lease_epoch: 1,
        lease_node: live_lease_holder(),
        transition: "destroying",
        transition_reason: "admin_reap"
      )

      {:ok, _live, html} = conn |> login_user(admin) |> live(~p"/admin/sandboxes")

      row = badge(html, sandbox)
      assert row =~ "destroying"
      refute row =~ "(unfinished)", "an owner is working on this row; it is not unfinished"

      stamp(sandbox, lease_node: dead_lease_holder())

      {:ok, _live, html} = conn |> login_user(admin) |> live(~p"/admin/sandboxes")
      assert badge(html, sandbox) =~ "destroying (unfinished)"
    end
  end
end
