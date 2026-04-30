defmodule Tymeslot.Emails.EmailSchedulerIntegrationPausedTest do
  use Tymeslot.DataCase, async: true

  @moduletag :workers

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Workers.EmailWorker

  describe "schedule_integration_paused_notification/4" do
    test "enqueues job with correct worker, args, queue, and cutoff_days" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_paused_notification(
                 user,
                 integration,
                 :calendar,
                 14
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_paused_notification",
          "user_id" => user.id,
          "integration_id" => integration.id,
          "integration_type" => "calendar",
          "cutoff_days" => 14
        }
      )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.queue == "emails"
    end

    test "uses medium priority" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_paused_notification(
                 user,
                 integration,
                 :calendar,
                 14
               )

      job = List.first(all_enqueued(worker: EmailWorker))
      assert job.priority == 2
    end

    test "coerces atom type to string in args" do
      user = insert(:user)
      integration = insert(:video_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_paused_notification(
                 user,
                 integration,
                 :video,
                 14
               )

      assert_enqueued(
        worker: EmailWorker,
        args: %{
          "action" => "send_integration_paused_notification",
          "integration_type" => "video"
        }
      )
    end

    test "prevents duplicate jobs within 90-day window" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user)

      assert :ok =
               EmailScheduler.schedule_integration_paused_notification(
                 user,
                 integration,
                 :calendar,
                 14
               )

      assert :ok =
               EmailScheduler.schedule_integration_paused_notification(
                 user,
                 integration,
                 :calendar,
                 14
               )

      jobs =
        all_enqueued(
          worker: EmailWorker,
          args: %{
            "action" => "send_integration_paused_notification",
            "integration_id" => integration.id
          }
        )

      assert length(jobs) == 1
    end
  end
end
