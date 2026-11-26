defmodule Tymeslot.MeetingPayments.RefundsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  alias Ecto.UUID

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.BookingPayments
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.StripeFixtures
  alias Tymeslot.StripeStub
  alias Tymeslot.StripeStubResponses
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  # ---------------------------------------------------------------------------
  # Helpers shared across unit tests (no DB needed)
  # ---------------------------------------------------------------------------

  defp payment_stub(attrs) do
    defaults = %{
      amount_cents: 5000,
      currency: "eur",
      refunded_amount_cents: 0,
      status: :paid,
      paid_at: DateTime.utc_now(:second)
    }

    Map.merge(defaults, Map.new(attrs))
  end

  # ---------------------------------------------------------------------------
  # refundable_remaining_cents/1
  # ---------------------------------------------------------------------------

  describe "refundable_remaining_cents/1" do
    test "returns amount_cents when nothing has been refunded" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})
      assert Refunds.refundable_remaining_cents(payment) == 5000
    end

    test "returns the difference when partially refunded" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 2000})
      assert Refunds.refundable_remaining_cents(payment) == 3000
    end

    test "returns 0 when fully refunded" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 5000})
      assert Refunds.refundable_remaining_cents(payment) == 0
    end

    test "clamps to 0 when refunded exceeds amount (defensive)" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 6000})
      assert Refunds.refundable_remaining_cents(payment) == 0
    end
  end

  # ---------------------------------------------------------------------------
  # refundable?/1
  # ---------------------------------------------------------------------------

  describe "refund_outstanding?/1" do
    test "returns true for a paid payment with nothing refunded yet" do
      payment = payment_stub(%{status: :paid, refunded_amount_cents: 0})
      assert Refunds.refund_outstanding?(payment)
    end

    test "returns true for a partially refunded payment with a balance left" do
      payment =
        payment_stub(%{
          status: :partially_refunded,
          amount_cents: 5000,
          refunded_amount_cents: 2000
        })

      assert Refunds.refund_outstanding?(payment)
    end

    test "returns false once the whole amount has been given back" do
      payment =
        payment_stub(%{status: :refunded, amount_cents: 5000, refunded_amount_cents: 5000})

      refute Refunds.refund_outstanding?(payment)
    end

    test "returns false for a disputed payment, since Stripe owns the decision" do
      payment = payment_stub(%{status: :disputed, refunded_amount_cents: 0})
      refute Refunds.refund_outstanding?(payment)
    end

    test "returns false for a payment that never settled" do
      payment = payment_stub(%{status: :pending, refunded_amount_cents: 0})
      refute Refunds.refund_outstanding?(payment)
    end

    test "returns false for no payment at all, as a free booking has none" do
      refute Refunds.refund_outstanding?(nil)
    end

    # The distinction from refundable?/1: the host is still holding the money
    # whether or not Tymeslot can be the one to send it back.
    test "stays true outside the 60-day window, where refundable?/1 turns false" do
      payment =
        payment_stub(%{
          status: :paid,
          paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)
        })

      assert Refunds.refund_outstanding?(payment)
      refute Refunds.refundable?(payment)
    end
  end

  describe "refundable?/1" do
    test "returns true for a paid payment within the window" do
      payment = payment_stub(%{status: :paid, paid_at: DateTime.utc_now(:second)})
      assert Refunds.refundable?(payment)
    end

    test "returns true for a partially_refunded payment within the window" do
      payment =
        payment_stub(%{status: :partially_refunded, paid_at: DateTime.utc_now(:second)})

      assert Refunds.refundable?(payment)
    end

    test "returns false when paid_at is nil" do
      payment = payment_stub(%{status: :paid, paid_at: nil})
      refute Refunds.refundable?(payment)
    end

    # Shouldn't occur — such a row should carry "refunded" — but the balance is
    # the thing that decides, so a stale status must not offer a refund of zero
    # that `validate_amount/2` would then reject.
    test "returns false for a paid row whose balance is already fully refunded" do
      payment =
        payment_stub(%{status: :paid, amount_cents: 5000, refunded_amount_cents: 5000})

      refute Refunds.refundable?(payment)
    end

    test "returns false for a fully refunded payment" do
      payment = payment_stub(%{status: :refunded, paid_at: DateTime.utc_now(:second)})
      refute Refunds.refundable?(payment)
    end

    test "returns false when outside the 60-day window" do
      old_paid_at = DateTime.add(DateTime.utc_now(:second), -61, :day)
      payment = payment_stub(%{status: :paid, paid_at: old_paid_at})
      refute Refunds.refundable?(payment)
    end

    test "returns true on the last day of the window (boundary)" do
      paid_at = DateTime.add(DateTime.utc_now(:second), -60, :day)
      payment = payment_stub(%{status: :paid, paid_at: paid_at})
      assert Refunds.refundable?(payment)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_refund_amount/2
  # ---------------------------------------------------------------------------

  defp paid_booking_payment(attrs \\ %{}) do
    defaults = %{
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_payment_intent_id: "pi_TEST_#{System.unique_integer([:positive])}",
      stripe_checkout_session_id: "cs_TEST_#{System.unique_integer([:positive])}",
      amount_cents: 5000,
      application_fee_cents: 25,
      currency: "eur",
      status: :paid,
      paid_at: DateTime.utc_now(:second),
      refunded_amount_cents: 0,
      stripe_account_id: "acct_TEST"
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  # What a refund made at once (`refund_now/4`) asks of Stripe and records.
  # The outbox mechanics (replays, adoption, retries) are in
  # `RefundOutboxTest`.
  describe "refund_now/4" do
    test "a full refund asks Stripe for the charge on the host's account and records it" do
      payment = paid_booking_payment()

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_full"))

      assert {:ok, %{status: :succeeded}} = Refunds.refund_now(payment, 5000, :host, [])

      assert [%{form: form, headers: headers}] = StripeStub.requests(:create_refund)
      assert form["charge"] == payment.stripe_charge_id
      assert form["amount"] == "5000"
      assert form["refund_application_fee"] == "true"
      assert form["metadata"]["meeting_id"] == to_string(payment.meeting_id)
      assert form["metadata"]["booking_payment_id"] == payment.id
      assert headers["stripe-account"] == payment.stripe_account_id
      refute Map.has_key?(form, "reason")

      reloaded = BookingPaymentQueries.get(payment.id)
      assert reloaded.status == :refunded
      assert reloaded.refunded_amount_cents == 5000

      assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
    end

    test "a second partial reaching the total refunds the payment" do
      payment = paid_booking_payment(%{refunded_amount_cents: 2000, status: :partially_refunded})

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_top_up", 2000))

      assert {:ok, _refund} = Refunds.refund_now(payment, 3000, :host, [])

      assert %{status: :refunded, refunded_amount_cents: 5000} =
               BookingPaymentQueries.get(payment.id)
    end

    # Adding the amount instead could count it twice, over a total
    # charge.refunded already raised; the next attempt adopts it expanded.
    test "an answer without the expanded charge records nothing and is retried" do
      payment = paid_booking_payment(%{refunded_amount_cents: 2000, status: :partially_refunded})

      StripeStub.expect(
        :create_refund,
        StripeFixtures.object("refund", %{"id" => "re_unexpanded"})
      )

      assert {:pending, refund} = Refunds.refund_now(payment, 1500, :host, [])

      assert %{status: :pending, executing_until: nil} = RefundQueries.get(refund.id)

      assert %{status: :partially_refunded, refunded_amount_cents: 2000} =
               BookingPaymentQueries.get(payment.id)
    end

    test "omits refund_application_fee when no fee was collected" do
      payment = paid_booking_payment(%{application_fee_cents: 0})

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_zero_fee"))

      assert {:ok, _refund} = Refunds.refund_now(payment, 1000, :host, [])

      assert [%{form: form}] = StripeStub.requests(:create_refund)
      refute Map.has_key?(form, "refund_application_fee")
    end

    test "passes the supplied reason through to Stripe" do
      payment = paid_booking_payment()

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_reason"))

      assert {:ok, _refund} =
               Refunds.refund_now(payment, 500, :host, reason: "requested_by_customer")

      assert [%{form: %{"reason" => "requested_by_customer"}}] =
               StripeStub.requests(:create_refund)
    end

    test "a refund only another host could make is not found" do
      payment = paid_booking_payment()

      assert {:error, :not_found} =
               Refunds.refund_now(payment, 1500, :host, host_user_id: payment.host_user_id + 1)

      assert_untouched(payment)
    end

    # No Stripe stub is installed: any request fails the test.
    test "refuses, without asking Stripe, what the payment cannot be refunded" do
      assert {:error, :invalid_amount} =
               Refunds.refund_now(paid_booking_payment(), 6000, :host, [])

      assert {:error, :invalid_amount} = Refunds.refund_now(paid_booking_payment(), 0, :host, [])

      assert {:error, :invalid_amount} =
               %{refunded_amount_cents: 4500, status: :partially_refunded}
               |> paid_booking_payment()
               |> Refunds.refund_now(600, :host, [])

      assert {:error, :already_refunded} =
               %{status: :refunded, refunded_amount_cents: 5000}
               |> paid_booking_payment()
               |> Refunds.refund_now(100, :host, [])

      assert {:error, :outside_refund_window} =
               %{paid_at: DateTime.add(DateTime.utc_now(:second), -61, :day)}
               |> paid_booking_payment()
               |> Refunds.refund_now(100, :host, [])

      assert {:error, :not_paid} =
               %{paid_at: nil, status: :pending}
               |> paid_booking_payment()
               |> Refunds.refund_now(100, :host, [])

      assert {:error, :under_dispute} =
               %{status: :disputed}
               |> paid_booking_payment()
               |> Refunds.refund_now(100, :host, [])

      assert StripeStub.requests(:create_refund) == []
    end

    test "a permanent Stripe refusal fails the refund and leaves the payment as it was" do
      payment = paid_booking_payment()

      StripeStub.expect(:create_refund, {:error_fixture, "invalid_request_error"})

      assert {:error, :refund_failed} = Refunds.refund_now(payment, 1000, :host, [])
      assert_untouched_after_request(payment)
    end
  end

  describe "refund_now/4 after a partly lost dispute" do
    # 5000 paid, 3000 taken back by a lost dispute, nothing refunded at Stripe.
    defp after_lost_dispute,
      do:
        paid_booking_payment(%{
          refunded_amount_cents: 3000,
          disputed_lost_cents: 3000,
          status: :partially_refunded
        })

    test "refuses more than the remainder without asking Stripe" do
      assert {:error, :invalid_amount} =
               Refunds.refund_now(after_lost_dispute(), 2500, :host, [])
    end

    test "records a refund of the remainder against Stripe's refunds" do
      payment = after_lost_dispute()

      StripeStub.expect(:create_refund, StripeStubResponses.refund("re_rest"))

      assert {:ok, _refund} = Refunds.refund_now(payment, 2000, :host, [])

      assert %{refunded_amount_cents: 5000, disputed_lost_cents: 3000, status: :refunded} =
               BookingPaymentQueries.get(payment.id)
    end
  end

  describe "get_payment_for_host/2" do
    test "returns the host's own payment" do
      payment = paid_booking_payment()

      assert {:ok, %{id: id}} =
               BookingPayments.get_payment_for_host(payment.id, payment.host_user_id)

      assert id == payment.id
    end

    test "is not found for another host, an unknown id, or a malformed id" do
      payment = paid_booking_payment()

      assert {:error, :not_found} =
               BookingPayments.get_payment_for_host(payment.id, payment.host_user_id + 1)

      assert {:error, :not_found} =
               BookingPayments.get_payment_for_host(UUID.generate(), payment.host_user_id)

      assert {:error, :not_found} =
               BookingPayments.get_payment_for_host("not-a-uuid", payment.host_user_id)
    end
  end

  describe "payment_for_meeting/2" do
    test "returns the payment only to the host who took it" do
      meeting = insert(:meeting)
      payment = paid_booking_payment(%{meeting_id: meeting.id})

      assert %{id: id} = BookingPayments.payment_for_meeting(meeting.id, payment.host_user_id)
      assert id == payment.id

      assert BookingPayments.payment_for_meeting(meeting.id, payment.host_user_id + 1) == nil
    end
  end

  defp assert_untouched(payment) do
    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.refunded_amount_cents == 0
    assert reloaded.status == :paid
    refute_enqueued(worker: SendBookingPaymentRefunded)
    assert StripeStub.requests(:create_refund) == []
  end

  defp assert_untouched_after_request(payment) do
    reloaded = BookingPaymentQueries.get(payment.id)
    assert reloaded.refunded_amount_cents == 0
    assert reloaded.status == :paid
    refute_enqueued(worker: SendBookingPaymentRefunded)
  end
end
