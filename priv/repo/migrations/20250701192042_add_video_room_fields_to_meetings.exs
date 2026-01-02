defmodule Tymeslot.Repo.Migrations.AddVideoRoomFieldsToMeetings do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      add :video_room_id, :string, comment: "MiroTalk room ID extracted from meeting URL"
      add :organizer_video_url, :string, comment: "Secure video join URL for the organizer"
      add :attendee_video_url, :string, comment: "Secure video join URL for the attendee"
      add :video_room_enabled, :boolean, default: false, comment: "Whether video room is enabled for this meeting"
      add :video_room_created_at, :utc_datetime, comment: "When the video room was created"
      add :video_room_expires_at, :utc_datetime, comment: "When video room access expires"
    end

    create index(:meetings, [:video_room_id])
    create index(:meetings, [:video_room_enabled])
    create index(:meetings, [:video_room_expires_at])
  end
end
