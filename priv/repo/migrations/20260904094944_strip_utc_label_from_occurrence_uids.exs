defmodule Tymeslot.Repo.Migrations.StripUtcLabelFromOccurrenceUids do
  @moduledoc """
  Rewrites the stored identity of every expanded recurring occurrence to match
  the UID format `ICalNormaliser.build_uid/1` now emits.

  Each occurrence of a recurring CalDAV or ICS event is cached under a UID
  built as `"\#{base_uid}_\#{suffix}"`, where the suffix is the occurrence's
  own start time. That suffix used to be formatted `%Y%m%dT%H%M%SZ`, but the
  datetime it formats has already been shifted into the event's own timezone,
  so the trailing `Z` labelled a local wall clock as UTC. Dropping the `Z` was
  the fix; it also changes the UID, and the UID is identity.

  `provider_calendar_events` is keyed on `(calendar_integration_id, uid)`, so
  without this rewrite every occurrence already cached would look deleted on
  the next full fetch. On a recurring-heavy calendar that trips
  `Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler`'s bulk-deletion guard,
  which rolls the whole sync back for a 24-hour grace period, while delta syncs
  insert new-format rows alongside the old ones and the grid shows each
  occurrence twice. `event_colour_overrides.provider_uid` holds the same UID
  and has no such recovery path at all: a user's per-event colour choice keyed
  on the old UID would be orphaned permanently.

  ## Which rows are rewritten

  The predicate is the shape of the suffix alone: `_YYYYMMDDTHHMMSSZ` at the
  very end of the value. All-day occurrences use a `%Y%m%d` suffix, were never
  affected, and do not match. Google's instance iCalUIDs embed a similar
  fragment but end `@google.com`, so the end anchor excludes them; the CalDAV
  family and iCloud use opaque UUID-shaped UIDs.

  Both tables are matched with the *identical* predicate, deliberately. A
  provider UID that happened to end in that shape on a non-recurring event
  would be a false positive, and the cost of one is much lower when the cache
  row and the colour override move together than when only one of them does.

  ## Collisions against the unique indexes

  `left(uid, -1)` drops exactly one character, so two distinct old UIDs can
  only collide if they differ in that character alone; the `Z` anchor means
  only one of the pair is ever rewritten. The real collision is with a row that
  already holds the new format, which is what the `DELETE`s ahead of each
  `UPDATE` clear. That state cannot exist on a released database, because the
  format change has not shipped in any tag and migrations run offline in a
  one-shot VM before Phoenix boots. It can exist on a database that has run the
  unreleased code, and the new-format row is the freshly synced one, so the
  old-format duplicate is what gets dropped.

  No batching: the rewrite is a single sequential pass over a table holding
  tens of thousands of rows at most, with no concurrent traffic to block.
  """
  use Ecto.Migration

  # Rewriting stored data is the entire point of this migration, and the rows
  # it touches are ones this repository wrote under its own previous format.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file operation_delete

  def up do
    execute("""
    DELETE FROM provider_calendar_events AS stale
    USING provider_calendar_events AS fresh
    WHERE stale.uid ~ '_[0-9]{8}T[0-9]{6}Z$'
      AND fresh.calendar_integration_id = stale.calendar_integration_id
      AND fresh.uid = left(stale.uid, -1)
    """)

    execute("""
    UPDATE provider_calendar_events
    SET uid = left(uid, -1)
    WHERE uid ~ '_[0-9]{8}T[0-9]{6}Z$'
    """)

    execute("""
    DELETE FROM event_colour_overrides AS stale
    USING event_colour_overrides AS fresh
    WHERE stale.provider_uid ~ '_[0-9]{8}T[0-9]{6}Z$'
      AND fresh.user_id = stale.user_id
      AND fresh.calendar_integration_id = stale.calendar_integration_id
      AND fresh.provider_uid = left(stale.provider_uid, -1)
    """)

    execute("""
    UPDATE event_colour_overrides
    SET provider_uid = left(provider_uid, -1)
    WHERE provider_uid ~ '_[0-9]{8}T[0-9]{6}Z$'
    """)
  end

  # Deliberately a no-op. Re-appending the `Z` would restore precisely the
  # mismatch this migration exists to clear, breaking every occurrence the
  # running code can address; and the duplicate rows dropped above cannot be
  # reconstructed. The forward direction is idempotent — after it runs nothing
  # matches the predicate — so re-applying it is the safe repair, not reversing
  # it.
  def down, do: :ok
end
