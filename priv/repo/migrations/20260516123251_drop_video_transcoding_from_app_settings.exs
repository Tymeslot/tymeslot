defmodule Tymeslot.Repo.Migrations.DropVideoTranscodingFromAppSettings do
  use Ecto.Migration

  # Drops the `video_transcoding_enabled` column originally added by
  # CreateAppSettings. The toggle is being removed from the admin UI —
  # the worker already self-degrades when ffmpeg is unavailable, so a
  # runtime flag adds no value. Idempotent so existing dev/CI databases
  # that already ran the original migration are cleaned up cleanly.

  def up do
    execute("ALTER TABLE app_settings DROP COLUMN IF EXISTS video_transcoding_enabled")
  end

  def down do
    execute(
      "ALTER TABLE app_settings ADD COLUMN IF NOT EXISTS video_transcoding_enabled boolean"
    )
  end
end
