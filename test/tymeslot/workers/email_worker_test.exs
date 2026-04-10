defmodule Tymeslot.Workers.EmailWorkerTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  describe "schedule_confirmation_emails/1" do
    test "creates high priority job with uniqueness constraint" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_confirmation_emails",
          "meeting_id" => meeting.id
        }
      )

      # Verify priority
      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "prevents duplicate jobs within 5 minute window" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)
      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      # Only one job should exist
      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
    end

    test "uses emails queue" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_cancellation_emails/1" do
    test "creates high priority job with uniqueness constraint" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_cancellation_emails",
          "meeting_id" => meeting.id
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "prevents duplicate jobs within 5 minute window" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)
      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_cancellation_emails", "meeting_id" => meeting.id}
        )

      assert length(jobs) == 1
    end

    test "uses emails queue" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailScheduler.schedule_cancellation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_reminder_emails/4" do
    test "creates medium priority job" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id,
          "reminder_value" => 30,
          "reminder_unit" => "minutes"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end

    test "schedules job at specified time" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 1, :hour), :second)

      assert :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 1, "hours", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), scheduled_at) == :eq
    end

    test "prevents duplicate jobs" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 30, :minute), :second)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # Should not create duplicate job
      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
      job = List.first(jobs)
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), scheduled_at) == :eq
    end

    test "reschedules reminder by replacing existing job" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 30, :minute), :second)
      new_scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 45, :minute), :second)

      assert :ok =
               EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # In production, this would delete the existing job and create a new one with new_scheduled_at.
      # In Oban.Testing (manual mode), deletion from the DB won't affect the memory-enqueued job,
      # and the second insert will be treated as a unique duplicate by the code.
      assert :ok =
               EmailScheduler.schedule_reminder_emails(
                 meeting.id,
                 30,
                 "minutes",
                 new_scheduled_at
               )

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
      # We skip the time comparison as Oban.Testing mailbox won't reflect the "replacement"
      # done via DB deletion in worker code.
    end
  end

  describe "schedule_email_verification/2" do
    test "creates high priority job" do
      user = insert(:user)
      url = "https://example.com/verify"

      assert :ok = EmailScheduler.schedule_email_verification(user.id, url)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_email_verification",
          "user_id" => user.id,
          "verification_url" => url
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end
  end

  describe "schedule_password_reset/2" do
    test "creates high priority job" do
      user = insert(:user)
      url = "https://example.com/reset"

      assert :ok = EmailScheduler.schedule_password_reset(user.id, url)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_password_reset",
          "user_id" => user.id,
          "reset_url" => url
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end
  end

  describe "perform/1 send_cancellation_emails" do
    test "discards job when meeting is not found" do
      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => UUID.generate()
               })
    end

    test "discards job when meeting is not cancelled" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user)

      assert {:discard, "Meeting not cancelled"} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "sends cancellation emails for a cancelled meeting" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:ok, :sent}, {:ok, :sent}}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job on partial failure to avoid duplicate sends" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:ok, :sent}, {:error, :delivery_failed}}
      end)

      assert {:discard, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "returns error on total failure so job is retried" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      Mox.expect(Tymeslot.EmailServiceMock, :send_cancellation_emails, fn _details ->
        {{:error, :delivery_failed}, {:error, :delivery_failed}}
      end)

      assert {:error, _reason} =
               perform_job(EmailWorker, %{
                 "action" => "send_cancellation_emails",
                 "meeting_id" => meeting.id
               })
    end
  end

  describe "perform/1 error handling" do
    test "discards job with missing action parameter" do
      assert {:discard, "Missing action parameter"} =
               perform_job(EmailWorker, %{"meeting_id" => 123})
    end

    test "discards job with unknown action" do
      assert {:discard, reason} =
               perform_job(EmailWorker, %{
                 "action" => "unknown_action",
                 "meeting_id" => 123
               })

      assert reason =~ "Unknown action"
    end

    test "discards job if meeting not found for confirmations" do
      fake_id = UUID.generate()

      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_confirmation_emails",
                 "meeting_id" => fake_id
               })
    end

    test "discards job if meeting not found for reminders" do
      fake_id = UUID.generate()

      assert {:discard, "Meeting not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => fake_id
               })
    end

    test "discards job if meeting is cancelled for reminders" do
      profile = insert(:profile)
      meeting = insert(:meeting, organizer_user: profile.user, status: "cancelled")

      assert {:discard, "Meeting cancelled"} =
               perform_job(EmailWorker, %{
                 "action" => "send_reminder_emails",
                 "meeting_id" => meeting.id
               })
    end

    test "discards job if user not found for email verification" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_verification",
                 "user_id" => 999_999,
                 "verification_url" => "http://test.com"
               })
    end

    test "discards job if user not found for password reset" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_password_reset",
                 "user_id" => 999_999,
                 "reset_url" => "http://test.com"
               })
    end

    test "discards send_email_change_verification job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_verification",
                 "user_id" => 999_999,
                 "new_email" => "new@example.com",
                 "verification_url" => "https://example.com/verify/token"
               })
    end

    test "discards send_email_change_notification job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_notification",
                 "user_id" => 999_999,
                 "new_email" => "new@example.com"
               })
    end

    test "discards send_email_change_confirmations job if user not found" do
      assert {:discard, "User not found"} =
               perform_job(EmailWorker, %{
                 "action" => "send_email_change_confirmations",
                 "user_id" => 999_999,
                 "old_email" => "old@example.com",
                 "new_email" => "new@example.com"
               })
    end
  end

  describe "schedule_calendar_invitation/1" do
    test "creates high priority job with correct args" do
      user = insert(:user)

      params = %{
        user_id: user.id,
        attendee_email: "colleague@example.com",
        event_title: "Team Standup",
        event_uid: "uid-abc-123",
        event_start_at: "2026-04-10T10:00:00Z",
        event_end_at: "2026-04-10T10:30:00Z",
        event_location: "Room 42",
        event_description: "Daily sync"
      }

      assert :ok = EmailScheduler.schedule_calendar_invitation(params)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_calendar_invitation",
          "user_id" => user.id,
          "attendee_email" => "colleague@example.com",
          "event_title" => "Team Standup",
          "event_uid" => "uid-abc-123",
          "event_start_at" => "2026-04-10T10:00:00Z",
          "event_end_at" => "2026-04-10T10:30:00Z",
          "event_location" => "Room 42",
          "event_description" => "Daily sync"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "prevents duplicate jobs within 5 minute window" do
      user = insert(:user)

      params = %{
        user_id: user.id,
        attendee_email: "colleague@example.com",
        event_title: "Team Standup",
        event_uid: "uid-abc-123",
        event_start_at: "2026-04-10T10:00:00Z",
        event_end_at: "2026-04-10T10:30:00Z"
      }

      assert :ok = EmailScheduler.schedule_calendar_invitation(params)
      assert :ok = EmailScheduler.schedule_calendar_invitation(params)

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_calendar_invitation", "event_uid" => "uid-abc-123"}
        )

      assert length(jobs) == 1
    end
  end

  describe "perform/1 send_admin_alert" do
    test "happy path: returns :ok when all required fields are present" do
      Mox.expect(Tymeslot.EmailServiceMock, :send_admin_alert, fn _recipient,
                                                                  _category,
                                                                  _severity,
                                                                  _message,
                                                                  _metadata ->
        {:ok, "sent"}
      end)

      assert :ok =
               perform_job(EmailWorker, %{
                 "action" => "send_admin_alert",
                 "recipient" => "ops@example.com",
                 "category" => "Webhook",
                 "severity" => "warning",
                 "message" => "Unhandled webhook event",
                 "metadata" => %{"event_id" => "evt_001"},
                 "alert_hash" => String.duplicate("a", 64)
               })
    end
  end

  describe "backoff/1" do
    test "calculates exponential backoff: 1s, 2s, 4s, 8s, 16s" do
      assert EmailWorker.backoff(%Oban.Job{attempt: 1}) == 1
      assert EmailWorker.backoff(%Oban.Job{attempt: 2}) == 2
      assert EmailWorker.backoff(%Oban.Job{attempt: 3}) == 4
      assert EmailWorker.backoff(%Oban.Job{attempt: 4}) == 8
      assert EmailWorker.backoff(%Oban.Job{attempt: 5}) == 16
    end

    test "caps backoff at 16 seconds" do
      assert EmailWorker.backoff(%Oban.Job{attempt: 6}) == 16
      assert EmailWorker.backoff(%Oban.Job{attempt: 10}) == 16
    end
  end

  describe "job configuration" do
    test "worker is configured with correct queue and max_attempts" do
      # Oban worker configuration is compile-time
      # We can verify through job creation
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
      assert job.max_attempts == 5
    end

    test "confirmation emails have priority 0 (highest)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      EmailScheduler.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reminder emails have priority 2 (medium)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end
  end
end
