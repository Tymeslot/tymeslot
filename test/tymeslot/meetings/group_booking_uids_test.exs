defmodule Tymeslot.Meetings.GroupBookingUidsTest do
  @moduledoc """
  Coverage for the two lookups behind the calendar grid's seat lock: the set
  the grid paints from, for the range it has loaded, and the single-uid guard
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
    from = DateTime.utc_now() |> DateTime.add(-1, :day) |> DateTime.truncate(:second)
    to = DateTime.add(from, 7, :day)
    %{user: user, from: from, to: to}
  end

  defp meeting_for(user, attrs \\ []) do
    insert(:meeting, [organizer_user: user, organizer_user_id: user.id] ++ attrs)
  end

  defp locked?(user, meeting, from, to) do
    in_set =
      MapSet.member?(
        Meetings.group_booking_uids_for_user(user.id, from, to),
        meeting.calendar_uid
      )

    guarded = Meetings.group_booking_uid?(user.id, meeting.calendar_uid)

    # The set and the guard must never disagree for a meeting in range.
    assert in_set == guarded
    in_set
  end

  test "a group meeting with a live seat is locked", %{user: user, from: from, to: to} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting)

    assert locked?(user, meeting, from, to)
  end

  test "a solo booking is not", %{user: user, from: from, to: to} do
    meeting = meeting_for(user)

    refute locked?(user, meeting, from, to)
  end

  test "a group meeting whose seats were all cancelled is not", %{
    user: user,
    from: from,
    to: to
  } do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting, cancelled_at: DateTime.utc_now(:second))

    refute locked?(user, meeting, from, to)
  end

  test "a group meeting with no participants is not", %{user: user, from: from, to: to} do
    meeting = meeting_for(user, capacity: 2)

    refute locked?(user, meeting, from, to)
  end

  test "a cancelled group meeting is not, whatever its participant rows say", %{
    user: user,
    from: from,
    to: to
  } do
    meeting = meeting_for(user, capacity: 2, status: "cancelled")
    insert(:participant, meeting: meeting)

    refute locked?(user, meeting, from, to)
  end

  test "another organiser's group meeting is neither in the set nor guarded", %{
    user: user,
    from: from,
    to: to
  } do
    other = insert(:user)
    meeting = meeting_for(other, capacity: 2)
    insert(:participant, meeting: meeting)

    refute locked?(user, meeting, from, to)

    # It is locked for its own organiser.
    assert locked?(other, meeting, from, to)
  end

  test "the set holds only meetings overlapping the range, the guard ignores it", %{user: user} do
    meeting = meeting_for(user, capacity: 2)
    insert(:participant, meeting: meeting)

    # Ends exactly when the meeting starts, and starts exactly when it ends:
    # neither overlaps.
    before_from = DateTime.add(meeting.start_time, -1, :day)
    after_to = DateTime.add(meeting.end_time, 1, :day)

    refute MapSet.member?(
             Meetings.group_booking_uids_for_user(user.id, before_from, meeting.start_time),
             meeting.calendar_uid
           )

    refute MapSet.member?(
             Meetings.group_booking_uids_for_user(user.id, meeting.end_time, after_to),
             meeting.calendar_uid
           )

    # A window covering only part of the meeting still holds it.
    assert MapSet.member?(
             Meetings.group_booking_uids_for_user(
               user.id,
               DateTime.add(meeting.start_time, 30, :minute),
               after_to
             ),
             meeting.calendar_uid
           )

    assert Meetings.group_booking_uid?(user.id, meeting.calendar_uid)
  end

  test "several seats on one meeting yield one entry", %{user: user, from: from, to: to} do
    meeting = meeting_for(user, capacity: 3)
    insert(:participant, meeting: meeting)
    insert(:participant, meeting: meeting)

    assert Meetings.group_booking_uids_for_user(user.id, from, to) ==
             MapSet.new([meeting.calendar_uid])
  end

  test "an event with no uid is never locked", %{user: user} do
    refute Meetings.group_booking_uid?(user.id, nil)
  end
end
