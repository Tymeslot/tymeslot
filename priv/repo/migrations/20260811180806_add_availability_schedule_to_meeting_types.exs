defmodule Tymeslot.Repo.Migrations.AddAvailabilityScheduleToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # Tymeslot deploys as a single instance and migrates with the app stopped, so a
  # brief lock while the foreign key and its index are added is acceptable.

  def change do
    alter table(:meeting_types) do
      add(
        :availability_schedule_id,
        references(:availability_schedules, on_delete: :nilify_all)
      )
    end

    create(index(:meeting_types, [:availability_schedule_id]))
  end
end
