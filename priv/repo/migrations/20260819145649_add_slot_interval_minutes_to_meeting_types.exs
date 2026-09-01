defmodule Tymeslot.Repo.Migrations.AddSlotIntervalMinutesToMeetingTypes do
  use Ecto.Migration

  # Nullable with no default: NULL means "use the meeting type's own duration",
  # which is exactly the behaviour every existing row already has. Nothing to
  # backfill, and no default means no table rewrite.
  def change do
    alter table(:meeting_types) do
      add(:slot_interval_minutes, :integer)
    end
  end
end
