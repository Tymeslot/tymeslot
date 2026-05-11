defmodule Tymeslot.MeetingPayments.RefundsTest do
  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :database
  @moduletag :payments

  import Mox

  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.Refunds
  alias Tymeslot.MeetingPayments.StripeAdapterMock
  alias Tymeslot.Workers.SendBookingPaymentRefunded

  setup :verify_on_exit!

  # ---------------------------------------------------------------------------
  # Helpers shared across unit tests (no DB needed)
  # ---------------------------------------------------------------------------

  defp payment_stub(attrs \\ %{}) do
    defaults = %{
      amount_cents: 5000,
      refunded_amount_cents: 0,
      status: "paid",
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

  describe "refundable?/1" do
    test "returns true for a paid payment within the window" do
      payment = payment_stub(%{status: "paid", paid_at: DateTime.utc_now(:second)})
      assert Refunds.refundable?(payment)
    end

    test "returns true for a partially_refunded payment within the window" do
      payment =
        payment_stub(%{status: "partially_refunded", paid_at: DateTime.utc_now(:second)})

      assert Refunds.refundable?(payment)
    end

    test "returns false when paid_at is nil" do
      payment = payment_stub(%{status: "paid", paid_at: nil})
      refute Refunds.refundable?(payment)
    end

    test "returns false for a fully refunded payment" do
      payment = payment_stub(%{status: "refunded", paid_at: DateTime.utc_now(:second)})
      refute Refunds.refundable?(payment)
    end

    test "returns false when outside the 60-day window" do
      old_paid_at = DateTime.add(DateTime.utc_now(:second), -61, :day)
      payment = payment_stub(%{status: "paid", paid_at: old_paid_at})
      refute Refunds.refundable?(payment)
    end

    test "returns true on the last day of the window (boundary)" do
      paid_at = DateTime.add(DateTime.utc_now(:second), -60, :day)
      payment = payment_stub(%{status: "paid", paid_at: paid_at})
      assert Refunds.refundable?(payment)
    end
  end

  # ---------------------------------------------------------------------------
  # parse_refund_amount/2
  # ---------------------------------------------------------------------------

  describe "parse_refund_amount/2" do
    test "full type returns the remaining refundable amount" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 1000})
      assert {:ok, 4000} = Refunds.parse_refund_amount(payment, %{"refund_type" => "full"})
    end

    test "partial type with valid decimal amount returns cents" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})
      assert {:ok, 1500} = Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "15.00"})
    end

    test "partial type normalises comma as decimal separator" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})
      assert {:ok, 1500} = Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "15,00"})
    end

    test "partial type parses whole-number amount (no decimal point)" do
      payment = payment_stub(%{amount_cents: 10_000, refunded_amount_cents: 0})
      assert {:ok, 1000} = Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "10"})
    end

    test "partial type parses sub-dollar amount correctly" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 0})
      assert {:ok, 50} = Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "0.50"})
    end

    test "partial type parses 29.99 correctly (no float rounding hazard)" do
      payment = payment_stub(%{amount_cents: 10_000, refunded_amount_cents: 0})
      assert {:ok, 2999} = Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "29.99"})
    end

    test "partial type returns :invalid_amount for scientific notation" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "1e2"})
    end

    test "partial type returns :invalid_amount for negative amount" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "-1"})
    end

    test "partial type returns :invalid_amount for sub-cent precision" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "10.005"})
    end

    test "partial type returns :exceeds_remaining when amount is too large" do
      payment = payment_stub(%{amount_cents: 5000, refunded_amount_cents: 4500})
      assert {:error, :exceeds_remaining} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "10.00"})
    end

    test "partial type returns :invalid_amount for zero" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "0"})
    end

    test "partial type returns :invalid_amount for zero with decimal" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "0.00"})
    end

    test "partial type returns :invalid_amount for non-numeric string" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => "abc"})
    end

    test "partial type returns :invalid_amount for empty string" do
      payment = payment_stub()
      assert {:error, :invalid_amount} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "partial", "amount" => ""})
    end

    test "returns :choose_type when refund_type key is absent" do
      payment = payment_stub()
      assert {:error, :choose_type} = Refunds.parse_refund_amount(payment, %{})
    end

    test "returns :choose_type for an unrecognised refund_type value" do
      payment = payment_stub()
      assert {:error, :choose_type} =
               Refunds.parse_refund_amount(payment, %{"refund_type" => "unknown"})
    end
  end

  defp paid_booking_payment(attrs \\ %{}) do
    defaults = %{
      stripe_charge_id: "ch_TEST_#{System.unique_integer([:positive])}",
      stripe_payment_intent_id: "pi_TEST_#{System.unique_integer([:positive])}",
      stripe_checkout_session_id: "cs_TEST_#{System.unique_integer([:positive])}",
      amount_cents: 5000,
      application_fee_cents: 25,
      currency: "eur",
      status: "paid",
      paid_at: DateTime.utc_now(:second),
      refunded_amount_cents: 0,
      stripe_account_id: "acct_TEST"
    }

    insert(:booking_payment, Map.merge(defaults, Map.new(attrs)))
  end

  describe "issue_refund/3 — full refund" do
    test "transitions paid → refunded and updates refunded_amount_cents" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.charge == payment.stripe_charge_id
        assert params.amount == 5000
        assert params.refund_application_fee == true
        assert params.metadata.meeting_id == payment.meeting_id
        assert params.metadata.booking_payment_id == payment.id
        assert opts[:connect_account] == payment.stripe_account_id
        assert opts[:idempotency_key] == "refund:#{payment.id}:5000:5000"
        {:ok, %{id: "re_full"}}
      end)

      assert {:ok, updated} = Refunds.issue_refund(payment, 5000)
      assert updated.status == "refunded"
      assert updated.refunded_amount_cents == 5000

      reloaded = BookingPaymentQueries.by_charge_id(payment.stripe_charge_id)
      assert reloaded.status == "refunded"
      assert reloaded.refunded_amount_cents == 5000
    end
  end

  describe "issue_refund/3 — partial refund" do
    test "transitions paid → partially_refunded and tracks running total" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.amount == 2000
        assert opts[:idempotency_key] == "refund:#{payment.id}:2000:2000"
        {:ok, %{id: "re_partial"}}
      end)

      assert {:ok, updated} = Refunds.issue_refund(payment, 2000)
      assert updated.status == "partially_refunded"
      assert updated.refunded_amount_cents == 2000
    end

    test "second partial reaching total transitions to refunded" do
      payment = paid_booking_payment(%{refunded_amount_cents: 2000, status: "partially_refunded"})

      expect(StripeAdapterMock, :create_refund, fn params, opts ->
        assert params.amount == 3000
        # cumulative after = 2000 (existing) + 3000 (this call) = 5000
        assert opts[:idempotency_key] == "refund:#{payment.id}:5000:3000"
        {:ok, %{id: "re_top_up"}}
      end)

      assert {:ok, updated} = Refunds.issue_refund(payment, 3000)
      assert updated.status == "refunded"
      assert updated.refunded_amount_cents == 5000
    end

    test "second partial below total stays partially_refunded" do
      payment = paid_booking_payment(%{refunded_amount_cents: 1000, status: "partially_refunded"})

      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_partial2"}}
      end)

      assert {:ok, updated} = Refunds.issue_refund(payment, 1500)
      assert updated.status == "partially_refunded"
      assert updated.refunded_amount_cents == 2500
    end
  end

  describe "issue_refund/3 — validation" do
    test "rejects over-refund without calling Stripe" do
      payment = paid_booking_payment()

      assert {:error, :invalid_amount} = Refunds.issue_refund(payment, 6000)
    end

    test "rejects refund that exceeds remaining refundable balance" do
      payment = paid_booking_payment(%{refunded_amount_cents: 4500, status: "partially_refunded"})

      # remaining = 500; asking for 600 must error
      assert {:error, :invalid_amount} = Refunds.issue_refund(payment, 600)
    end

    test "rejects zero or negative amounts" do
      payment = paid_booking_payment()

      assert {:error, :invalid_amount} = Refunds.issue_refund(payment, 0)
      assert {:error, :invalid_amount} = Refunds.issue_refund(payment, -100)
    end

    test "rejects already-refunded payment" do
      payment =
        paid_booking_payment(%{
          status: "refunded",
          refunded_amount_cents: 5000
        })

      assert {:error, :already_refunded} = Refunds.issue_refund(payment, 100)
    end

    test "rejects refund outside the 60-day window" do
      old_paid_at = DateTime.add(DateTime.utc_now(:second), -61, :day)
      payment = paid_booking_payment(%{paid_at: old_paid_at})

      assert {:error, :outside_refund_window} = Refunds.issue_refund(payment, 100)
    end

    test "rejects refund when paid_at is missing" do
      payment = paid_booking_payment(%{paid_at: nil, status: "pending"})

      assert {:error, :not_paid} = Refunds.issue_refund(payment, 100)
    end
  end

  describe "issue_refund/3 — application fee handling" do
    test "omits refund_application_fee when application_fee_cents is 0" do
      payment = paid_booking_payment(%{application_fee_cents: 0})

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        refute Map.has_key?(params, :refund_application_fee)
        {:ok, %{id: "re_zero_fee"}}
      end)

      assert {:ok, updated} = Refunds.issue_refund(payment, 1000)
      assert updated.status == "partially_refunded"
    end

    test "includes refund_application_fee=true when application_fee_cents > 0" do
      payment = paid_booking_payment(%{application_fee_cents: 25})

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.refund_application_fee == true
        {:ok, %{id: "re_with_fee"}}
      end)

      assert {:ok, _payment} = Refunds.issue_refund(payment, 1000)
    end
  end

  describe "issue_refund/3 — Stripe failure" do
    test "returns the Stripe error and does not update the row" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:error, :stripe_failure}
      end)

      assert {:error, :stripe_failure} = Refunds.issue_refund(payment, 1000)

      reloaded = BookingPaymentQueries.by_charge_id(payment.stripe_charge_id)
      assert reloaded.status == "paid"
      assert reloaded.refunded_amount_cents == 0
    end
  end

  describe "issue_refund/3 — email enqueueing" do
    test "enqueues a SendBookingPaymentRefunded job after a successful refund" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:ok, %{id: "re_email"}}
      end)

      assert {:ok, _updated} = Refunds.issue_refund(payment, 5000)

      assert_enqueued(
        worker: SendBookingPaymentRefunded,
        args: %{booking_payment_id: payment.id}
      )
    end

    test "does not enqueue email when Stripe call fails" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn _params, _opts ->
        {:error, :stripe_failure}
      end)

      assert {:error, :stripe_failure} = Refunds.issue_refund(payment, 5000)

      refute_enqueued(worker: SendBookingPaymentRefunded)
    end
  end

  describe "issue_refund/3 — reason metadata" do
    test "passes the supplied reason through to Stripe" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.reason == "requested_by_customer"
        {:ok, %{id: "re_reason"}}
      end)

      assert {:ok, _payment} = Refunds.issue_refund(payment, 500, "requested_by_customer")
    end

    test "passes nil reason when none supplied" do
      payment = paid_booking_payment()

      expect(StripeAdapterMock, :create_refund, fn params, _opts ->
        assert params.reason == nil
        {:ok, %{id: "re_no_reason"}}
      end)

      assert {:ok, _payment} = Refunds.issue_refund(payment, 500)
    end
  end
end
