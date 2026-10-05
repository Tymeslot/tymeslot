defmodule Tymeslot.Repo.Migrations.RewriteAvailabilityWindowsEndingAtMidnight do
  use Ecto.Migration

  @moduledoc """
  Turns windows ending at 23:59 into windows ending at midnight, "00:00 (+1)".

  Before hours could end on the next day, 23:59 was the latest end the editor
  could reach, so it is how hosts wrote "until the end of the day". This is a
  deliberate change of meaning, decided by the product owner: such a window
  gains the last minute of the day, and joins the next day's hours when those
  start at 00:00, so a host open every day from 00:00 to 23:59 becomes open
  around the clock.

  Rewritten, in this order:

    * breaks ending at or after 23:59 inside a window about to be rewritten
      now end at 00:00, so they still reach the window's end rather than
      leaving a one-minute gap at 23:59;
    * weekly windows and date overrides with both times, an end at or after
      23:59 and a start before it now end at 00:00 on the next day.

  Rows whose start is not before their end offer nothing today and are left
  as they are. Time off is not touched: a period without an end time already
  runs to the following midnight.

  Rolling back turns every window flagged as ending at 00:00 the next day back
  into a 23:59 end, and those windows' 00:00 break ends into 23:59: exactly
  what the rewritten rows held (23:59:59 comes back as 23:59:00, the same to
  the minute). Windows that run further past midnight are left to the earlier
  migration's rollback.
  """

  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # Migrations run offline: start.sh executes them in a one-shot VM before
  # Phoenix starts, so no request contends for the locks. Each statement is a
  # single UPDATE over tables of seven rows (or a handful of overrides) per
  # schedule, and every row it writes satisfies the next-day constraints the
  # earlier migration created (an end of 00:00 is at or before any start).

  @rewritable "start_time IS NOT NULL AND end_time >= TIME '23:59' AND start_time < end_time AND NOT ends_next_day"

  def up do
    execute("""
    UPDATE availability_breaks AS b
    SET end_time = TIME '00:00'
    FROM weekly_availability AS wa
    WHERE b.weekly_availability_id = wa.id
      AND wa.start_time IS NOT NULL AND wa.end_time >= TIME '23:59'
      AND wa.start_time < wa.end_time AND NOT wa.ends_next_day
      AND b.end_time >= TIME '23:59'
    """)

    execute("UPDATE weekly_availability SET end_time = TIME '00:00', ends_next_day = true WHERE #{@rewritable}")
    execute("UPDATE availability_overrides SET end_time = TIME '00:00', ends_next_day = true WHERE #{@rewritable}")
  end

  def down do
    execute("""
    UPDATE availability_breaks AS b
    SET end_time = TIME '23:59'
    FROM weekly_availability AS wa
    WHERE b.weekly_availability_id = wa.id
      AND wa.ends_next_day AND wa.end_time = TIME '00:00'
      AND b.end_time = TIME '00:00'
    """)

    execute("UPDATE weekly_availability SET end_time = TIME '23:59', ends_next_day = false WHERE ends_next_day AND end_time = TIME '00:00'")
    execute("UPDATE availability_overrides SET end_time = TIME '23:59', ends_next_day = false WHERE ends_next_day AND end_time = TIME '00:00'")
  end
end
