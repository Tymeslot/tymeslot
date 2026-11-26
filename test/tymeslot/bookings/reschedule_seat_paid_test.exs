defmodule Tymeslot.Bookings.RescheduleSeatPaidTest do
  @moduledoc """
  Moving a paid seat: its payment follows it to the new seat, unchanged
  (no price difference is charged or refunded), and stays where it was
  when the move fails. A seat held for a booker still paying keeps the old
  meeting when its last participant moves away.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :bookings
  @moduletag :payments
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers, only: [open_schedule_for: 1]
  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

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

    base_params = %{
      duration: "30min",
      user_timezone: "Etc/UTC",
      organizer_user_id: user.id,
      meeting_type_id: meeting_type.id
    }

    old_params = Map.merge(base_params, %{date: Date.add(Date.utc_today(), 2), time: "14:00"})

    {:ok, old_meeting} =
      Create.execute(old_params, %{"name" => "Mover", "email" => "mover@example.com"})

    [mover] = ParticipantQueries.list_live_for_meeting(old_meeting.id)

    payment =
      insert(:paid_booking_payment,
        meeting_id: old_meeting.id,
        participant_id: mover.id,
        seat_payment: true,
        seats: 1,
        amount_cents: 2000,
        refunded_amount_cents: 300,
        status: :partially_refunded,
        host_user_id: user.id
      )

    %{
      user: user,
      base_params: base_params,
      old_meeting: old_meeting,
      mover: mover,
      payment: payment
    }
  end

  defp move(ctx, params),
    do: RescheduleSeat.execute(ctx.mover.management_token, params, ctx.user.id)

  # As the seat reschedule form submits it.
  defp new_slot_params do
    %{
      date: Date.to_iso8601(Date.add(Date.utc_today(), 3)),
      time: "10:00",
      duration: "30min",
      user_timezone: "Etc/UTC"
    }
  end

  test "a moved paid seat takes its payment with it", ctx do
    assert {:ok, %{meeting: new_meeting, participant: new_participant}} =
             move(ctx, new_slot_params())

    moved = Repo.reload!(ctx.payment)
    assert moved.participant_id == new_participant.id
    assert moved.meeting_id == new_meeting.id
    assert moved.status == :partially_refunded
    assert moved.amount_cents == 2000
    assert moved.refunded_amount_cents == 300
  end

  test "a failed move leaves the payment where it was", ctx do
    full = Map.merge(ctx.base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})
    {:ok, _m} = Create.execute(full, %{"name" => "A", "email" => "a@example.com"})
    {:ok, _m} = Create.execute(full, %{"name" => "B", "email" => "b@example.com"})

    assert {:error, :slot_taken} = move(ctx, new_slot_params())

    stayed = Repo.reload!(ctx.payment)
    assert stayed.participant_id == ctx.mover.id
    assert stayed.meeting_id == ctx.old_meeting.id
  end

  test "a seat held for a booker paying keeps the old meeting when its last participant moves",
       ctx do
    insert(:seat_hold, meeting: ctx.old_meeting, email: "payer@example.com")

    assert {:ok, _booked} = move(ctx, new_slot_params())

    assert Repo.get!(MeetingSchema, ctx.old_meeting.id).status == :confirmed
    assert ParticipantQueries.list_live_for_meeting(ctx.old_meeting.id) == []
  end

  describe "the meeting a move would vacate (vacated_meeting/2)" do
    test "is the old meeting when the mover holds its last live seat", ctx do
      seat = %{participant: ctx.mover, meeting: ctx.old_meeting}

      assert %{id: meeting_id} = RescheduleSeat.vacated_meeting(seat, ctx.user.id)
      assert meeting_id == ctx.old_meeting.id
    end

    test "is none while a booker still holds a seat on it", ctx do
      insert(:seat_hold, meeting: ctx.old_meeting, email: "payer@example.com")
      seat = %{participant: ctx.mover, meeting: ctx.old_meeting}

      assert RescheduleSeat.vacated_meeting(seat, ctx.user.id) == nil
    end
  end
end
