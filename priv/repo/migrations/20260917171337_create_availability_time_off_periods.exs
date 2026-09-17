defmodule Tymeslot.Repo.Migrations.CreateAvailabilityTimeOffPeriods do
  @moduledoc """
  Periods during which the profile's owner is away and takes no bookings, held
  here rather than as blocking events in a connected calendar.

  Keyed on `profile_id`, not on `availability_schedules.id`: being on holiday
  is a fact about the person, not about one named schedule, so a period has to
  reach every schedule the profile owns. A per-schedule row would leave a
  second schedule quietly bookable through a holiday the owner believed they
  had entered once.

  A period is one continuous interval in the owner's timezone, from
  `starts_on` at `start_time` to `ends_on` at `end_time`, both dates
  inclusive. A null `start_time` means from the start of `starts_on`, and a
  null `end_time` means to the end of `ends_on`, so whole-day time off is the
  case where both are null and needs no sentinel times. Days between the two
  ends are always blocked in full; the times only ever trim the first and last
  day, which is what "leaving Friday lunchtime, back Monday morning" needs.

  `label` is the owner's own note ("Portugal") and is never rendered on the
  booking page: a blocked day there is indistinguishable from any other day
  the schedule does not offer.
  """
  use Ecto.Migration

  # Both assurances apply because the table is created empty in this same
  # migration: the reference is declared as part of CREATE TABLE rather than
  # added to a table already holding rows, and there are no rows for the index
  # to lock out. CREATE INDEX CONCURRENTLY could not run here in any case,
  # since it cannot run inside the transaction a migration runs in.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def change do
    create table(:availability_time_off_periods) do
      add(:profile_id, references(:profiles, on_delete: :delete_all), null: false)
      add(:starts_on, :date, null: false)
      add(:ends_on, :date, null: false)
      add(:start_time, :time)
      add(:end_time, :time)
      add(:label, :string)

      timestamps(type: :utc_datetime)
    end

    # Every read is "which periods of this profile overlap this date window?",
    # so the profile leads and the two bounds follow it in the order the
    # overlap predicate compares them.
    # Named explicitly: the derived name exceeds Postgres' 63-character
    # identifier limit and would be silently truncated, leaving the index under
    # a name no later migration could predict in order to drop it.
    create(
      index(:availability_time_off_periods, [:profile_id, :ends_on, :starts_on],
        name: :availability_time_off_periods_profile_id_range_index
      )
    )
  end
end
