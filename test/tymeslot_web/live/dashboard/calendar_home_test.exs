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

  alias Plug.Test

  setup %{conn: conn} do
    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    _profile = insert(:profile, user: user, timezone: "Etc/UTC")
    conn = conn |> Test.init_test_session(%{}) |> fetch_session()
    conn = log_in_user(conn, user)
    {:ok, conn: conn, user: user}
  end

  describe "calendar as the landing mode" do
    test "/dashboard renders the calendar grid with the calendar tab active", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ "calendar-grid"
      assert html =~ ~s(data-testid="mode-tab-calendar")

      # The calendar tab is the active mode tab.
      assert [{"a", attrs, _children}] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s{[data-testid="mode-tab-calendar"]})

      assert {"class", class} = List.keyfind(attrs, "class", 0)
      assert class =~ "mode-tab--active"
    end

    test "the scheduling mode tab links to the overview", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert [{"a", attrs, _children}] =
               html
               |> Floki.parse_document!()
               |> Floki.find(~s{[data-testid="mode-tab-scheduling"]})

      assert {"href", "/dashboard/overview"} = List.keyfind(attrs, "href", 0)
    end

    test "/dashboard/overview still renders the overview", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/overview")

      assert html =~ "Overview"
      assert html =~ "Your day"
    end
  end

  describe "slim navigation rail" do
    test "renders in calendar mode with links to the scheduling sections", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard")

      assert html =~ ~s(data-testid="calendar-rail")
      assert html =~ ~s(data-tour="calendar-rail")

      rail =
        html
        |> Floki.parse_document!()
        |> Floki.find(~s{[data-testid="calendar-rail"] a})

      hrefs = Enum.map(rail, fn {"a", attrs, _c} -> :proplists.get_value("href", attrs) end)

      assert "/dashboard/overview" in hrefs
      assert "/dashboard/meetings" in hrefs
      assert "/dashboard/availability" in hrefs
      assert "/dashboard/integrations" in hrefs
    end

    test "does not render in scheduling mode", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/dashboard/overview")

      refute html =~ ~s(data-testid="calendar-rail")
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
end
