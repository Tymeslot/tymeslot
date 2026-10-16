defmodule Tymeslot.Repo.Migrations.AddVideoProcessingStatusToThemeCustomizations do
  @moduledoc """
  A theme customisation's video processing state moves from one
  `video_processing` string per row into `video_processing_status`, a map
  keyed by the asset field whose video it describes
  (`%{"background_video_path" => "completed"}`), so a theme may offer more
  than one video. Every row with a state gets it under
  `background_video_path`, the one video field there has been.

  This is the expand half of an expand/contract change: `video_processing`
  stays, so an installation that goes back to the previous release without
  running `down/0` still finds the column it reads. A later release drops
  it. Only rows whose map is still empty are filled, so the migration is
  safe to run again.

  `down/0` carries the background video's state back into
  `video_processing` (where the map has one) before removing the map, so a
  rollback keeps the state recorded since the upgrade.
  """
  use Ecto.Migration

  # The backfill is the point of the migration. The column's constant
  # default is added without rewriting the table, and `down/0` removes only
  # the column this migration added.
  # excellent_migrations:safety-assured-for-this-file column_added_with_default
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed
  # excellent_migrations:safety-assured-for-this-file operation_update
  # excellent_migrations:safety-assured-for-this-file column_removed

  def up do
    alter table(:theme_customizations) do
      add_if_not_exists(:video_processing_status, :map,
        null: false,
        default: fragment("'{}'::jsonb")
      )
    end

    execute("""
    UPDATE theme_customizations
    SET video_processing_status = jsonb_build_object('background_video_path', video_processing)
    WHERE video_processing IS NOT NULL
      AND video_processing_status = '{}'::jsonb
    """)
  end

  def down do
    execute("""
    UPDATE theme_customizations
    SET video_processing = video_processing_status ->> 'background_video_path'
    WHERE video_processing_status ? 'background_video_path'
    """)

    alter table(:theme_customizations) do
      remove_if_exists(:video_processing_status, :map)
    end
  end
end
