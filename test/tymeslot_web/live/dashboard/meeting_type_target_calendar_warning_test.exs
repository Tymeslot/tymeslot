defmodule TymeslotWeb.Dashboard.MeetingTypeTargetCalendarWarningTest do
  @moduledoc """
  The journey a host takes once a provider withdraws write access to the
  calendar a meeting type books into.

  Nothing in the app asks the host to save the meeting type again, so the only
  way they learn the target went read-only is by being told: a badge on the
  meeting type card, and a notice above the picker in the editor. Booking-time
  behaviour is deliberately unchanged, which
  `Tymeslot.Integrations.Calendar.Runtime.BookingIntegrationResolver` covers.
  """

  use TymeslotWeb.LiveCase, async: false

  @moduletag :meeting_types
  @moduletag :calendar
  @moduletag :live

  import Phoenix.LiveViewTest
  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  setup :setup_dashboard_user

  defp meeting_type_with_target(user, calendars, target_calendar_id) do
    integration =
      insert(:calendar_integration, user: user, is_active: true, calendar_list: calendars)

    insert(:meeting_type,
      user: user,
      name: "Discovery call",
      calendar_integration: integration,
      target_calendar_id: target_calendar_id
    )
  end

  defp writable_and_read_only do
    [
      %{"id" => "cal-writable", "name" => "Primary", "selected" => true, "read_only" => false},
      %{"id" => "cal-locked", "name" => "Shared", "selected" => true, "read_only" => true}
    ]
  end

  defp open_editor(view, meeting_type) do
    view
    |> element("button[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    render(view)
  end

  test "the card and the editor both flag a target calendar gone read-only",
       %{conn: conn, user: user} do
    meeting_type = meeting_type_with_target(user, writable_and_read_only(), "cal-locked")

    {:ok, view, html} = live(conn, ~p"/dashboard/meeting-settings")

    assert html =~ "Read-only"

    editor = open_editor(view, meeting_type)

    assert editor =~ "is now read-only"
  end

  test "picking a writable calendar clears the editor warning",
       %{conn: conn, user: user} do
    meeting_type = meeting_type_with_target(user, writable_and_read_only(), "cal-locked")

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    assert open_editor(view, meeting_type) =~ "is now read-only"

    view
    |> element("button[phx-click*='select_target_calendar']", "Primary")
    |> render_click()

    refute render(view) =~ "is now read-only"
  end

  test "defers to the account-level notice when nothing writable is left to choose",
       %{conn: conn, user: user} do
    calendars = [
      %{"id" => "cal-locked", "name" => "Shared", "selected" => true, "read_only" => true}
    ]

    meeting_type = meeting_type_with_target(user, calendars, "cal-locked")

    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    editor = open_editor(view, meeting_type)

    assert editor =~ "None of the calendars you selected for this account can accept bookings."
    refute editor =~ "is now read-only"
  end

  test "a still-writable target raises nothing", %{conn: conn, user: user} do
    meeting_type = meeting_type_with_target(user, writable_and_read_only(), "cal-writable")

    {:ok, view, html} = live(conn, ~p"/dashboard/meeting-settings")

    refute html =~ "Read-only"
    refute open_editor(view, meeting_type) =~ "is now read-only"
  end
end
