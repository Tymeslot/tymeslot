defmodule Tymeslot.Repo.Migrations.ConvertLocationVideoIntegrationToList do
  @moduledoc """
  A video location now names a list of providers the booker picks between,
  `video_integration_ids`, instead of exactly one `video_integration_id`.

  Every stored location still carrying the single key is rewritten to the
  one-element list that means the same thing, and the old key is dropped. A
  location whose key holds `null` becomes an empty list, which is what it
  already offered. Rows with no such location are left untouched, so the
  migration is safe to run again and on a database that never held the old
  shape.
  """
  use Ecto.Migration

  # Rewriting the stored lists is the whole of this migration: the schema
  # reads only the new key, so a location left in the old shape would load as
  # a video option with no provider at all.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    execute("""
    UPDATE meeting_types
    SET locations = (
      SELECT array_agg(
        CASE
          WHEN elem ? 'video_integration_id' THEN
            (elem - 'video_integration_id')
            || jsonb_build_object(
              'video_integration_ids',
              CASE
                WHEN jsonb_typeof(elem -> 'video_integration_id') = 'number'
                  THEN jsonb_build_array(elem -> 'video_integration_id')
                ELSE '[]'::jsonb
              END
            )
          ELSE elem
        END
        ORDER BY ord
      )
      FROM unnest(locations) WITH ORDINALITY AS entries(elem, ord)
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(locations) AS entry WHERE entry ? 'video_integration_id'
    )
    """)
  end

  def down do
    execute("""
    UPDATE meeting_types
    SET locations = (
      SELECT array_agg(
        CASE
          WHEN elem ? 'video_integration_ids' THEN
            (elem - 'video_integration_ids')
            || jsonb_build_object('video_integration_id', elem -> 'video_integration_ids' -> 0)
          ELSE elem
        END
        ORDER BY ord
      )
      FROM unnest(locations) WITH ORDINALITY AS entries(elem, ord)
    )
    WHERE EXISTS (
      SELECT 1 FROM unnest(locations) AS entry WHERE entry ? 'video_integration_ids'
    )
    """)
  end
end
