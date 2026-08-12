defmodule Tymeslot.Bookings.RescheduleGroupMeetingTest do
  @moduledoc """
  Coverage for what the whole-meeting reschedule does when the meeting is a
  group slot.

  A group slot is shared: moving the meeting row would move everybody on it
  without asking, and the notification would go to an attendee a group meeting
  does not have. Participants move their own seat through
  `Tymeslot.Bookings.RescheduleSeat`; a host who wants the whole slot moved
  sends a reschedule request, which reaches every participant.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Mox
  import Tymeslot.Factory
  import Tymeslot.MeetingTestHelpers

  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  test "refuses to move a slot that has participants on it" do
    %{user: user} = create_user_with_profile()
    meeting = insert_meeting_for_user(user, %{capacity: 2})

    insert(:participant, meeting: meeting, name: "Booker", email: "booker@example.com")

    new_params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    assert {:error, :group_meeting_not_reschedulable} =
             Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

    assert {:ok, %{start_time: unchanged}} = MeetingQueries.get_meeting(meeting.id)
    assert unchanged == meeting.start_time
  end

  test "a solo meeting is unaffected by the guard" do
    %{user: user} = create_user_with_profile()
    meeting = insert_meeting_for_user(user)

    new_params = %{
      date: Date.to_string(Date.add(Date.utc_today(), 2)),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    assert {:ok, %{id: rescheduled_id}} =
             Reschedule.execute(meeting.uid, new_params, %{}, meeting.organizer_user_id)

    assert rescheduled_id == meeting.id
  end
end
