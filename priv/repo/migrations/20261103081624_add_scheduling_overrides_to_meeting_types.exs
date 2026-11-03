defmodule Tymeslot.Repo.Migrations.AddSchedulingOverridesToMeetingTypes do
  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # Each constraint covers a column added in this same migration, so every
  # existing row is NULL and satisfies `IS NULL OR …`; the validation scan
  # cannot fail. Migrations run offline: `start.sh` executes them in a
  # one-shot VM and only starts Phoenix once they finish, so the ACCESS
  # EXCLUSIVE lock blocks no traffic. Revisit this if a deployment target
  # ever migrates against a running instance.

  # Per-meeting-type overrides of the scheduling rules an availability schedule
  # sets. NULL means "use the schedule's value", so every existing meeting type
  # keeps exactly the rules it has today and no backfill is needed. The ranges
  # repeat `Tymeslot.Validation.Constraints`, which the changeset enforces.
  @ranges [
    buffer_before_minutes: {0, 120},
    buffer_after_minutes: {0, 120},
    min_advance_hours: {0, 168},
    advance_booking_days: {1, 365}
  ]

  def change do
    alter table(:meeting_types) do
      add :buffer_before_minutes, :integer
      add :buffer_after_minutes, :integer
      add :min_advance_hours, :integer
      add :advance_booking_days, :integer
    end

    for {column, {min, max}} <- @ranges do
      create(
        constraint(:meeting_types, :"meeting_types_#{column}_range",
          check: "#{column} IS NULL OR #{column} BETWEEN #{min} AND #{max}"
        )
      )
    end
  end
end
