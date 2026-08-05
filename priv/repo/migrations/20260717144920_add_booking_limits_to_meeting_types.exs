defmodule Tymeslot.Repo.Migrations.AddBookingLimitsToMeetingTypes do
  use Ecto.Migration

  @moduledoc """
  Per-meeting-type booking limits: how many bookings of this type a host
  accepts per day, week, and month. NULL means no limit, so existing rows
  need no backfill and the check constraints hold for all current data.
  """

  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  #
  # Each constraint covers a column added in this same migration, so every
  # existing row is NULL and satisfies `IS NULL OR … > 0` — the validation
  # scan cannot fail. Migrations run offline: `start.sh` executes them in a
  # one-shot VM and only starts Phoenix once they finish, so the ACCESS
  # EXCLUSIVE lock blocks no traffic. Revisit this if a deployment target
  # ever migrates against a running instance.

  def change do
    alter table(:meeting_types) do
      add(:max_bookings_per_day, :integer)
      add(:max_bookings_per_week, :integer)
      add(:max_bookings_per_month, :integer)
    end

    create(
      constraint(:meeting_types, :meeting_types_max_bookings_per_day_positive,
        check: "max_bookings_per_day IS NULL OR max_bookings_per_day > 0"
      )
    )

    create(
      constraint(:meeting_types, :meeting_types_max_bookings_per_week_positive,
        check: "max_bookings_per_week IS NULL OR max_bookings_per_week > 0"
      )
    )

    create(
      constraint(:meeting_types, :meeting_types_max_bookings_per_month_positive,
        check: "max_bookings_per_month IS NULL OR max_bookings_per_month > 0"
      )
    )
  end
end
