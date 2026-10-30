defmodule Tymeslot.Repo.Migrations.CreateCalendarEventUndeliveredUpdates do
  use Ecto.Migration

  # The reference and the index are created against a table this same
  # migration creates: it holds no rows yet, so there is no lock contention or
  # table rewrite to avoid by adding them concurrently or in a later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # A guest of a dashboard calendar event whose latest update email could not
  # be delivered, kept so the organiser sees it on the event and can tell the
  # guest another way. A later email that does reach the guest clears it, as
  # does the organiser dismissing it.
  #
  # The event is addressed within its calendar integration by the uid its
  # cached row carries, not by a column on `provider_calendar_events`: a write
  # to a whole series drops the series' cached rows and the next sync inserts
  # them afresh, which would lose a value held there. The row goes with its
  # integration.
  def change do
    create table(:calendar_event_undelivered_updates) do
      add(
        :calendar_integration_id,
        references(:calendar_integrations, on_delete: :delete_all),
        null: false
      )

      add(:event_uid, :string, null: false)
      add(:email, :string, null: false)
      add(:failed_at, :utc_datetime, null: false)

      timestamps(type: :utc_datetime)
    end

    # One record per guest of an event: a retried or rescued job records the
    # same failure again, and must find the row it left. Named explicitly, as
    # the derived name exceeds Postgres' 63-character identifier limit.
    create(
      unique_index(
        :calendar_event_undelivered_updates,
        [:calendar_integration_id, :event_uid, :email],
        name: :calendar_event_undelivered_updates_event_email_index
      )
    )
  end
end
