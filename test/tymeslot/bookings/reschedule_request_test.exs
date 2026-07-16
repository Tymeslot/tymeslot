defmodule Tymeslot.Bookings.RescheduleRequestTest do
  @moduledoc """
  Tests for the organizer reschedule request workflow.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  alias Tymeslot.Bookings.RescheduleRequest
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Workers.CalendarEventWorker
  alias Tymeslot.Workers.EmailWorker
  import Tymeslot.MeetingTestHelpers

  describe "send_reschedule_request/1" do
    test "voids the original slot: status, calendar event, reminders, attendee email" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      # Reminder created at booking time, pinned to the original slot.
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)

      {:ok, updated} = MeetingQueries.get_meeting(meeting.id)
      assert updated.status == "reschedule_requested"

      # The calendar event is removed from the organizer's calendar...
      assert_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )

      # ...reminders for the void time slot are gone...
      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      # ...and the attendee is asked to pick a new time.
      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end

    test "leaves everything untouched when policy blocks the request" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: -7_200, duration: 3_600})

      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert {:error, "Cannot reschedule a meeting that has already occurred"} =
               RescheduleRequest.send_reschedule_request(meeting)

      {:ok, unchanged} = MeetingQueries.get_meeting(meeting.id)
      assert unchanged.status == "confirmed"

      refute_enqueued(
        worker: CalendarEventWorker,
        args: %{"action" => "delete", "meeting_id" => meeting.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end
  end
end
