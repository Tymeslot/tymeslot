defmodule Tymeslot.Repo.Migrations.CreateAvailabilitySchedules do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file table_dropped
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # A brand-new table has no existing rows, so its defaults, foreign key and
  # indexes cannot rewrite or lock anything. The raw SQL is the backfill below,
  # and the table drop is confined to `down/0`.

  def up do
    create table(:availability_schedules) do
      add(:profile_id, references(:profiles, on_delete: :delete_all), null: false)
      add(:name, :string, null: false)
      add(:is_default, :boolean, null: false, default: false)
      add(:buffer_minutes, :integer, null: false, default: 15)
      add(:min_advance_hours, :integer, null: false, default: 3)
      add(:advance_booking_days, :integer, null: false, default: 90)

      timestamps(type: :utc_datetime)
    end

    create(index(:availability_schedules, [:profile_id]))

    create(
      unique_index(:availability_schedules, [:profile_id],
        where: "is_default",
        name: :availability_schedules_one_default_per_profile
      )
    )

    create(unique_index(:availability_schedules, [:profile_id, :name]))

    # Backfill: every existing profile gets exactly one default schedule carrying
    # the policy values currently stored on the profile. COALESCE guards against
    # NULLs in self-hosted databases that predate the column defaults.
    execute("""
    INSERT INTO availability_schedules
      (profile_id, name, is_default, buffer_minutes, min_advance_hours,
       advance_booking_days, inserted_at, updated_at)
    SELECT
      p.id,
      'Working hours',
      true,
      COALESCE(p.buffer_minutes, 15),
      COALESCE(p.min_advance_hours, 3),
      COALESCE(p.advance_booking_days, 90),
      (NOW() AT TIME ZONE 'utc'),
      (NOW() AT TIME ZONE 'utc')
    FROM profiles AS p
    ON CONFLICT DO NOTHING
    """)
  end

  def down do
    drop(table(:availability_schedules))
  end
end
