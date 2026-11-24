defmodule Tymeslot.Repo.Migrations.AddStripeRefundedCentsToBookingPayments do
  @moduledoc """
  Records the refunds made at Stripe in their own column, apart from the
  whole `refunded_amount_cents`, which stays capped at the amount paid.
  Derived from the whole, the refunds of a charge refunded and then lost in
  a dispute over the same money were hidden by the cap.

  Existing rows take the whole less the dispute's part, the figure every
  reader derived until now: exact for every row except one whose refunds
  and lost dispute together exceed the amount paid. Only Stripe knows
  those refunds, so `Tymeslot.Release.backfill_dispute_losses/1` corrects
  such rows from the charge. The check holds for every existing row once
  filled: the existing checks keep the dispute's part within the whole and
  the whole within `0..amount_cents`, and the fill clamps to that range in
  any case.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  #
  # The default is a constant, which PostgreSQL 11 and later apply without
  # rewriting the table. Migrations run before the application starts, so
  # the fill and the lock the constraint takes to validate existing rows
  # block no live traffic. The UPDATE is the fill the constraint relies on.
  # Only `down/0` removes a column, the one `up/0` adds; the whole it was
  # filled from is still on every row.

  def up do
    alter table(:booking_payments) do
      add :stripe_refunded_cents, :integer, default: 0, null: false
    end

    execute("""
    UPDATE booking_payments
    SET stripe_refunded_cents =
      LEAST(GREATEST(refunded_amount_cents - disputed_lost_cents, 0), amount_cents)
    WHERE refunded_amount_cents > disputed_lost_cents
    """)

    create(
      constraint(:booking_payments, :stripe_refunded_within_amount,
        check: "stripe_refunded_cents >= 0 AND stripe_refunded_cents <= amount_cents"
      )
    )
  end

  def down do
    drop(constraint(:booking_payments, :stripe_refunded_within_amount))

    alter table(:booking_payments) do
      remove :stripe_refunded_cents
    end
  end
end
