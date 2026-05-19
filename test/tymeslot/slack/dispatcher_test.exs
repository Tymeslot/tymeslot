defmodule Tymeslot.Slack.DispatcherTest do
  use Tymeslot.DataCase, async: false

  @moduletag :slack
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Slack.Dispatcher
  alias Tymeslot.Workers.SlackWorker

  setup do
    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      environment: :test
    )

    :ok
  end

  describe "dispatch/2 — atom event mapping" do
    test "converts :meeting_created to the dotted string and enqueues a worker job" do
      user = insert(:user)

      integration =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )
    end

    test "converts :meeting_cancelled to the dotted string" do
      user = insert(:user)

      _integration =
        insert(:slack_integration,
          user: user,
          events: ["meeting.cancelled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      assert :ok = Dispatcher.dispatch(:meeting_cancelled, meeting)

      assert_enqueued(worker: SlackWorker, args: %{"event_type" => "meeting.cancelled"})
    end

    test "passes a string event_type through unchanged" do
      user = insert(:user)

      _integration =
        insert(:slack_integration,
          user: user,
          events: ["meeting.rescheduled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      assert :ok = Dispatcher.dispatch("meeting.rescheduled", meeting)

      assert_enqueued(worker: SlackWorker, args: %{"event_type" => "meeting.rescheduled"})
    end
  end

  describe "dispatch/2 — guards" do
    test "returns :no_organizer when meeting has no organizer_user_id" do
      meeting = insert(:meeting, organizer_user_id: nil)
      assert {:error, :no_organizer} = Dispatcher.dispatch(:meeting_created, meeting)
      refute_enqueued(worker: SlackWorker)
    end

    test "enqueues nothing when no integration subscribes to the event" do
      user = insert(:user)

      _wrong_event =
        insert(:slack_integration,
          user: user,
          events: ["meeting.cancelled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)
      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)
      refute_enqueued(worker: SlackWorker)
    end

    test "enqueues only for active integrations" do
      user = insert(:user)

      insert(:slack_integration,
        user: user,
        events: ["meeting.created"],
        is_active: false
      )

      meeting = insert(:meeting, organizer_user_id: user.id)
      assert :ok = Dispatcher.dispatch(:meeting_created, meeting)
      refute_enqueued(worker: SlackWorker)
    end
  end
end
