defmodule Tymeslot.Repo.Migrations.ClearReadOnlyOnExchangeCalendars do
  use Ecto.Migration

  # Exchange connected before write support pinned every discovered folder to
  # `read_only: true`, because there was no write path to offer. That flag is
  # a JSON key inside each element of `calendar_integrations.calendar_list`,
  # and nothing recomputes it on a sync — only re-running folder discovery
  # does, which happens when the user presses Refresh and at no other time.
  # So an Exchange mailbox connected on an earlier version stays unwritable
  # after upgrading: no booking-target chips, no grid editing, and a meeting
  # type that refuses to save against it.
  #
  # Discovery has never derived `true` for an Exchange folder (FindFolder
  # reports no access rights, so it emits `false` for all of them); the only
  # source of `true` on such a row is the removed override. There is nothing
  # legitimate to clobber, which is why this rewrites unconditionally rather
  # than trying to tell a stale flag from a real one.
  #
  # Deliberately scoped to `provider = 'exchange'`. `read_only: true` is
  # correct and load-bearing on an `ics_url` subscription, and genuinely
  # server-derived on CalDAV, Google and Outlook rows.

  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  def up do
    # `calendar_list` is `jsonb[]`, an array of documents rather than one
    # document, so each element is rewritten individually and re-aggregated.
    # `WITH ORDINALITY` preserves the order: the default booking calendar
    # falls back to the first eligible entry, so a reshuffle would silently
    # move which calendar a user's bookings land in.
    execute("""
    UPDATE calendar_integrations
    SET calendar_list = (
          SELECT array_agg(jsonb_set(entry, '{read_only}', 'false'::jsonb) ORDER BY ord)
          FROM unnest(calendar_list) WITH ORDINALITY AS elements(entry, ord)
        )
    WHERE provider = 'exchange'
      AND EXISTS (
          SELECT 1
          FROM unnest(calendar_list) AS stale(entry)
          WHERE stale.entry ->> 'read_only' = 'true'
      )
    """)
  end

  # Restoring the flag would put every upgraded Exchange mailbox back into the
  # state this migration exists to leave, and the value it would restore is no
  # longer true of the provider.
  def down, do: :ok
end
