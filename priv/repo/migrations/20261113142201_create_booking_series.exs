defmodule Tymeslot.Repo.Migrations.CreateBookingSeries do
  @moduledoc """
  Creates `booking_series`: the owner of a set of sessions booked in one
  flow. Every occurrence stays an ordinary `meetings` row (or a
  `meeting_participants` row on a group type) carrying `series_id` and
  `series_position`.

  `mode` is `recurring` (the same time on a fixed rhythm, which needs a
  `frequency` and an `interval` of 1 to 4) or `flexible` (sessions picked at
  different times, no rule). `occurrences_count` is 2 to 26: a single booking
  creates no series. `uid` is the bearer for the attendee's series page, as
  `meetings.uid` is for a booking.

  The table is new, so no existing row can violate its constraints. The rule
  check wraps its test in `COALESCE(..., false)`: a CHECK passes on NULL, so a
  recurring row with no frequency would otherwise slip through.
  """

  use Ecto.Migration

  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file check_constraint_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  #
  # The references and every index are on the table created in this same
  # migration. It is empty and unreachable until the migration commits, so
  # there are no rows to validate and no concurrent readers to lock out.

  def change do
    create table(:booking_series, primary_key: false) do
      add(:id, :binary_id, primary_key: true)
      add(:uid, :uuid, null: false)
      add(:organizer_user_id, references(:users, on_delete: :delete_all))
      add(:meeting_type_id, references(:meeting_types, on_delete: :nilify_all))
      add(:mode, :string, null: false)
      add(:frequency, :string)
      add(:interval, :integer)
      add(:occurrences_count, :integer, null: false)
      add(:attendee_name, :string, null: false)
      add(:attendee_email, :string, null: false)
      add(:attendee_timezone, :string)
      add(:attendee_locale, :string)
      add(:unit_price_cents, :integer)
      add(:cancelled_at, :utc_datetime_usec)
      add(:invitee_data_erased_at, :utc_datetime_usec)

      timestamps(type: :utc_datetime_usec)
    end

    create(
      constraint(:booking_series, :booking_series_mode_check,
        check: "mode IN ('recurring', 'flexible')"
      )
    )

    create(
      constraint(:booking_series, :booking_series_rule_check,
        check:
               "mode = 'flexible' OR COALESCE(frequency IN ('daily', 'weekly', 'monthly') AND interval BETWEEN 1 AND 4, false)"
      )
    )

    create(
      constraint(:booking_series, :booking_series_count_check,
        check: "occurrences_count BETWEEN 2 AND 26"
      )
    )

    create(unique_index(:booking_series, [:uid]))
    create(index(:booking_series, [:organizer_user_id]))
    create(index(:booking_series, [:meeting_type_id]))
  end
end
