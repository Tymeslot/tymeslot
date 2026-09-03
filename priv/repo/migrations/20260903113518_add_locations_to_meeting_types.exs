defmodule Tymeslot.Repo.Migrations.AddLocationsToMeetingTypes do
  @moduledoc """
  Gives a meeting type an ordered list of locations instead of a single mode.

  Until now a meeting type was either in-person or a video call on one
  chosen integration, expressed as the `allow_video` / `video_integration_id`
  pair. That pair stays, maintained as a projection of the list so every
  existing reader keeps working, but the list is what the booker sees: one
  entry and the location is simply stated, two or more and they choose.

  Existing types are migrated to the single-entry list that means exactly
  what they mean today, so nothing changes for a host until they add a
  second option.
  """
  use Ecto.Migration

  # The backfill is the point of this migration: released code reads
  # `locations` as the source of truth, so no row may reach it holding the
  # NULL that `ALTER TABLE ... ADD COLUMN` leaves behind.
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update

  def up do
    alter table(:meeting_types) do
      add :locations, {:array, :map}
    end

    # A video type becomes one video option named after the integration it
    # already points at, so the host recognises it in the editor. The join is
    # an inner one on purpose: a type flagged `allow_video` whose integration
    # was deleted has no provider to offer and falls through to the in-person
    # default below, which is what it effectively already was.
    execute("""
    UPDATE meeting_types AS mt
    SET locations = ARRAY[
      jsonb_build_object(
        'id', gen_random_uuid()::text,
        'kind', 'video',
        'label', COALESCE(NULLIF(vi.name, ''), 'Video call'),
        'collect_from_guest', false,
        'video_integration_id', vi.id,
        'position', 0
      )
    ]::jsonb[]
    FROM video_integrations AS vi
    WHERE mt.video_integration_id = vi.id
      AND mt.allow_video IS TRUE
      AND mt.locations IS NULL
    """)

    execute("""
    UPDATE meeting_types
    SET locations = ARRAY[
      jsonb_build_object(
        'id', gen_random_uuid()::text,
        'kind', 'in_person',
        'label', 'In person',
        'collect_from_guest', false,
        'position', 0
      )
    ]::jsonb[]
    WHERE locations IS NULL
    """)
  end

  def down do
    alter table(:meeting_types) do
      # Dropping the column is the whole point of the rollback, and
      # `allow_video` / `video_integration_id` still carry everything the
      # pre-list code needs, so nothing has to be restored from it first.
      # excellent_migrations:safety-assured-for-next-line column_removed
      remove :locations
    end
  end
end
