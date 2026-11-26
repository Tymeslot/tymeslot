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

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments
  alias Tymeslot.MeetingPayments.BookingPayments

  defp cancelled_meeting(opts \\ []) do
    cancelled_at = Keyword.get(opts, :cancelled_at, DateTime.utc_now(:second))
    insert(:meeting, status: :cancelled, cancelled_at: cancelled_at)
  end

  defp payment_for(host_user_id, meeting, attrs \\ %{}) do
    defaults = %{host_user_id: host_user_id, meeting: meeting}
    insert(:paid_booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "list_outstanding_refunds_for_host/2" do
    test "lists a cancelled booking whose money the host still holds" do
      payment = payment_for(1, cancelled_meeting())

      assert [found] = BookingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == payment.id
    end

    test "lists a partially refunded booking, for the balance that remains" do
      payment =
        payment_for(1, cancelled_meeting(), %{
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 2000
        })

      assert [found] = BookingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == payment.id
      assert MeetingPayments.refundable_remaining_cents(found) == 3000
    end

    test "omits a booking that has been refunded in full" do
      payment_for(1, cancelled_meeting(), %{
        status: :refunded,
        amount_cents: 5000,
        refunded_amount_cents: 5000
      })

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a meeting that is still going ahead" do
      payment_for(1, insert(:meeting, status: :confirmed))

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a disputed payment, since Stripe owns the decision" do
      payment_for(1, cancelled_meeting(), %{status: :disputed})

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "omits a payment that never settled" do
      payment_for(1, cancelled_meeting(), %{status: :pending, paid_at: nil})

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
    end

    test "never returns another host's payment" do
      theirs = payment_for(2, cancelled_meeting())

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
      assert [found] = BookingPayments.list_outstanding_refunds_for_host(2)
      assert found.id == theirs.id
    end

    # A payment that completed after its slot was taken leaves the booking
    # expired and the money owed until its automatic refund goes through.
    # It has no cancellation date, so it takes its place by its payment's.
    test "lists expired bookings among cancellations, oldest first by when each became owed" do
      now = DateTime.utc_now(:second)
      days_ago = &DateTime.add(now, -&1, :day)

      expired_20 =
        payment_for(1, insert(:meeting, status: :expired), %{paid_at: days_ago.(20)})

      cancelled_10 = payment_for(1, cancelled_meeting(cancelled_at: days_ago.(10)))

      expired_5 =
        payment_for(1, insert(:meeting, status: :expired), %{paid_at: days_ago.(5)})

      cancelled_1 = payment_for(1, cancelled_meeting(cancelled_at: days_ago.(1)))

      ids =
        1
        |> BookingPayments.list_outstanding_refunds_for_host()
        |> Enum.map(& &1.id)

      assert ids == [expired_20.id, cancelled_10.id, expired_5.id, cancelled_1.id]
      assert BookingPayments.outstanding_refunds_summary_for_host(1).count == 4
    end

    # Rows owed since the same moment come back in one fixed order, so the
    # bounded window is the same rows on every read.
    test "breaks a tie on the date by id" do
      at = DateTime.add(DateTime.utc_now(:second), -1, :day)
      payments = for _row <- 1..3, do: payment_for(1, cancelled_meeting(cancelled_at: at))

      ids =
        1
        |> BookingPayments.list_outstanding_refunds_for_host()
        |> Enum.map(& &1.id)

      assert ids == payments |> Enum.map(& &1.id) |> Enum.sort()
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
        |> BookingPayments.list_outstanding_refunds_for_host()
        |> Enum.map(& &1.id)

      assert ids == [older.id, recent.id]
    end

    test "preloads the meeting, which the card renders the cancellation date from" do
      payment_for(1, cancelled_meeting())

      assert [found] = BookingPayments.list_outstanding_refunds_for_host(1)
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

      outstanding = BookingPayments.list_outstanding_refunds_for_host(1)

      assert length(outstanding) == 26
      assert hd(outstanding).id == oldest.id
    end

    test "honours an explicit limit" do
      for _row <- 1..3, do: payment_for(1, cancelled_meeting())

      assert length(BookingPayments.list_outstanding_refunds_for_host(1, limit: 2)) == 2
    end
  end

  # A participant cancelling their own paid seat is never refunded on its
  # own, and the session it was on goes ahead, so the meeting's status alone
  # cannot say the money is owed: the seat's participant does.
  describe "seat payments" do
    defp seat_payment_for(host_user_id, meeting, participant, attrs \\ %{}) do
      payment_for(
        host_user_id,
        meeting,
        Map.merge(%{participant_id: participant.id, seat_payment: true}, Map.new(attrs))
      )
    end

    test "a participant who cancelled a paid seat appears on outstanding refunds" do
      session = insert(:group_meeting, status: :confirmed, capacity: 4)
      left_at = DateTime.add(DateTime.utc_now(:second), -2, :day)
      left = insert(:participant, meeting: session, cancelled_at: left_at)
      staying = insert(:participant, meeting: session)

      payment = seat_payment_for(1, session, left, %{amount_cents: 2000})
      seat_payment_for(1, session, staying, %{amount_cents: 2000})

      assert [found] = BookingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == payment.id
      assert found.participant.cancelled_at == left_at

      assert %{count: 1, totals: [%{currency: "eur", amount_cents: 2000}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    # A moved seat's payment follows it to the participant it became on the
    # new session (decision: a moved seat keeps its payment); the participant
    # it left behind is cancelled, but nothing is owed.
    test "a moved paid seat is not outstanding" do
      old_session = insert(:group_meeting, status: :confirmed, capacity: 4)
      new_session = insert(:group_meeting, status: :confirmed, capacity: 4)

      _left_behind =
        insert(:participant, meeting: old_session, cancelled_at: DateTime.utc_now(:second))

      moved = insert(:participant, meeting: new_session)

      seat_payment_for(1, new_session, moved)

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
      assert %{count: 0} = BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    # Refused at checkout (its slot full): the session goes ahead with the
    # others, but this seat never happened, so its money is owed back until
    # its refund goes through.
    test "a seat paid for but never booked is outstanding on a session going ahead" do
      session = insert(:group_meeting, status: :confirmed, capacity: 4)

      refused =
        payment_for(1, session, %{seat_payment: true, participant_id: nil, amount_cents: 2500})

      assert [found] = BookingPayments.list_outstanding_refunds_for_host(1)
      assert found.id == refused.id

      assert %{count: 1, totals: [%{currency: "eur", amount_cents: 2500}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end
  end

  describe "a pending refund" do
    test "lowers the balance a listed payment shows, read with the list" do
      meeting = cancelled_meeting()
      payment = payment_for(1, meeting)
      insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2000)

      assert [listed] = BookingPayments.list_outstanding_refunds_for_host(1)
      assert listed.pending_refund_cents == 2000
      assert MeetingPayments.refundable_remaining_cents(listed) == 3000

      assert [recent] = BookingPayments.list_payments_for_host(1)
      assert MeetingPayments.refundable_remaining_cents(recent) == 3000

      assert %{pending_refund_cents: 2000} = BookingPayments.payment_for_meeting(meeting.id, 1)

      # Still owed to the attendee until the refund settles.
      assert %{totals: [%{currency: "eur", amount_cents: 5000}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    test "that covers the balance keeps the booking listed until it settles" do
      payment = payment_for(1, cancelled_meeting())
      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 5000)

      insert(:booking_payment_refund,
        booking_payment: payment,
        amount_cents: 900,
        status: :failed
      )

      assert [%{pending_refund_cents: 5000} = listed] =
               BookingPayments.list_outstanding_refunds_for_host(1)

      assert MeetingPayments.refund_pending?(listed)
      assert %{count: 1} = BookingPayments.outstanding_refunds_summary_for_host(1)

      refund
      |> Changeset.change(status: :succeeded, settled_at: DateTime.utc_now(:second))
      |> Repo.update!()

      payment
      |> Changeset.change(refunded_amount_cents: 5000, status: :refunded)
      |> Repo.update!()

      assert BookingPayments.list_outstanding_refunds_for_host(1) == []
      assert %{count: 0, totals: []} = BookingPayments.outstanding_refunds_summary_for_host(1)
    end
  end

  describe "outstanding_refunds_summary_for_host/1" do
    test "counts the rows and totals what is still owed" do
      payment_for(1, cancelled_meeting(), %{amount_cents: 5000})
      payment_for(1, cancelled_meeting(), %{amount_cents: 3400})

      assert %{count: 2, totals: [%{currency: "eur", amount_cents: 8400}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    test "totals only the balance left after a partial refund" do
      payment_for(1, cancelled_meeting(), %{
        status: :partially_refunded,
        amount_cents: 5000,
        refunded_amount_cents: 2000
      })

      assert %{count: 1, totals: [%{amount_cents: 3000}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    # A host who changed their default currency can be holding money in both,
    # and one sum across the two would be a figure with no meaning.
    test "keeps the totals apart per currency" do
      payment_for(1, cancelled_meeting(), %{currency: "chf", amount_cents: 2000})
      payment_for(1, cancelled_meeting(), %{currency: "eur", amount_cents: 8400})

      assert %{
               count: 2,
               totals: [
                 %{currency: "chf", amount_cents: 2000},
                 %{currency: "eur", amount_cents: 8400}
               ]
             } = BookingPayments.outstanding_refunds_summary_for_host(1)
    end

    test "is empty when the host owes nothing" do
      payment_for(1, insert(:meeting, status: :confirmed))

      assert BookingPayments.outstanding_refunds_summary_for_host(1) == %{count: 0, totals: []}
    end

    test "never counts another host's payment" do
      payment_for(2, cancelled_meeting())

      assert %{count: 0} = BookingPayments.outstanding_refunds_summary_for_host(1)
      assert %{count: 1} = BookingPayments.outstanding_refunds_summary_for_host(2)
    end

    # The bug the summary exists to close: the list is capped at 50 rows, and a
    # full table with thirteen rows missing looks exactly like a full table
    # with nothing missing unless something reports the true count.
    test "reports the rows the list's window drops" do
      now = DateTime.utc_now(:second)

      for hour <- 1..51 do
        payment_for(1, cancelled_meeting(cancelled_at: DateTime.add(now, -hour, :hour)), %{
          amount_cents: 100
        })
      end

      assert length(BookingPayments.list_outstanding_refunds_for_host(1)) == 50

      assert %{count: 51, totals: [%{amount_cents: 5100}]} =
               BookingPayments.outstanding_refunds_summary_for_host(1)
    end
  end
end
