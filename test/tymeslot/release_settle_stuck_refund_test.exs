defmodule Tymeslot.ReleaseSettleStuckRefundTest do
  @moduledoc """
  An operator records how a refund Tymeslot cannot ask Stripe about ended
  (a Connect account the host revoked), from what Stripe's dashboard shows,
  and the refund settles under the same rules as one an attempt or a
  webhook settles.
  """

  # async: false: admin alerts are captured through application env.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :payments
  @moduletag :integration
  @moduletag :capture_log

  import ExUnit.CaptureIO
  import Tymeslot.AdminAlertsCaptureHelpers
  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.BookingPaymentQueries
  alias Tymeslot.MeetingPayments.RefundQueries
  alias Tymeslot.Release
  alias Tymeslot.Workers.SendBookingPaymentRefunded
  alias Tymeslot.Workers.SendRefundFailed

  setup :capture_admin_alerts

  setup do
    payment = insert(:paid_booking_payment, amount_cents: 5_000)
    refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 2_000)
    %{payment: payment, refund: refund}
  end

  defp settle(refund_id, outcome) do
    with_io(fn -> Release.settle_stuck_refund(refund_id, outcome) end)
  end

  describe "settling a stuck refund as made at Stripe" do
    test "records the Stripe refund, raises the payment's figures and emails the attendee",
         %{payment: payment, refund: refund} do
      {result, output} = settle(refund.id, {:succeeded, "re_BY_HAND", 2_000})

      assert {:ok, %{status: :succeeded}} = result

      assert %{status: :succeeded, stripe_refund_id: "re_BY_HAND", executing_until: nil} =
               RefundQueries.get(refund.id)

      assert %{
               stripe_refunded_cents: 2_000,
               refunded_amount_cents: 2_000,
               status: :partially_refunded
             } = BookingPaymentQueries.get(payment.id)

      assert_enqueued(worker: SendBookingPaymentRefunded, args: %{booking_payment_id: payment.id})
      refute_received {:send_alert, :refund_failed, _payload}

      assert output =~ ~r/BEFORE refund #{refund.id} pending/
      assert output =~ ~r/BEFORE payment #{payment.id} paid .*refunded 0 of 5000/
      assert output =~ ~r/AFTER refund #{refund.id} succeeded .*re_BY_HAND/
      assert output =~ ~r/AFTER payment #{payment.id} partially_refunded .*refunded 2000 of 5000/
      assert output =~ ~r/\nSETTLED: /
    end

    test "never lowers the refunds already recorded when Stripe's total given is below them" do
      payment = insert(:paid_booking_payment, amount_cents: 5_000, refunded_amount_cents: 3_000)
      refund = insert(:booking_payment_refund, booking_payment: payment, amount_cents: 1_000)

      {result, _output} = settle(refund.id, {:succeeded, "re_LOW_TOTAL", 2_000})

      assert {:ok, %{status: :succeeded}} = result

      assert %{stripe_refunded_cents: 3_000, refunded_amount_cents: 3_000} =
               BookingPaymentQueries.get(payment.id)
    end
  end

  describe "settling a stuck refund as never made" do
    test "fails it by hand, tells the host and leaves the payment's figures alone" do
      payment =
        insert(:paid_booking_payment,
          amount_cents: 5_000,
          refunded_amount_cents: 1_000,
          status: :partially_refunded
        )

      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          amount_cents: 2_000,
          source: :host
        )

      {result, output} = settle(refund.id, :failed)

      assert {:ok, %{status: :failed}} = result

      assert %{status: :failed, failure_code: "settled_by_hand", stripe_refund_id: nil} =
               RefundQueries.get(refund.id)

      assert %{
               stripe_refunded_cents: 1_000,
               refunded_amount_cents: 1_000,
               status: :partially_refunded
             } = BookingPaymentQueries.get(payment.id)

      refund_id = refund.id
      assert_received {:send_alert, :refund_failed, %{refund_id: ^refund_id}}
      assert_enqueued(worker: SendRefundFailed, args: %{refund_id: refund.id})
      refute_enqueued(worker: SendBookingPaymentRefunded)

      assert output =~ ~r/AFTER refund #{refund.id} failed .*settled_by_hand/
      assert output =~ ~r/\nSETTLED: /
    end
  end

  describe "refusals" do
    test "a refund no longer pending is refused and left as it is", %{payment: payment} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          status: :succeeded,
          stripe_refund_id: "re_ALREADY",
          settled_at: DateTime.utc_now(:second)
        )

      {result, output} = settle(refund.id, :failed)

      assert {:error, :not_pending} = result
      assert %{status: :succeeded, failure_code: nil} = RefundQueries.get(refund.id)
      assert output =~ ~r/\nREFUSED: .*succeeded/
      refute_received {:send_alert, :refund_failed, _payload}
    end

    test "a refund an attempt holds now is refused and left pending", %{payment: payment} do
      refund =
        insert(:booking_payment_refund,
          booking_payment: payment,
          executing_until: DateTime.add(DateTime.utc_now(:second), 300)
        )

      {result, output} = settle(refund.id, {:succeeded, "re_IN_FLIGHT", 1_000})

      assert {:error, :attempt_in_flight} = result
      assert %{status: :pending, stripe_refund_id: nil} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0} = BookingPaymentQueries.get(payment.id)
      assert output =~ ~r/\nREFUSED: an attempt/
    end

    test "an unknown or malformed refund id is refused" do
      for id <- [UUID.generate(), "not-a-uuid"] do
        {result, output} = settle(id, :failed)

        assert {:error, :not_found} = result
        assert output =~ ~r/^REFUSED: no refund/m
      end
    end

    test "a malformed outcome is refused and the refund left pending",
         %{payment: payment, refund: refund} do
      outcomes = [
        {:succeeded, "ch_NOT_A_REFUND", 2_000},
        {:succeeded, "re_X", "2000"},
        {:succeeded, "re_X"},
        :succeeded,
        {:failed, "re_X"},
        "failed"
      ]

      for outcome <- outcomes do
        {result, output} = settle(refund.id, outcome)

        assert {:error, :invalid_outcome} = result, "accepted #{inspect(outcome)}"
        assert output =~ ~r/\nREFUSED: /
      end

      assert %{status: :pending} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0} = BookingPaymentQueries.get(payment.id)
    end

    test "a charge total that cannot include the refund, or exceeds the amount paid, is refused",
         %{payment: payment, refund: refund} do
      for total <- [1_999, 5_001] do
        {result, output} = settle(refund.id, {:succeeded, "re_X", total})

        assert {:error, :charge_total_out_of_range} = result
        assert output =~ ~r/\nREFUSED: .*between 2000 and 5000/
      end

      assert %{status: :pending} = RefundQueries.get(refund.id)
      assert %{refunded_amount_cents: 0} = BookingPaymentQueries.get(payment.id)
    end
  end
end
