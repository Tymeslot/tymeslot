defmodule Tymeslot.Repo.Migrations.AddAdminBootstrappedAtToAppSettings do
  use Ecto.Migration

  # When the first-user-becomes-admin bootstrap closed. `Tymeslot.Auth.AdminBootstrap`
  # promotes a sign-up only while this is nil and sets it in the same
  # transaction, so the gate is a one-way latch rather than "is this user the
  # only row right now", which reopened whenever the table emptied again.
  #
  # An install that already has users is past its bootstrap, whether or not an
  # admin survives, so it is latched here. A fresh install stays nil and its
  # first sign-up is promoted as before.
  # `add_if_not_exists` and the COALESCE below make `up` safe to re-apply
  # over an already-migrated table: an existing timestamp is kept.
  def up do
    alter table(:app_settings) do
      add_if_not_exists(:admin_bootstrapped_at, :utc_datetime)
    end

    flush()

    # The singleton row is seeded by the create_app_settings migration, but an
    # install could have lost it; the upsert covers that case. A single row on
    # a one-row table.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    INSERT INTO app_settings (id, admin_bootstrapped_at, inserted_at, updated_at)
    SELECT 1,
           date_trunc('second', NOW() AT TIME ZONE 'UTC'),
           NOW() AT TIME ZONE 'UTC',
           NOW() AT TIME ZONE 'UTC'
    WHERE EXISTS (SELECT 1 FROM users)
    ON CONFLICT (id) DO UPDATE
      SET admin_bootstrapped_at =
        COALESCE(app_settings.admin_bootstrapped_at, EXCLUDED.admin_bootstrapped_at)
    """)
  end

  def down do
    alter table(:app_settings) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:admin_bootstrapped_at)
    end
  end
end
