defmodule TymeslotWeb.Dashboard.TimeFormatConsistencyTest do
  @moduledoc """
  The organiser picks a 12- or 24-hour clock once, and every dashboard surface
  honours it.

  `profile_settings_time_format_test.exs` already covers the profile control
  itself: that it renders, stores, and reads back. What is covered here is the
  part that spans surfaces, because the setting is only useful if it travels:

    * the availability editor's list view, whose break times and time dropdowns
      predated the preference and rendered a fixed 24-hour clock
    * the calendar's own settings modal, which writes the same column as the
      profile control but left the rest of the dashboard rendering the old clock
      until a full page load, since the sidebar patches rather than remounts
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :integration
  @moduletag :availability
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid

  setup :setup_dashboard_user

  setup %{profile: profile} do
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    monday =
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: 1,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

    insert(:availability_break,
      weekly_availability: monday,
      start_time: ~T[14:00:00],
      end_time: ~T[14:30:00],
      label: "Lunch"
    )

    :ok
  end

  describe "the availability editor" do
    test "shows break times on a 24-hour clock when that is the choice", %{
      conn: conn,
      user: user
    } do
      CalendarGrid.save_preferences(user.id, %{time_format: "24h"})

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "14:00 - 14:30"
    end

    test "shows the same break on a 12-hour clock when that is the choice", %{
      conn: conn,
      user: user
    } do
      CalendarGrid.save_preferences(user.id, %{time_format: "12h"})

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "2:00 PM - 2:30 PM"
      refute html =~ "14:00 - 14:30"
    end

    test "labels the time dropdowns in the chosen clock while still submitting 24h values", %{
      conn: conn,
      user: user
    } do
      CalendarGrid.save_preferences(user.id, %{time_format: "12h"})

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      # The label is what the organiser reads; the value is what the schedule
      # stores. Only the first may follow the preference, or a 12-hour organiser
      # would silently write a different time than a 24-hour one.
      assert html =~ ~r/<option value="14:30"[^>]*>2:30 PM</
    end

    test "keeps the dropdowns on a 24-hour clock for an organiser who chose one", %{
      conn: conn,
      user: user
    } do
      CalendarGrid.save_preferences(user.id, %{time_format: "24h"})

      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ ~r/<option value="14:30"[^>]*>14:30</
    end
  end

  describe "changing the clock in the calendar settings modal" do
    # Without a connected calendar the grid renders its empty state instead of
    # the header, so the settings button the organiser clicks is not there.
    setup %{user: user} do
      insert(:calendar_integration, user: user, is_active: true)
      :ok
    end

    test "carries to the availability editor without a page reload", %{conn: conn, user: user} do
      CalendarGrid.save_preferences(user.id, %{time_format: "12h"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")

      view |> element("button[phx-click='toggle_settings']") |> render_click()
      view |> element("#time-format-toggle-24h") |> render_click()

      # Patching, not re-mounting: the sidebar navigates with patch, so this is
      # the journey an organiser actually takes between the two settings.
      html = render_patch(view, ~p"/dashboard/availability")

      assert html =~ "14:00 - 14:30"
      refute html =~ "2:00 PM - 2:30 PM"
    end

    test "writes the same preference the profile control reads", %{conn: conn, user: user} do
      CalendarGrid.save_preferences(user.id, %{time_format: "12h"})

      {:ok, view, _html} = live(conn, ~p"/dashboard/calendar")

      view |> element("button[phx-click='toggle_settings']") |> render_click()
      view |> element("#time-format-toggle-24h") |> render_click()

      assert CalendarGrid.get_user_time_format(user.id, "en") == "24h"
    end
  end
end
