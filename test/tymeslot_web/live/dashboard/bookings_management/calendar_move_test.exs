defmodule TymeslotWeb.Dashboard.BookingsManagement.CalendarMoveTest do
  @moduledoc """
  The dashboard's offer to move a flagged booking to the time its calendar
  event now has: the card button, the confirmation, and the refusals.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :meetings
  @moduletag :live
  @moduletag :calendar

  import Tymeslot.Factory
  import Tymeslot.AuthTestHelpers
  import Phoenix.LiveViewTest

  alias Ecto.Changeset
  alias Plug.Test
  alias Tymeslot.Bookings.CalendarJobs
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers

  setup %{conn: conn} do
    TestMocks.setup_email_mocks()

    user = insert(:user, onboarding_completed_at: DateTime.utc_now())
    profile = insert(:profile, user: user)
    integration = insert(:calendar_integration, user: user, provider: "outlook")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        status: "confirmed",
        attendee_name: "Ada Attendee",
        calendar_sync_status: "externally_modified",
        calendar_integration_id: integration.id,
        provider_event_id: "evt-1"
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        provider: "outlook",
        provider_event_id: "evt-1",
        start_at: DateTime.add(meeting.start_time, 2, :hour),
        end_at: DateTime.add(meeting.end_time, 2, :hour)
      )

    conn = conn |> Test.init_test_session(%{}) |> fetch_session() |> log_in_user(user)

    %{conn: conn, user: user, profile: profile, meeting: meeting, event: event}
  end

  # The time as the card shows a meeting's time: date and clock range in the
  # host's timezone.
  defp shown(profile, start_at, end_at) do
    stub = %{start_time: start_at, end_time: end_at}
    tz = Helpers.get_meeting_timezone(stub, profile)
    "#{Helpers.format_meeting_date(stub, tz)}, #{Helpers.format_meeting_time(stub, tz, "12h")}"
  end

  defp send_to_component(view, event, params) do
    view |> with_target("#bookings-management") |> render_click(event, params)
  end

  test "a movable flagged booking offers its calendar time", %{
    conn: conn,
    profile: profile,
    event: event
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    html = render(view)

    assert html =~ "Move booking to"
    assert html =~ shown(profile, event.start_at, event.end_at)
    assert html =~ "Dismiss"
    assert has_element?(view, "[phx-click=show_calendar_move_modal]")
  end

  test "a flagged booking without a cached event offers only Dismiss", %{conn: conn, event: event} do
    Repo.delete!(event)

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    assert render(view) =~ "Dismiss"
    refute has_element?(view, "[phx-click=show_calendar_move_modal]")
  end

  test "confirming moves the booking and clears the warning", %{
    conn: conn,
    meeting: meeting,
    event: event
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()
    assert render(view) =~ "Move booking to the new time"

    view |> element("[data-testid=confirm-calendar-move]") |> render_click()

    assert render(view) =~ "Booking moved to"
    {:ok, moved} = MeetingQueries.get_meeting(meeting.id)
    assert moved.start_time == DateTime.truncate(event.start_at, :second)
    assert moved.calendar_sync_status == nil
    refute has_element?(view, "[phx-click=show_calendar_move_modal]")
    refute render(view) =~ "rescheduled in your external calendar"
  end

  test "a confirm refused after the modal opened says why and leaves the booking", %{
    conn: conn,
    meeting: meeting
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()

    {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

    view |> element("[data-testid=confirm-calendar-move]") |> render_click()

    html = render(view)

    assert html =~
             "Tymeslot is still updating your calendar for this booking. Please try again in a moment."

    refute html =~ "Your calendar now has this meeting at"
    refute has_element?(view, "[phx-click=show_calendar_move_modal]")

    {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
    assert unchanged.start_time == meeting.start_time
    assert unchanged.calendar_sync_status == "externally_modified"
  end

  test "a calendar time changed after the modal opened is offered again, not applied", %{
    conn: conn,
    profile: profile,
    meeting: meeting,
    event: event
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()
    assert render(view) =~ shown(profile, event.start_at, event.end_at)

    later_start = DateTime.add(event.start_at, 1, :hour)
    later_end = DateTime.add(event.end_at, 1, :hour)
    event |> Changeset.change(start_at: later_start, end_at: later_end) |> Repo.update!()

    view |> element("[data-testid=confirm-calendar-move]") |> render_click()

    html = render(view)
    assert html =~ "The meeting has moved again in your calendar."
    assert html =~ "Your calendar now has this meeting at"
    assert html =~ shown(profile, later_start, later_end)
    refute html =~ shown(profile, event.start_at, event.end_at)

    {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
    assert unchanged.start_time == meeting.start_time
    assert unchanged.calendar_sync_status == "externally_modified"

    view |> element("[data-testid=confirm-calendar-move]") |> render_click()

    assert render(view) =~ "Booking moved to"
    {:ok, moved} = MeetingQueries.get_meeting(meeting.id)
    assert moved.start_time == DateTime.truncate(later_start, :second)
  end

  test "a move onto another booking's start says that booking is in the way", %{
    conn: conn,
    user: user,
    meeting: meeting,
    event: event
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()

    insert(:meeting,
      organizer_user_id: user.id,
      status: "confirmed",
      start_time: DateTime.truncate(event.start_at, :second),
      end_time: DateTime.truncate(event.end_at, :second)
    )

    view |> element("[data-testid=confirm-calendar-move]") |> render_click()

    assert render(view) =~
             "Tymeslot could not move this booking. Another booking already starts at that time."

    {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
    assert unchanged.start_time == meeting.start_time
  end

  test "a refused open refreshes the list so the stale Move button goes", %{
    conn: conn,
    meeting: meeting
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")
    assert has_element?(view, "[phx-click=show_calendar_move_modal]")

    {:ok, _job} = CalendarJobs.schedule_job(meeting, "update")

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()

    assert render(view) =~ "Tymeslot is still updating your calendar"
    refute has_element?(view, "[phx-click=show_calendar_move_modal]")
  end

  test "the modal shows the time the calendar has when it opens", %{
    conn: conn,
    profile: profile,
    event: event
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    later_start = DateTime.add(event.start_at, 1, :hour)
    later_end = DateTime.add(event.end_at, 1, :hour)
    event |> Changeset.change(start_at: later_start, end_at: later_end) |> Repo.update!()

    view |> element("[phx-click=show_calendar_move_modal]") |> render_click()

    html = render(view)
    assert html =~ "Your calendar now has this meeting at"
    assert html =~ shown(profile, later_start, later_end)
  end

  test "another organiser's meeting cannot be moved", %{conn: conn} do
    other = insert(:user)
    other_integration = insert(:calendar_integration, user: other, provider: "outlook")

    foreign =
      insert(:meeting,
        organizer_user_id: other.id,
        status: "confirmed",
        calendar_sync_status: "externally_modified",
        calendar_integration_id: other_integration.id,
        provider_event_id: "evt-foreign"
      )

    insert(:provider_calendar_event,
      calendar_integration: other_integration,
      provider: "outlook",
      provider_event_id: "evt-foreign",
      start_at: DateTime.add(foreign.start_time, 2, :hour),
      end_at: DateTime.add(foreign.end_time, 2, :hour)
    )

    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    send_to_component(view, "show_calendar_move_modal", %{"id" => foreign.id})
    send_to_component(view, "confirm_calendar_move", %{})

    {:ok, unchanged} = MeetingQueries.get_meeting(foreign.id)
    assert unchanged.start_time == foreign.start_time
    assert unchanged.calendar_sync_status == "externally_modified"
    refute render(view) =~ "Your calendar now has this meeting at"
  end

  test "a malformed id opens nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/meetings")

    send_to_component(view, "show_calendar_move_modal", %{"id" => "not-a-uuid"})
    refute render(view) =~ "Your calendar now has this meeting at"
  end
end
