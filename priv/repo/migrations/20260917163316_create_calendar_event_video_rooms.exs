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
  # The event is identified within its calendar integration by the uid
  # Tymeslot generated and by the identifier the calendar provider returned,
  # the two identifiers the event cache addresses it by. The room is never read
  # back out of the event's description: the organiser can edit that text, and
  # a room found there need not be one Tymeslot created.
  #
  # The row goes with its user. Losing the video integration only clears the
  # link, as it does for a meeting: `provider` survives, so a reconnected
  # integration for the same provider can still reach the room. Losing the
  # calendar integration clears the event's identity, and a room whose event
  # can no longer be checked is kept rather than deleted.
  def change do
    create table(:calendar_event_video_rooms) do
      add(:user_id, references(:users, on_delete: :delete_all), null: false)

      add(:video_integration_id, references(:video_integrations, on_delete: :nilify_all))
      add(:provider, :string, null: false)
      add(:calendar_integration_id, references(:calendar_integrations, on_delete: :nilify_all))
      add(:event_uid, :string, null: false)
      add(:provider_event_id, :string)
      add(:room_id, :string, null: false)
      add(:lobby_opens_at, :utc_datetime)
      add(:ends_at, :utc_datetime)

      timestamps(type: :utc_datetime)
    end

    # Named explicitly: the derived names exceed Postgres' 63-character
    # identifier limit and would be silently truncated.
    create(
      index(:calendar_event_video_rooms, [:calendar_integration_id, :event_uid],
        name: :calendar_event_video_rooms_calendar_event_uid_index
      )
    )

    create(
      index(:calendar_event_video_rooms, [:calendar_integration_id, :provider_event_id],
        name: :calendar_event_video_rooms_calendar_provider_event_index
      )
    )

    # One record per conversation: a room adopted a second time for the same
    # event must not be recorded, and later deleted, twice.
    create(unique_index(:calendar_event_video_rooms, [:video_integration_id, :room_id]))
    create(index(:calendar_event_video_rooms, [:user_id]))
    create(index(:calendar_event_video_rooms, [:ends_at]))
  end
end
