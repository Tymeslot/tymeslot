defmodule Tymeslot.Repo.Migrations.AddStatusCheckToPaymentTransactions do
  use Ecto.Migration

  @moduledoc """
  Closes the `payment_transactions.status` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Backfills any row already outside the set to `failed` before adding the
  constraint. `failed` is the only inert choice: `completed` would count an
  unconfirmed row as revenue and as a subscription ownership signal, and
  `pending` would collide with the one-pending-transaction-per-user unique
  index and be picked up by the abandoned-checkout sweep. The column is
  `NOT NULL`, so there are no NULLs to repair.
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
    UPDATE payment_transactions
    SET status = 'failed'
    WHERE status NOT IN ('pending', 'completed', 'failed', 'pending_reconciliation')
    """)

    create(
      constraint(:payment_transactions, :payment_transactions_status_must_be_known,
        check: "status IN ('pending', 'completed', 'failed', 'pending_reconciliation')"
      )
    )
  end

  def down do
    drop(constraint(:payment_transactions, :payment_transactions_status_must_be_known))
  end
end
