defmodule Tymeslot.Repo.Migrations.CreateAvailabilityOverrides do
  use Ecto.Migration

  def change do
    create table(:availability_overrides) do
      add :profile_id, references(:profiles, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :override_type, :string, null: false
      add :start_time, :time, null: true
      add :end_time, :time, null: true
      add :reason, :string, null: true

      timestamps()
    end

    create unique_index(:availability_overrides, [:profile_id, :date])
    create index(:availability_overrides, [:profile_id])

    # Add check constraint for override_type
    execute("ALTER TABLE availability_overrides ADD CONSTRAINT override_type_check CHECK (override_type IN ('unavailable', 'custom_hours', 'available'))")
  end
end