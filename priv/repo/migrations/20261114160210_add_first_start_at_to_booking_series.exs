defmodule Tymeslot.Repo.Migrations.AddFirstStartAtToBookingSeries do
  @moduledoc """
  Adds `booking_series.first_start_at`: when the series' first session
  started as booked. A later session may be moved up to a year past it, and
  it must not follow the sessions as they move: a one-to-one session is
  moved in place, so reading the earliest live start instead lets each move
  push the limit later.

  Existing series are backfilled with the earliest start of their sessions
  and seats, cancelled ones included, which is what the limit was read from
  until now. A series with no session keeps `NULL`, which offers no
  widened reach. Rolling back drops the column.
  """
  use Ecto.Migration

  def up do
    alter table(:booking_series) do
      add(:first_start_at, :utc_datetime_usec)
    end

    flush()

    # A one-shot backfill of a column added in this same migration, on a
    # table with no reader of it yet; it takes row locks only.
    # excellent_migrations:safety-assured-for-next-line raw_sql_executed
    execute("""
    UPDATE booking_series AS s
    SET first_start_at = starts.first_start
    FROM (
      SELECT series_id, min(start_time) AS first_start
      FROM (
        SELECT m.series_id, m.start_time
        FROM meetings AS m
        WHERE m.series_id IS NOT NULL
        UNION ALL
        SELECT p.series_id, m.start_time
        FROM meeting_participants AS p
        JOIN meetings AS m ON m.id = p.meeting_id
        WHERE p.series_id IS NOT NULL
      ) AS occurrences
      GROUP BY series_id
    ) AS starts
    WHERE starts.series_id = s.id
      AND s.first_start_at IS NULL
    """)
  end

  def down do
    # Rolling back removes the column this migration added; nothing read it
    # before.
    alter table(:booking_series) do
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove(:first_start_at)
    end
  end
end
