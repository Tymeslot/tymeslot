defmodule Tymeslot.Repo.Migrations.CreateCalendarEventVideoRooms do
  use Ecto.Migration

  # The references and indexes are all created against a table this same
  # migration creates: it holds no rows yet, so there is no lock contention or
  # table rewrite to avoid by adding them concurrently or in a later migration.
  # excellent_migrations:safety-assured-for-this-file column_reference_added
  # excellent_migrations:safety-assured-for-this-file index_not_concurrently

  # A video room made for an event created on the dashboard calendar grid, for
  # a provider whose rooms stay on the organiser's server until something
  # deletes them. Such an event lives only in the organiser's calendar, so no
  # `meetings` row holds its room; this row is what lets the room be deleted
  # when the event is, when the integration is disconnected, and some days
  # after the event has ended.
  #
  # The event is identified by its calendar integration and iCal uid, the same
  # pair that addresses it in the event cache. The room is never read back out
  # of the event's description: the organiser can edit that text, and a room
  # found there need not be one Tymeslot created.
  #
  # The row goes with its video integration or user. Losing the calendar
  # integration only clears the event's identity: the room still exists and
  # still falls due for deletion.
  def change do
    create table(:calendar_event_video_rooms) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:video_integration_id, references(:video_integrations, on_delete: :delete_all),
        null: false
      )

      add(:calendar_integration_id, references(:calendar_integrations, on_delete: :nilify_all))
      add(:event_uid, :string, null: false)
      add(:room_id, :string, null: false)
      add(:starts_at, :utc_datetime)
      add(:ends_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    create(index(:calendar_event_video_rooms, [:calendar_integration_id, :event_uid]))
    create(index(:calendar_event_video_rooms, [:video_integration_id]))
    create(index(:calendar_event_video_rooms, [:user_id]))
    create(index(:calendar_event_video_rooms, [:ends_at]))
  end
end
