defmodule Tymeslot.Migrations.AddStripeRefundedCentsToBookingPaymentsTest do
  @moduledoc """
  Verifies `20261124084318_add_stripe_refunded_cents_to_booking_payments`
  fills the refunds made of existing rows as the refunded whole less a lost
  dispute's part, and then bounds the column by the amount paid.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :payments
  @moduletag :database
  @moduletag :migrations

  alias Ecto.UUID
  alias Tymeslot.Repo
  alias Tymeslot.Test.MigrationRunner

  @version 20_261_124_084_318

  test "fills the refunds made from the whole and the dispute's part" do
    paid = insert(:paid_booking_payment, amount_cents: 10_000)
    refunded = insert(:paid_booking_payment, amount_cents: 10_000, refunded_amount_cents: 4_000)

    partly_lost =
      insert(:paid_booking_payment,
        amount_cents: 10_000,
        refunded_amount_cents: 10_000,
        disputed_lost_cents: 6_000
      )

    only_lost =
      insert(:paid_booking_payment,
        amount_cents: 10_000,
        refunded_amount_cents: 6_000,
        disputed_lost_cents: 6_000
      )

    MigrationRunner.rerun!(@version)

    assert Repo.reload!(paid).stripe_refunded_cents == 0
    assert Repo.reload!(refunded).stripe_refunded_cents == 4_000
    assert Repo.reload!(partly_lost).stripe_refunded_cents == 4_000
    assert Repo.reload!(only_lost).stripe_refunded_cents == 0

    assert_raise Postgrex.Error, ~r/stripe_refunded_within_amount/, fn ->
      Repo.query!("UPDATE booking_payments SET stripe_refunded_cents = 10001 WHERE id = $1", [
        UUID.dump!(paid.id)
      ])
    end
  end
end
