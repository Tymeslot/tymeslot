defmodule Tymeslot.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  def change do
    create table(:profiles) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :timezone, :string, default: "Europe/Kyiv", null: false

      # Room for future settings
      add :buffer_minutes, :integer, default: 15
      add :advance_booking_days, :integer, default: 90
      add :min_advance_hours, :integer, default: 3

      timestamps()
    end

    create unique_index(:profiles, [:user_id])
  end
end
