defmodule Tymeslot.Repo.Migrations.SplitAvailabilityScheduleBuffers do
  use Ecto.Migration

  @moduledoc """
  Replaces each schedule's single `buffer_minutes`, applied to both sides of
  every booking, with `buffer_before_minutes` and `buffer_after_minutes`.

  Both new values start as a copy of the old one. For an equal pair, padding
  the new booking and padding the busy time are the same rule, so no schedule
  offers a different slot after this runs.

  The old column never had a range constraint, so a self-hosted database can
  hold values no form would accept (the dirty seed carries one). The backfill
  clamps them into 0..120 before the range constraints are added, which is
  what lets those constraints be created over existing rows.

  Rolling back keeps the larger of the two buffers, so a schedule never
  offers a slot after rollback that its asymmetric pair would have refused.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file column_removed
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the locks. The defaults are
  # constants, which Postgres 11+ records in the catalogue without rewriting
  # the table. The raw SQL is the single backfill UPDATE below, and every row
  # satisfies the range constraints by the time they are created. The old
  # column is removed only after its values are copied out, and nothing in
  # the application reads it from this release on.

  def up do
    alter table(:availability_schedules) do
      add(:buffer_before_minutes, :integer, null: false, default: 15)
      add(:buffer_after_minutes, :integer, null: false, default: 15)
    end

    execute("""
    UPDATE availability_schedules
    SET buffer_before_minutes = LEAST(GREATEST(buffer_minutes, 0), 120),
        buffer_after_minutes = LEAST(GREATEST(buffer_minutes, 0), 120)
    """)

    create(
      constraint(:availability_schedules, :availability_schedules_buffer_before_minutes_range,
        check: "buffer_before_minutes BETWEEN 0 AND 120"
      )
    )

    create(
      constraint(:availability_schedules, :availability_schedules_buffer_after_minutes_range,
        check: "buffer_after_minutes BETWEEN 0 AND 120"
      )
    )

    alter table(:availability_schedules) do
      remove(:buffer_minutes)
    end
  end

  def down do
    alter table(:availability_schedules) do
      add(:buffer_minutes, :integer, null: false, default: 15)
    end

    execute("""
    UPDATE availability_schedules
    SET buffer_minutes = GREATEST(buffer_before_minutes, buffer_after_minutes)
    """)

    drop(constraint(:availability_schedules, :availability_schedules_buffer_after_minutes_range))
    drop(constraint(:availability_schedules, :availability_schedules_buffer_before_minutes_range))

    alter table(:availability_schedules) do
      remove(:buffer_after_minutes)
      remove(:buffer_before_minutes)
    end
  end
end
