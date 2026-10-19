defmodule Tymeslot.Repo.Migrations.AddBlocksAvailabilityToCalendarList do
  use Ecto.Migration

  # Each calendar in `calendar_integrations.calendar_list` gains
  # `blocks_availability`: whether its busy time removes slots from the
  # booking page. Before the choice existed every selected calendar blocked,
  # so every existing entry, selected or not, is written `true`: nobody's
  # availability changes on deploy, and a calendar ticked later behaves as it
  # would have before.
  #
  # `CalendarEntry` already reads a missing key as `true`, so this only makes
  # the stored rows say what the code assumes. Only entries without the key
  # are touched, so a second run updates no rows, and a choice already made
  # is never overwritten. Only JSON objects are entries: anything else in the
  # array (a string, a number, a null, a nested array) is left exactly as it
  # is, since `||` would turn it into an array and grow it on every run.

  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  def up do
    # `calendar_list` is `jsonb[]`, so each element is rewritten and the array
    # re-aggregated. `WITH ORDINALITY` keeps the order: the default booking
    # calendar falls back to the first eligible entry.
    execute("""
    UPDATE calendar_integrations
    SET calendar_list = (
          SELECT array_agg(
                   CASE WHEN jsonb_typeof(entry) = 'object'
                             AND NOT (entry ? 'blocks_availability')
                        THEN entry || '{"blocks_availability": true}'::jsonb
                        ELSE entry END
                   ORDER BY ord)
          FROM unnest(calendar_list) WITH ORDINALITY AS elements(entry, ord)
        )
    WHERE EXISTS (
          SELECT 1
          FROM unnest(calendar_list) AS legacy(entry)
          WHERE jsonb_typeof(legacy.entry) = 'object'
            AND NOT (legacy.entry ? 'blocks_availability')
        )
    """)
  end

  # Strips the key again. Code that predates it ignores the key in any case,
  # so a rollback does not need this; running it discards every show-only
  # choice, which that code could not honour either.
  def down do
    execute("""
    UPDATE calendar_integrations
    SET calendar_list = (
          SELECT array_agg(
                   CASE WHEN jsonb_typeof(entry) = 'object'
                        THEN entry - 'blocks_availability'
                        ELSE entry END
                   ORDER BY ord)
          FROM unnest(calendar_list) WITH ORDINALITY AS elements(entry, ord)
        )
    WHERE EXISTS (
          SELECT 1
          FROM unnest(calendar_list) AS current(entry)
          WHERE jsonb_typeof(current.entry) = 'object'
            AND current.entry ? 'blocks_availability'
        )
    """)
  end
end
