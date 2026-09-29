defmodule Tymeslot.Repo.Migrations.TrackCalendarEventVideoRoomPresence do
  use Ecto.Migration

  # When the nightly scan last found a grid event's room's event in the
  # calendar cache, and the iCalendar UID the event's own cached row carries,
  # which outlives an Outlook event's id when the event moves to another
  # calendar. Both start empty: a room is only ever judged gone once its event
  # has been seen.
  def change do
    alter table(:calendar_event_video_rooms) do
      add(:event_seen_at, :utc_datetime)
      add(:event_ical_uid, :string)
    end
  end
end
