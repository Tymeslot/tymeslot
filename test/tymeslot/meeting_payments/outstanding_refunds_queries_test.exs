defmodule Tymeslot.MeetingPayments.OutstandingRefundsQueriesTest do
  @moduledoc """
  The query behind the payments screen's "Refunds outstanding" card.

  A cancellation never refunds on its own, and when the attendee cancels no
  refund is even offered, so a host can be left holding money with nothing
  telling them. There is deliberately no stored "refund owed" flag: the answer
  is derived from the meeting's status and the payment's own balance, and these
  tests pin that derivation, including the cases that must *not* appear.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  @moduletag :database
  @moduletag :payments
  @moduletag :queries

  alias Tymeslot.MeetingPayments

  defp cancelled_meeting(opts \\ []) do
    cancelled_at = Keyword.get(opts, :cancelled_at, DateTime.utc_now(:second))
    insert(:meeting, status: "cancelled", cancelled_at: cancelled_at)
  end

  defp payment_for(host_user_id, meeting, attrs \\ %{}) do
    defaults = %{host_user_id: host_user_id, meeting: meeting}
    insert(:paid_booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "list_outstanding_refunds_for_host/2" do
    test "lists a cancelled booking whose money the host still holds" do
      payment = payment_for(1, cancelled_meeting())

      assert [found] = MeetingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == payment.id
    end

    test "lists a partially refunded booking, for the balance that remains" do
      payment =
        payment_for(1, cancelled_meeting(), %{
          status: "partially_refunded",
          amount_cents: 5000,
          refunded_amount_cents: 2000
        })

      assert [found] = MeetingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == payment.id
      assert MeetingPayments.refundable_remaining_cents(found) == 3000
    end

    test "omits a booking that has been refunded in full" do
      payment_for(1, cancelled_meeting(), %{
        status: "refunded",
        amount_cents: 5000,
        refunded_amount_cents: 5000
      })

      assert MeetingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a meeting that is still going ahead" do
      payment_for(1, insert(:meeting, status: "confirmed"))

      assert MeetingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a disputed payment, since Stripe owns the decision" do
      payment_for(1, cancelled_meeting(), %{status: "disputed"})

      assert MeetingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a payment that never settled" do
      payment_for(1, cancelled_meeting(), %{status: "pending", paid_at: nil})

      assert MeetingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "never returns another host's payment" do
      theirs = payment_for(2, cancelled_meeting())

      assert MeetingPayments.list_outstanding_refunds_for_host(1) == []
      assert [found] = MeetingPayments.list_outstanding_refunds_for_host(2)
      assert found.id == theirs.id
    end

    # Oldest first: the longer somebody has been out of pocket, the more
    # urgent the row.
    test "orders by cancellation date, oldest first" do
      now = DateTime.utc_now(:second)
      recent = payment_for(1, cancelled_meeting(cancelled_at: now))

      older =
        payment_for(1, cancelled_meeting(cancelled_at: DateTime.add(now, -5, :day)))

      ids =
        1
        |> MeetingPayments.list_outstanding_refunds_for_host()
        |> Enum.map(& &1.id)

      assert ids == [older.id, recent.id]
    end

    test "preloads the meeting, which the card renders the cancellation date from" do
      payment_for(1, cancelled_meeting())

      assert [found] = MeetingPayments.list_outstanding_refunds_for_host(1)
      assert %DateTime{} = found.meeting.cancelled_at
    end

    # The bug this card exists to fix: the recent-payments list is capped at 25
    # rows, so an older unrefunded cancellation scrolled out of sight entirely.
    test "is not bounded by the recent-payments window" do
      now = DateTime.utc_now(:second)

      oldest =
        payment_for(1, cancelled_meeting(cancelled_at: DateTime.add(now, -90, :day)))

      for day <- 1..25 do
        payment_for(1, cancelled_meeting(cancelled_at: DateTime.add(now, -day, :hour)))
      end

      outstanding = MeetingPayments.list_outstanding_refunds_for_host(1)

      assert length(outstanding) == 26
      assert hd(outstanding).id == oldest.id
    end

    test "honours an explicit limit" do
      for _row <- 1..3, do: payment_for(1, cancelled_meeting())

      assert length(MeetingPayments.list_outstanding_refunds_for_host(1, limit: 2)) == 2
    end
  end
end
