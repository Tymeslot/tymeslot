defmodule Tymeslot.MeetingPayments.LifetimeStatsQueriesTest do
  @moduledoc """
  The query behind the payments screen's lifetime totals. A host who changed
  their default currency holds money in more than one, and adding 100 EUR to
  50 CHF gives a number that means nothing, so the totals come back per
  currency.
  """

  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory

  @moduletag :database
  @moduletag :payments
  @moduletag :queries

  alias Tymeslot.MeetingPayments.BookingPayments

  test "totals each currency separately" do
    insert(:paid_booking_payment,
      host_user_id: 7,
      currency: "eur",
      amount_cents: 10_000,
      application_fee_cents: 50
    )

    insert(:paid_booking_payment,
      host_user_id: 7,
      currency: "eur",
      status: :partially_refunded,
      amount_cents: 2_000,
      refunded_amount_cents: 1_000,
      stripe_refunded_cents: 1_000,
      application_fee_cents: 10
    )

    insert(:paid_booking_payment,
      host_user_id: 7,
      currency: "chf",
      amount_cents: 5_000,
      application_fee_cents: 25
    )

    assert BookingPayments.lifetime_stats_for_host(7) == [
             %{currency: "chf", received: 5_000, refunded: 0, platform_fee: 25},
             %{currency: "eur", received: 12_000, refunded: 1_000, platform_fee: 55}
           ]
  end

  # Refunds ask Stripe to return the fee too, in proportion to the amount
  # refunded, so the host no longer pays the returned part.
  test "takes the fee Stripe returned with each refund off the platform fee" do
    insert(:paid_booking_payment,
      host_user_id: 7,
      status: :refunded,
      amount_cents: 2_500,
      refunded_amount_cents: 2_500,
      stripe_refunded_cents: 2_500,
      application_fee_cents: 13
    )

    insert(:paid_booking_payment,
      host_user_id: 7,
      status: :partially_refunded,
      amount_cents: 2_500,
      refunded_amount_cents: 1_000,
      stripe_refunded_cents: 1_000,
      application_fee_cents: 13
    )

    # A lost dispute takes money without a refund, so no fee comes back.
    insert(:paid_booking_payment,
      host_user_id: 7,
      status: :partially_refunded,
      amount_cents: 2_000,
      refunded_amount_cents: 500,
      disputed_lost_cents: 500,
      application_fee_cents: 10
    )

    assert [%{currency: "eur", platform_fee: platform_fee}] =
             BookingPayments.lifetime_stats_for_host(7)

    # 0 for the full refund, 13 - round(13 * 1_000 / 2_500) = 8, and 10.
    assert platform_fee == 18
  end

  # A refund made in the Stripe dashboard is recorded as external and returns
  # no fee; only Tymeslot's own refund beside it does.
  test "a refund made in the Stripe dashboard returns no platform fee" do
    payment =
      insert(:paid_booking_payment,
        host_user_id: 7,
        status: :partially_refunded,
        amount_cents: 2_500,
        refunded_amount_cents: 1_500,
        stripe_refunded_cents: 1_500,
        application_fee_cents: 13
      )

    insert(:booking_payment_refund,
      booking_payment: payment,
      source: :host,
      status: :succeeded,
      amount_cents: 1_000
    )

    insert(:booking_payment_refund,
      booking_payment: payment,
      source: :external,
      status: :succeeded,
      amount_cents: 500
    )

    assert [%{currency: "eur", platform_fee: platform_fee}] =
             BookingPayments.lifetime_stats_for_host(7)

    # Only Tymeslot's 1_000 returns fee: 13 - round(13 * 1_000 / 2_500) = 8.
    assert platform_fee == 8
  end

  test "leaves out pending payments and other hosts' payments" do
    insert(:booking_payment, host_user_id: 7, status: :pending)
    insert(:paid_booking_payment, host_user_id: 8)

    assert BookingPayments.lifetime_stats_for_host(7) == []
  end
end
