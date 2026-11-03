defmodule Tymeslot.Repo.Migrations.AddSchedulingOverridesToMeetingTypes do
  use Ecto.Migration

  # Per-meeting-type overrides of the scheduling rules an availability schedule
  # sets. NULL means "use the schedule's value", so every existing meeting type
  # keeps exactly the rules it has today and no backfill is needed.
  def change do
    alter table(:meeting_types) do
      add :buffer_before_minutes, :integer
      add :buffer_after_minutes, :integer
      add :min_advance_hours, :integer
      add :advance_booking_days, :integer
    end
  end
end
