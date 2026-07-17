defmodule Tymeslot.Repo.Migrations.AddBookingLimitsToProfiles do
  use Ecto.Migration

  @moduledoc """
  Account-wide booking limits: how many bookings a host accepts per day,
  week, and month across all meeting types. NULL means no limit, so
  existing rows need no backfill and the check constraints hold for all
  current data.
  """

  def change do
    alter table(:profiles) do
      add(:max_bookings_per_day, :integer)
      add(:max_bookings_per_week, :integer)
      add(:max_bookings_per_month, :integer)
    end

    create(
      constraint(:profiles, :profiles_max_bookings_per_day_positive,
        check: "max_bookings_per_day IS NULL OR max_bookings_per_day > 0"
      )
    )

    create(
      constraint(:profiles, :profiles_max_bookings_per_week_positive,
        check: "max_bookings_per_week IS NULL OR max_bookings_per_week > 0"
      )
    )

    create(
      constraint(:profiles, :profiles_max_bookings_per_month_positive,
        check: "max_bookings_per_month IS NULL OR max_bookings_per_month > 0"
      )
    )
  end
end
