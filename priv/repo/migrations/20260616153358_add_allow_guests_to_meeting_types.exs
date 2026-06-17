defmodule Tymeslot.Repo.Migrations.AddAllowGuestsToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add :allow_guests, :boolean, default: false, null: false
    end
  end
end
