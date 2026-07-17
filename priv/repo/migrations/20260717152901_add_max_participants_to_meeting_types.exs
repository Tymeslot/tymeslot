defmodule Tymeslot.Repo.Migrations.AddMaxParticipantsToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add :max_participants, :integer, default: 1, null: false
    end
  end
end
