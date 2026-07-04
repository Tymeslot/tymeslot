defmodule Tymeslot.Repo.Migrations.ConvertProviderCalendarEventsTimestampsToUtc do
  @moduledoc """
  Converts provider_calendar_events.inserted_at/updated_at from naive
  `timestamp` to `timestamptz`, matching the schema's new
  `timestamps(type: :utc_datetime_usec)`.

  Isolated from the bulk timestamp migration because this is the calendar-event
  cache — the largest of the affected tables. The ALTER rewrites the table under
  an ACCESS EXCLUSIVE lock, so an operator on a busy instance may want to run it
  during a quiet window. Existing naive values were stored as UTC wall-clock, so
  `AT TIME ZONE 'UTC'` reinterprets them as the correct instant losslessly.
  """

  use Ecto.Migration

  def up do
    execute(
      "ALTER TABLE provider_calendar_events ALTER COLUMN inserted_at TYPE timestamptz USING inserted_at AT TIME ZONE 'UTC'"
    )

    execute(
      "ALTER TABLE provider_calendar_events ALTER COLUMN updated_at TYPE timestamptz USING updated_at AT TIME ZONE 'UTC'"
    )
  end

  def down do
    execute(
      "ALTER TABLE provider_calendar_events ALTER COLUMN inserted_at TYPE timestamp USING inserted_at AT TIME ZONE 'UTC'"
    )

    execute(
      "ALTER TABLE provider_calendar_events ALTER COLUMN updated_at TYPE timestamp USING updated_at AT TIME ZONE 'UTC'"
    )
  end
end
