defmodule Tymeslot.Bookings.RescheduleApprovalTest do
  @moduledoc """
  Rescheduling a booking on a meeting type that requires the host's approval.

  This is the hole the gate would otherwise have. A host who approves a
  Tuesday agreed to Tuesday, not to the invitee's standing right to move the
  booking anywhere afterwards, so a reschedule has to re-enter the gate rather
  than carry the old answer across.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.MeetingTestHelpers

  @moduletag :bookings
  @moduletag :meetings

  alias Tymeslot.Bookings.Cancel
  alias Tymeslot.Bookings.Reschedule
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Meetings.ApprovalJobs
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.Workers.ApprovalExpiryWorker
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks
  alias Tymeslot.Workers.EmailWorker

  setup :verify_on_exit!

  setup do
    TestMocks.setup_email_mocks()
    :ok
  end

  defp gated_booking(requires_approval, meeting_attrs \\ %{}) do
    %{user: user} = create_always_bookable_profile()

    meeting_type =
      insert(:meeting_type,
        user: user,
        user_id: user.id,
        requires_approval: requires_approval,
        approval_window_hours: 12
      )

    meeting =
      insert_meeting_for_user(
        user,
        Map.merge(%{meeting_type_id: meeting_type.id, status: "confirmed"}, meeting_attrs)
      )

    new_date = Date.add(Date.utc_today(), 2)

    params = %{
      date: Date.to_string(new_date),
      time: "2:00 PM",
      duration: "60min",
      user_timezone: "America/New_York"
    }

    %{user: user, meeting: meeting, params: params}
  end

  defp reload(meeting), do: Repo.get!(MeetingSchema, meeting.id)

  describe "rescheduling a booking on a gated meeting type" do
    test "returns it to the gate rather than moving a confirmed booking" do
      %{meeting: meeting, params: params} = gated_booking(true)

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert rescheduled.status == "awaiting_approval"
      assert reload(meeting).status == "awaiting_approval"
    end

    test "gives the new request its own window rather than the old one" do
      %{meeting: meeting, params: params} = gated_booking(true)

      {:ok, rescheduled} = Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert rescheduled.approval_requested_at
      assert rescheduled.approval_deadline_at

      window = DateTime.diff(rescheduled.approval_deadline_at, rescheduled.approval_requested_at)
      assert window == 12 * 3600
    end

    test "clears the previous answer so the new request does not look resolved" do
      %{meeting: meeting, params: params} =
        gated_booking(true, %{
          approval_resolved_at: DateTime.utc_now(:second),
          approval_nudge_sent_at: DateTime.utc_now(:second),
          decline_reason: "an earlier no"
        })

      {:ok, rescheduled} = Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      # A stale resolved-at would make the new request look answered; a stale
      # nudge timestamp would suppress the nudge for a window never nudged.
      assert is_nil(rescheduled.approval_resolved_at)
      assert is_nil(rescheduled.approval_nudge_sent_at)
      assert is_nil(rescheduled.decline_reason)
    end

    test "tells the invitee a request was made, not that their meeting moved" do
      %{meeting: meeting, params: params} = gated_booking(true)

      Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_booking_request_emails", "meeting_id" => meeting.id}
      )

      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reschedule_request", "meeting_id" => meeting.id}
      )
    end

    test "starts a fresh expiry clock for the new time" do
      %{meeting: meeting, params: params} = gated_booking(true)

      Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => meeting.id})
    end

    test "cancels reminders pinned to the old time rather than leaving them to fire" do
      %{meeting: meeting, params: params} = gated_booking(true)

      # Reminder created for the original (confirmed) slot.
      :ok = EmailScheduler.schedule_reminder_emails(meeting.id, 30, "minutes")

      assert {:ok, _rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      # The booking is back in the gate — nobody has agreed to the new time
      # yet, so nothing should remind the attendee about it.
      refute_enqueued(
        worker: EmailWorker,
        args: %{"action" => "send_reminder_emails", "meeting_id" => meeting.id}
      )
    end
  end

  describe "rescheduling a held request" do
    test "re-enters the gate with a fresh window rather than being left alone" do
      %{meeting: meeting, params: params} =
        gated_booking(true, %{
          status: "awaiting_approval",
          approval_requested_at: DateTime.add(DateTime.utc_now(:second), -1, :hour),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 11, :hour)
        })

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert rescheduled.status == "awaiting_approval"
      assert reload(meeting).status == "awaiting_approval"

      window = DateTime.diff(rescheduled.approval_deadline_at, rescheduled.approval_requested_at)
      assert window == 12 * 3600
    end
  end

  describe "rescheduling a booking whose status the gate is not meaningful for" do
    test "awaiting_payment: leaves the status untouched instead of confirming it into the gate" do
      %{meeting: meeting, params: params} = gated_booking(true, %{status: "awaiting_payment"})

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      # A booking that never paid must not be revived into a state the host
      # can approve — that would confirm a meeting nobody paid for.
      assert rescheduled.status == "awaiting_payment"
      refute_enqueued(worker: ApprovalExpiryWorker)
    end

    test "expired: leaves the status untouched instead of reviving a refunded request" do
      %{meeting: meeting, params: params} =
        gated_booking(true, %{
          status: "expired",
          approval_resolved_at: DateTime.utc_now(:second),
          cancelled_at: DateTime.utc_now(:second)
        })

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      # An expired request was already released and refunded; reviving it
      # into the gate would let the host approve a meeting the invitee has
      # already been paid back for.
      assert rescheduled.status == "expired"
      refute_enqueued(worker: ApprovalExpiryWorker)
    end
  end

  describe "rescheduling a booking on an ungated meeting type" do
    test "leaves the status alone, as it always did" do
      %{meeting: meeting, params: params} = gated_booking(false)

      assert {:ok, rescheduled} =
               Reschedule.execute(meeting.uid, params, %{}, meeting.organizer_user_id)

      assert rescheduled.status == "confirmed"
      refute_enqueued(worker: ApprovalExpiryWorker)
    end
  end

  describe "withdrawing a request" do
    test "stops the clock so the host is not nudged about it" do
      %{user: user} = create_always_bookable_profile()

      held =
        insert_meeting_for_user(user, %{
          status: "awaiting_approval",
          approval_requested_at: DateTime.utc_now(:second),
          approval_deadline_at: DateTime.add(DateTime.utc_now(:second), 12, :hour)
        })

      :ok = ApprovalJobs.schedule_expiry(held)

      {:ok, _cancelled} = Cancel.execute(held)

      # A nudge for a request the invitee has withdrawn asks a real person to
      # decide something that no longer exists.
      refute_enqueued(worker: ApprovalExpiryWorker, args: %{"meeting_id" => held.id})
    end
  end
end
