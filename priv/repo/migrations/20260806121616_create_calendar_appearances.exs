defmodule Tymeslot.Repo.Migrations.CreateCalendarAppearances do
  use Ecto.Migration

  # Both assurances apply because the table is created empty in this same
  # migration: there are no rows for the index to lock out, and the reference is
  # declared as part of CREATE TABLE rather than added to a table already
  # holding data, so nothing a running deploy reads is locked. Building the
  # index concurrently is not possible here in any case, since CREATE INDEX
  # CONCURRENTLY cannot run inside the transaction a migration runs in.
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently
  # excellent_migrations:safety-assured-for-this-file column_reference_added

  # One row per (integration, provider calendar). A missing row means "inherit":
  # the integration's own colour, and the integration-level visibility stored in
  # calendar_preferences.hidden_integration_ids. Rows are therefore written only
  # when the organiser departs from the default, and deleting one restores
  # inheritance rather than leaving a calendar in a third state.
  #
  # Deliberately its own table rather than fields on the integration's embedded
  # calendar_list: rediscovery rebuilds that list from the provider and carries
  # over only :selected, so a colour stored there would be silently dropped the
  # next time the organiser refreshed their calendars.
  def change do
    create table(:calendar_appearances) do
      add(:calendar_integration_id, references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      add(:provider_calendar_id, :string, null: false)
      add(:colour, :string)
      add(:hidden, :boolean, null: false, default: false)

      timestamps(type: :utc_datetime_usec)
    end

    # Named explicitly: the derived name exceeds Postgres' 63-character
    # identifier limit and would be silently truncated, leaving the index under
    # a name no later migration could predict in order to drop it.
    create(
      unique_index(:calendar_appearances, [:calendar_integration_id, :provider_calendar_id],
        name: :calendar_appearances_integration_calendar_index
      )
    )
  end
end
