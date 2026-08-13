defmodule TymeslotWeb.Dashboard.CalendarHomeTest do
  @moduledoc """
  Covers the calendar-first dashboard landing: `/dashboard` opens the calendar
  mode, the overview lives at `/dashboard/overview`, and calendar mode carries
  the Up-next strip and the setup checklist.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.AuthTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "calendar as the landing page" do
    test "/dashboard renders the calendar grid with the Calendar item active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "calendar-grid"

      assert [{"a", attrs, _children}] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s{#dashboard-sidebar a[href="/dashboard"]})

      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "dashboard-nav-link--active"
    end

    test "the calendar keeps the standard sidebar rather than a rail", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(id="dashboard-sidebar")
      refute html =~ ~s(data-testid="calendar-rail")
      refute html =~ "mode-tab-bar"
    end

    test "the sidebar reaches every scheduling section from the calendar", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      hrefs =
        html
        |> Floki.parse_document!()
        |> Floki.find("#dashboard-sidebar a")
        |> Enum.flat_map(&Floki.attribute(&1, "href"))

      assert "/dashboard/overview" in hrefs
      assert "/dashboard/meetings" in hrefs
      assert "/dashboard/availability" in hrefs
      assert "/dashboard/integrations" in hrefs
    end

    test "/dashboard/overview still renders the overview", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/overview")

      assert html =~ "Overview"
      assert html =~ "Your day"
    end
  end

  describe "up-next strip" do
    test "shows the next booking above the grid", %{conn: conn, user: user} do
      start_time = DateTime.add(DateTime.utc_now(), 3600, :second)

      insert(:meeting,
        organizer_user: user,
        organizer_email: user.email,
        title: "Strategy sync",
        attendee_name: "Grace Hopper",
        start_time: start_time,
        end_time: DateTime.add(start_time, 1800, :second),
        status: "confirmed"
      )

      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "data-testid=\"up-next-strip\""
      assert html =~ "Strategy sync"
      assert html =~ "Grace Hopper"
    end

    test "renders no strip when nothing is upcoming", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      refute html =~ "data-testid=\"up-next-strip\""
    end
  end

  describe "timezone in the calendar header" do
    setup %{user: user} do
      user.id |> Profiles.get_profile() |> Profiles.update_timezone("Europe/Kyiv")

      :ok
    end

    test "shows the profile zone", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert header_timezone(html) == "Kyiv, Ukraine"
    end
  end

  describe "timezone for a profile that has none" do
    setup %{user: user} do
      user.id
      |> Profiles.get_profile()
      |> Changeset.change(timezone: nil)
      |> Repo.update!()

      :ok
    end

    test "falls back to UTC rather than rendering an empty zone", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert header_timezone(html) == "UTC"
    end
  end

  describe "setup checklist on the calendar" do
    test "shows while setup is incomplete and hides once dismissed", %{conn: conn, user: user} do
      {:ok, lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "data-tour=\"quick-actions\""

      lv
      |> element(~s{[data-tour="quick-actions"] button[phx-click="onboarding:dismiss"]})
      |> render_click()

      refute render(lv) =~ "data-tour=\"quick-actions\""

      # Dismissal persists across a fresh mount.
      {:ok, _lv2, html2} = live(conn, ~p"/dashboard")
      refute html2 =~ "data-tour=\"quick-actions\""
      _user = user
    end
  end

  # The header renders the zone twice, once for the desktop row and once for the
  # mobile one; both read the same assign, so the first is representative.
  defp header_timezone(html) do
    html
    |> Floki.parse_document!()
    |> Floki.find(~s{[data-testid="timezone-display"]})
    |> Enum.take(1)
    |> Floki.text()
    |> String.trim()
  end
end
