defmodule Tymeslot.Repo.Migrations.AddAllowVideoToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add :allow_video, :boolean, default: true, null: false
    end
  end
end
