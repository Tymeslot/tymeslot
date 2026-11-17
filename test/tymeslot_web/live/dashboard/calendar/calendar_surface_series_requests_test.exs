defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceSeriesRequestsTest do
  @moduledoc """
  Answering a series request from the calendar's preview: Accept or Decline
  on any one session answers the whole request, and the flash says so with
  the session count, as it does on the Meetings page.

  The clock is frozen at 08:00 UTC on Wednesday 14 October 2026.
  """

  # Answers run in a task off the LiveView, as in
  # `CalendarSurfaceBookingsTest`.
  use TymeslotWeb.LiveCase, async: false

  @moduletag :calendar
  @moduletag :bookings
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Repo

  @async_timeout 1_000

  setup %{conn: conn}, do: owner(conn)

  # One request for three sessions of a series, all held together, within
  # the frozen week so each can be opened from the grid.
  defp series_request(user) do
    series = insert(:booking_series, organizer_user: user, occurrences_count: 3)

    for {day, position} <- Enum.with_index([15, 16, 17], 1) do
      {:ok, start_at, 0} = DateTime.from_iso8601("2026-10-#{day}T10:00:00Z")

      insert(:meeting,
        organizer_user: user,
        series_id: series.id,
        series_position: position,
        title: "Mentoring with Ada Lovelace",
        meeting_type: "Mentoring",
        attendee_name: "Ada Lovelace",
        attendee_email: "ada@example.com",
        start_time: start_at,
        end_time: DateTime.add(start_at, 30, :minute),
        status: "awaiting_approval",
        approval_requested_at: ~U[2026-10-13 10:00:00Z],
        approval_deadline_at: ~U[2026-10-15 08:00:00Z]
      )
    end
  end

  defp open(lv, meeting) do
    lv
    |> element("#calendar-canvas")
    |> render_hook("calendar:open", %{"id" => "booking-#{meeting.id}"})

    assert_reply(lv, %{opened: true})
  end

  defp statuses(meetings), do: Enum.map(meetings, &Repo.get!(MeetingSchema, &1.id).status)

  test "Accept on one session confirms the whole series and says so", %{conn: conn, user: user} do
    sessions = series_request(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, Enum.at(sessions, 1))

    lv |> element("#calendar-preview-accept") |> render_click()
    render_async(lv, @async_timeout)

    assert statuses(sessions) == [:confirmed, :confirmed, :confirmed]

    html = render(lv)
    assert html =~ "All 3 sessions confirmed. The invitee has been told."
    refute html =~ "Booking confirmed."
  end

  test "Decline on one session declines the whole series and says so", %{conn: conn, user: user} do
    sessions = series_request(user)
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, hd(sessions))

    lv |> element("#calendar-preview-decline") |> render_click()
    lv |> form("#decline-request-form", %{"reason" => ""}) |> render_submit()
    render_async(lv, @async_timeout)

    assert statuses(sessions) == [:cancelled, :cancelled, :cancelled]

    html = render(lv)
    assert html =~ "Request declined. All 3 sessions are free again."
    refute html =~ "The slot is free again."
  end
end
