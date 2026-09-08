defmodule Tymeslot.Repo.Migrations.BackfillCaldavCalendarPathsFromBookingCalendar do
  @moduledoc """
  Restores `calendar_paths` on CalDAV integrations that lost their selection.

  `calendar_paths` is derived from the `selected` flag on `calendar_list`, and
  two paths could reset every flag to false while leaving `calendar_list` and
  `default_booking_calendar_id` intact: a reconnect whose submitted paths did
  not match the discovered ones by exact string equality, and a re-discovery
  that returned entries under changed hrefs. Both are fixed in the same change
  as this migration.

  A CalDAV sync iterates `calendar_paths` and nothing else, so an affected
  integration silently synced no calendars while reporting success. The
  companion code change turns that state into an error, which without this
  backfill would ask owners whose selection is recoverable to reconnect for no
  reason.

  Only rows where the booking calendar still resolves to an entry in
  `calendar_list` are repaired; that entry is the calendar bookings are already
  written to, so re-selecting it restores the previous behaviour rather than
  guessing. Rows with an empty `calendar_list`, or whose booking calendar is no
  longer listed, are left alone: there is nothing to derive from, and the
  companion change surfaces them for reconnection.

  The filter names every provider in the CalDAV family, since each is stored
  under its own `provider` string and all of them sync by path. Google and
  Outlook sync by token, so an empty `calendar_paths` is their normal state.

  Read-only calendars are never selected. An affected integration may also have
  had additional read-write calendars selected for availability; those are not
  recoverable and the owner can re-add them.
  """

  use Ecto.Migration

  # This is a targeted data repair, not a schema change: it writes only to rows
  # already in a broken state, and touches no column definition.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  def up do
    execute("""
    UPDATE calendar_integrations AS ci
    SET calendar_paths = ARRAY[entry.path],
        calendar_list = (
          SELECT array_agg(
                   CASE WHEN (c->>'path') = entry.path
                        THEN jsonb_set(c, '{selected}', 'true'::jsonb)
                        ELSE c
                   END
                   ORDER BY ord
                 )
          FROM unnest(ci.calendar_list) WITH ORDINALITY AS t(c, ord)
        ),
        updated_at = NOW()
    FROM (
      SELECT i.id AS integration_id, (c->>'path') AS path
      FROM calendar_integrations AS i,
           unnest(i.calendar_list) AS c
      WHERE i.provider IN ('caldav', 'radicale', 'nextcloud', 'zimbra', 'mailbox_org', 'apple', 'baikal')
        AND COALESCE(array_length(i.calendar_paths, 1), 0) = 0
        AND i.default_booking_calendar_id IS NOT NULL
        AND (c->>'id') = i.default_booking_calendar_id
        AND (c->>'path') IS NOT NULL
        AND (c->>'path') <> ''
        AND COALESCE((c->>'read_only')::boolean, false) = false
    ) AS entry
    WHERE ci.id = entry.integration_id
    """)
  end

  def down do
    # The previous state was an empty selection that synced nothing. Restoring
    # it would reintroduce the fault, and the rows carry no record of which
    # calendars were selected before, so this is deliberately irreversible.
    :ok
  end
end
