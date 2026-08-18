defmodule TymeslotWeb.Dashboard.AnnouncementModalTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :live
  @moduletag :notifications

  import Phoenix.LiveViewTest
  import Tymeslot.Factory

  alias Plug.Conn
  alias Plug.Test, as: PlugTest
  alias Tymeslot.Announcements
  alias Tymeslot.Announcements.AnnouncementQueries
  alias Tymeslot.AnnouncementsMidCtaTestCatalog
  alias Tymeslot.AnnouncementsSingleTestCatalog
  alias Tymeslot.AnnouncementsTestCatalog
  alias Tymeslot.AuthTestHelpers

  setup %{conn: conn} do
    previous = Application.get_env(:tymeslot, :announcement_catalogs, [])

    Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsTestCatalog])

    on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)

    {:ok, conn: conn}
  end

  defp pre_existing_user(opts \\ []) do
    inserted_at = Keyword.get(opts, :inserted_at, ~N[2025-12-01 00:00:00])

    user =
      insert(:user,
        inserted_at: inserted_at,
        onboarding_completed_at: DateTime.utc_now()
      )

    insert(:profile, user: user)
    user
  end

  defp log_in(conn, user) do
    conn
    |> PlugTest.init_test_session(%{})
    |> Conn.fetch_session()
    |> AuthTestHelpers.log_in_user(user)
  end

  describe "/dashboard with no unseen announcements" do
    test "does not render the modal", %{conn: conn} do
      user = pre_existing_user()
      Announcements.mark_seen!(user, "test_alpha")
      Announcements.mark_seen!(user, "test_beta")

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "announcement-modal-modal"
    end
  end

  describe "/dashboard with unseen announcements" do
    test "renders the first announcement and the step indicator", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Alpha"
      assert html =~ "1 / 2"
    end

    test "Next advances and marks the prior announcement seen", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view
      |> element(~s|button[phx-click="next"]|)
      |> render_click()

      rendered = render(view)
      assert rendered =~ "Beta"
      assert rendered =~ "2 / 2"
      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_alpha"]
    end

    test "CTA on the last item closes the modal and marks all seen", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element(~s|button[phx-click="next"]|) |> render_click()
      view |> element(~s|button[phx-click="cta"]|) |> render_click()

      keys = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert keys == ["test_alpha", "test_beta"]

      # The component sends {:external_redirect, url} to the parent LiveView,
      # which redirects to the composed docs URL — assert the navigation fires.
      assert_redirect(view, "https://tymeslot.app/docs/beta")
    end

    test "Got it on the last item finishes without navigating, even when it has a CTA", %{
      conn: conn
    } do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Advance to the last item (test_beta), which carries a CTA.
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      rendered = render(view)
      # The last slide offers both the CTA and a plain finish button.
      assert rendered =~ "Try Beta"
      assert rendered =~ "Got it"

      # "Got it" (the finish action) closes and marks all seen, with no redirect.
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      keys = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert keys == ["test_alpha", "test_beta"]
      refute render(view) =~ "announcement-modal-modal"
    end

    test "closing on item 1 marks every announcement seen", %{conn: conn} do
      user = pre_existing_user()

      conn = log_in(conn, user)
      {:ok, view, _html} = live(conn, ~p"/dashboard")

      view |> element(~s|.modal-header button[aria-label="Close modal"]|) |> render_click()

      # Dismissing the stack marks all announcements seen, not just the current one.
      keys = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert keys == ["test_alpha", "test_beta"]

      {:ok, _view, html} = live(conn, ~p"/dashboard")
      refute html =~ "announcement-modal-modal"
    end
  end

  describe "/dashboard for a user who signed up after every announcement" do
    test "does not render the modal", %{conn: conn} do
      user = pre_existing_user(inserted_at: ~N[2026-04-01 00:00:00])

      conn = log_in(conn, user)
      {:ok, _view, html} = live(conn, ~p"/dashboard")

      refute html =~ "announcement-modal-modal"
    end
  end

  describe "completing every announcement — end-to-end journey" do
    test "modal never appears again after all items are acknowledged", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      # Mount — modal renders with the first announcement.
      {:ok, view, html} = live(conn, ~p"/dashboard")
      assert html =~ "Alpha"
      assert html =~ "1 / 2"

      # Advance past the first item.
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      # Acknowledge the last item via its CTA button (test_beta has a CTA).
      view |> element(~s|button[phx-click="cta"]|) |> render_click()

      # Both announcements are now marked seen.
      seen = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert seen == ["test_alpha", "test_beta"]

      # The LiveView navigates away; consume the redirect so the process is clean.
      assert_redirect(view, "https://tymeslot.app/docs/beta")

      # Re-mount the dashboard — the modal must not appear.
      {:ok, _view2, html2} = live(conn, ~p"/dashboard")
      refute html2 =~ "announcement-modal-modal"
    end
  end

  describe "back navigation" do
    test "Back from item 2 returns to item 1", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Advance to item 2.
      view |> element(~s|button[phx-click="next"]|) |> render_click()
      rendered = render(view)
      assert rendered =~ "Beta"
      assert rendered =~ "2 / 2"

      # Go back to item 1.
      view |> element(~s|button[phx-click="back"]|) |> render_click()
      rendered = render(view)
      assert rendered =~ "Alpha"
      assert rendered =~ "1 / 2"
    end

    test "Back button is disabled at item 1 — advances then returns do not crash", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # The button's own class carries `disabled:opacity-40`, so match the
      # attribute on the button itself rather than the substring anywhere.
      assert has_element?(view, ~s|button[phx-click="back"][disabled]|)

      # On item 2 it is enabled again.
      view |> element(~s|button[phx-click="next"]|) |> render_click()
      refute has_element?(view, ~s|button[phx-click="back"][disabled]|)

      # Retreating clamps back to 0, where it is disabled once more.
      view |> element(~s|button[phx-click="back"]|) |> render_click()

      rendered = render(view)

      assert rendered =~ "Alpha"
      assert rendered =~ "1 / 2"
      assert has_element?(view, ~s|button[phx-click="back"][disabled]|)
      assert Process.alive?(view.pid)
    end
  end

  describe "non-last item with a CTA — secondary CTA button alongside Next" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsMidCtaTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)
      :ok
    end

    test "renders secondary CTA button and Next button on the middle item", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Advance from item 1 (test_alpha, no CTA) to item 2 (test_gamma, has CTA, non-last).
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      rendered = render(view)
      assert rendered =~ "Gamma"
      assert rendered =~ "2 / 3"
      # Secondary CTA button and Next button must both be present.
      assert rendered =~ "Try Gamma"
      assert rendered =~ "Next"
    end

    test "clicking the CTA on a non-last item marks every announcement seen and navigates", %{
      conn: conn
    } do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # Advance to item 2 (test_gamma).
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      # Click the secondary CTA button on test_gamma (a non-last carousel item).
      view |> element(~s|button[phx-click="cta"]|) |> render_click()

      # Taking a CTA dismisses the whole stack — every item is marked seen,
      # including test_beta, which was never displayed.
      seen = Enum.sort(AnnouncementQueries.seen_keys_for(user.id))
      assert seen == ["test_alpha", "test_beta", "test_gamma"]

      # The component sends {:external_redirect, url} to the parent LiveView,
      # which redirects to the composed docs URL for the slug.
      assert_redirect(view, "https://tymeslot.app/docs/gamma")
    end
  end

  describe "single announcement" do
    setup do
      previous = Application.get_env(:tymeslot, :announcement_catalogs, [])
      Application.put_env(:tymeslot, :announcement_catalogs, [AnnouncementsSingleTestCatalog])
      on_exit(fn -> Application.put_env(:tymeslot, :announcement_catalogs, previous) end)
      :ok
    end

    test "primary button reads 'Got it' and no step indicator is shown", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, _view, html} = live(conn, ~p"/dashboard")

      assert html =~ "Solo"
      assert html =~ "Got it"
      refute html =~ "data-test=\"step-indicator\""
    end

    test "clicking 'Got it' marks the announcement seen and closes the modal", %{conn: conn} do
      user = pre_existing_user()
      conn = log_in(conn, user)

      {:ok, view, _html} = live(conn, ~p"/dashboard")

      # The single item has no CTA, so the last-item button is "Got it" (phx-click="next").
      view |> element(~s|button[phx-click="next"]|) |> render_click()

      assert AnnouncementQueries.seen_keys_for(user.id) == ["test_solo"]

      rendered = render(view)
      refute rendered =~ "announcement-modal-modal"
    end
  end
end
