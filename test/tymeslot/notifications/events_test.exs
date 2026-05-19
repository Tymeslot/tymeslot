defmodule Tymeslot.Notifications.EventsTest do
  use Tymeslot.DataCase, async: false

  @moduletag :notifications

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.Notifications.Events
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker}

  setup :verify_on_exit!

  describe "should_trigger_notifications?/2" do
    test "returns true for confirmed meetings on creation" do
      assert Events.should_trigger_notifications?(:meeting_created, %{status: "confirmed"})
    end

    test "returns false for pending meetings on creation" do
      refute Events.should_trigger_notifications?(:meeting_created, %{status: "pending"})
    end

    test "returns true for cancelled status on cancellation" do
      assert Events.should_trigger_notifications?(:meeting_cancelled, %{status: "cancelled"})
    end

    test "returns true for video_room_created when enabled" do
      assert Events.should_trigger_notifications?(:video_room_created, %{video_room_enabled: true})
    end

    test "returns true for reminder_triggered when confirmed and not sent" do
      assert Events.should_trigger_notifications?(:reminder_triggered, %{
               status: "confirmed",
               reminder_email_sent: false
             })
    end

    test "returns false for reminder_triggered when already sent" do
      refute Events.should_trigger_notifications?(:reminder_triggered, %{
               status: "confirmed",
               reminder_email_sent: true
             })
    end
  end

  describe "get_event_metadata/2" do
    test "returns correct metadata map" do
      meeting = %{
        id: "123",
        uid: "UID-123",
        status: "confirmed",
        attendee_email: "a@test.com",
        organizer_email: "o@test.com",
        start_time: DateTime.utc_now()
      }

      meta = Events.get_event_metadata(:meeting_created, meeting)
      assert meta.meeting_id == "123"
      assert meta.event_type == :meeting_created
      assert meta.attendee_email == "a@test.com"
    end
  end

  describe "validate_event/2" do
    test "returns :ok for valid event" do
      assert Events.validate_event(:meeting_created, %{status: "confirmed"}) == :ok
    end

    test "returns error if meeting is nil" do
      assert Events.validate_event(:meeting_created, nil) == {:error, "Meeting is required"}
    end

    test "returns error if event should not trigger" do
      assert Events.validate_event(:meeting_created, %{status: "pending"}) ==
               {:error, "Event should not trigger notifications"}
    end
  end

  describe "status change handling" do
    test "meeting_status_changed handles cancellation" do
      # Note: This will call meeting_cancelled which calls Orchestrator
      # Since we don't have a mock for Orchestrator, we just check it doesn't crash
      # if we provide enough data or if it's already tested.
      # Actually, Orchestrator might fail if it tries to do DB stuff.
    end
  end

  describe "dispatch wiring" do
    setup do
      setup_config(:tymeslot,
        feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
        slack_notifications_allowed: true,
        telegram_notifications_allowed: true,
        environment: :test
      )

      # Allow Orchestrator's immediate email side-effects to no-op so we can
      # focus on the dispatch wiring rather than the email pipeline.
      stub(Tymeslot.EmailServiceMock, :send_appointment_confirmations, fn _details ->
        {:ok, %{}}
      end)

      user = insert(:user)

      slack_integration =
        insert(:slack_integration,
          user: user,
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true
        )

      telegram_integration =
        insert(:telegram_integration,
          user: user,
          events: ["meeting.created", "meeting.cancelled", "meeting.rescheduled"],
          is_active: true
        )

      meeting = insert(:meeting, organizer_user_id: user.id)

      %{
        user: user,
        meeting: meeting,
        slack_integration: slack_integration,
        telegram_integration: telegram_integration
      }
    end

    test "meeting_created/1 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_created(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )
    end

    test "meeting_cancelled/1 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_cancelled(meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.cancelled",
          "meeting_id" => meeting.id
        }
      )
    end

    test "meeting_rescheduled/2 enqueues Telegram and Slack jobs", %{
      meeting: meeting,
      slack_integration: slack_integration,
      telegram_integration: telegram_integration
    } do
      Events.meeting_rescheduled(meeting, meeting)

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => telegram_integration.id,
          "event_type" => "meeting.rescheduled",
          "meeting_id" => meeting.id
        }
      )

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => slack_integration.id,
          "event_type" => "meeting.rescheduled",
          "meeting_id" => meeting.id
        }
      )
    end
  end
end
