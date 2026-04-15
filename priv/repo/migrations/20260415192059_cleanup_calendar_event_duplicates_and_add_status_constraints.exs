defmodule Tymeslot.Repo.Migrations.CleanupCalendarEventDuplicatesAndAddStatusConstraints do
  @moduledoc """
  Cleans up legacy junk in `provider_calendar_events` and locks the schema
  down so it can't recur:

  1. **Normalises historical `status='free'` rows** — an older parser wrote
     `TRANSP:TRANSPARENT` into the `status` column. Those rows are remapped
     to `status='confirmed', transparency='transparent'`, which is what the
     current code would have written.

  2. **De-duplicates recurring masters.** A historical sync generated UIDs
     differently and left multiple rows per event surviving the
     `(calendar_integration_id, uid)` unique constraint. We collapse
     `(calendar_integration_id, summary, start_at, end_at)` clusters to the
     most recent `synced_at` row and delete the rest. Non-null summaries and
     timestamps only — duplicate rows with missing identifying data are left
     alone because we can't safely merge them.

  3. **Adds CHECK constraints** on `status` and `transparency` so the legal
     values are enforced at write time. This turns "historical parser
     bug wrote wrong column" into a foreground failure instead of silent
     cache rot.

  This migration is defensive against all three cache states —
  `status='free'` rows, duplicate clusters, and clean data — so it is safe
  to run on any user's database regardless of how much drift they have.
  """

  use Ecto.Migration

  def up do
    # 1. Normalise legacy status='free' rows to (status='confirmed',
    # transparency='transparent'). The check constraint below would reject
    # them otherwise, so this MUST happen first.
    execute("""
    UPDATE provider_calendar_events
       SET status = 'confirmed',
           transparency = 'transparent'
     WHERE status = 'free'
    """)

    # 2. De-duplicate (calendar_integration_id, summary, start_at, end_at)
    # clusters, keeping the row with the most recent synced_at. Uses
    # ROW_NUMBER to rank and deletes everything except rank 1, atomically.
    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY calendar_integration_id, summary, start_at, end_at
               ORDER BY synced_at DESC NULLS LAST, id DESC
             ) AS rn
        FROM provider_calendar_events
       WHERE summary IS NOT NULL
         AND start_at IS NOT NULL
         AND end_at IS NOT NULL
    )
    DELETE FROM provider_calendar_events
     WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
    """)

    # Same treatment for all-day events, which use start_date/end_date
    # instead of start_at/end_at.
    execute("""
    WITH ranked AS (
      SELECT id,
             ROW_NUMBER() OVER (
               PARTITION BY calendar_integration_id, summary, start_date, end_date
               ORDER BY synced_at DESC NULLS LAST, id DESC
             ) AS rn
        FROM provider_calendar_events
       WHERE all_day = true
         AND summary IS NOT NULL
         AND start_date IS NOT NULL
         AND end_date IS NOT NULL
    )
    DELETE FROM provider_calendar_events
     WHERE id IN (SELECT id FROM ranked WHERE rn > 1)
    """)

    # 3. Add CHECK constraints. Drop-if-exists first so repeated runs during
    # development or on intermediate feature branches don't conflict with
    # older experiments.
    execute("""
    ALTER TABLE provider_calendar_events
      DROP CONSTRAINT IF EXISTS provider_calendar_events_status_check
    """)

    execute("""
    ALTER TABLE provider_calendar_events
      ADD CONSTRAINT provider_calendar_events_status_check
      CHECK (status IS NULL OR status IN ('confirmed', 'tentative', 'cancelled', 'declined'))
    """)

    execute("""
    ALTER TABLE provider_calendar_events
      DROP CONSTRAINT IF EXISTS provider_calendar_events_transparency_check
    """)

    execute("""
    ALTER TABLE provider_calendar_events
      ADD CONSTRAINT provider_calendar_events_transparency_check
      CHECK (transparency IS NULL OR transparency IN ('opaque', 'transparent'))
    """)
  end

  def down do
    execute("""
    ALTER TABLE provider_calendar_events
      DROP CONSTRAINT IF EXISTS provider_calendar_events_transparency_check
    """)

    execute("""
    ALTER TABLE provider_calendar_events
      DROP CONSTRAINT IF EXISTS provider_calendar_events_status_check
    """)

    # Data changes are not reversible.
  end
end
