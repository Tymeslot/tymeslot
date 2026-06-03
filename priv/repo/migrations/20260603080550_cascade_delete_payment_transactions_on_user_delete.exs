defmodule Tymeslot.Repo.Migrations.CascadeDeletePaymentTransactionsOnUserDelete do
  use Ecto.Migration

  # Repair migration. The original `create_payment_transactions` migration
  # declared the user FK as `on_delete: :delete_all`, but databases that ran a
  # pre-release variant of that migration ended up with `:nilify_all` (ON DELETE
  # SET NULL) instead, leaving orphaned payment rows after a user exercises their
  # right-to-delete. Re-assert the cascade so every database converges on the
  # intended behaviour. On databases that already have `:delete_all` this is a
  # harmless drop-and-recreate of the same constraint.
  #
  # The column's NULL constraint is deliberately left untouched (no `null:`
  # option), so this neither relaxes a correct NOT NULL column nor fails on a
  # drifted nullable one.

  def change do
    drop(constraint(:payment_transactions, "payment_transactions_user_id_fkey"))

    alter table(:payment_transactions) do
      modify(:user_id, references(:users, on_delete: :delete_all))
    end
  end
end
