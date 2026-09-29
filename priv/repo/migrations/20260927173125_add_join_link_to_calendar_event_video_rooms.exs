defmodule Tymeslot.Repo.Migrations.AddJoinLinkToCalendarEventVideoRooms do
  use Ecto.Migration

  # The join link a grid event's room is published under, learnt by the
  # nightly scan from the event's cached row. Once the event is gone from the
  # cache, it is the only way left to find another event still carrying the
  # link, such as the earlier half of a split series. Text, since a Teams
  # join link runs well past 255 characters. It starts empty and is learnt
  # the next time the event is seen.
  def change do
    alter table(:calendar_event_video_rooms) do
      add(:join_link, :text)
    end
  end
end
