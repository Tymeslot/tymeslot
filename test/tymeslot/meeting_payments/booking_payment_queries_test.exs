defmodule Tymeslot.MeetingPayments.BookingPaymentQueriesTest do
  use Tymeslot.DataCase, async: true

  @moduletag :database
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.SeatPaymentQueries

  describe "a group meeting's seat payments" do
    test "by_meeting_id ignores seat payments" do
      host = insert(:user)
      meeting = insert(:group_meeting, organizer_user_id: host.id)
      [first_hold, second_hold] = insert_pair(:seat_hold, meeting: meeting)

      first =
        insert(:booking_payment,
          meeting: meeting,
          seat_hold_id: first_hold.id,
          participant: insert(:participant, meeting: meeting),
          seat_payment: true,
          host_user_id: host.id,
          inserted_at: ~U[2026-11-01 10:00:00Z]
        )

      second =
        insert(:booking_payment,
          meeting: meeting,
          seat_hold_id: second_hold.id,
          participant: insert(:participant, meeting: meeting),
          seat_payment: true,
          host_user_id: host.id,
          inserted_at: ~U[2026-11-01 10:05:00Z]
        )

      assert BookingPaymentQueries.by_meeting_id(meeting.id) == nil
      assert BookingPaymentQueries.for_meeting(meeting.id) == nil
      assert BookingPaymentQueries.for_meeting_for_host(meeting.id, host.id) == nil

      assert Enum.map(SeatPaymentQueries.list_for_live_seats(meeting.id), & &1.id) ==
               [first.id, second.id]
    end

    test "list_for_live_seats leaves out a payment that never became a seat and a seat left" do
      meeting = insert(:group_meeting)
      [refused_hold, left_hold, live_hold] = insert_list(3, :seat_hold, meeting: meeting)
      left = insert(:participant, meeting: meeting, cancelled_at: ~U[2026-11-01 09:00:00Z])

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: refused_hold.id,
        seat_payment: true
      )

      insert(:booking_payment,
        meeting: meeting,
        seat_hold_id: left_hold.id,
        participant: left,
        seat_payment: true
      )

      live =
        insert(:booking_payment,
          meeting: meeting,
          seat_hold_id: live_hold.id,
          participant: insert(:participant, meeting: meeting),
          seat_payment: true
        )

      assert Enum.map(SeatPaymentQueries.list_for_live_seats(meeting.id), & &1.id) == [
               live.id
             ]
    end

    test "list_for_live_seats leaves out a one-to-one booking's payment" do
      meeting = insert(:meeting)
      payment = insert(:booking_payment, meeting: meeting)

      assert SeatPaymentQueries.list_for_live_seats(meeting.id) == []
      assert BookingPaymentQueries.by_meeting_id(meeting.id).id == payment.id
    end
  end

  describe "by_seat_hold_id/1" do
    test "finds the payment opened for a hold" do
      meeting = insert(:group_meeting)
      hold = insert(:seat_hold, meeting: meeting)

      payment =
        insert(:booking_payment, meeting: meeting, seat_hold_id: hold.id, seat_payment: true)

      assert SeatPaymentQueries.by_seat_hold_id(hold.id).id == payment.id
    end

    test "is nil for an unknown or malformed id" do
      assert SeatPaymentQueries.by_seat_hold_id(UUID.generate()) == nil
      assert SeatPaymentQueries.by_seat_hold_id("not-a-uuid") == nil
    end
  end
end
