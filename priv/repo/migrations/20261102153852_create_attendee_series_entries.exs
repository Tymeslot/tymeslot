defmodule Tymeslot.Repo.Migrations.CreateAttendeeSeriesEntries do
  use Ecto.Migration

  # The reference and the index are created against a table this same
  # migration creates: it holds no rows yet, so there is no lock contention or
  # table rewrite to avoid by adding them concurrently or in a later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # An entry in a guest's calendar that an attendee email about an occurrence
  # of a recurring series put there: its UID, the timing it was last sent at
  # (instants for a timed entry, dates with an exclusive end for an all-day
  # one) and the SEQUENCE it was last sent at.
  #
  # The series is addressed within its calendar integration by how its
  # provider addresses it as a whole (`master:<id>` or `resource:<href>`), not
  # by a column on `provider_calendar_events`: a write to a whole series drops
  # the series' cached rows and the next sync inserts them afresh, which would
  # lose what the guests were sent. The row goes with its integration.
  def change do
    create table(:attendee_series_entries) do
      add(
        :calendar_integration_id,
        references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      add(:series_address, :text, null: false)
      add(:entry_uid, :text, null: false)
      add(:start_at, :utc_datetime_usec)
      add(:end_at, :utc_datetime_usec)
      add(:start_date, :date)
      add(:end_date, :date)
      add(:sent_sequence, :integer, null: false)

      timestamps(type: :utc_datetime)
    end

    # One record per entry of a series: a later email about the same entry
    # replaces what the guest was last sent. Named explicitly, as the derived
    # name exceeds Postgres' 63-character identifier limit.
    create(
      unique_index(
        :attendee_series_entries,
        [:calendar_integration_id, :series_address, :entry_uid],
        name: :attendee_series_entries_entry_index
      )
    )
  end
end
