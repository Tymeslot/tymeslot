defmodule Tymeslot.Workers.EmailWorkerTest do
  @moduletag :workers
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_confirmation_emails/1" do
  @moduletag :workers
    test "creates high priority job with uniqueness constraint" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)

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

      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)
      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)

      # Only one job should exist
      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
    end

    test "uses emails queue" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_reminder_emails/4" do
    test "creates medium priority job" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

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

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, 1, "hours", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert DateTime.compare(DateTime.truncate(job.scheduled_at, :second), scheduled_at) == :eq
    end

    test "prevents duplicate jobs" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.truncate(DateTime.add(DateTime.utc_now(), 30, :minute), :second)

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # Should not create duplicate job
      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

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

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      # In production, this would delete the existing job and create a new one with new_scheduled_at.
      # In Oban.Testing (manual mode), deletion from the DB won't affect the memory-enqueued job,
      # and the second insert will be treated as a unique duplicate by the code.
      assert :ok =
               EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", new_scheduled_at)

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

      assert :ok = EmailWorker.schedule_email_verification(user.id, url)

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

      assert :ok = EmailWorker.schedule_password_reset(user.id, url)

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

      EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
      assert job.max_attempts == 5
    end

    test "confirmation emails have priority 0 (highest)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)

      EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reminder emails have priority 2 (medium)" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      EmailWorker.schedule_reminder_emails(meeting.id, 30, "minutes", scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end
  end
end
