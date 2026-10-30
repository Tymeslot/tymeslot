defmodule Tymeslot.Repo.Migrations.AddStatusCheckToConnectAccounts do
  use Ecto.Migration

  @moduledoc """
  Closes the `connect_accounts.status` vocabulary at the database layer,
  matching the `Ecto.Enum` the schema now declares. `Ecto.Enum` raises on load
  for a value outside its list, so a stray row would break every read of it.

  Any row already outside the set is backfilled from the facts the row itself
  records, which is what each status means: a soft-deleted row (`deleted_at`
  set) becomes `deleted`, a row that holds a Stripe account id becomes
  `active`, and anything else is an unfinished placeholder, `creating`. The
  column is `NOT NULL`, so there are no NULLs to repair.
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
    UPDATE connect_accounts
    SET status = CASE
      WHEN deleted_at IS NOT NULL THEN 'deleted'
      WHEN stripe_account_id IS NOT NULL THEN 'active'
      ELSE 'creating'
    END
    WHERE status NOT IN ('creating', 'active', 'deleted')
    """)

    create(
      constraint(:connect_accounts, :connect_accounts_status_must_be_known,
        check: "status IN ('creating', 'active', 'deleted')"
      )
    )
  end

  def down do
    drop(constraint(:connect_accounts, :connect_accounts_status_must_be_known))
  end
end
