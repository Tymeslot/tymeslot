defmodule Tymeslot.CalendarGrid.EventVideoRoomsTest do
  @moduledoc """
  The record of a video room made for a calendar grid event: what is recorded,
  when the room stops being needed, and how moving and deleting the event
  reach the room on the organiser's Nextcloud server. The jobs the grid queues
  are drained from the queue, and only the HTTP client is stubbed.
  """

  use Tymeslot.DataCase, async: true
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Integrations.Video.VideoIntegrationSchema
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker

  @room_path "/ocs/v2.php/apps/spreed/api/v4/room"

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    %{user: user, calendar: insert(:calendar_integration, user: user)}
  end

  describe "record/2" do
    test "records a Nextcloud Talk room under its event's identity and times", %{
      user: user,
      calendar: calendar
    } do
      talk = insert_talk_integration(user, "record.example.com")

      assert :ok =
               EventVideoRooms.record(context(:nextcloud_talk, "rec00001"), %{
                 user_id: user.id,
                 video_integration_id: talk.id,
                 calendar_integration_id: calendar.id,
                 uid: "grid-event-1",
                 all_day: false,
                 start: ~U[2026-10-05 09:00:00.123456Z],
                 end: ~U[2026-10-05 10:00:00Z],
                 recurrence_rule: nil
               })

      assert [
               %EventVideoRoomSchema{
                 user_id: user_id,
                 video_integration_id: video_integration_id,
                 room_id: "rec00001",
                 starts_at: ~U[2026-10-05 09:00:00Z],
                 ends_at: ~U[2026-10-05 10:00:00Z]
               }
             ] = EventVideoRoomQueries.list_for_event(calendar.id, "grid-event-1")

      assert {user_id, video_integration_id} == {user.id, talk.id}
    end

    test "records nothing for a provider whose rooms need no deleting", %{
      user: user,
      calendar: calendar
    } do
      mirotalk = insert(:video_integration, user: user, provider: "mirotalk")

      assert :ok =
               EventVideoRooms.record(context(:mirotalk, "miro-room"), %{
                 user_id: user.id,
                 video_integration_id: mirotalk.id,
                 calendar_integration_id: calendar.id,
                 uid: "grid-event-2",
                 all_day: false,
                 start: ~U[2026-10-05 09:00:00Z],
                 end: ~U[2026-10-05 10:00:00Z],
                 recurrence_rule: nil
               })

      assert EventVideoRoomQueries.list_for_event(calendar.id, "grid-event-2") == []
    end
  end

  describe "times/1" do
    test "a one-off event's room is needed until the event ends, its lobby waiting for the start" do
      assert EventVideoRooms.times(timed(nil)) ==
               {~U[2026-10-05 09:00:00Z], ~U[2026-10-05 10:00:00Z]}
    end

    # The exclusive end date is midnight in some timezone, which can lie up to
    # a day after midnight UTC.
    test "an all-day event's room is kept for the whole day after its exclusive end date" do
      schedule = %{
        all_day: true,
        start: ~D[2026-10-05],
        end: ~D[2026-10-06],
        recurrence_rule: nil
      }

      assert EventVideoRooms.times(schedule) == {nil, ~U[2026-10-07 00:00:00Z]}
    end

    test "a series ending on a date is needed until a day after its last possible occurrence" do
      assert EventVideoRooms.times(timed("FREQ=DAILY;UNTIL=20261031T235959Z")) ==
               {nil, ~U[2026-11-02 00:59:59Z]}
    end

    # Three repetitions of a weekly rule, each allowed a week plus a week for
    # its weekday filter: 42 days after the first start, then the event's hour
    # and a day's margin. The real last occurrence (Monday 12 October) ends
    # well inside that.
    test "a series ending after a count is needed until no occurrence could still be running" do
      assert EventVideoRooms.times(timed("RRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=3")) ==
               {nil, ~U[2026-11-17 10:00:00Z]}
    end

    test "a series with no end is never treated as over" do
      assert EventVideoRooms.times(timed("FREQ=WEEKLY;BYDAY=MO")) == {nil, nil}
    end

    # BYMONTHDAY=31 skips the months without a 31st, so repetitions can lie
    # further apart than the bound allows for.
    test "a rule beyond what the grid's editor writes is never treated as over" do
      assert EventVideoRooms.times(timed("FREQ=MONTHLY;BYMONTHDAY=31;COUNT=2")) == {nil, nil}
    end
  end

  describe "rescheduled/1" do
    test "moves a one-off event's room and then its Talk lobby to the new start", %{
      user: user,
      calendar: calendar
    } do
      host = "moved.example.com"
      room = insert_room(user, calendar, host, "move0001", "grid-move")

      new_start = ~U[2026-10-06 14:00:00Z]

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-move",
                 all_day: false,
                 start_at: new_start,
                 end_at: ~U[2026-10-06 15:00:00Z],
                 recurrence_rule: nil
               })

      assert %{starts_at: ^new_start, ends_at: ~U[2026-10-06 15:00:00Z]} = Repo.reload!(room)

      assert_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "update"}
      )

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == "https://#{host}#{@room_path}/move0001/webinar/lobby"
        assert Jason.decode!(body) == %{"state" => 1, "timer" => DateTime.to_unix(new_start)}
        {:ok, %Req.Response{status: 200, body: ocs(%{})}}
      end)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)

      # Only a delete forgets the room: it still has to be deleted later.
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "an edit that leaves the event's times alone queues nothing", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "still.example.com", "stil0001", "grid-still")

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-still",
                 all_day: false,
                 start_at: room.starts_at,
                 end_at: room.ends_at,
                 recurrence_rule: nil,
                 summary: "Renamed"
               })

      refute_enqueued(worker: VideoSyncWorker)
    end

    # Moving one occurrence says nothing about where the series ends, so an
    # earlier occurrence must not bring the room's deletion forward.
    test "moving one occurrence of a series earlier keeps the later end", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_room(user, calendar, "series.example.com", "seri0001", "grid-series",
          starts_at: nil,
          ends_at: ~U[2026-12-01 10:00:00Z]
        )

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-series",
                 all_day: false,
                 start_at: ~U[2026-10-01 09:00:00Z],
                 end_at: ~U[2026-10-01 10:00:00Z],
                 recurrence_rule: "FREQ=WEEKLY;COUNT=2"
               })

      assert %{starts_at: nil, ends_at: ~U[2026-12-01 10:00:00Z]} = Repo.reload!(room)
      refute_enqueued(worker: VideoSyncWorker)
    end
  end

  describe "moved/4" do
    test "the room follows its event to another calendar and a new uid", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "relocate.example.com", "relo0001", "grid-old")
      destination = insert(:calendar_integration, user: user)

      assert :ok = EventVideoRooms.moved(calendar.id, "grid-old", destination.id, "grid-new")

      assert EventVideoRoomQueries.list_for_event(calendar.id, "grid-old") == []
      assert [%{id: id}] = EventVideoRoomQueries.list_for_event(destination.id, "grid-new")
      assert id == room.id
    end
  end

  describe "event_deleted/2" do
    test "deletes the event's conversation on the server and forgets it", %{
      user: user,
      calendar: calendar
    } do
      host = "deleted.example.com"
      room = insert_room(user, calendar, host, "dele0001", "grid-deleted")
      other = insert_room(user, calendar, "kept.example.com", "keep0001", "grid-kept")

      assert :ok = EventVideoRooms.event_deleted(calendar.id, "grid-deleted")

      refute_enqueued(worker: VideoSyncWorker, args: %{"event_room_id" => other.id})

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://#{host}#{@room_path}/dele0001"
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)

      assert Repo.get(EventVideoRoomSchema, room.id) == nil
      assert Repo.get(EventVideoRoomSchema, other.id)
    end

    # The nightly clean-up retries a room whose record survives, so a refused
    # delete must not forget it.
    test "keeps the record when the server refuses the delete", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "refused.example.com", "refu0001", "grid-refused")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: ""}}
      end)

      assert {:discard, "Invalid configuration"} =
               perform_job(VideoSyncWorker, %{"event_room_id" => room.id, "action" => "delete"})

      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "a job for a record already gone is discarded" do
      assert {:discard, "Calendar event video room not found"} =
               perform_job(VideoSyncWorker, %{"event_room_id" => -1, "action" => "delete"})
    end
  end

  describe "the record's lifetime" do
    test "goes with its video integration", %{user: user, calendar: calendar} do
      room = insert_room(user, calendar, "cascade.example.com", "casc0001", "grid-cascade")

      Repo.delete!(Repo.get!(VideoIntegrationSchema, room.video_integration_id))

      assert Repo.get(EventVideoRoomSchema, room.id) == nil
    end

    test "outlives its calendar integration, which only clears the event's identity", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "orphan.example.com", "orph0001", "grid-orphan")

      Repo.delete!(calendar)

      assert %{calendar_integration_id: nil, room_id: "orph0001"} = Repo.reload!(room)
    end

    test "goes with its user", %{user: user, calendar: calendar} do
      room = insert_room(user, calendar, "user.example.com", "user0001", "grid-user")

      Repo.delete!(user)

      assert Repo.get(EventVideoRoomSchema, room.id) == nil
    end
  end

  defp timed(rule),
    do: %{
      all_day: false,
      start: ~U[2026-10-05 09:00:00Z],
      end: ~U[2026-10-05 10:00:00Z],
      recurrence_rule: rule
    }

  defp context(provider, room_id),
    do: %MeetingContext{
      provider_type: provider,
      provider_module: nil,
      room_data: %RoomData{
        room_id: room_id,
        meeting_url: "https://example.com/" <> room_id,
        provider_data: %{}
      }
    }

  defp insert_room(user, calendar, host, room_id, uid, attrs \\ []) do
    talk = insert_talk_integration(user, host)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: user.id,
            video_integration_id: talk.id,
            calendar_integration_id: calendar.id,
            event_uid: uid,
            room_id: room_id,
            starts_at: ~U[2026-10-05 09:00:00Z],
            ends_at: ~U[2026-10-05 10:00:00Z]
          },
          Map.new(attrs)
        )
      )

    room
  end

  defp insert_talk_integration(user, host) do
    base_url = "https://" <> host

    insert(:video_integration,
      user: user,
      provider: "nextcloud_talk",
      base_url: base_url,
      client_id_encrypted: Encryption.encrypt("organiser"),
      client_secret_encrypted: Encryption.encrypt("Abcde-Fghij-Klmno-Pqrst-Uvwxy"),
      provider_account_id: base_url <> "||organiser"
    )
  end

  defp ocs(data), do: Jason.encode!(%{"ocs" => %{"meta" => %{"status" => "ok"}, "data" => data}})
end
