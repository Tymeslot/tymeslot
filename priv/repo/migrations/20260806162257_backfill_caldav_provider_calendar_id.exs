defmodule Tymeslot.Repo.Migrations.BackfillCaldavProviderCalendarId do
  @moduledoc """
  Files each cached CalDAV event under the calendar it actually came from.

  Every CalDAV sync path built one normalisation context per batch and stamped
  `provider_calendar_id` with the integration's *first* calendar path, so an
  account with several calendars had all of its events filed under one of them.
  The per-calendar colour and visibility controls key on that column, so they
  silently did nothing for every calendar but the first.

  A CalDAV href is rooted at the collection it lives in, which makes it the
  authoritative record of the event's origin and lets the misfiled rows be
  repaired in place. Rows whose href matches no known path are left untouched
  rather than guessed at.
  """
  use Ecto.Migration

  # A backfill is the point of this migration, not an incidental write, and it
  # touches only rows this repository misfiled itself.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    execute("""
    UPDATE provider_calendar_events AS e
    SET provider_calendar_id = m.path
    FROM (
      SELECT DISTINCT ON (ev.id) ev.id AS event_id, p.path AS path
      FROM provider_calendar_events AS ev
      JOIN calendar_integrations AS ci ON ci.id = ev.calendar_integration_id
      CROSS JOIN LATERAL unnest(ci.calendar_paths) AS p(path)
      WHERE ev.provider_event_id LIKE '/%'
        AND left(ev.provider_event_id, length(p.path)) = p.path
      ORDER BY ev.id, length(p.path) DESC
    ) AS m
    WHERE e.id = m.event_id
      AND e.provider_calendar_id IS DISTINCT FROM m.path
    """)
  end

  # The pre-backfill state is "every event filed under the first path", which
  # is precisely the bug. Restoring it would re-break the colour and visibility
  # controls, so the down migration deliberately does nothing.
  def down, do: :ok
end
