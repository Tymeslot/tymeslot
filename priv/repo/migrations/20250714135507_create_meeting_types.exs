defmodule Tymeslot.Repo.Migrations.CreateMeetingTypes do
  use Ecto.Migration

  def change do
    create table(:meeting_types) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :description, :text
      add :duration_minutes, :integer, null: false
      add :icon, :string
      add :is_active, :boolean, default: true
      add :sort_order, :integer, default: 0

      timestamps()
    end

    create index(:meeting_types, [:user_id])
    create index(:meeting_types, [:user_id, :is_active])
    create unique_index(:meeting_types, [:user_id, :name])
  end
end
