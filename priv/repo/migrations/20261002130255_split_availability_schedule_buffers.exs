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

  This is the expand half of an expand/contract change: `buffer_minutes`
  stays in place, unread, so the previous release keeps working against this
  schema. Its schema selects the column on every slot calculation, so it must
  exist for an image rolled back without running `down/0`, and for the
  previous release still serving requests while a zero-downtime deploy
  overlaps the two. The column keeps its `NOT NULL DEFAULT 15`, so inserts
  from this release, which no longer set it, still succeed. Nothing keeps it
  in sync with the new pair: an image rollback sees each schedule's buffer as
  it stood at upgrade time (15 for schedules created since), the same
  trade-off the theme settings migration made. The column is dropped in a
  later release.

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
  # the table. The raw SQL is the backfill UPDATE in each direction, and every
  # row satisfies the range constraints by the time they are created. Only
  # `down/0` removes columns, the two this migration added, after their
  # values are folded back into `buffer_minutes`; `up/0` removes nothing.

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

    # `buffer_minutes` is deliberately left in place; see the moduledoc.
  end

  def down do
    # Restores the column on a database that ran the earlier draft of this
    # migration, which dropped it; a no-op everywhere else.
    alter table(:availability_schedules) do
      add_if_not_exists(:buffer_minutes, :integer, null: false, default: 15)
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
