defmodule Tymeslot.Repo.Migrations.RelaxMeetingsAttendeeColumnsNullable do
  use Ecto.Migration

  # Repair migration. The original create_meetings migration was later patched
  # to declare attendee_name / attendee_email as nullable, so that group
  # meetings (max_participants > 1) can hold a slot row with no attendee —
  # bookers live in meeting_participants instead. Databases that ran the
  # original version (with NOT NULL) before that patch keep the old
  # constraint, because Ecto never re-runs an already-applied migration. This
  # heals them.
  #
  # DROP NOT NULL is a no-op on a column that is already nullable, so this is
  # safe on fresh installs and idempotent across any prior state.

  def up do
    execute("ALTER TABLE meetings ALTER COLUMN attendee_name DROP NOT NULL")
    execute("ALTER TABLE meetings ALTER COLUMN attendee_email DROP NOT NULL")
  end

  # Intentionally irreversible: re-imposing NOT NULL would fail on any group
  # meeting rows created with no attendee.
  def down do
    :ok
  end
end
