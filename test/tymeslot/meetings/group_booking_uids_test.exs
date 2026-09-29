defmodule Tymeslot.Meetings.GroupBookingUidsTest do
  @moduledoc """
  Coverage for the two lookups behind the calendar grid's seat lock: the set
  the grid paints from, and the single-uid guard the drag handler enforces.
  Both answer the same question, so they are asserted against the same
  cases: `Tymeslot.Meetings.group?/1` (`capacity > 1`), never live seat
  counts — a group slot with nobody currently on it is still a group slot.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  import Tymeslot.Factory

  alias Tymeslot.Meetings

  setup do
    user = insert(:user)
    %{user: user}
  end

  defp meeting_for(user, attrs \\ []) do
    insert(:meeting, [organizer_user: user, organizer_user_id: user.id] ++ attrs)
  end

  test "a group booking is locked", %{user: user} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting)

    assert MapSet.member?(Meetings.group_booking_uids_for_user(user.id), meeting.calendar_uid)
    assert Meetings.group_booking_uid?(meeting.calendar_uid)
  end

  test "a solo booking is not", %{user: user} do
    meeting = meeting_for(user)

    refute MapSet.member?(Meetings.group_booking_uids_for_user(user.id), meeting.calendar_uid)
    refute Meetings.group_booking_uid?(meeting.calendar_uid)
  end

  # The row stays a group slot even while nobody currently holds a seat on
  # it: capacity is decided once, at booking time, not re-derived from who
  # happens to be on the meeting right now.
  test "a group slot whose seats were all cancelled is still locked", %{user: user} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting, cancelled_at: DateTime.utc_now(:second))

    assert MapSet.member?(Meetings.group_booking_uids_for_user(user.id), meeting.calendar_uid)
    assert Meetings.group_booking_uid?(meeting.calendar_uid)
  end

  test "a group slot with no participants yet is still locked", %{user: user} do
    meeting = meeting_for(user, capacity: 2)

    assert MapSet.member?(Meetings.group_booking_uids_for_user(user.id), meeting.calendar_uid)
    assert Meetings.group_booking_uid?(meeting.calendar_uid)
  end

  test "another organiser's group booking is not in this user's set", %{user: user} do
    other = insert(:user)
    meeting = meeting_for(other, capacity: 2)

    refute MapSet.member?(Meetings.group_booking_uids_for_user(user.id), meeting.calendar_uid)

    # The guard is per event, not per user: ownership is already established
    # by the time it runs.
    assert Meetings.group_booking_uid?(meeting.calendar_uid)
  end

  test "several seats on one meeting yield one entry", %{user: user} do
    meeting = meeting_for(user, capacity: 3)
    insert(:participant, meeting: meeting)
    insert(:participant, meeting: meeting)

    uids = Meetings.group_booking_uids_for_user(user.id)

    assert MapSet.size(uids) == 1
  end

  test "an event with no uid is never locked" do
    refute Meetings.group_booking_uid?(nil)
  end
end
