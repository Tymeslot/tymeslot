defmodule Tymeslot.Repo.Migrations.IncreaseUrlColumnLengths do
  use Ecto.Migration

  def change do
    alter table(:meetings) do
      # Increase URL column lengths from default 255 to 1000 characters
      # MiroTalk URLs with tokens can be very long
      modify :view_url, :string, size: 1000
      modify :reschedule_url, :string, size: 1000
      modify :cancel_url, :string, size: 1000
      modify :meeting_url, :string, size: 1000
      modify :organizer_video_url, :string, size: 1000
      modify :attendee_video_url, :string, size: 1000
    end
  end
end
