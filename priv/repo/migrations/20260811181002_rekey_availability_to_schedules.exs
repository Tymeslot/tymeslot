defmodule Tymeslot.Repo.Migrations.RekeyAvailabilityToSchedules do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file column_removed
  # excellent_migrations:safety-assured-for-this-file column_type_changed
  # excellent_migrations:safety-assured-for-this-file not_null_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Tymeslot deploys as a single instance (a self-hosted container or one
  # Cloudron instance) and migrates with the app stopped, so a brief table lock
  # is acceptable. The backfill and the orphan sweep must run in the same
  # transaction as the constraint, or a partially migrated database would be
  # left with unusable availability rows.

  def up do
    alter table(:weekly_availability) do
      add(:schedule_id, references(:availability_schedules, on_delete: :delete_all))
    end

    alter table(:availability_overrides) do
      add(:schedule_id, references(:availability_schedules, on_delete: :delete_all))
    end

    execute("""
    UPDATE weekly_availability AS wa
    SET schedule_id = s.id
    FROM availability_schedules AS s
    WHERE s.profile_id = wa.profile_id AND s.is_default
    """)

    execute("""
    UPDATE availability_overrides AS ao
    SET schedule_id = s.id
    FROM availability_schedules AS s
    WHERE s.profile_id = ao.profile_id AND s.is_default
    """)

    # Rows whose profile no longer exists cannot be attached to a schedule. They
    # are already unreachable through the application; drop them so the NOT NULL
    # constraint below can be added.
    execute("DELETE FROM weekly_availability WHERE schedule_id IS NULL")
    execute("DELETE FROM availability_overrides WHERE schedule_id IS NULL")

    # Removing profile_id also drops the (profile_id, day_of_week) and
    # (profile_id, date) unique indexes that depend on it.
    alter table(:weekly_availability) do
      modify(:schedule_id, :bigint, null: false)
      remove(:profile_id)
    end

    alter table(:availability_overrides) do
      modify(:schedule_id, :bigint, null: false)
      remove(:profile_id)
    end

    create(unique_index(:weekly_availability, [:schedule_id, :day_of_week]))
    create(unique_index(:availability_overrides, [:schedule_id, :date]))
  end

  def down do
    raise Ecto.MigrationError,
      message:
        "rekey_availability_to_schedules is irreversible: profile_id was dropped after backfill"
  end
end
