defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfacePreviewTest do
  @moduledoc """
  The preview that opens when an event on the new grid is clicked: calendar
  and account, time with how far away it is, place, guests, whether guests
  can book over it, and whether it is still waiting to sync. Read only in
  this release.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn}, do: owner(conn)

  defp open(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})

  test "shows the calendar, time, place, guests and what it means for bookings", %{
    conn: conn,
    integration: integration
  } do
    review =
      event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z], 60,
        location: "Room 4",
        attendees: [%{"email" => "ada@example.com", "display_name" => "Ada Lovelace"}]
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    assert_reply(lv, %{opened: true})
    assert has_element?(lv, "#calendar-preview #calendar-preview-title", "Design review")
    assert has_element?(lv, "#calendar-preview", "Work · Work account")
    assert has_element?(lv, "#calendar-preview", "Wed 14 Oct, 10:00–11:00")
    assert has_element?(lv, "#calendar-preview", "in 1 h")
    assert has_element?(lv, "#calendar-preview", "Room 4")
    assert has_element?(lv, "#calendar-preview", "Ada Lovelace")
    assert has_element?(lv, "#calendar-preview", "Guests can't book this time")
  end

  test "a free event says guests can book over it", %{conn: conn, integration: integration} do
    focus =
      event(integration, "work", "Focus time", ~U[2026-10-15 09:00:00Z], 120,
        transparency: "transparent"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{focus.id}")

    assert has_element?(lv, "#calendar-preview", "Guests can book this time")
  end

  test "a booking leads with the guest's name", %{conn: conn, user: user} do
    meeting =
      insert(:meeting,
        organizer_user: user,
        title: "Intro call",
        attendee_name: "Anna Kowalski",
        start_time: ~U[2026-10-15 10:00:00Z],
        end_time: ~U[2026-10-15 10:30:00Z],
        status: "confirmed"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "booking-#{meeting.id}")

    assert has_element?(lv, "#calendar-preview-title", "Anna Kowalski · Intro call")
    assert has_element?(lv, "#calendar-preview", "Tymeslot booking")
  end

  test "an event waiting to sync says where it is waiting to go", %{
    conn: conn,
    integration: integration
  } do
    dentist =
      event(integration, "family", "Dentist", ~U[2026-10-16 14:00:00Z], 30,
        sync_state: "locally_modified"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{dentist.id}")

    assert has_element?(lv, "#calendar-preview", "Saved here, waiting to reach Work account")
  end

  test "a video link becomes a Join link, and only a web address does", %{
    conn: conn,
    integration: integration
  } do
    call =
      event(integration, "work", "Call", ~U[2026-10-15 13:00:00Z], 30,
        video_link: "https://meet.example.com/abc"
      )

    odd =
      event(integration, "work", "Odd", ~U[2026-10-15 15:00:00Z], 30,
        video_link: "javascript:alert(1)"
      )

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-#{call.id}")
    assert has_element?(lv, "#calendar-preview a[href='https://meet.example.com/abc']", "Join")

    open(lv, "event-#{odd.id}")
    refute has_element?(lv, "#calendar-preview a")
  end

  test "an id the grid did not load opens nothing", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")

    open(lv, "event-999999999")

    assert_reply(lv, %{opened: false})
    refute has_element?(lv, "#calendar-preview")
  end

  test "closing the preview tells the canvas to take focus back", %{
    conn: conn,
    integration: integration
  } do
    review = event(integration, "work", "Design review", ~U[2026-10-14 09:00:00Z])
    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "event-#{review.id}")

    lv |> element("#calendar-preview button[aria-label='Close']") |> render_click()

    refute has_element?(lv, "#calendar-preview")
    assert_push_event(lv, "calendar:preview-closed", %{})
  end
end
