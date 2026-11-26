defmodule Tymeslot.Repo.Migrations.AddDisputedLostCentsToBookingPayments do
  @moduledoc """
  Records how much of `refunded_amount_cents` a lost dispute took back,
  apart from the refunds made at Stripe, so the refunds can be compared
  with Stripe's own refunded total for the charge, which never counts a
  dispute.

  Existing rows start at 0. Nothing a row records tells a lost dispute from
  a won one after earlier refunds (the dispute's amount is not kept), so a
  row whose dispute was lost before this column existed keeps counting the
  loss as refunds, as it did before. The check holds for every existing row
  without a backfill: 0 is within `0..refunded_amount_cents` whatever the
  refunded total is.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # The default is a constant, which PostgreSQL 11 and later apply without
  # rewriting the table. Migrations run before the application starts, so
  # the lock the constraint takes to validate existing rows blocks no live
  # traffic.

  def change do
    alter table(:booking_payments) do
      add :disputed_lost_cents, :integer, default: 0, null: false
    end

    create(
      constraint(:booking_payments, :disputed_lost_within_refunded,
        check: "disputed_lost_cents >= 0 AND disputed_lost_cents <= refunded_amount_cents"
      )
    )
  end
end
