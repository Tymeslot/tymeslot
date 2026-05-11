defmodule Tymeslot.Repo.Migrations.AddHostDeletedAtIndexToPaymentTransactions do
  @moduledoc """
  Adds a concurrent index on `payment_transactions(host_deleted_at)` to support
  efficient data-retention queries that filter by deletion date.

  Extracted from `20260508164247_add_retention_columns_to_payment_transactions.exs`
  which originally built this index inside a DDL transaction, causing a full
  AccessExclusiveLock for the duration.
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    execute("CREATE INDEX CONCURRENTLY IF NOT EXISTS payment_transactions_host_deleted_at_index ON payment_transactions (host_deleted_at)")
  end

  def down do
    execute("DROP INDEX CONCURRENTLY IF EXISTS payment_transactions_host_deleted_at_index")
  end
end
