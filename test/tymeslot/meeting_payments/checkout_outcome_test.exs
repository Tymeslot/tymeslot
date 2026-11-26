defmodule Tymeslot.MeetingPayments.CheckoutOutcomeTest do
  @moduledoc """
  What an attendee returning from Stripe Checkout should be told, derived from
  the booking and payment rows their meeting actually reached.

  The states are produced by the real transitions wherever one exists
  (`Approval.withdraw/2`, `Approval.decline/2`, the async-failure webhook), so
  a change to what those transitions write shows up here rather than being
  papered over by a hand-built row.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :payments
  @moduletag :bookings

  alias Ecto.Changeset
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPaymentSchema
  alias Tymeslot.MeetingPayments.Checkout
  alias Tymeslot.MeetingPayments.Webhooks.FailAndExpire
  alias Tymeslot.Meetings.Approval
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatHoldSchema
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub

  defp held_paid_meeting(attrs \\ %{}) do
    user = insert(:user)
    now = DateTime.utc_now(:second)

    meeting =
      insert(
        :meeting,
        Map.merge(
          %{
            status: :awaiting_approval,
            organizer_user: user,
            organizer_user_id: user.id,
            approval_requested_at: now,
            approval_deadline_at: DateTime.add(now, 24, :hour)
          },
          attrs
        )
      )

    insert(:booking_payment, %{
      meeting_id: meeting.id,
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_account_id: "acct_TEST",
      amount_cents: 5000,
      refunded_amount_cents: 0,
      application_fee_cents: 0,
      status: :paid,
      paid_at: now
    })

    meeting
  end

  defp outcome(meeting) do
    Checkout.checkout_outcome(
      BookingPaymentQueries.by_meeting_id(meeting.id),
      Repo.get!(MeetingSchema, meeting.id)
    )
  end

  defp expect_refund(result \\ nil) do
    StripeStub.expect(
      :create_refund,
      1,
      result ||
        StripeFixtures.object("refund_with_charge", %{
          "id" => "re_TEST",
          "amount" => 5000,
          "charge" => %{"amount_refunded" => 5000}
        })
    )
  end

  describe "before the payment completes" do
    test "a checkout still in flight is processing" do
      meeting = insert(:meeting, status: :awaiting_payment)
      insert(:booking_payment, meeting_id: meeting.id, status: :pending, paid_at: nil)

      assert outcome(meeting) == :processing
    end

    test "nothing loaded yet is processing" do
      assert Checkout.checkout_outcome(nil, nil) == :processing
    end

    test "an asynchronous payment failure is failed, not processing" do
      meeting = insert(:meeting, status: :awaiting_payment)

      insert(:booking_payment,
        meeting_id: meeting.id,
        stripe_account_id: "acct_TEST",
        status: :pending,
        paid_at: nil
      )

      assert :ok =
               FailAndExpire.handle(
                 %{
                   "id" => "evt_async_failed",
                   "account" => "acct_TEST",
                   "data" => %{"object" => %{"client_reference_id" => meeting.id}}
                 },
                 "checkout.session.async_payment_failed",
                 :async_payment_failed
               )

      assert outcome(meeting) == :failed
    end

    test "an unpaid booking cancelled before checkout finished is failed" do
      meeting = insert(:meeting, status: :cancelled)
      insert(:booking_payment, meeting_id: meeting.id, status: :pending, paid_at: nil)

      assert outcome(meeting) == :failed
    end
  end

  describe "after the payment completes" do
    test "a confirmed booking is confirmed" do
      meeting = insert(:meeting, status: :confirmed)

      insert(:booking_payment,
        meeting_id: meeting.id,
        status: :paid,
        paid_at: DateTime.utc_now(:second)
      )

      assert outcome(meeting) == :confirmed
    end

    test "a disputed payment is classified by its booking, like any other paid one" do
      meeting = insert(:meeting, status: :confirmed)

      insert(:booking_payment,
        meeting_id: meeting.id,
        status: :disputed,
        paid_at: DateTime.utc_now(:second)
      )

      assert outcome(meeting) == :confirmed
    end

    test "a paid request still held for the host is awaiting approval" do
      assert outcome(held_paid_meeting()) == :awaiting_approval
    end

    test "a held request the attendee withdrew is cancelled, not confirmed" do
      meeting = held_paid_meeting()

      assert {:ok, _withdrawn} = Approval.withdraw(meeting)

      assert outcome(meeting) == :cancelled
    end

    test "a booking the host approved and then cancelled is cancelled, not declined" do
      meeting = held_paid_meeting()
      assert {:ok, approved} = Approval.approve(meeting)

      approved
      |> Changeset.change(status: :cancelled, cancelled_at: DateTime.utc_now(:second))
      |> Repo.update!()

      assert outcome(meeting) == :cancelled
    end

    test "a declined request is declined once the refund has gone through" do
      meeting = held_paid_meeting()
      expect_refund()

      assert {:ok, _declined} = Approval.decline(meeting, nil)
      assert %{success: 1} = Oban.drain_queue(queue: :payments, with_scheduled: true)

      assert BookingPaymentQueries.by_meeting_id(meeting.id).status == :refunded
      assert outcome(meeting) == :declined
    end

    test "a declined request is still declined when its refund failed and left it paid" do
      meeting = held_paid_meeting()
      expect_refund({:error_fixture, "invalid_request_error"})

      assert {:ok, _declined} = Approval.decline(meeting, nil)
      assert %{cancelled: 1} = Oban.drain_queue(queue: :payments, with_scheduled: true)

      assert BookingPaymentQueries.by_meeting_id(meeting.id).status == :paid
      assert outcome(meeting) == :declined
    end

    test "a re-requested confirmed meeting that is declined is declined, with no refund" do
      meeting = held_paid_meeting(%{first_announced_at: DateTime.utc_now(:second)})
      test_pid = self()

      # A stub rather than a missing expectation: the release runs its refund
      # step inside a rescue, so an unexpected Stripe request would be
      # swallowed.
      StripeStub.stub(:create_refund, fn _request ->
        send(test_pid, :refund_attempted)
        StripeFixtures.object("refund_with_charge", %{"id" => "re_unexpected"})
      end)

      assert {:ok, _declined} = Approval.decline(meeting, nil)

      refute_received :refund_attempted
      assert outcome(meeting) == :declined
    end

    test "a request nobody answered in time is expired" do
      meeting = held_paid_meeting()

      assert {:ok, _expired} = Approval.expire(meeting)

      assert outcome(meeting) == :expired
    end
  end

  # A seat's outcome is its hold's: the shared meeting says nothing about
  # whether this booker's seats were paid, so the rows here are the hold and
  # its payment only.
  describe "seat_checkout_outcome/2" do
    defp seat_outcome(hold_attrs, payment_attrs \\ %{status: :pending, paid_at: nil}) do
      Checkout.seat_checkout_outcome(
        struct(SeatHoldSchema, hold_attrs),
        payment_attrs && struct(BookingPaymentSchema, payment_attrs)
      )
    end

    defp paid, do: %{status: :paid, paid_at: DateTime.utc_now(:second)}

    test "no hold to judge is still processing" do
      assert Checkout.seat_checkout_outcome(nil, nil) == :processing
    end

    test "a hold that became a seat is confirmed" do
      assert seat_outcome(%{status: :converted}, paid()) == :confirmed
    end

    # The page reports the checkout, which did book the seat; what became of
    # the seat afterwards is the seat's own confirmation and emails' story.
    test "a seat cancelled since its payment still reads as confirmed" do
      assert seat_outcome(%{status: :converted}, %{status: :refunded, paid_at: paid().paid_at}) ==
               :confirmed
    end

    test "a hold released because its session was cancelled is cancelled" do
      assert seat_outcome(%{status: :released, released_reason: :meeting_cancelled}) ==
               :cancelled
    end

    test "a hold released because its payment failed is failed" do
      assert seat_outcome(%{status: :released, released_reason: :failed}, %{
               status: :failed,
               paid_at: nil
             }) == :failed
    end

    # Its payment came after the hold had gone and found no room: refunded.
    test "a released hold whose payment completed late is expired" do
      assert seat_outcome(%{status: :released, released_reason: :expired}, paid()) == :expired
      assert seat_outcome(%{status: :released, released_reason: :failed}, paid()) == :expired
    end

    test "any other release is expired" do
      assert seat_outcome(%{status: :released, released_reason: :expired}) == :expired
      assert seat_outcome(%{status: :released, released_reason: :abandoned}) == :expired
    end

    test "a held seat whose payment failed is failed" do
      assert seat_outcome(%{status: :held}, %{status: :failed, paid_at: nil}) == :failed
    end

    test "a held seat whose payment is pending is still processing" do
      assert seat_outcome(%{status: :held}) == :processing
      assert seat_outcome(%{status: :held}, nil) == :processing
    end
  end
end
