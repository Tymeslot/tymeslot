defmodule Tymeslot.Repo.Migrations.RelaxBookingPaymentsAttendeeColumnsNullable do
  use Ecto.Migration

  # Repair migration. The original create_booking_payments migration was later
  # patched to declare attendee_email / attendee_name as nullable so host
  # deletion can anonymise them to nil. Databases that ran the original version
  # (with NOT NULL) before that patch keep the old constraint, because Ecto
  # never re-runs an already-applied migration. This heals them.
  #
  # DROP NOT NULL is a no-op on a column that is already nullable, so this is
  # safe on fresh installs and idempotent across any prior state.

  def up do
    execute("ALTER TABLE booking_payments ALTER COLUMN attendee_email DROP NOT NULL")
    execute("ALTER TABLE booking_payments ALTER COLUMN attendee_name DROP NOT NULL")
  end

  # Intentionally irreversible: re-imposing NOT NULL would fail on rows whose
  # attendee data has already been anonymised to nil.
  def down do
    :ok
  end
end
