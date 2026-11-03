defmodule Tymeslot.Repo.Migrations.AddStatusCheckToBookingPayments do
  use Ecto.Migration

  @moduledoc """
  Closes the `booking_payments.status` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Any row already outside the set is backfilled from the money the row itself
  records, the same derivation the refund webhooks use: fully refunded becomes
  `refunded`, partly refunded `partially_refunded`, captured (`paid_at` set)
  `paid`, and a row that never took money `failed`, so it is neither swept as a
  live checkout nor offered for refund. A dispute cannot be told from the row
  alone, so no stray row is promoted to `disputed`. The column is `NOT NULL`,
  so there are no NULLs to repair.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  #
  # Migrations run offline: `start.sh` executes them in a one-shot VM and only
  # starts Phoenix once they finish, so the ACCESS EXCLUSIVE lock the constraint
  # takes to validate existing rows blocks no live traffic. Revisit this if a
  # deployment target ever migrates against a running instance. The raw UPDATE
  # is the backfill that constraint needs: it has no changeset to run through,
  # and it must repair the rows before the constraint can accept them.
  def up do
    execute("""
    UPDATE booking_payments
    SET status = CASE
      WHEN refunded_amount_cents > 0 AND refunded_amount_cents >= amount_cents THEN 'refunded'
      WHEN refunded_amount_cents > 0 THEN 'partially_refunded'
      WHEN paid_at IS NOT NULL THEN 'paid'
      ELSE 'failed'
    END
    WHERE status NOT IN
      ('pending', 'paid', 'failed', 'refunded', 'partially_refunded', 'disputed')
    """)

    create(
      constraint(:booking_payments, :booking_payments_status_must_be_known,
        check:
          "status IN ('pending', 'paid', 'failed', 'refunded', 'partially_refunded', 'disputed')"
      )
    )
  end

  def down do
    drop(constraint(:booking_payments, :booking_payments_status_must_be_known))
  end
end
