defmodule Tymeslot.Repo.Migrations.AddExtraLengthsToMeetingTypes do
  use Ecto.Migration

  # Further durations a booker may choose between, next to `duration_minutes`.
  # Nullable with no default: NULL means "only `duration_minutes`", which is
  # exactly what every existing row offers today. Nothing to backfill, and no
  # default means no table rewrite.
  def change do
    alter table(:meeting_types) do
      add(:extra_lengths_minutes, {:array, :integer})
    end
  end
end
