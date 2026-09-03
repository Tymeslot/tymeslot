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

  import Tymeslot.Factory

  @moduletag :notifications
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Notifications.Events
  alias Tymeslot.Notifications.Orchestrator
  alias Tymeslot.Webhooks.Dispatcher, as: WebhookDispatcher
  alias Tymeslot.Workers.EmailWorker

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
    # These three events used to call `Webhooks.Dispatcher.dispatch/2` (and
    # its Telegram/Slack counterparts) bare, unlike every other event, which
    # routes through `Events.dispatch_channel/3` and its blanket rescue. A
    # raising dispatcher (a DB blip, a failed Oban insert) would escape
    # straight out of `Events.meeting_requested/1` — and, worse,
    # `Bookings.Create.run_meeting_transaction/3` calls it from inside an
    # open `Repo.transaction/1` for gated bookings, so the raise would fail
    # the invitee's booking outright rather than just costing a
    # notification.
    setup do
      unload_if_mocked(WebhookDispatcher)
      :meck.new(WebhookDispatcher, [:passthrough])

      :meck.expect(WebhookDispatcher, :dispatch, fn _event, _meeting ->
        raise "simulated webhook dispatch failure"
      end)

      on_exit(fn -> unload_if_mocked(WebhookDispatcher) end)

      %{meeting: held_meeting()}
    end

    test "meeting_requested/1 does not raise", %{meeting: meeting} do
      assert {:ok, :notifications_scheduled} = Events.meeting_requested(meeting)
    end

    test "meeting_declined/1 does not raise", %{meeting: meeting} do
      assert {:ok, :notifications_scheduled} = Events.meeting_declined(meeting)
    end

    test "meeting_request_expired/1 does not raise", %{meeting: meeting} do
      assert {:ok, :notifications_scheduled} = Events.meeting_request_expired(meeting)
    end
  end
end
