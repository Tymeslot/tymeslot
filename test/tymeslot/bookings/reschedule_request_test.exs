defmodule Tymeslot.Bookings.RescheduleRequestTest do
  @moduledoc """
  Tests for the organizer reschedule request workflow.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo
  @moduletag :bookings

  alias Tymeslot.Bookings.RescheduleRequest
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.MeetingConflictQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.Scheduling
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
      # `status` is left untouched — only `reschedule_requested_at` marks the
      # request, so the underlying lifecycle status survives it.
      assert updated.status == "confirmed"
      assert %DateTime{} = updated.reschedule_requested_at

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

    test "the original slot becomes bookable by someone else, via the real conflict-checked booking path" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)

      # The void slot must not keep blocking conflict detection — otherwise
      # nobody, including the original attendee, could ever book that window
      # again.
      refute MeetingConflictQueries.time_conflict_exists?(meeting.start_time, meeting.end_time)

      # A fresh booking landing on the exact original window — the same path
      # a new attendee's booking or the original attendee's rebooking near
      # their original time takes — succeeds instead of being rejected as a
      # conflict.
      other_user = insert(:user)
      insert(:profile, user: other_user)

      attrs =
        params_for(:meeting,
          organizer_user_id: other_user.id,
          organizer_email: other_user.email,
          start_time: meeting.start_time,
          end_time: meeting.end_time
        )

      assert {:ok, new_meeting} = Scheduling.create_meeting_with_conflict_check(attrs)
      assert new_meeting.id != meeting.id
    end

    test "rejects a second request against an already-voided slot, without a duplicate email" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)

      {:ok, once_requested} = MeetingQueries.get_meeting(meeting.id)

      assert {:error, :already_requested} =
               RescheduleRequest.send_reschedule_request(once_requested)

      # Only the first request's email job was queued.
      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )

      all_jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
        )

      assert length(all_jobs) == 1
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
