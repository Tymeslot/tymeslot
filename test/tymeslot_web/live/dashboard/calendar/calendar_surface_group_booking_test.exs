defmodule TymeslotWeb.Dashboard.Calendar.CalendarSurfaceGroupBookingTest do
  @moduledoc """
  A group booking's preview on the calendar: how many of its seats are
  taken, counting a booker's guests as the meetings list does, beside why
  it cannot be changed from the calendar. A one-to-one booking counts none.
  """

  use TymeslotWeb.LiveCase, async: true

  @moduletag :calendar
  @moduletag :meetings
  @moduletag :live

  import Tymeslot.Factory
  import TymeslotWeb.CalendarSurfaceHelpers

  setup %{conn: conn}, do: owner(conn)

  defp open(lv, id),
    do: lv |> element("#calendar-canvas") |> render_hook("calendar:open", %{"id" => id})

  defp meeting(user, attrs),
    do:
      insert(
        :meeting,
        [
          organizer_user: user,
          organizer_user_id: user.id,
          start_time: ~U[2026-10-16 10:00:00Z],
          end_time: ~U[2026-10-16 11:00:00Z]
        ] ++ attrs
      )

  test "the preview says how many seats are taken, and why it is locked", %{
    conn: conn,
    user: user
  } do
    group = meeting(user, capacity: 3)
    insert(:participant, meeting: group)
    insert(:participant, meeting: group)

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "booking-#{group.id}")

    assert has_element?(lv, "#calendar-preview-seats", "2/3 seats taken")
    assert has_element?(lv, "#calendar-preview-locked")
  end

  test "a one-to-one booking has no seat count", %{conn: conn, user: user} do
    solo = meeting(user, [])

    {:ok, lv, _html} = live(conn, ~p"/dashboard/calendar")
    open(lv, "booking-#{solo.id}")

    assert has_element?(lv, "#calendar-preview")
    refute has_element?(lv, "#calendar-preview-seats")
  end
end
