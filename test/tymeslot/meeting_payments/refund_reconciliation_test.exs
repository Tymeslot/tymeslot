defmodule Tymeslot.MeetingPayments.RefundReconciliationTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :payments

  alias Ecto.UUID
  alias Tymeslot.MeetingPayments.RefundReconciliation
  alias Tymeslot.MeetingPayments.RefundSchema

  @payment_id "9f0c3a52-6d0e-4c0b-9f6e-3a1d2b7c8e01"

  defp row(attrs) do
    struct!(
      %RefundSchema{
        id: UUID.generate(),
        booking_payment_id: @payment_id,
        amount_cents: 2_000,
        source: :host,
        status: :pending
      },
      attrs
    )
  end

  defp stripe_refund(status, metadata, id \\ "re_1") do
    %{"id" => id, "amount" => 2_000, "status" => status, "metadata" => metadata}
  end

  defp made_for(row, status), do: stripe_refund(status, %{"tymeslot_refund_id" => row.id})

  describe "a pending row" do
    for status <- ["succeeded", "pending", "requires_action"] do
      test "settles succeeded when Stripe reports #{status}" do
        pending = row(status: :pending)
        refund = made_for(pending, unquote(status))

        assert RefundReconciliation.plan([pending], [refund]) ==
                 [{:settle_succeeded, pending, refund}]
      end
    end

    for status <- ["failed", "canceled"] do
      test "settles failed when Stripe reports #{status}" do
        pending = row(status: :pending)
        refund = made_for(pending, unquote(status))

        assert RefundReconciliation.plan([pending], [refund]) == [
                 {:settle_failed, pending, refund}
               ]
      end
    end

    test "is matched by the Stripe refund it records when the metadata names no row" do
      pending = row(status: :pending, stripe_refund_id: "re_1")
      refund = stripe_refund("succeeded", %{})

      assert RefundReconciliation.plan([pending], [refund]) ==
               [{:settle_succeeded, pending, refund}]
    end
  end

  describe "a succeeded row" do
    for status <- ["failed", "canceled"] do
      test "fails after success when Stripe reports #{status}" do
        succeeded = row(status: :succeeded, stripe_refund_id: "re_1")
        refund = made_for(succeeded, unquote(status))

        assert RefundReconciliation.plan([succeeded], [refund]) ==
                 [{:fail_after_success, succeeded, refund}]
      end
    end

    test "a refund seen twice plans nothing the second time" do
      succeeded = row(status: :succeeded, stripe_refund_id: "re_1")

      assert RefundReconciliation.plan([succeeded], [made_for(succeeded, "succeeded")]) == []
    end

    test "a second committed Stripe refund naming it is a duplicate" do
      succeeded = row(status: :succeeded, stripe_refund_id: "re_1")
      second = stripe_refund("succeeded", %{"tymeslot_refund_id" => succeeded.id}, "re_2")

      assert RefundReconciliation.plan([succeeded], [second]) ==
               [{:duplicate, succeeded, second}]
    end

    test "a second committed Stripe refund another row records is that row's" do
      succeeded = row(status: :succeeded, stripe_refund_id: "re_1")
      other = row(status: :succeeded, stripe_refund_id: "re_2")
      second = stripe_refund("succeeded", %{"tymeslot_refund_id" => succeeded.id}, "re_2")

      assert RefundReconciliation.plan([succeeded, other], [second]) == []
    end

    test "is not taken for a second Stripe refund naming it" do
      succeeded = row(status: :succeeded, stripe_refund_id: "re_1")
      second = stripe_refund("failed", %{"tymeslot_refund_id" => succeeded.id}, "re_2")

      assert RefundReconciliation.plan([succeeded], [second]) == []
    end
  end

  describe "a failed row" do
    test "Tymeslot failed is settled succeeded when Stripe made its refund after all" do
      failed = row(status: :failed, failure_code: "retries_exhausted")
      refund = made_for(failed, "succeeded")

      assert RefundReconciliation.plan([failed], [refund]) == [
               {:settle_succeeded, failed, refund}
             ]
    end

    test "failed on another attempt's refund is settled succeeded by one Stripe made" do
      failed = row(status: :failed, failure_code: "refund_failed")
      refund = made_for(failed, "succeeded")

      assert RefundReconciliation.plan([failed], [refund]) == [
               {:settle_succeeded, failed, refund}
             ]
    end

    test "Stripe failed stays failed whatever an older report says" do
      failed = row(status: :failed, failure_code: "refund_failed", stripe_refund_id: "re_1")

      assert RefundReconciliation.plan([failed], [made_for(failed, "succeeded")]) == []
    end

    test "in its final state matching Stripe's plans nothing" do
      failed = row(status: :failed, failure_code: "refund_canceled", stripe_refund_id: "re_1")

      assert RefundReconciliation.plan([failed], [made_for(failed, "canceled")]) == []
    end
  end

  describe "a Stripe refund belonging to no row" do
    test "a dashboard refund is recorded as external" do
      refund = stripe_refund("succeeded", %{})

      assert RefundReconciliation.plan([row(status: :succeeded)], [refund]) ==
               [{:record_external, refund}]
    end

    test "a dashboard refund without metadata is recorded as external" do
      refund = Map.delete(stripe_refund("pending", %{}), "metadata")

      assert RefundReconciliation.plan([], [refund]) == [{:record_external, refund}]
    end

    for status <- ["failed", "canceled"] do
      test "a #{status} dashboard refund is not recorded" do
        assert RefundReconciliation.plan([], [stripe_refund(unquote(status), %{})]) == []
      end
    end

    test "a pre-release Tymeslot refund is ignored" do
      refund = stripe_refund("succeeded", %{"booking_payment_id" => @payment_id})

      assert RefundReconciliation.plan([], [refund]) == []
    end

    test "one naming a row that is not the payment's is ignored" do
      refund = stripe_refund("succeeded", %{"tymeslot_refund_id" => UUID.generate()})

      assert RefundReconciliation.plan([row(status: :pending)], [refund]) == []
    end
  end

  test "plans each refund of the charge in order" do
    pending = row(status: :pending)
    succeeded = row(status: :succeeded, stripe_refund_id: "re_2")
    settled = made_for(pending, "succeeded")
    failed = stripe_refund("failed", %{"tymeslot_refund_id" => succeeded.id}, "re_2")
    dashboard = stripe_refund("succeeded", %{}, "re_3")

    assert RefundReconciliation.plan([pending, succeeded], [settled, failed, dashboard]) == [
             {:settle_succeeded, pending, settled},
             {:fail_after_success, succeeded, failed},
             {:record_external, dashboard}
           ]
  end

  describe "stale_committed_cents/2" do
    test "counts what an older report still shows committed of refunds Stripe failed" do
      stripe_failed =
        row(status: :failed, failure_code: "refund_failed", stripe_refund_id: "re_1")

      tymeslot_failed = row(status: :failed, failure_code: "retries_exhausted")
      succeeded = row(status: :succeeded, stripe_refund_id: "re_3")

      report = [
        made_for(stripe_failed, "succeeded"),
        stripe_refund("succeeded", %{"tymeslot_refund_id" => tymeslot_failed.id}, "re_2"),
        stripe_refund("succeeded", %{}, "re_3"),
        stripe_refund("failed", %{}, "re_4")
      ]

      assert RefundReconciliation.stale_committed_cents(
               [stripe_failed, tymeslot_failed, succeeded],
               report
             ) == 2_000
    end

    test "is zero when the report already shows the refund ended" do
      failed = row(status: :failed, failure_code: "refund_canceled", stripe_refund_id: "re_1")

      assert RefundReconciliation.stale_committed_cents([failed], [made_for(failed, "canceled")]) ==
               0
    end
  end
end
