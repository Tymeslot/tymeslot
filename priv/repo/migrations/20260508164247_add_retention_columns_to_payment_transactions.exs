defmodule Tymeslot.Repo.Migrations.AddRetentionColumnsToPaymentTransactions do
  @moduledoc """
  Brings payment_transactions in line with the retention design used for
  booking_payments:
    - FK on user_id changed to :nilify_all so rows survive user deletion
    - Snapshot columns (host_email, host_name) backfilled from users
    - host_deleted_at marker for retention queries

  host_name is backfilled from users.name (the existing display-name column
  on Tymeslot.Auth.UserSchema). Both snapshot columns are nullable; rows
  whose user has no name fall back to NULL.

  ## Rollback

  This migration is irreversible. Once the :nilify_all cascade is in place,
  any host deletion nilifies user_id on existing rows. Re-adding the NOT NULL
  FK with on_delete: :delete_all would abort if any such rows exist, leaving
  the database in a broken intermediate state (index gone, columns present,
  FK partially applied). Tax-compliance data must never be silently destroyed
  by a partial rollback — raise instead so the operator can make an explicit,
  informed decision.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:payment_transactions, "payment_transactions_user_id_fkey"))

    alter table(:payment_transactions) do
      modify(:user_id, references(:users, on_delete: :nilify_all), null: true)
      add(:host_email, :string)
      add(:host_name, :string)
      add(:host_deleted_at, :utc_datetime)
    end

    # Backfill snapshot columns from the users table so existing rows carry
    # their host identity forward when the user is later deleted.
    execute("""
    UPDATE payment_transactions pt
    SET host_email = u.email,
        host_name = u.name
    FROM users u
    WHERE pt.user_id = u.id;
    """)

    create(index(:payment_transactions, [:host_deleted_at]))
  end

  def down do
    raise "irreversible migration: nilified user_id rows cannot have a NOT NULL FK re-applied without destroying tax-compliance data"
  end
end
