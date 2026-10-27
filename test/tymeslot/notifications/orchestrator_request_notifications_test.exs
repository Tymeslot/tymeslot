defmodule Tymeslot.Notifications.OrchestratorRequestNotificationsTest do
  @moduledoc """
  `Orchestrator.schedule_request_notifications/1` schedules three
  independent jobs (request email, approval nudge, expiry). A failure in one
  must not suppress the others — the expiry has a cron backstop, but the
  nudge does not, so a lost request email must not also cost the nudge.
  """

  # async: false — :meck patches Oban globally for the duration of each test.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  @moduletag :notifications
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Webhooks
  alias Tymeslot.Workers.EmailWorker
  alias Tymeslot.Workers.SlackWorker
  alias Tymeslot.Workers.TelegramWorker

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    insert(:meeting, Map.merge(defaults, attrs))
  end

  # Fails only the Oban.insert call for the request-email job, letting every
  # other insert (the nudge, the expiry) go through unpatched.
  defp fail_request_email_inserts do
    unload_if_mocked(Oban)
    :meck.new(Oban, [:passthrough])

    :meck.expect(Oban, :insert, fn changeset ->
      if Changeset.get_field(changeset, :args)["action"] == "send_booking_request_emails" do
        {:error, %Changeset{changeset | valid?: false, errors: [base: {"simulated", []}]}}
      else
        :meck.passthrough([changeset])
      end
    end)

    on_exit(fn -> unload_if_mocked(Oban) end)
  end

  defp unload_if_mocked(module) do
    :meck.unload(module)
  rescue
    _error -> :ok
  end

  describe "schedule_request_notifications/1" do
    test "schedules a request email, a nudge and an expiry when all succeed" do
      meeting = held_meeting()

      assert {:ok, :notifications_scheduled} =
               Orchestrator.schedule_request_notifications(meeting)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting.id}
      )

      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})
    end

    test "still arms the nudge and the expiry when the request-email insert fails" do
      fail_request_email_inserts()
      meeting = held_meeting()

      assert {:error, _reason} = Orchestrator.schedule_request_notifications(meeting)

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_approval_nudge", "meeting_id" => meeting.id}
      )

      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})
    end
  end

  describe "Events request-lifecycle dispatch survives a raising channel" do
    # These three events once called the channel dispatchers bare, unlike
    # every other event. A raising channel (a DB blip, a failed Oban insert)
    # would escape straight out of `Events.meeting_requested/2` and fail the
    # caller, a reschedule sending a booking back into the approval gate,
    # rather than just cost a notification.
    #
    # The webhook channel is made to raise with :meck: `Events` fans out
    # through `ChannelFanout.dispatch/2` without a `:channels` seam, and
    # nothing a webhook subscription can hold makes scheduling raise.
    setup do
      setup_config(:tymeslot,
        telegram_notifications_allowed: true,
        telegram_shared_bot: false,
        slack_notifications_allowed: true
      )

      unload_if_mocked(Webhooks)
      :meck.new(Webhooks, [:passthrough])

      :meck.expect(Webhooks, :schedule_for_event, fn _user_id, _event_type, _meeting ->
        raise "simulated webhook scheduling failure"
      end)

      on_exit(fn -> unload_if_mocked(Webhooks) end)

      meeting = held_meeting()
      user = meeting.organizer_user
      events = ["meeting.requested", "meeting.declined", "meeting.request_expired"]

      %{
        meeting: meeting,
        slack: insert(:slack_integration, user: user, events: events),
        telegram: insert(:telegram_integration, user: user, events: events)
      }
    end

    # Webhooks run first, so the channels after a raising one must still
    # be scheduled.
    defp assert_other_channels_enqueued(ctx, event_type) do
      assert_enqueued(
        worker: SlackWorker,
        args: %{
          "integration_id" => ctx.slack.id,
          "event_type" => event_type,
          "meeting_id" => ctx.meeting.id
        }
      )

      assert_enqueued(
        worker: TelegramWorker,
        args: %{
          "integration_id" => ctx.telegram.id,
          "event_type" => event_type,
          "meeting_id" => ctx.meeting.id
        }
      )
    end

    test "meeting_requested/1 does not raise and still reaches Slack and Telegram",
         %{meeting: meeting} = ctx do
      assert {:ok, :notifications_scheduled} = Events.meeting_requested(meeting)
      assert_other_channels_enqueued(ctx, "meeting.requested")
    end

    test "meeting_declined/1 does not raise and still reaches Slack and Telegram",
         %{meeting: meeting} = ctx do
      assert {:ok, :notifications_scheduled} = Events.meeting_declined(meeting)
      assert_other_channels_enqueued(ctx, "meeting.declined")
    end

    test "meeting_request_expired/1 does not raise and still reaches Slack and Telegram",
         %{meeting: meeting} = ctx do
      assert {:ok, :notifications_scheduled} = Events.meeting_request_expired(meeting)
      assert_other_channels_enqueued(ctx, "meeting.request_expired")
    end
  end
end
