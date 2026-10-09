defmodule Tymeslot.Repo.Migrations.AddEndsNextDayToAvailabilityWindows do
  use Ecto.Migration

  @moduledoc """
  Lets a day's availability window, and a date override's custom hours, end
  on the next day ("22:00 to 02:00 (+1)", or "00:00 to 00:00 (+1)" for a full
  24 hours).

  Every existing row gets `ends_next_day = false` and so means exactly what it
  meant before. The constraints only govern the new flag: a flagged row needs
  both times and an end at or before its start. No existing row can violate
  them, because none is flagged. The older same-day rule (end after start)
  stays in the changesets, as before: adding it here would mean healing rows
  that break it, and any heal would change what the editor shows.

  ## Rolling back

  Rolling back cuts each overnight window and override back to its same-day
  part, ending at 23:59 (the latest end the old editor could hold), the
  closest the old schema can come; the hours after midnight are lost. Breaks
  inside an overnight weekly window follow it:

    * A break that crosses midnight (it starts at or after the window's start
      and ends at or before it, as 23:30 to 00:30 does inside 22:00 to 02:00)
      is cut to end at 23:59 too. Left as stored, its end would sit before its
      start, the old engine would never match it, and the minutes before
      midnight it covered would become bookable.
    * A break wholly after midnight (01:00 to 01:30 there) is left as stored.
      The old engine reads it as an early-morning break on the window's own
      date, before the window opens, so it blocks nothing, which is right
      for hours that no longer exist.
    * A break on the same-day part is untouched.

  A window, override or crossing break starting at 23:59 or later rolls back
  empty or reversed. The old engine offers nothing in it, which is what the
  same-day part of such a window offered anyway; the old editor asks for new
  times before it saves that row again.
  """

  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file column_removed
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the locks. The default is a
  # constant, which Postgres 11+ records in the catalogue without rewriting
  # the table. Both tables hold seven rows or a handful of overrides per
  # schedule, and every row satisfies the constraints by construction. The
  # raw SQL is the rollback UPDATEs in `down/0`, and the columns
  # removed there are the ones `up/0` adds, so only a rollback drops them.

  def up do
    alter table(:weekly_availability) do
      add(:ends_next_day, :boolean, null: false, default: false)
    end

    alter table(:availability_overrides) do
      add(:ends_next_day, :boolean, null: false, default: false)
    end

    create(
      constraint(:weekly_availability, :weekly_availability_next_day_end_check,
        check: next_day_end_check()
      )
    )

    create(
      constraint(:availability_overrides, :availability_overrides_next_day_end_check,
        check: next_day_end_check()
      )
    )
  end

  def down do
    # The constraints go first: a cut-back row (22:00 to 23:59, still
    # flagged until the column goes) is exactly what they refuse.
    drop(constraint(:availability_overrides, :availability_overrides_next_day_end_check))
    drop(constraint(:weekly_availability, :weekly_availability_next_day_end_check))

    # Breaks first, while their windows still say where midnight falls.
    execute("""
    UPDATE availability_breaks AS b
    SET end_time = '23:59:00'
    FROM weekly_availability AS wa
    WHERE b.weekly_availability_id = wa.id
      AND wa.ends_next_day
      AND b.start_time >= wa.start_time
      AND b.end_time <= wa.start_time
    """)

    execute("UPDATE weekly_availability SET end_time = '23:59:00' WHERE ends_next_day")
    execute("UPDATE availability_overrides SET end_time = '23:59:00' WHERE ends_next_day")

    alter table(:availability_overrides) do
      remove(:ends_next_day)
    end

    alter table(:weekly_availability) do
      remove(:ends_next_day)
    end
  end

  defp next_day_end_check do
    "NOT ends_next_day OR (start_time IS NOT NULL AND end_time IS NOT NULL AND end_time <= start_time)"
  end
end
