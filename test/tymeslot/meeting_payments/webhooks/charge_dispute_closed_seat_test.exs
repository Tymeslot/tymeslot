defmodule Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosedSeatTest do
  @moduledoc """
  A dispute closing on the payment of a group seat: a seat that never became
  a booked seat is refunded what the dispute left with the host, whatever
  became of the meeting it was held on; a booked seat is not.
  """

  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration

  @account "acct_TEST_HOST"

  import Tymeslot.Factory

  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Webhooks.ChargeDisputeClosed
  alias Tymeslot.MeetingPayments.Workers.ExecuteRefund
  alias Tymeslot.Repo

  describe "handle/1 — a paid seat" do
    # The seat's completion was refused (its slot had filled), its hold
    # released and its refund left to the dispute: the meeting it was held
    # on goes ahead with other seats, but this seat never happened.
    test "a disputed seat refused for a full slot is refunded once the dispute is won" do
      meeting = insert(:group_meeting, status: :confirmed)
      hold = insert(:seat_hold, meeting: meeting, status: :released, released_reason: :failed)

      bp =
        insert(:paid_booking_payment,
          stripe_account_id: @account,
          meeting_id: meeting.id,
          seat_hold_id: hold.id,
          seat_payment: true,
          status: :disputed,
          amount_cents: 2500,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_SEAT_REFUSED"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_SEAT_WON", "ch_SEAT_REFUSED", "won", 2500)
               )

      assert Repo.reload!(bp).status == :paid

      assert [%{amount_cents: 2500, status: :pending, source: :late_payment} = refund] =
               RefundQueries.list_for_payment(bp.id)

      assert_enqueued(worker: ExecuteRefund, args: %{refund_id: refund.id})
    end

    # Its hold was deleted (30 days after it settled, or on erasure) before
    # the dispute closed: the seat payment's marker still says what it was.
    test "a refused seat whose hold is gone is refunded once the dispute is won" do
      meeting = insert(:group_meeting, status: :confirmed)

      bp =
        insert(:paid_booking_payment,
          stripe_account_id: @account,
          meeting_id: meeting.id,
          seat_hold_id: nil,
          seat_payment: true,
          status: :disputed,
          amount_cents: 2500,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_SEAT_HOLD_GONE"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_SEAT_HOLD_GONE_WON", "ch_SEAT_HOLD_GONE", "won", 2500)
               )

      assert [%{amount_cents: 2500, status: :pending}] = RefundQueries.list_for_payment(bp.id)
    end

    test "a booked seat is not refunded when the dispute is won" do
      meeting = insert(:group_meeting, status: :confirmed)
      participant = insert(:participant, meeting: meeting)
      hold = insert(:seat_hold, meeting: meeting, status: :converted)

      bp =
        insert(:paid_booking_payment,
          stripe_account_id: @account,
          meeting_id: meeting.id,
          participant_id: participant.id,
          seat_hold_id: hold.id,
          seat_payment: true,
          status: :disputed,
          amount_cents: 2500,
          refunded_amount_cents: 0,
          stripe_charge_id: "ch_SEAT_BOOKED"
        )

      assert :ok =
               ChargeDisputeClosed.handle(
                 dispute_closed_event("evt_SEAT_BOOKED_WON", "ch_SEAT_BOOKED", "won", 2500)
               )

      assert RefundQueries.list_for_payment(bp.id) == []
      refute_enqueued(worker: ExecuteRefund)
    end
  end

  defp dispute_closed_event(event_id, charge_id, dispute_status, amount) do
    %{
      "id" => event_id,
      "account" => @account,
      "type" => "charge.dispute.closed",
      "created" => System.os_time(:second),
      "data" => %{
        "object" => %{
          "id" => "dp_#{event_id}",
          "object" => "dispute",
          "charge" => charge_id,
          "amount" => amount,
          "status" => dispute_status
        }
      }
    }
  end
end
