defmodule Tymeslot.Repo.Migrations.AddVideoProviderToMeetings do
  use Ecto.Migration

  # The backfill is a bounded one-off UPDATE over existing rows: it must run
  # inside the migration so no released code ever sees a room whose provider is
  # unknown. Annotated rather than restructured because there is no online
  # variant of "populate a column from a join".
  # excellent_migrations:safety-assured-for-this-file raw_sql_executed

  def up do
    alter table(:meetings) do
      add :video_provider, :string
    end

    # Rows whose integration link survived: copy the provider straight across.
    execute("""
    UPDATE meetings m
    SET video_provider = v.provider
    FROM video_integrations v
    WHERE m.video_integration_id = v.id
      AND m.video_provider IS NULL
    """)

    # Rows already orphaned by a disconnect: the link is gone, so infer the
    # provider from the stored join URL. Only the three OAuth providers are
    # recoverable this way; MiroTalk and Custom are self-hosted or arbitrary
    # URLs, and neither has a server-side meeting object to delete anyway.
    execute("""
    UPDATE meetings
    SET video_provider = CASE
      WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%zoom.us%' THEN 'zoom'
      WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%meet.google.com%' THEN 'google_meet'
      WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%teams.microsoft.com%' THEN 'teams'
      WHEN COALESCE(organizer_video_url, meeting_url, '') LIKE '%teams.live.com%' THEN 'teams'
    END
    WHERE video_provider IS NULL
      AND video_room_id IS NOT NULL
    """)
  end

  def down do
    alter table(:meetings) do
      remove :video_provider
    end
  end
end
