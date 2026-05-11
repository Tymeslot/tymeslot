defmodule Tymeslot.Repo.Migrations.AddConnectAccountsUserIdUniqueIndex do
  @moduledoc """
  Adds a partial unique index on `connect_accounts.user_id` scoped to live
  (non-deleted) rows, preventing two concurrent Stripe Connect onboarding
  requests for the same user from racing and creating duplicate placeholder
  rows.

  Also tightens the existing `stripe_account_id` partial unique index to
  exclude soft-deleted rows, allowing a host who disconnects and re-connects
  to reuse the same Stripe account ID on a fresh row.

  Both indexes are created with `create_if_not_exists` so this migration is
  safe to replay on a database that already has them (self-healing).
  """

  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    # Partial unique index: one live (non-deleted) row per user.
    create_if_not_exists(
      unique_index(
        :connect_accounts,
        [:user_id],
        where: "deleted_at IS NULL",
        name: :connect_accounts_user_id_live_unique_index,
        concurrently: true
      )
    )

    # Tighten the stripe_account_id uniqueness constraint to live rows only,
    # so a re-connect after a disconnect can reuse the same Stripe account ID.
    # Drop the old index first (it may not exist on fresh installs, hence the
    # raw SQL with IF EXISTS rather than `drop index`).
    execute("""
    DROP INDEX CONCURRENTLY IF EXISTS connect_accounts_stripe_account_id_index;
    """)

    create_if_not_exists(
      unique_index(
        :connect_accounts,
        [:stripe_account_id],
        where: "stripe_account_id IS NOT NULL AND deleted_at IS NULL",
        name: :connect_accounts_stripe_account_id_live_unique_index,
        concurrently: true
      )
    )
  end

  def down do
    drop_if_exists(
      unique_index(:connect_accounts, [:user_id],
        name: :connect_accounts_user_id_live_unique_index
      )
    )

    drop_if_exists(
      unique_index(:connect_accounts, [:stripe_account_id],
        name: :connect_accounts_stripe_account_id_live_unique_index
      )
    )

    # Restore the original non-deleted-aware stripe_account_id unique index.
    create_if_not_exists(
      unique_index(
        :connect_accounts,
        [:stripe_account_id],
        where: "stripe_account_id IS NOT NULL",
        concurrently: true
      )
    )
  end
end
