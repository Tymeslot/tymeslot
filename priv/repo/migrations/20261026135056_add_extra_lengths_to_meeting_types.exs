defmodule Tymeslot.Repo.Migrations.AddExtraLengthsToMeetingTypes do
  use Ecto.Migration

  # Further durations a booker may choose between, next to `duration_minutes`.
  # Nullable with no default: NULL means "only `duration_minutes`", which is
  # exactly what every existing row offers today. Nothing to backfill, and no
  # default means no table rewrite.
  #
  # `add_if_not_exists`: before it was merged, this migration ran under an
  # earlier version number, so a database that ran the feature branch already
  # has the column and only needs this version recorded. The only removal is
  # `down/0` undoing this migration.
  # excellent_migrations:safety-assured-for-this-file column_removed
  def up do
    alter table(:meeting_types) do
      add_if_not_exists(:extra_lengths_minutes, {:array, :integer})
    end
  end

  def down do
    alter table(:meeting_types) do
      remove_if_exists(:extra_lengths_minutes, {:array, :integer})
    end
  end
end
