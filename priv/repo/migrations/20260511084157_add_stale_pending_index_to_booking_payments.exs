defmodule Tymeslot.Repo.Migrations.AddStalePendingIndexToBookingPayments do
  @moduledoc """
  Adds a partial composite index on `booking_payments(status, inserted_at)`
  scoped to rows where `status = 'pending' AND stripe_checkout_session_id IS NOT NULL`.

  This covers the exact predicate used by `BookingPaymentQueries.list_stale_pending/2`
  (called by `ReconcileAwaitingPayments`), replacing a full scan of the `status = 'pending'`
  partition with an index range scan on `inserted_at <= cutoff`.

  The existing `[:status]` index is kept — other queries may filter on status alone.

  Created `concurrently` so existing traffic is not blocked during index build.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    create_if_not_exists(
      index(:booking_payments, [:status, :inserted_at],
        where: "status = 'pending' AND stripe_checkout_session_id IS NOT NULL",
        concurrently: true,
        name: :booking_payments_stale_pending_index
      )
    )
  end

  def down do
    drop_if_exists(index(:booking_payments, [:status, :inserted_at],
      name: :booking_payments_stale_pending_index
    ))
  end
end
