defmodule Tymeslot.Meetings.GroupBookingUidsTest do
  @moduledoc """
  Coverage for the two lookups behind the calendar grid's seat lock: the set
  the grid paints from, for the events it has loaded, and the single-uid guard
  its handlers enforce. Both answer the same question for the acting
  organiser, so they are asserted against the same cases: a group meeting
  (`capacity > 1`) whose slot is live and on which at least one seat has not
  been cancelled.
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

  defp locked?(user, meeting) do
    guarded = Meetings.group_booking_uid?(user.id, meeting.calendar_uid)

    among =
      MapSet.member?(
        Meetings.group_booking_uids_among(user.id, [meeting.calendar_uid, "unrelated-uid"]),
        meeting.calendar_uid
      )

    # The window's lookup and the guard must never disagree.
    assert among == guarded
    among
  end

  test "a group meeting with a live seat is locked", %{user: user} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting)

    assert locked?(user, meeting)
  end

  test "a solo booking is not", %{user: user} do
    meeting = meeting_for(user)

    refute locked?(user, meeting)
  end

  test "a group meeting whose seats were all cancelled is not", %{user: user} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting, cancelled_at: DateTime.utc_now(:second))

    refute locked?(user, meeting)
  end

  test "a group meeting with no participants is not", %{user: user} do
    meeting = meeting_for(user, capacity: 2)

    refute locked?(user, meeting)
  end

  test "a cancelled group meeting is not, whatever its participant rows say", %{user: user} do
    meeting = meeting_for(user, capacity: 2, status: :cancelled)
    insert(:participant, meeting: meeting)

    refute locked?(user, meeting)
  end

  test "another organiser's group meeting is neither in the set nor guarded", %{user: user} do
    other = insert(:user)
    meeting = meeting_for(other, capacity: 2)
    insert(:participant, meeting: meeting)

    refute locked?(user, meeting)

    # It is locked for its own organiser.
    assert locked?(other, meeting)
  end

  test "several seats on one meeting yield one entry", %{user: user} do
    meeting = meeting_for(user, capacity: 3)
    insert(:participant, meeting: meeting)
    insert(:participant, meeting: meeting)

    assert Meetings.group_booking_uids_among(user.id, [meeting.calendar_uid]) ==
             MapSet.new([meeting.calendar_uid])
  end

  test "an event with no uid is never locked", %{user: user} do
    refute Meetings.group_booking_uid?(user.id, nil)
  end

  test "the uid lookup ignores the range and asks nothing of no uids", %{user: user} do
    start = DateTime.add(DateTime.utc_now(:second), 60, :day)

    meeting =
      meeting_for(user, capacity: 2, start_time: start, end_time: DateTime.add(start, 1, :hour))

    insert(:participant, meeting: meeting)

    assert Meetings.group_booking_uids_among(user.id, [meeting.calendar_uid]) ==
             MapSet.new([meeting.calendar_uid])

    assert Meetings.group_booking_uids_among(user.id, []) == MapSet.new()
  end
end
