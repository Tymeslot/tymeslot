defmodule Tymeslot.MeetingsContext.NotificationsTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering notifications and
  async calendar-event side effects: reschedule requests and the async
  calendar-event cancellation path.
  """

  use Tymeslot.DataCase, async: true
  @moduletag :utils

  import Mox

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.TestMocks
  import Tymeslot.MeetingTestHelpers

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)

    TestMocks.setup_email_mocks()
    TestMocks.setup_calendar_mocks()

    :ok
  end

  describe "when sending reschedule request" do
    test "reschedule request stamps reschedule_requested_at and leaves the status confirmed" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      assert :ok = Meetings.send_reschedule_request(meeting)

      {:ok, updated} = MeetingQueries.get_meeting_by_uid(meeting.uid)
      # `status` is left untouched — only `reschedule_requested_at` marks
      # the meeting as awaiting a new time (see `Bookings.RescheduleRequest`).
      assert updated.status == "confirmed"
      assert %DateTime{} = updated.reschedule_requested_at
    end

    test "cannot send reschedule request for past meeting" do
      %{user: user} = create_user_with_profile()

      meeting =
        insert_meeting_for_user(user, %{
          status: "completed",
          start_offset: -86_400,
          duration: 3_600
        })

      result = Meetings.send_reschedule_request(meeting)

      assert {:error, _reason} = result
    end
  end

  describe "when cancelling calendar events" do
    test "calendar event cancellation does not fail meeting cancellation" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.cancel_calendar_event(meeting)

      assert result == :ok
    end
  end
end
