defmodule Tymeslot.Repo.Migrations.CreateAvailabilityBreaks do
  use Ecto.Migration

  def change do
    create table(:availability_breaks) do
      add :weekly_availability_id, references(:weekly_availability, on_delete: :delete_all), null: false
      add :start_time, :time, null: false
      add :end_time, :time, null: false
      add :label, :string, null: true
      add :sort_order, :integer, default: 0

      timestamps()
    end

    create index(:availability_breaks, [:weekly_availability_id])
  end
end