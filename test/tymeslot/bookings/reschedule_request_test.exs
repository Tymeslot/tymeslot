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

    test "the original slot becomes bookable with the same host, via the real conflict-checked booking path" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)

      # The void slot must not keep blocking the host's conflict detection,
      # otherwise nobody, including the original attendee, could ever book that
      # window again.
      Repo.transaction(fn ->
        assert {:ok, :no_conflicts} =
                 MeetingConflictQueries.count_conflicts(
                   meeting.start_time,
                   meeting.end_time,
                   nil,
                   user.id
                 )
      end)

      # A fresh booking with the same host at the exact original start time
      # succeeds. Conflicts are scoped per host, so only the same host can
      # prove this: the database's own uniqueness guarantee on
      # (organizer_user_id, start_time) must also treat the voided row as free.
      attrs =
        params_for(:meeting,
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: meeting.start_time,
          end_time: meeting.end_time
        )

      assert {:ok, new_meeting} = Scheduling.create_meeting_with_conflict_check(attrs)
      assert new_meeting.id != meeting.id
    end

    test "once someone else has taken the voided time, the original attendee cannot move back to it" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)

      {:ok, _taken} =
        :meeting
        |> params_for(
          organizer_user_id: user.id,
          organizer_email: user.email,
          start_time: meeting.start_time,
          end_time: meeting.end_time
        )
        |> Scheduling.create_meeting_with_conflict_check()

      {:ok, voided} = MeetingQueries.get_meeting(meeting.id)

      # The update `Bookings.Reschedule` makes when the attendee picks a time:
      # it clears the request, which puts the slot back in play.
      assert {:error, :time_conflict} =
               Scheduling.update_meeting_with_conflict_check(voided, %{
                 start_time: meeting.start_time,
                 end_time: meeting.end_time,
                 reschedule_requested_at: nil
               })
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

    test "a second request from the same stale copy is refused, without a second email" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      # Two tabs, or a double click: both hold the copy read before either
      # request, so only the guarded write can tell them apart.
      assert :ok = RescheduleRequest.send_reschedule_request(meeting)
      assert {:error, :already_requested} = RescheduleRequest.send_reschedule_request(meeting)

      assert [_only_one] =
               all_enqueued(
                 worker: EmailWorker,
                 args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
               )
    end

    test "a request from a copy read before the meeting was cancelled is refused" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      {:ok, _cancelled} =
        MeetingQueries.transition_to_cancelled(meeting.id,
          cancelled_at: DateTime.utc_now(:second)
        )

      assert {:error, _cancelled_refusal} = RescheduleRequest.send_reschedule_request(meeting)

      {:ok, current} = MeetingQueries.get_meeting(meeting.id)
      assert current.status == "cancelled"
      assert is_nil(current.reschedule_requested_at)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end

    test "a request from a copy read before the booking re-entered approval is refused" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      # The attendee moved the booking into an approval-gated time after the
      # host's page loaded it as confirmed.
      {:ok, _held} = MeetingQueries.update_meeting_status(meeting, %{status: "awaiting_approval"})

      assert {:error, {:not_reschedulable, :awaiting_approval}} =
               RescheduleRequest.send_reschedule_request(meeting)

      {:ok, current} = MeetingQueries.get_meeting(meeting.id)
      assert is_nil(current.reschedule_requested_at)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end

    test "a request from a copy read before the meeting moved to a time already started is refused" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      now = DateTime.utc_now(:second)

      {:ok, _moved} =
        MeetingQueries.update_meeting(meeting, %{
          start_time: DateTime.add(now, -600),
          end_time: DateTime.add(now, 3_000)
        })

      assert {:error, {:not_reschedulable, :started}} =
               RescheduleRequest.send_reschedule_request(meeting)

      {:ok, current} = MeetingQueries.get_meeting(meeting.id)
      assert is_nil(current.reschedule_requested_at)
    end

    test "the email job names the request it announces" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: 86_400, duration: 3_600})

      assert :ok = RescheduleRequest.send_reschedule_request(meeting)
      {:ok, requested} = MeetingQueries.get_meeting(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reschedule_request",
          "meeting_id" => meeting.id,
          "requested_at" => DateTime.to_iso8601(requested.reschedule_requested_at)
        }
      )
    end

    test "leaves everything untouched when policy blocks the request" do
      %{user: user} = create_user_with_profile()
      meeting = insert_meeting_for_user(user, %{start_offset: -7_200, duration: 3_600})

      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert {:error, {:not_reschedulable, :past}} =
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
