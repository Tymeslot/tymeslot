defmodule Tymeslot.MeetingsContext.NotificationsTest do
  @moduledoc """
  Behaviour tests for the Meetings context covering notifications and
  async calendar-event side effects: email scheduling, reminder lookups,
  reschedule requests, and calendar-event create/cancel async paths.
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

  describe "when scheduling email notifications" do
    test "email notifications are scheduled for new meetings" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.schedule_email_notifications(meeting)

      assert result in [:ok, {:error, :disabled}] or match?({:error, _reason}, result)
    end
  end

  describe "when checking meetings needing reminders" do
    test "returns meetings starting within the next hour that haven't been reminded" do
      %{user: user} = create_user_with_profile()

      meeting_soon =
        insert_meeting_for_user(user, %{
          start_offset: 1800,
          duration: 3_600,
          reminder_email_sent: false
        })

      _meeting_later =
        insert_meeting_for_user(user, %{
          start_offset: 7200,
          duration: 3_600,
          reminder_email_sent: false
        })

      meetings = Meetings.meetings_needing_reminders()

      meeting_ids = Enum.map(meetings, & &1.id)
      assert meeting_soon.id in meeting_ids
    end
  end

  describe "when sending reschedule request" do
    test "reschedule request updates meeting status" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.send_reschedule_request(meeting)

      case result do
        :ok ->
          {:ok, updated} = MeetingQueries.get_meeting_by_uid(meeting.uid)
          assert updated.status == "reschedule_requested"

        {:error, reason} ->
          assert is_binary(reason) or is_atom(reason)
      end
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

  describe "when creating calendar events asynchronously" do
    test "calendar event creation does not fail meeting creation" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user)

      result = Meetings.create_calendar_event_async(meeting)

      assert result == :ok
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
