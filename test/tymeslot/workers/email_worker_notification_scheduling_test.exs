defmodule Tymeslot.Workers.EmailWorkerNotificationSchedulingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_integration_unhealthy_notification/3" do
    test "enqueues job with correct worker, args, and queue" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_unhealthy_notification(
                 user,
                 integration,
                 :google
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "google"
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end

    test "uses medium priority" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_unhealthy_notification(
                 user,
                 integration,
                 :caldav
               )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end

    test "coerces atom type to string in args" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_unhealthy_notification(
                 user,
                 integration,
                 :outlook
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_unhealthy_notification",
          "integration_type" => "outlook"
        }
      )
    end

    test "prevents duplicate jobs within 30-day window" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_unhealthy_notification(
                 user,
                 integration,
                 :google
               )

      assert :ok =
               EmailScheduler.schedule_integration_unhealthy_notification(
                 user,
                 integration,
                 :google
               )

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_integration_unhealthy_notification",
            "integration_id" => integration.id
          }
        )

      assert length(jobs) == 1
    end
  end

  describe "schedule_event_update_notification/1" do
    test "enqueues job with correct args" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)
      before_start = ~U[2026-04-10 09:00:00Z]
      before_end = ~U[2026-04-10 09:30:00Z]

      params = %{
        user_id: user.id,
        event_uid: "uid-update-001",
        integration_id: integration.id,
        attendee_emails: ["alice@example.com", "bob@example.com"],
        before_title: "Old Title",
        before_location: "Old Room",
        before_description: "Old desc",
        before_start_at: before_start,
        before_end_at: before_end
      }

      assert :ok = EmailScheduler.schedule_event_update_notification(params)

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_event_update_notification",
          "user_id" => user.id,
          "event_uid" => "uid-update-001",
          "integration_id" => integration.id,
          "attendee_emails" => ["alice@example.com", "bob@example.com"],
          "before_title" => "Old Title",
          "before_location" => "Old Room",
          "before_description" => "Old desc",
          "before_start_at" => "2026-04-10T09:00:00Z",
          "before_end_at" => "2026-04-10T09:30:00Z"
        }
      )
    end

    test "schedules job approximately 2 minutes in the future" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      params = %{
        user_id: user.id,
        event_uid: "uid-update-002",
        integration_id: integration.id,
        attendee_emails: ["alice@example.com"],
        before_title: "Title",
        before_location: nil,
        before_description: nil,
        before_start_at: nil,
        before_end_at: nil
      }

      assert :ok = EmailScheduler.schedule_event_update_notification(params)

      job = List.first(all_enqueued(worker: EmailWorker))
      delay_seconds = DateTime.diff(job.scheduled_at, DateTime.utc_now())
      # Allow a small margin around the expected 120-second delay
      assert delay_seconds >= 115
      assert delay_seconds <= 125
    end

    test "uses medium-high priority" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      params = %{
        user_id: user.id,
        event_uid: "uid-update-003",
        integration_id: integration.id,
        attendee_emails: [],
        before_title: nil,
        before_location: nil,
        before_description: nil,
        before_start_at: nil,
        before_end_at: nil
      }

      assert :ok = EmailScheduler.schedule_event_update_notification(params)

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 1
    end

    test "coalesces rapid edits via uniqueness on event_uid" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      params = %{
        user_id: user.id,
        event_uid: "uid-update-004",
        integration_id: integration.id,
        attendee_emails: ["alice@example.com"],
        before_title: "Title",
        before_location: nil,
        before_description: nil,
        before_start_at: nil,
        before_end_at: nil
      }

      assert :ok = EmailScheduler.schedule_event_update_notification(params)
      assert :ok = EmailScheduler.schedule_event_update_notification(params)

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{"action" => "send_event_update_notification", "event_uid" => "uid-update-004"}
        )

      assert length(jobs) == 1
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
end
