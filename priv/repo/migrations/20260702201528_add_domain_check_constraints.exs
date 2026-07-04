defmodule Tymeslot.Repo.Migrations.AddDomainCheckConstraints do
  @moduledoc """
  Adds domain-invariant check constraints that the schemas assume but the DB
  did not enforce:

    * meetings.end_time > start_time
    * payment_transactions.amount / tax_amount / discount_amount >= 0

  Added as NOT VALID: the constraints are enforced for every new and updated
  row immediately, but existing rows are not scanned. This avoids failing the
  migration on an open-source install carrying unknown legacy data we cannot
  auto-repair (we can't invent a valid end_time or a correct amount). An
  operator can `VALIDATE CONSTRAINT` later once legacy rows are known clean.

  All checks are NULL-tolerant (a NULL column yields an unknown result, which
  passes), so nullable columns are unaffected.
  """

  use Ecto.Migration

  @constraints [
    {"meetings", "meetings_end_after_start", "end_time > start_time"},
    {"payment_transactions", "payment_transactions_amount_non_negative", "amount >= 0"},
    {"payment_transactions", "payment_transactions_tax_amount_non_negative", "tax_amount >= 0"},
    {"payment_transactions", "payment_transactions_discount_amount_non_negative",
     "discount_amount >= 0"}
  ]

  def up do
    for {table, name, check} <- @constraints do
      execute("ALTER TABLE #{table} ADD CONSTRAINT #{name} CHECK (#{check}) NOT VALID")
    end
  end

  def down do
    for {table, name, _check} <- @constraints do
      execute("ALTER TABLE #{table} DROP CONSTRAINT #{name}")
    end
  end
end
