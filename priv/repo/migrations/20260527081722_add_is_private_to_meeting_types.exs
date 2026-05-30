defmodule Tymeslot.Repo.Migrations.AddIsPrivateToMeetingTypes do
  use Ecto.Migration

  def change do
    alter table(:meeting_types) do
      add :is_private, :boolean, default: false, null: false
    end
  end
end
