defmodule Tymeslot.Repo.Migrations.AddParticipantIdToMeetingGuests do
  use Ecto.Migration

  def change do
    alter table(:meeting_guests) do
      add :participant_id,
          references(:meeting_participants, type: :binary_id, on_delete: :delete_all)
    end

    create index(:meeting_guests, [:participant_id])
  end
end
