defmodule Tymeslot.CalendarGrid.SharedVideoRoomTest do
  @moduledoc """
  A recorded video room that more than one calendar event links to: the
  occurrences of a series, and both halves of a series split for an edit of
  one occurrence and every following one. Letting one of them go (a video
  change on one occurrence, or a delete of one half) keeps the room while
  another cached event still carries its link, and deletes it with the last.

  The calendar write is stubbed at `Tymeslot.CalendarMock`; the room's delete
  is observed as the `Tymeslot.Workers.VideoSyncWorker` job it queues.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  @link "https://cloud.example.com/call/room-weekly-sync"

  setup do
    user = insert(:user)
    calendar = insert(:calendar_integration, user: user, provider: "google")
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk")

    # An occurrence of a Google series, as the sync caches it: an id of its
    # own, naming its master's, and the series' Talk link.
    row = fn master, stamp, attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: calendar,
            provider: "google",
            provider_calendar_id: "team-calendar",
            uid: "#{master}@google.com_#{stamp}",
            provider_event_id: "#{master}_#{stamp}",
            recurring_event_id: master,
            recurrence_rule: "FREQ=WEEKLY",
            summary: "Weekly sync",
            description: "Agenda\n\nJoin video call: #{@link}",
            start_at: ~U[2026-10-05 09:00:00.000000Z],
            end_at: ~U[2026-10-05 10:00:00.000000Z],
            all_day: false,
            video_link: @link,
            video_integration_id: talk.id,
            sync_state: "synced"
          },
          Map.new(attrs)
        )
      )
    end

    %{user: user, calendar: calendar, talk: talk, row: row}
  end

  defp record_room(%{user: user, calendar: calendar, talk: talk}, master) do
    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: calendar.id,
        event_uid: "#{master}@google.com",
        provider_event_id: master,
        room_id: "room-weekly-sync",
        lobby_opens_at: ~U[2026-10-05 08:45:00Z],
        ends_at: ~U[2026-12-28 10:00:00Z]
      })

    room
  end

  describe "choosing another video for one occurrence of a series" do
    setup context do
      %{
        room: record_room(context, "series-1"),
        occurrence: context.row.("series-1", "20261005T090000Z", [])
      }
    end

    test "keeps the room the other occurrences still use", %{
      user: user,
      row: row,
      room: room,
      occurrence: occurrence
    } do
      row.("series-1", "20261012T090000Z", description: "Agenda")
      expect_provider_update()

      assert {:ok, nil} = CalendarGrid.change_event_video(user.id, occurrence, nil)

      refute_enqueued(worker: VideoSyncWorker, args: %{"event_room_id" => room.id})
      assert Repo.reload(room)
    end

    test "deletes the room when no other occurrence carries its link", %{
      user: user,
      row: row,
      room: room,
      occurrence: occurrence
    } do
      row.("series-1", "20261012T090000Z", description: "Agenda", video_link: nil)
      expect_provider_update()

      assert {:ok, nil} = CalendarGrid.change_event_video(user.id, occurrence, nil)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )
    end
  end

  describe "deleting one half of a split series as a whole" do
    # The room moved to the later series, `tail-master`, on the split, while
    # the earlier one, `head-master`, keeps occurrences carrying its link.
    setup context do
      %{
        room: record_room(context, "tail-master"),
        tail: context.row.("tail-master", "20261019T090000Z", [])
      }
    end

    test "hands the room to the earlier half while it still carries the link", %{
      row: row,
      room: room,
      tail: tail
    } do
      # Only in its description: the sync has cached it, but its video has not
      # been handed back to it yet.
      head = row.("head-master", "20261005T090000Z", video_link: nil, video_integration_id: nil)

      # As the grid's delete does, the deleted half's rows go first.
      Repo.delete!(tail)
      assert :ok = EventVideoRooms.series_deleted(tail)

      refute_enqueued(worker: VideoSyncWorker, args: %{"event_room_id" => room.id})

      assert [%{id: room_id}] =
               EventVideoRooms.rooms_on_integration(head, room.video_integration_id)

      assert room_id == room.id

      Repo.delete!(head)
      assert :ok = EventVideoRooms.series_deleted(head)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )
    end

    # Deleted before its own rows are purged, the half's other occurrences
    # carry the link too, and must not keep the room for themselves.
    test "deletes the room when only the half's own rows carry the link", %{
      row: row,
      room: room,
      tail: tail
    } do
      row.("tail-master", "20261026T090000Z", [])
      row.("head-master", "20261005T090000Z", description: "Agenda", video_link: nil)

      assert :ok = EventVideoRooms.series_deleted(tail)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )
    end
  end

  defp expect_provider_update do
    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)
  end
end
