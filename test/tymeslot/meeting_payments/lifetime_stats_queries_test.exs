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

  alias Tymeslot.MeetingPayments

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
      status: "partially_refunded",
      amount_cents: 2_000,
      refunded_amount_cents: 500,
      application_fee_cents: 10
    )

    insert(:paid_booking_payment,
      host_user_id: 7,
      currency: "chf",
      amount_cents: 5_000,
      application_fee_cents: 25
    )

    assert MeetingPayments.lifetime_stats_for_host(7) == [
             %{currency: "chf", received: 5_000, refunded: 0, platform_fee: 25},
             %{currency: "eur", received: 12_000, refunded: 500, platform_fee: 60}
           ]
  end

  test "leaves out pending payments and other hosts' payments" do
    insert(:booking_payment, host_user_id: 7, status: "pending")
    insert(:paid_booking_payment, host_user_id: 8)

    assert MeetingPayments.lifetime_stats_for_host(7) == []
  end
end
