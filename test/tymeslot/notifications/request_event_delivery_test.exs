defmodule Tymeslot.Notifications.RequestEventDeliveryTest do
  @moduledoc """
  Delivery coverage for the three request-lifecycle event types
  (`meeting.requested`, `meeting.declined`, `meeting.request_expired`) and
  for the timing change to `meeting.created` on a gated booking.

  `Tymeslot.Notifications.EventsTest` already proves these events reach the
  Telegram/Slack dispatch wiring without raising; what was missing is proof
  that a webhook actually subscribed to one of them receives a job, and that
  a gated booking's `meeting.created` fires on approval rather than on
  submission — mirroring the coverage `test/tymeslot/webhooks/dispatcher_test.exs`
  already has for the three pre-existing event types.
  """

  use Tymeslot.DataCase, async: false

  use Oban.Testing, repo: Tymeslot.Repo

  import Tymeslot.Factory

  @moduletag :webhooks
  @moduletag :notifications

  alias Tymeslot.Bookings.Activation
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Webhooks.Dispatcher
  alias Tymeslot.Workers.WebhookWorker

  defp held_meeting(attrs \\ %{}) do
    user = insert(:user)

    defaults = %{
      status: "awaiting_approval",
      organizer_user: user,
      organizer_user_id: user.id,
      approval_requested_at: DateTime.utc_now(:second),
      approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 24, :hour)
    }

    %{meeting: insert(:meeting, Map.merge(defaults, attrs)), user: user}
  end

  describe "Dispatcher.dispatch/2 — the three request-lifecycle event types" do
    test "enqueues a job for a webhook subscribed to meeting.requested" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.requested"])

      assert :ok = Dispatcher.dispatch(:meeting_requested, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.requested"
      assert job.args["meeting_id"] == meeting.id
    end

    test "enqueues a job for a webhook subscribed to meeting.declined" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.declined"])

      assert :ok = Dispatcher.dispatch(:meeting_declined, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.declined"
      assert job.args["meeting_id"] == meeting.id
    end

    test "enqueues a job for a webhook subscribed to meeting.request_expired" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.request_expired"])

      assert :ok = Dispatcher.dispatch(:meeting_request_expired, meeting)

      assert [job] = all_enqueued(worker: WebhookWorker)
      assert job.args["event_type"] == "meeting.request_expired"
      assert job.args["meeting_id"] == meeting.id
    end

    test "a webhook subscribed only to meeting.created hears nothing from any of the three" do
      user = insert(:user)
      meeting = insert(:meeting, organizer_user: user)
      insert(:webhook, user: user, events: ["meeting.created"])

      assert :ok = Dispatcher.dispatch(:meeting_requested, meeting)
      assert :ok = Dispatcher.dispatch(:meeting_declined, meeting)
      assert :ok = Dispatcher.dispatch(:meeting_request_expired, meeting)

      assert all_enqueued(worker: WebhookWorker) == []
    end
  end

  describe "meeting.created timing on a gated booking" do
    test "fires meeting.requested on submission and meeting.created only once the host approves" do
      %{meeting: meeting, user: user} = held_meeting()

      insert(:webhook,
        user: user,
        events: ["meeting.created", "meeting.requested"]
      )

      # `Bookings.Create` hands a held booking to `Activation.activate/2`
      # exactly like this, with no options — the same seam a real gated
      # submission goes through.
      assert :ok = Activation.activate(meeting)

      assert [requested_job] = all_enqueued(worker: WebhookWorker)
      assert requested_job.args["event_type"] == "meeting.requested"

      refute_enqueued(worker: WebhookWorker, args: %{"event_type" => "meeting.created"})

      assert {:ok, confirmed} = Approval.approve(meeting)

      assert_enqueued(
        worker: WebhookWorker,
        args: %{"event_type" => "meeting.created", "meeting_id" => confirmed.id}
      )
    end
  end
end
