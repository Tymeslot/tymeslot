defmodule Tymeslot.Bookings.NotificationFanoutIntegrationTest do
  @moduledoc """
  Integration coverage for the seam between the booking domain and the
  outbound notification fan-out.

  `Tymeslot.Notifications.Events` is exercised directly elsewhere
  (`Tymeslot.Notifications.EventsTest`) with a factory meeting, and each
  dispatcher is unit-tested in isolation. Neither proves the seam: that a
  *real* booking action reaches `Events` at all. Nothing failed when the
  `Events.meeting_created/1` call was the thing that broke, because every
  test either called `Events` itself or stopped at the dispatcher.

  The three call sites that matter each own a lifecycle transition:

    * `Bookings.Create.execute/2`      → `Events.meeting_created/1`
    * `Bookings.Reschedule.execute/4`  → `Events.meeting_rescheduled/2`
    * `Bookings.Cancel`                → `Events.meeting_cancelled/1`

  Each test drives the real domain function and asserts the Slack, Telegram
  and webhook delivery jobs land with the event type that transition
  promises. A regression here is silent in production: the booking still
  succeeds, the organiser simply never hears about it.

  A booking whose meeting type creates a video room does not reach `Events` on
  the booking path at all: it defers the whole event to `VideoRoomWorker` so
  that every notification carries the join link. That branch is covered here
  too, driving the job as well as the booking, because a fixture without a
  video integration exercises only the other half of the `if` and is how this
  module missed the event being dropped for every video booking.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings
  @moduletag :notifications
  @moduletag :integration

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory
  import Tymeslot.WorkerTestHelpers

  alias Tymeslot.Bookings.{Cancel, Create, Reschedule}
  alias Tymeslot.Integrations.Video.VideoIntegrationQueries
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.{SlackWorker, TelegramWorker, VideoRoomWorker, WebhookWorker}

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    stub(Tymeslot.EmailServiceMock, :send_appointment_confirmations, fn _details -> {:ok, %{}} end)

    setup_config(:tymeslot,
      feature_access_checker: Tymeslot.Features.DefaultAccessChecker,
      slack_notifications_allowed: true,
      telegram_notifications_allowed: true
    )

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "UTC")
    # Notification fan-out is the subject here, so the host offers every hour
    # of every day and the schedule never refuses the bookings these tests make.
    _schedule = open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Fan-out Chat",
        duration_minutes: 30,
        is_active: true
      )

    all_events = ["meeting.created", "meeting.cancelled", "meeting.rescheduled"]

    slack = insert(:slack_integration, user: user, events: all_events, is_active: true)
    telegram = insert(:telegram_integration, user: user, events: all_events, is_active: true)
    webhook = insert(:webhook, user: user, events: all_events, is_active: true)

    %{
      user: user,
      meeting_type: meeting_type,
      slack: slack,
      telegram: telegram,
      webhook: webhook
    }
  end

  describe "a booking reaches every outbound channel" do
    test "Create.execute/2 fans out meeting.created to Slack, Telegram and webhooks", ctx do
      assert {:ok, meeting} = Create.execute(booking_params(ctx), form_data())

      assert_fanned_out(ctx, meeting, "meeting.created")
    end

    test "Reschedule.execute/4 fans out meeting.rescheduled", ctx do
      assert {:ok, meeting} = Create.execute(booking_params(ctx), form_data())

      new_params = %{
        date: Date.to_string(Date.add(Date.utc_today(), 2)),
        time: "15:00",
        duration: "30min",
        user_timezone: "UTC"
      }

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, new_params, form_data(), ctx.user.id)

      assert_fanned_out(ctx, rescheduled, "meeting.rescheduled")
    end

    test "cancelling fans out meeting.cancelled", ctx do
      assert {:ok, meeting} = Create.execute(booking_params(ctx), form_data())

      assert {:ok, cancelled} = Cancel.execute(meeting.uid)

      assert_fanned_out(ctx, cancelled, "meeting.cancelled")
    end
  end

  describe "a booking with a video room reaches every outbound channel" do
    setup ctx do
      integration =
        insert(:video_integration, user: ctx.user, provider: "mirotalk", is_active: true)

      video_type =
        insert(:meeting_type,
          user: ctx.user,
          name: "Fan-out Call",
          duration_minutes: 30,
          is_active: true,
          allow_video: true,
          video_integration_id: integration.id
        )

      %{video_type: video_type, video_integration: integration}
    end

    test "the deferred event fans out once the room exists", ctx do
      params = booking_params(%{user: ctx.user, meeting_type: ctx.video_type})

      assert {:ok, meeting} = Create.execute_with_video_room(params, form_data())

      # Nothing has been announced yet: the booking handed the whole event to
      # the job so the payload can carry the join link.
      refute_enqueued(worker: WebhookWorker)

      assert_enqueued(
        worker: VideoRoomWorker,
        args: %{"meeting_id" => meeting.id, "announce" => true}
      )

      expect_mirotalk_success()

      assert :ok =
               perform_job(VideoRoomWorker, %{
                 "meeting_id" => meeting.id,
                 "announce" => true
               })

      assert_fanned_out(ctx, meeting, "meeting.created")
    end

    test "the event still fans out when the room can never be created", ctx do
      params = booking_params(%{user: ctx.user, meeting_type: ctx.video_type})

      assert {:ok, meeting} = Create.execute_with_video_room(params, form_data())

      # A room that cannot be created must not cost the subscriber the booking.
      {:ok, _inactive} = VideoIntegrationQueries.toggle_active(ctx.video_integration)

      assert {:discard, _reason} =
               perform_job(
                 VideoRoomWorker,
                 %{"meeting_id" => meeting.id, "announce" => true},
                 attempt: 1
               )

      assert_fanned_out(ctx, meeting, "meeting.created")
    end
  end

  describe "channel selection is honoured" do
    test "an integration not subscribed to the event receives no job", _ctx do
      quiet_user = insert(:user)
      quiet_profile = insert(:profile, user: quiet_user, timezone: "UTC")
      _schedule = open_schedule_for(quiet_profile)

      quiet_type =
        insert(:meeting_type,
          user: quiet_user,
          name: "Quiet Chat",
          duration_minutes: 30,
          is_active: true
        )

      quiet_slack =
        insert(:slack_integration,
          user: quiet_user,
          events: ["meeting.cancelled"],
          is_active: true
        )

      assert {:ok, _meeting} =
               Create.execute(
                 booking_params(%{user: quiet_user, meeting_type: quiet_type}),
                 form_data()
               )

      refute_enqueued(worker: SlackWorker, args: %{"integration_id" => quiet_slack.id})
    end

    test "a deactivated integration is skipped while its active sibling still fires", _ctx do
      mixed_user = insert(:user)
      mixed_profile = insert(:profile, user: mixed_user, timezone: "UTC")
      _schedule = open_schedule_for(mixed_profile)

      mixed_type =
        insert(:meeting_type,
          user: mixed_user,
          name: "Mixed Chat",
          duration_minutes: 30,
          is_active: true
        )

      dormant_telegram =
        insert(:telegram_integration,
          user: mixed_user,
          events: ["meeting.created"],
          is_active: false
        )

      active_slack =
        insert(:slack_integration,
          user: mixed_user,
          events: ["meeting.created"],
          is_active: true
        )

      assert {:ok, meeting} =
               Create.execute(
                 booking_params(%{user: mixed_user, meeting_type: mixed_type}),
                 form_data()
               )

      # Same user, same event, same booking: only the `is_active` flag differs.
      # Asserting both halves in one test is what proves the skip is driven by
      # that flag rather than by the fan-out having stopped altogether.
      refute_enqueued(worker: TelegramWorker, args: %{"integration_id" => dormant_telegram.id})

      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => active_slack.id,
          "event_type" => "meeting.created",
          "meeting_id" => meeting.id
        }
      )
    end
  end

  defp assert_fanned_out(ctx, meeting, event_type) do
    assert_enqueued(
      worker: SlackWorker,
      args: %{
        "integration_id" => ctx.slack.id,
        "event_type" => event_type,
        "meeting_id" => meeting.id
      }
    )

    assert_enqueued(
      worker: TelegramWorker,
      args: %{
        "integration_id" => ctx.telegram.id,
        "event_type" => event_type,
        "meeting_id" => meeting.id
      }
    )

    assert_enqueued(
      worker: WebhookWorker,
      args: %{
        "webhook_id" => ctx.webhook.id,
        "event_type" => event_type,
        "meeting_id" => meeting.id
      }
    )
  end

  defp booking_params(%{user: user, meeting_type: meeting_type}) do
    %{
      date: Date.add(Date.utc_today(), 1),
      time: "14:00",
      duration: "30min",
      user_timezone: "UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }
  end

  defp form_data do
    %{
      "name" => "Test Attendee",
      "email" => "attendee@example.com",
      "message" => "Looking forward to it!"
    }
  end
end
