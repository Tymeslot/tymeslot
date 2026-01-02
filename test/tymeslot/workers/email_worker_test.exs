defmodule Tymeslot.Workers.EmailWorkerTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_confirmation_emails/1" do
    test "creates high priority job with uniqueness constraint" do
      meeting = insert(:meeting)

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
      meeting = insert(:meeting)

      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)
      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)

      # Only one job should exist
      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
    end

    test "uses emails queue" do
      meeting = insert(:meeting)

      assert :ok = EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end
  end

  describe "schedule_reminder_emails/2" do
    test "creates medium priority job" do
      meeting = insert(:meeting)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, scheduled_at)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_reminder_emails",
          "meeting_id" => meeting.id
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end

    test "schedules job at specified time" do
      meeting = insert(:meeting)
      scheduled_at = DateTime.add(DateTime.utc_now(), 1, :hour)

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert DateTime.compare(job.scheduled_at, scheduled_at) == :eq
    end

    test "prevents duplicate jobs within 1 hour window" do
      meeting = insert(:meeting)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, scheduled_at)
      assert :ok = EmailWorker.schedule_reminder_emails(meeting.id, scheduled_at)

      jobs = all_enqueued(worker: EmailWorker)
      assert length(jobs) == 1
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
      meeting = insert(:meeting, organizer_user_id: profile.user_id, status: "cancelled")

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
      meeting = insert(:meeting)

      EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
      assert job.max_attempts == 5
    end

    test "confirmation emails have priority 0 (highest)" do
      meeting = insert(:meeting)

      EmailWorker.schedule_confirmation_emails(meeting.id)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 0
    end

    test "reminder emails have priority 2 (medium)" do
      meeting = insert(:meeting)
      scheduled_at = DateTime.add(DateTime.utc_now(), 30, :minute)

      EmailWorker.schedule_reminder_emails(meeting.id, scheduled_at)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end
  end
end
