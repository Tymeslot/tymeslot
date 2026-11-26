defmodule Tymeslot.Bookings.SeatReleaseTest do
  @moduledoc """
  Coverage for `SeatRelease.release/1`'s three outcomes: the meeting is
  cancelled, seats remain, or the emptiness check itself could not be
  completed. The last one must be reported honestly, not folded into
  `:seats_remain` — a caller that cannot tell "definitely still populated"
  from "don't know" cannot reason about a meeting left confirmed with
  nobody on it.
  """

  # async: false — one test patches `MeetingQueries.update_meeting_status/2`
  # with :meck to force the failure `release/1`'s error branch handles.
  # `flip_to_cancelled/1` builds its own attrs internally and they are
  # always valid, so there is no way to drive that branch through the
  # public API; :meck also replaces the module globally for every process.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings

  import Mox
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.Bookings.CancelSeat
  alias Tymeslot.Bookings.Create
  alias Tymeslot.Bookings.SeatRelease
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.Meetings.MeetingQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!
  setup :capture_admin_alerts

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    user = insert(:user, email: "organizer@example.com", name: "Test Organizer")
    profile = insert(:profile, user: user, timezone: "Etc/UTC")
    open_schedule_for(profile)

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: 30,
        is_active: true,
        max_participants: 2
      )

    meeting_params = %{
      date: Date.add(Date.utc_today(), 2),
      time: "14:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    {:ok, meeting} =
      Create.execute(meeting_params, %{"name" => "Solo", "email" => "solo@example.com"})

    # Empty the meeting directly (rather than through `CancelSeat`) so
    # `release/1` is exercised in isolation from its callers.
    [participant] = ParticipantQueries.list_live_for_meeting(meeting.id)
    {:ok, _cancelled} = ParticipantQueries.cancel(participant)

    %{meeting: meeting, meeting_type: meeting_type, user: user}
  end

  test "cancels an emptied meeting", %{meeting: meeting} do
    assert {:ok, :meeting_cancelled} = SeatRelease.release(meeting)
    assert Repo.get!(MeetingSchema, meeting.id).status == :cancelled
  end

  test "reports seats remaining without touching the meeting", %{meeting: meeting} do
    other = insert(:participant, meeting: meeting, cancelled_at: nil)

    assert {:ok, :seats_remain} = SeatRelease.release(meeting)
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    assert ParticipantQueries.count_live_for_meeting(meeting.id) == 1
    assert other.cancelled_at == nil
  end

  test "an honest error, not :seats_remain, when the status flip fails — and it alerts",
       %{meeting: meeting} do
    :meck.new(MeetingQueries, [:passthrough])

    :meck.expect(MeetingQueries, :update_meeting_status, fn _meeting, _attrs ->
      changeset =
        %MeetingSchema{}
        |> Changeset.change()
        |> Changeset.add_error(:status, "simulated failure")

      {:error, changeset}
    end)

    try do
      # Must not be reported as `:seats_remain`: that would tell the caller
      # a confirmed meeting is definitely still populated, when in truth
      # the check never completed.
      assert {:error, :release_check_failed} = SeatRelease.release(meeting)
    after
      :meck.unload(MeetingQueries)
    end

    # The transaction rolled back — status is untouched, not flipped to
    # "cancelled" and not silently left ambiguous either.
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed

    assert_receive {:send_alert, :group_meeting_release_failed, payload}
    assert payload.meeting_id == meeting.id
  end

  # A booker mid-checkout holds a seat on the meeting: it stays for them.
  test "the last participant leaving keeps a meeting with an open hold", %{meeting: meeting} do
    insert(:seat_hold, meeting: meeting, email: "payer@example.com")

    assert {:ok, :seats_remain} = SeatRelease.release(meeting)
    assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
  end

  describe "cancel_if_emptied/1, inside the caller's transaction" do
    test "keeps a meeting a booker still holds a seat on", %{meeting: meeting} do
      insert(:seat_hold, meeting: meeting, email: "payer@example.com")

      assert {:ok, :seats_remain} = SeatRelease.cancel_if_emptied(meeting)
      assert Repo.get!(MeetingSchema, meeting.id).status == :confirmed
    end

    test "cancels it once the hold is no longer held", %{meeting: meeting} do
      insert(:seat_hold,
        meeting: meeting,
        email: "payer@example.com",
        status: :released,
        released_reason: :expired
      )

      assert {:ok, {:cancelled, %{status: :cancelled}}} = SeatRelease.cancel_if_emptied(meeting)
      assert Repo.get!(MeetingSchema, meeting.id).status == :cancelled
    end
  end

  test "the participant's own cancellation refunds nothing", ctx do
    params = %{
      date: Date.add(Date.utc_today(), 3),
      time: "14:00",
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: ctx.user.id,
      meeting_type_id: ctx.meeting_type.id
    }

    {:ok, meeting} = Create.execute(params, %{"name" => "Payer", "email" => "payer@example.com"})
    {:ok, _joined} = Create.execute(params, %{"name" => "Stayer", "email" => "stay@example.com"})

    payer =
      meeting.id
      |> ParticipantQueries.list_live_for_meeting()
      |> Enum.find(&(&1.email == "payer@example.com"))

    payment =
      insert(:paid_booking_payment,
        meeting_id: meeting.id,
        participant_id: payer.id,
        seat_payment: true,
        amount_cents: 2000,
        host_user_id: ctx.user.id
      )

    # No Stripe call is expected: none is stubbed.
    assert {:ok, _result} = CancelSeat.execute(payer.management_token)

    unchanged = Repo.reload!(payment)
    assert unchanged.status == :paid
    assert unchanged.refunded_amount_cents == 0
    assert unchanged.participant_id == payer.id
    assert RefundQueries.list_for_payment(payment.id) == []
  end
end
