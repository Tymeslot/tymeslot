defmodule Tymeslot.Repo.Migrations.CreateWeeklyAvailability do
  use Ecto.Migration

  def change do
    create table(:weekly_availability) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :day_of_week, :integer, null: false
      add :is_available, :boolean, default: false
      add :start_time, :time, null: true
      add :end_time, :time, null: true

      timestamps()
    end

    create unique_index(:weekly_availability, [:profile_id, :day_of_week])
    create index(:weekly_availability, [:profile_id])
  end
end