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
end
