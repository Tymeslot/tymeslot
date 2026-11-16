defmodule Tymeslot.Repo.Migrations.CreateEventBookabilityOverrides do
  @moduledoc """
  The organiser's own say over whether one calendar event stops guests
  booking its time: `busy` true ("Treat as Busy") or false ("Treat as
  Free"), whatever its calendar marks it. Keyed like
  `event_colour_overrides`' external target, by the event's integration and
  cached uid, so it survives a re-sync.
  """

  use Ecto.Migration

  # The table is created here, empty, so its references and index lock and
  # validate nothing that already exists.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  def up do
    create table(:event_bookability_overrides) do
      add :user_id, references(:users, on_delete: :delete_all), null: false

      add :calendar_integration_id,
          references(:calendar_integrations, on_delete: :delete_all),
          null: false

      # Text, as `provider_calendar_events.uid` is: provider ids run long.
      add :provider_uid, :text, null: false
      add :busy, :boolean, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(
             :event_bookability_overrides,
             [:user_id, :calendar_integration_id, :provider_uid],
             name: :event_bookability_overrides_user_event_index
           )

    # For the integration's cascade delete.
    create index(:event_bookability_overrides, [:calendar_integration_id])
  end

  def down do
    # Undoes only this migration's own table.
    # excellent_migrations:safety-assured-for-next-line table_dropped
    drop table(:event_bookability_overrides)
  end
end
