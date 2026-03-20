defmodule TymeslotWeb.Dashboard.AvailabilityLiveTest do
  use TymeslotWeb.LiveCase, async: false

  @moduletag :availability
  @moduletag :live

  import Tymeslot.DashboardTestHelpers

  alias Tymeslot.Availability.{Breaks, WeeklySchedule}
  alias Tymeslot.DatabaseQueries.WeeklyAvailabilityQueries
  alias Tymeslot.Infrastructure.AvailabilityCache

  setup %{conn: conn} do
    AvailabilityCache.clear_all()
    {:ok, ctx} = setup_dashboard_user(%{conn: conn})

    {:ok, _count} =
      WeeklyAvailabilityQueries.create_default_weekly_schedule(ctx[:profile].id)

    ctx
  end

  # ===========================================================================
  # Page rendering
  # ===========================================================================

  describe "page rendering" do
    test "renders the availability page with weekly schedule", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      assert html =~ "Weekly Schedule"
      assert html =~ "Monday"
      assert html =~ "Sunday"
    end

    test "shows all 7 days", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      for day <- ~w[Monday Tuesday Wednesday Thursday Friday Saturday Sunday] do
        assert html =~ day
      end
    end

    test "shows workdays as available and weekend as off by default", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/dashboard/availability")

      # Workdays show Available toggle
      assert html =~ "Available"
      # Weekend days show Off toggle
      assert html =~ "Off"
    end
  end

  # ===========================================================================
  # Toggling day availability
  # ===========================================================================

  describe "toggling day availability" do
    test "toggles a workday off", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='toggle_day_available'][phx-value-day='1']")
      |> render_click()

      html = render(view)
      assert html =~ "Monday availability updated"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.is_available == false
    end

    test "toggles a workday off and back on", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Toggle Monday off
      view
      |> element("button[phx-click='toggle_day_available'][phx-value-day='1']")
      |> render_click()

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.is_available == false

      # Toggle Monday back on
      view
      |> element("button[phx-click='toggle_day_available'][phx-value-day='1']")
      |> render_click()

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.is_available == true
    end

    test "toggles a weekend day on", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Saturday (day 6) starts unavailable
      view
      |> element("button[phx-click='toggle_day_available'][phx-value-day='6']")
      |> render_click()

      html = render(view)
      assert html =~ "Saturday availability updated"

      day = WeeklySchedule.get_day_availability(profile.id, 6)
      assert day.is_available == true
    end
  end

  # ===========================================================================
  # Updating work hours
  # ===========================================================================

  describe "updating work hours" do
    test "updates start and end time for a workday", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # The form uses phx-change with a hidden "day" input to identify which
      # day to update. Each available day renders its own form; since all 5
      # workday forms share the same phx-change attribute, we first toggle
      # days 2–5 off to leave only Monday's form, then submit the change.
      for day <- 2..5 do
        view
        |> element("button[phx-click='toggle_day_available'][phx-value-day='#{day}']")
        |> render_click()
      end

      view
      |> form("form[phx-change='update_day_hours']", %{
        "day" => "1",
        "start" => "09:00",
        "end" => "17:00"
      })
      |> render_change()

      html = render(view)
      assert html =~ "Monday hours updated"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.start_time == ~T[09:00:00]
      assert day.end_time == ~T[17:00:00]
    end
  end

  # ===========================================================================
  # Managing breaks
  # ===========================================================================

  describe "managing breaks" do
    test "shows add break form when button is clicked", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      html = render(view)
      assert html =~ "From"
      assert html =~ "Until"
    end

    test "hides add break form after cancel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      view
      |> element("button[phx-click='hide_add_break_form']")
      |> render_click()

      html = render(view)
      refute html =~ "phx-submit=\"add_break\""
    end

    test "adds a break and shows it in the list", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      view
      |> form("form[phx-submit='add_break']", %{
        "day" => "1",
        "start" => "12:00",
        "end" => "13:00",
        "label" => "Lunch"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Break added"
      assert html =~ "Lunch"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      breaks = Breaks.get_breaks_for_day(day.id)
      assert length(breaks) == 1
      [break] = breaks
      assert break.label == "Lunch"
      assert break.start_time == ~T[12:00:00]
      assert break.end_time == ~T[13:00:00]
    end

    test "deletes a break via the confirmation modal", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      # Add a break first
      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      view
      |> form("form[phx-submit='add_break']", %{
        "day" => "1",
        "start" => "12:00",
        "end" => "13:00",
        "label" => "Lunch"
      })
      |> render_submit()

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      [break] = Breaks.get_breaks_for_day(day.id)

      # Open delete modal
      view
      |> element("button[phx-click='show_delete_break_modal'][phx-value-break_id='#{break.id}']")
      |> render_click()

      html = render(view)
      assert html =~ "Delete Break"

      # Confirm deletion
      view
      |> element("#delete-break-modal button", "Delete Break")
      |> render_click()

      html = render(view)
      assert html =~ "Break deleted"

      breaks = Breaks.get_breaks_for_day(day.id)
      assert breaks == []
    end

    test "adds a break without a label", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_add_break_form'][phx-value-day='1']")
      |> render_click()

      view
      |> form("form[phx-submit='add_break']", %{
        "day" => "1",
        "start" => "15:00",
        "end" => "15:30",
        "label" => ""
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Break added"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      [break] = Breaks.get_breaks_for_day(day.id)
      # Empty label is normalised to "Break" by the input validation layer
      assert break.label == "Break"
    end
  end

  # ===========================================================================
  # Clearing day settings
  # ===========================================================================

  describe "clearing day settings" do
    test "shows the clear day modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_clear_day_modal'][phx-value-day='1']")
      |> render_click()

      html = render(view)
      assert html =~ "Clear Day Settings"
    end

    test "clears a workday after confirmation", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_clear_day_modal'][phx-value-day='1']")
      |> render_click()

      view
      |> element("#clear-day-modal button", "Clear All Settings")
      |> render_click()

      html = render(view)
      assert html =~ "settings cleared"

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.is_available == false
    end

    test "cancelling the clear modal does not clear the day", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element("button[phx-click='show_clear_day_modal'][phx-value-day='1']")
      |> render_click()

      view
      |> element("#clear-day-modal button", "Cancel")
      |> render_click()

      day = WeeklySchedule.get_day_availability(profile.id, 1)
      assert day.is_available == true
    end
  end

  # ===========================================================================
  # Copying day settings
  # ===========================================================================

  describe "copying day settings" do
    test "copies settings from Monday to all days", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element(
        "button[phx-click='copy_to_days'][phx-value-from_day='1'][phx-value-to_days='1,2,3,4,5,6,7']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "Settings copied to"

      # Saturday should now be available with Monday's default hours
      saturday = WeeklySchedule.get_day_availability(profile.id, 6)
      assert saturday.is_available == true
      assert saturday.start_time == ~T[11:00:00]
      assert saturday.end_time == ~T[19:30:00]
    end

    test "copies settings from Monday to workdays only", %{conn: conn, profile: profile} do
      {:ok, view, _html} = live(conn, ~p"/dashboard/availability")

      view
      |> element(
        "button[phx-click='copy_to_days'][phx-value-from_day='1'][phx-value-to_days='1,2,3,4,5']"
      )
      |> render_click()

      html = render(view)
      assert html =~ "Settings copied to"

      # Tuesday through Friday should have Monday's hours
      tuesday = WeeklySchedule.get_day_availability(profile.id, 2)
      assert tuesday.is_available == true
      assert tuesday.start_time == ~T[11:00:00]
      assert tuesday.end_time == ~T[19:30:00]

      # Weekend should remain unchanged
      saturday = WeeklySchedule.get_day_availability(profile.id, 6)
      assert saturday.is_available == false
    end
  end
end
