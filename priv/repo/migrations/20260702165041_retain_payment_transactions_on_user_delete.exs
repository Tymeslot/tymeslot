defmodule Tymeslot.Repo.Migrations.RetainPaymentTransactionsOnUserDelete do
  @moduledoc """
  Restores the tax-record retention design for payment_transactions.

  History: 20260508164247 deliberately set the user_id FK to :nilify_all so
  financial rows survive a user deletion (EU/Swiss commercial-law retention,
  GDPR Art. 17(3)(b) carve-out). A later migration, 20260603080550, reverted
  it to :delete_all on the mistaken premise that :nilify_all was pre-release
  drift — which quietly re-armed a hard delete of tax records.

  This re-asserts :nilify_all with a nullable column. Deletion survival is
  still guaranteed primarily by DataRetention.anonymise_host/1 nilifying
  user_id before the user row is removed; the FK is the DB-level safety net
  for any row that pre-pass misses or a future reordering, so a missed row is
  orphaned (recoverable) rather than destroyed.
  """

  use Ecto.Migration

  def up do
    drop(constraint(:payment_transactions, "payment_transactions_user_id_fkey"))

    alter table(:payment_transactions) do
      modify(:user_id, references(:users, on_delete: :nilify_all), null: true)
    end
  end

  def down do
    raise "irreversible migration: re-applying :delete_all would re-arm destruction of retained tax records"
  end
end
