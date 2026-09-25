defmodule Tymeslot.CalendarGrid.EventVideoRoomsTest do
  @moduledoc """
  The record of a video room made for a calendar grid event: what is recorded,
  which calendar events it follows, and when the calendar lets the room go.
  The jobs the grid queues are drained from the queue, and only the HTTP
  client is stubbed. Throughout, a room that may still be in use is kept.
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
  @day 86_400

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    %{user: user, calendar: insert(:calendar_integration, user: user)}
  end

  describe "record/2" do
    test "records a Nextcloud Talk room under its event's identifiers and times", %{
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
                 provider_event_id: "provider-event-1",
                 all_day: false,
                 start: ~U[2026-10-05 09:00:00.123456Z],
                 end: ~U[2026-10-05 10:00:00Z],
                 recurrence_rule: nil
               })

      assert [
               %EventVideoRoomSchema{
                 provider: "nextcloud_talk",
                 room_id: "rec00001",
                 event_uid: "grid-event-1",
                 provider_event_id: "provider-event-1",
                 lobby_opens_at: ~U[2026-10-05 09:00:00Z],
                 ends_at: ~U[2026-10-05 10:00:00Z]
               } = room
             ] = Repo.all(EventVideoRoomSchema)

      assert {room.user_id, room.video_integration_id} == {user.id, talk.id}
    end

    test "records nothing for a provider whose rooms need no deleting", %{
      user: user,
      calendar: calendar
    } do
      mirotalk = insert(:video_integration, user: user, provider: "mirotalk")

      assert :ok =
               EventVideoRooms.record(
                 context(:mirotalk, "miro-room"),
                 event(user, mirotalk, calendar)
               )

      assert Repo.all(EventVideoRoomSchema) == []
    end

    test "records a conversation adopted again for the same event only once", %{
      user: user,
      calendar: calendar
    } do
      talk = insert_talk_integration(user, "adopted.example.com")
      grid_event = event(user, talk, calendar)

      assert :ok = EventVideoRooms.record(context(:nextcloud_talk, "adop0001"), grid_event)
      assert :ok = EventVideoRooms.record(context(:nextcloud_talk, "adop0001"), grid_event)

      assert [%EventVideoRoomSchema{room_id: "adop0001"}] = Repo.all(EventVideoRoomSchema)
    end
  end

  describe "identified/4" do
    # Google and Outlook address the event by the id they returned from then on,
    # and Google only within the calendar it was written to.
    test "records the identifier and calendar the provider wrote the event to", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_room(user, calendar, "identified.example.com", "iden0001", "grid-uid",
          provider_event_id: nil
        )

      assert :ok = EventVideoRooms.identified(calendar.id, "grid-uid", "googleid0001", "work")

      assert %{provider_event_id: "googleid0001", provider_calendar_id: "work"} =
               Repo.reload!(room)
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

      assert %{lobby_opens_at: ^new_start, ends_at: ~U[2026-10-06 15:00:00Z]} = Repo.reload!(room)
      assert_enqueued(worker: VideoSyncWorker, args: event_room_args(room, "update"))

      expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
        assert url == "https://#{host}#{@room_path}/move0001/webinar/lobby"
        assert Jason.decode!(body) == %{"state" => 1, "timer" => DateTime.to_unix(new_start)}
        {:ok, %Req.Response{status: 200, body: ocs(%{})}}
      end)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)

      # Only a delete forgets the room: it still has to be deleted later.
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "finds the room by the identifier the calendar returned", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_room(user, calendar, "by-provider-id.example.com", "prov0001", "grid-uid-2",
          provider_event_id: "googleid0002"
        )

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "googleid0002@google.com",
                 provider_event_id: "googleid0002",
                 all_day: false,
                 start_at: ~U[2026-10-07 09:00:00Z],
                 end_at: ~U[2026-10-07 10:00:00Z]
               })

      assert Repo.reload!(room).ends_at == ~U[2026-10-07 10:00:00Z]
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
                 start_at: room.lobby_opens_at,
                 end_at: room.ends_at,
                 summary: "Renamed"
               })

      refute_enqueued(worker: VideoSyncWorker)
    end

    # A lobby left at the old hour would hold guests out of an event that now
    # runs all day.
    test "making an event all-day opens its lobby as the day begins", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "all-day.example.com", "alld0001", "grid-all-day")

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-all-day",
                 all_day: true,
                 start_date: ~D[2026-10-05],
                 end_date: ~D[2026-10-06]
               })

      assert %{lobby_opens_at: ~U[2026-10-04 10:00:00Z], ends_at: ~U[2026-10-07 00:00:00Z]} =
               Repo.reload!(room)

      assert_enqueued(worker: VideoSyncWorker, args: event_room_args(room, "update"))
    end

    # Google caches each occurrence under its parent's id, and one occurrence
    # moved earlier says nothing about where the series ends.
    test "moving an occurrence of a Google series opens the lobby earlier and keeps the end", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_room(user, calendar, "series.example.com", "seri0001", "grid-series",
          provider_event_id: "googleseries1",
          ends_at: ~U[2026-12-01 10:00:00Z]
        )

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "googleseries1@google.com",
                 provider_event_id: "googleseries1_20261012T090000Z",
                 recurring_event_id: "googleseries1",
                 all_day: false,
                 start_at: ~U[2026-10-01 09:00:00Z],
                 end_at: ~U[2026-10-01 10:00:00Z]
               })

      assert %{lobby_opens_at: ~U[2026-10-01 09:00:00Z], ends_at: nil} = Repo.reload!(room)
      assert_enqueued(worker: VideoSyncWorker, args: event_room_args(room, "update"))
    end

    test "a room deleted meanwhile is left deleted", %{user: user, calendar: calendar} do
      room = insert_room(user, calendar, "gone.example.com", "gone0001", "grid-gone")
      :ok = EventVideoRoomQueries.delete(room)

      assert EventVideoRoomQueries.update_times(room, nil, nil) == :gone
      assert Repo.all(EventVideoRoomSchema) == []
    end
  end

  describe "moved/5" do
    test "a one-off event's room follows it to another calendar and its new identifiers", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "relocate.example.com", "relo0001", "grid-old")
      destination = insert(:calendar_integration, user: user)

      assert :ok =
               EventVideoRooms.moved(
                 %{calendar_integration_id: calendar.id, uid: "grid-old"},
                 destination.id,
                 "grid-new",
                 "outlookid0001",
                 "destination-calendar"
               )

      assert %{
               event_uid: "grid-new",
               provider_event_id: "outlookid0001",
               provider_calendar_id: "destination-calendar"
             } =
               moved = Repo.reload!(room)

      assert moved.calendar_integration_id == destination.id
    end

    test "an occurrence moved out of its series leaves the room with the series", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "occurrence.example.com", "occu0001", "grid-series-2")
      destination = insert(:calendar_integration, user: user)

      occurrence = %{
        calendar_integration_id: calendar.id,
        uid: "grid-series-2_20261005T090000",
        recurrence_rule: "FREQ=WEEKLY"
      }

      assert :ok =
               EventVideoRooms.moved(occurrence, destination.id, "grid-new-2", "grid-new-2", nil)

      assert %{event_uid: "grid-series-2"} = moved = Repo.reload!(room)
      assert moved.calendar_integration_id == calendar.id
    end
  end

  describe "event_deleted/1" do
    test "deletes a one-off event's conversation on the server and forgets it", %{
      user: user,
      calendar: calendar
    } do
      host = "deleted.example.com"
      room = insert_room(user, calendar, host, "dele0001", "grid-deleted")
      other = insert_room(user, calendar, "kept.example.com", "keep0001", "grid-kept")

      assert :ok =
               EventVideoRooms.event_deleted(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-deleted"
               })

      refute_enqueued(worker: VideoSyncWorker, args: %{"event_room_id" => other.id})

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://#{host}#{@room_path}/dele0001"
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)

      assert Repo.get(EventVideoRoomSchema, room.id) == nil
      assert Repo.get(EventVideoRoomSchema, other.id)
    end

    # The rest of the series still meets in the conversation.
    test "deleting one occurrence of a series keeps its conversation", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_room(user, calendar, "one-occurrence.example.com", "occd0001", "grid-series-3",
          provider_event_id: "googleseries3"
        )

      assert :ok =
               EventVideoRooms.event_deleted(%{
                 calendar_integration_id: calendar.id,
                 uid: "googleseries3@google.com",
                 provider_event_id: "googleseries3_20261005T090000Z",
                 recurring_event_id: "googleseries3"
               })

      refute_enqueued(worker: VideoSyncWorker)
      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    # The nightly clean-up retries a room whose record survives, so a refused
    # delete must not forget it.
    test "keeps the record when the server refuses the delete", %{
      user: user,
      calendar: calendar
    } do
      room = insert_room(user, calendar, "refused.example.com", "refu0001", "grid-refused")

      expect(HTTPClientMock, :request, fn :delete, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 403, body: talk_refusal()}}
      end)

      assert {:discard, "Invalid configuration"} =
               perform_job(VideoSyncWorker, event_room_args(room, "delete"))

      assert Repo.get(EventVideoRoomSchema, room.id)
    end

    test "a job for a record already gone is discarded" do
      assert {:discard, "Calendar event video room not found"} =
               perform_job(VideoSyncWorker, %{"event_room_id" => -1, "action" => "delete"})
    end
  end

  describe "check_expired/1" do
    test "keeps a room whose event ended within the retention period", %{
      user: user,
      calendar: calendar
    } do
      room = ended_room(user, calendar, "recent.example.com", 6)

      assert EventVideoRooms.check_expired(room) == :kept
    end

    # Moved in a calendar client: the grid never heard of it, the cache did.
    test "keeps a room whose event the calendar has since moved later, and follows it", %{
      user: user,
      calendar: calendar
    } do
      room = ended_room(user, calendar, "moved-later.example.com", 8)
      new_start = DateTime.add(DateTime.utc_now(:second), 2 * @day, :second)
      cache_event(calendar, room.event_uid, new_start)

      assert EventVideoRooms.check_expired(room) == :kept

      assert %{lobby_opens_at: ^new_start} = reloaded = Repo.reload!(room)
      assert reloaded.ends_at == DateTime.add(new_start, 1800, :second)
      assert_enqueued(worker: VideoSyncWorker, args: event_room_args(room, "update"))
    end

    test "lets a room go whose cached event also ended past retention", %{
      user: user,
      calendar: calendar
    } do
      room = ended_room(user, calendar, "cached-ended.example.com", 8)
      cache_event(calendar, room.event_uid, DateTime.add(room.ends_at, -1800, :second))

      assert EventVideoRooms.check_expired(room) == :expired
    end

    test "lets a room go whose event is gone from a calendar synced since it fell due", %{
      user: user
    } do
      calendar =
        insert(:calendar_integration,
          user: user,
          last_external_sync_at: DateTime.utc_now(:second)
        )

      room = ended_room(user, calendar, "gone-synced.example.com", 8)

      assert EventVideoRooms.check_expired(room) == :expired
    end

    # Absent from a cache that has not been refreshed says nothing.
    test "keeps a room whose event is absent from a calendar not synced since", %{user: user} do
      calendar =
        insert(:calendar_integration,
          user: user,
          last_external_sync_at: DateTime.add(DateTime.utc_now(:second), -30 * @day, :second)
        )

      room = ended_room(user, calendar, "gone-stale.example.com", 8)

      assert EventVideoRooms.check_expired(room) == :kept
    end

    # A CalDAV series is cached as its occurrences, under the series uid.
    test "keeps a room whose event the calendar now repeats, and stops offering it", %{
      user: user,
      calendar: calendar
    } do
      room = ended_room(user, calendar, "now-series.example.com", 8)
      start = DateTime.add(room.ends_at, -1800, :second)

      insert(:provider_calendar_event,
        calendar_integration: calendar,
        uid: room.event_uid <> "_20260901T090000",
        start_at: start,
        end_at: room.ends_at,
        recurrence_rule: "FREQ=WEEKLY"
      )

      assert EventVideoRooms.check_expired(room) == :kept
      assert Repo.reload!(room).ends_at == nil
    end

    test "keeps a room whose calendar integration is gone", %{user: user, calendar: calendar} do
      room = ended_room(user, calendar, "no-calendar.example.com", 8)
      Repo.delete!(calendar)

      {:ok, orphan} = EventVideoRoomQueries.get_with_integrations(room.id)

      assert EventVideoRooms.check_expired(orphan) == :kept
    end

    # The job asks again: the event may have moved after the scan queued it.
    test "an expire job keeps a room whose event moved after it was queued", %{
      user: user,
      calendar: calendar
    } do
      room = ended_room(user, calendar, "moved-after-scan.example.com", 8)

      cache_event(
        calendar,
        room.event_uid,
        DateTime.add(DateTime.utc_now(:second), @day, :second)
      )

      assert :ok = perform_job(VideoSyncWorker, event_room_args(room, "expire"))

      assert Repo.get(EventVideoRoomSchema, room.id)
    end
  end

  describe "the record's lifetime" do
    # As for a meeting: a disconnect without deleting the rooms, then a
    # reconnect, must still be able to reach the conversation.
    test "outlives its video integration and is reached through a reconnected one", %{
      user: user,
      calendar: calendar
    } do
      host = "reconnected.example.com"
      room = insert_room(user, calendar, host, "reco0001", "grid-reconnect")

      Repo.delete!(Repo.get!(VideoIntegrationSchema, room.video_integration_id))
      assert %{video_integration_id: nil, provider: "nextcloud_talk"} = Repo.reload!(room)

      _reconnected = insert_talk_integration(user, host)

      expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
        assert url == "https://#{host}#{@room_path}/reco0001"
        {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end)

      assert :ok = perform_job(VideoSyncWorker, event_room_args(room, "delete"))
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

  defp event(user, integration, calendar),
    do: %{
      user_id: user.id,
      video_integration_id: integration.id,
      calendar_integration_id: calendar.id,
      uid: "grid-event",
      all_day: false,
      start: ~U[2026-10-05 09:00:00Z],
      end: ~U[2026-10-05 10:00:00Z]
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

  defp event_room_args(room, action), do: %{"event_room_id" => room.id, "action" => action}

  # A room whose event ended `days` days ago, loaded as the scan loads it.
  defp ended_room(user, calendar, host, days) do
    ends_at = DateTime.add(DateTime.utc_now(:second), -days * @day, :second)

    room =
      insert_room(
        user,
        calendar,
        host,
        "ended001",
        "grid-ended-#{days}-#{System.unique_integer([:positive])}",
        lobby_opens_at: DateTime.add(ends_at, -1800, :second),
        ends_at: ends_at
      )

    {:ok, loaded} = EventVideoRoomQueries.get_with_integrations(room.id)
    loaded
  end

  defp cache_event(calendar, uid, start_at),
    do:
      insert(:provider_calendar_event,
        calendar_integration: calendar,
        uid: uid,
        start_at: start_at,
        end_at: DateTime.add(start_at, 1800, :second),
        all_day: false
      )

  defp insert_room(user, calendar, host, room_id, uid, attrs \\ []) do
    talk = insert_talk_integration(user, host)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: user.id,
            video_integration_id: talk.id,
            provider: "nextcloud_talk",
            calendar_integration_id: calendar.id,
            event_uid: uid,
            room_id: room_id,
            lobby_opens_at: ~U[2026-10-05 09:00:00Z],
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

  # A refusal Talk itself worded: a 403 whose body is not the OCS envelope
  # comes from something in front of Nextcloud, which the client reports as an
  # HTTP error instead.
  defp talk_refusal do
    Jason.encode!(%{
      "ocs" => %{
        "meta" => %{"status" => "failure", "statuscode" => 403, "message" => ""},
        "data" => %{"error" => "permissions"}
      }
    })
  end
end
