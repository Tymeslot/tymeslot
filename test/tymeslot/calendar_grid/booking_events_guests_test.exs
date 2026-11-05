defmodule Tymeslot.CalendarGrid.BookingEventsGuestsTest do
  @moduledoc """
  A booking on the calendar carries the guests whose invitation still
  stands, with the answer each gave, so the preview can show them without a
  query of its own.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  import Tymeslot.Factory

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.Guests

  test "a booking carries its guests with their answers" do
    user = insert(:user)
    start_at = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[10:00:00], "Etc/UTC")

    meeting =
      insert(:meeting,
        organizer_user: user,
        start_time: start_at,
        end_time: DateTime.add(start_at, 1800, :second),
        status: "confirmed"
      )

    {:ok, [_grace, alan]} =
      Guests.create_for_meeting(meeting.id, ["grace@example.com", "alan@example.com"], :organizer)

    {:ok, _alan} = Meetings.record_guest_rsvp(alan.rsvp_token, :declined)

    [booking] =
      CalendarGrid.list_booking_events_for_range(
        user.id,
        DateTime.add(start_at, -3600, :second),
        DateTime.add(start_at, 86_400, :second)
      )

    assert booking.guests |> Enum.map(&{&1.email, &1.status}) |> Enum.sort() == [
             {"alan@example.com", :declined},
             {"grace@example.com", :pending}
           ]
  end

  test "another organiser's meeting and its guest do not appear" do
    user = insert(:user)
    other = insert(:user)
    start_at = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[10:00:00], "Etc/UTC")

    theirs =
      insert(:meeting,
        organizer_user: other,
        start_time: start_at,
        end_time: DateTime.add(start_at, 1800, :second),
        status: "confirmed"
      )

    {:ok, [_guest]} = Guests.create_for_meeting(theirs.id, ["grace@example.com"], :organizer)

    assert CalendarGrid.list_booking_events_for_range(
             user.id,
             DateTime.add(start_at, -3600, :second),
             DateTime.add(start_at, 86_400, :second)
           ) == []
  end

  test "a group meeting leaves out the guest of a participant who cancelled" do
    user = insert(:user)
    start_at = DateTime.new!(Date.add(Date.utc_today(), 1), ~T[10:00:00], "Etc/UTC")

    meeting =
      insert(:group_meeting,
        organizer_user: user,
        start_time: start_at,
        end_time: DateTime.add(start_at, 1800, :second),
        status: "confirmed",
        capacity: 4
      )

    staying = insert(:participant, meeting: meeting)
    leaving = insert(:participant, meeting: meeting, cancelled_at: DateTime.utc_now(:second))

    {:ok, [_stays]} = Guests.create_for_participant(meeting.id, staying.id, ["stays@example.com"])

    {:ok, [_leaves]} =
      Guests.create_for_participant(meeting.id, leaving.id, ["leaves@example.com"])

    [booking] =
      CalendarGrid.list_booking_events_for_range(
        user.id,
        DateTime.add(start_at, -3600, :second),
        DateTime.add(start_at, 86_400, :second)
      )

    assert Enum.map(booking.guests, & &1.email) == ["stays@example.com"]
  end
end
