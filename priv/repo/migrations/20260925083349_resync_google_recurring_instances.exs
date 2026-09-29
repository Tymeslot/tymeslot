defmodule Tymeslot.Repo.Migrations.ResyncGoogleRecurringInstances do
  @moduledoc """
  Clears the collapsed cache rows of Google recurring series and makes every
  Google integration resynchronise from scratch, so each occurrence is cached
  under the UID `Google.EventNormaliser.cache_uid/1` now gives it.

  Google sync lists events with `singleEvents=true`, so a recurring series
  arrives as one instance per occurrence, all sharing the series' iCalUID.
  Those instances used to be cached under that shared iCalUID, and
  `provider_calendar_events` is unique on `(calendar_integration_id, uid)`, so
  every instance of a series overwrote the last and the whole series collapsed
  into a single row: the calendar grid showed one occurrence and lost the rest.
  Each instance is now cached as `<iCalUID>_<original start stamp>`.

  Changing the UID alone does not repair a database that already holds the
  collapsed rows. The booking calendar syncs incrementally against the stored
  `google_sync_token`, and a sync token only returns what changed since it was
  issued: the unchanged instances of an existing series would never arrive
  again under their new UIDs, and the collapsed row would stay behind beside
  whichever instances did, showing its occurrence twice.

  ## What this does

  * Deletes every cached Google row with a `recurring_event_id`, except the
    rows kept for a series' video (below). That column is set only on the
    instances of a recurring series, so the predicate selects
    exactly the rows cached under the old shared UID, plus any per-instance
    rows a database running the unreleased code already wrote. Those come back
    on the next sync too, so there is no reason to tell them apart. Single
    events and every other provider are untouched: CalDAV, ICS and Exchange
    occurrences have always carried their own UIDs.
  * Deletes every cached Google row with a `recurrence_rule`, with the same
    exception: a series cached as its unexpanded master. The incremental
    sync used to omit
    `singleEvents`, so a series created or changed after the bootstrap
    arrived that way, as did a series the grid created and cached itself. The
    bootstrap brings its occurrences back in its place.
  * Keeps, for each Google series whose rows carry a video, one row as the
    series' master: its row for the master itself where there is one, or
    else one of its instances' rows, re-filed under the master's id with no
    `recurring_event_id`. A sync never writes a row's video, so a series the
    grid created with a video (its link on the master row it cached, or on
    the collapsed row the sync later made of it) would otherwise come back
    without one, with no row left to recover it from. When the bootstrap
    caches the series' instances, the sync gives them that row's video and
    then drops it, as it drops any master row its occurrences replace
    (`Sync.upsert_cache/2`).
  * Drops the sync token of every Google integration. With no token,
    `SyncGoogleCalendarWorker` takes its bootstrap path, a full listing of the
    sync window, which caches every instance afresh and stores a new token.
    Secondary calendars need no token change: they are fully listed on every
    sync already.

  Until each integration's next sync (a webhook, or the fallback sweep within
  15 minutes) its recurring Google events are missing from the grid and from
  the published free/busy feed, both of which read this cache. Booking
  availability is unaffected: it reads the providers live.

  A per-event colour override on a Google series keeps pointing at the old
  shared UID, which nothing produces any more, so it stops matching. That is
  accepted: an override on the collapsed row coloured one arbitrary occurrence,
  and there is no single instance it could correctly move to.

  No batching: a single pass over a table holding tens of thousands of rows at
  most, run offline before Phoenix boots.
  """
  use Ecto.Migration

  # Clearing stale cached rows and sync cursors is the entire point of this
  # migration. Every row it touches is a cache entry or token this repository
  # derived from the provider, and the next sync rebuilds all of it.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file operation_delete

  def up do
    # One statement: the DELETE reads the rows as they were before the
    # UPDATE, and spares the rows the UPDATE kept.
    execute("""
    WITH series_rows AS (
      SELECT id,
             calendar_integration_id,
             COALESCE(NULLIF(recurring_event_id, ''), provider_event_id) AS master_id,
             NULLIF(recurring_event_id, '') IS NULL AS master_row,
             updated_at
      FROM provider_calendar_events
      WHERE provider = 'google'
        AND (recurring_event_id IS NOT NULL OR recurrence_rule IS NOT NULL)
        AND video_integration_id IS NOT NULL
        AND video_link <> ''
    ),
    carriers AS (
      SELECT DISTINCT ON (calendar_integration_id, master_id) id, master_id
      FROM series_rows
      WHERE master_id IS NOT NULL AND master_id <> ''
      ORDER BY calendar_integration_id, master_id, master_row DESC, updated_at DESC, id
    ),
    kept AS (
      UPDATE provider_calendar_events AS e
      SET provider_event_id = c.master_id, recurring_event_id = NULL
      FROM carriers AS c
      WHERE e.id = c.id
      RETURNING e.id
    )
    DELETE FROM provider_calendar_events
    WHERE provider = 'google'
      AND (recurring_event_id IS NOT NULL OR recurrence_rule IS NOT NULL)
      AND id NOT IN (SELECT id FROM kept)
    """)

    execute("""
    UPDATE calendar_integrations SET google_sync_token = NULL
    WHERE provider = 'google' AND google_sync_token IS NOT NULL
    """)
  end

  # Deliberately a no-op. The deleted rows are a cache the provider repopulates
  # on the next sync, and the dropped tokens are replaced by the bootstrap that
  # sync performs, so there is nothing to restore. Re-applying `up/0` is safe:
  # it only clears what the next sync rebuilds.
  def down, do: :ok
end
