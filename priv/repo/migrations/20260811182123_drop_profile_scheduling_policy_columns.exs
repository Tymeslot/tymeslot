defmodule Tymeslot.Repo.Migrations.DropProfileSchedulingPolicyColumns do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_removed
  # The values were copied onto each profile's default schedule by
  # create_availability_schedules, which runs before this migration. The
  # schedule is now the only source of truth for buffer, minimum notice and the
  # advance booking window.

  def up do
    alter table(:profiles) do
      remove(:buffer_minutes)
      remove(:min_advance_hours)
      remove(:advance_booking_days)
    end
  end

  def down do
    raise Ecto.MigrationError,
      message: "drop_profile_scheduling_policy_columns is irreversible"
  end
end
