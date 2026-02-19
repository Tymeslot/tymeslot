defmodule Tymeslot.Webhooks.DispatcherTest do
  use Tymeslot.DataCase, async: false

  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Webhooks.Dispatcher
  alias Tymeslot.Workers.WebhookWorker

  setup do
    setup_config(:tymeslot, feature_access_checker: Tymeslot.Features.DefaultAccessChecker)
    :ok
  end

  describe "dispatch/2 - dispatching to subscribed webhooks" do
    test "enqueues a job for a webhook subscribed to meeting.created" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.created"])

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.created"
      assert job.args["meeting_id"] == meeting.id
    end

    test "enqueues a job for a webhook subscribed to meeting.cancelled" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.cancelled"])

      assert :ok = Dispatcher.dispatch(:meeting_cancelled, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.cancelled"
    end

    test "enqueues a job for a webhook subscribed to meeting.rescheduled" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.rescheduled"])

      assert :ok = Dispatcher.dispatch(:meeting_rescheduled, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.rescheduled"
    end

    test "also accepts string event types directly" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.created"])

      assert :ok = Dispatcher.dispatch("meeting.created", meeting)

      assert [_job] = all_enqueued(worker: WebhookWorker)
    end
  end

  describe "dispatch/2 - meeting with no organizer" do
    test "returns an error and enqueues no jobs" do
      _webhook = insert(:webhook)
      meeting = insert(:meeting, organizer_user: nil, organizer_user_id: nil)

      assert {:error, :no_organizer} = Dispatcher.dispatch(:meeting_created, meeting)
      assert all_enqueued(worker: WebhookWorker) == []
    end
  end

  describe "dispatch/2 - fan-out" do
    test "enqueues jobs for all webhooks subscribed to the event" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.created"])
      insert(:webhook, user: user, events: ["meeting.created"])

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert length(all_enqueued(worker: WebhookWorker)) == 2
    end

    test "only enqueues jobs for the organizer's own webhooks, not other users" do
      organizer = insert(:user)
      other_user = insert(:user)
      meeting = insert(:meeting, organizer_user: organizer)
      insert(:webhook, user: organizer, events: ["meeting.created"])
      insert(:webhook, user: other_user, events: ["meeting.created"])

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["webhook_id"] != nil
    end
  end

  describe "dispatch/2 - event filtering" do
    test "does not enqueue when no webhook is subscribed to the triggered event" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.cancelled"])

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert all_enqueued(worker: WebhookWorker) == []
    end

    test "only enqueues for subscribed webhooks when user has multiple webhooks with different events" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      created_webhook = insert(:webhook, user: user, events: ["meeting.created"])
      _cancelled_webhook = insert(:webhook, user: user, events: ["meeting.cancelled"])

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["webhook_id"] == created_webhook.id
    end

    test "does not enqueue for inactive webhooks" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.created"], is_active: false)

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert all_enqueued(worker: WebhookWorker) == []
    end
  end
end
