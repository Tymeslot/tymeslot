defmodule Tymeslot.CalendarGrid.EventVideoRoomsTeamsTest do
  @moduledoc """
  The record of a Teams meeting made for a calendar grid event: the separate
  Outlook event it gets when it cannot be attached to the grid event itself.
  Such a room is recorded so that it follows its grid event, and only for
  that: the meeting attached to the grid event is the event itself, and
  neither a series nor a disconnect moves or deletes a separate one.

  The journeys through the grid are in
  `Tymeslot.CalendarGrid.TeamsSeparateEventCleanupTest`.
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
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.Integrations.Video.MeetingContext
  alias Tymeslot.Integrations.Video.RoomData
  alias Tymeslot.Repo
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  setup do
    user = insert(:user)
    %{user: user, calendar: insert(:calendar_integration, user: user)}
  end

  describe "record/2" do
    test "records a separate Teams event, as its join link does not name it", %{
      user: user,
      calendar: calendar
    } do
      teams = insert(:video_integration, user: user, provider: "teams")

      assert :ok =
               EventVideoRooms.record(
                 context(:teams, "AAMk-teams-event"),
                 grid_event(user, teams, calendar)
               )

      assert [%EventVideoRoomSchema{provider: "teams", room_id: "AAMk-teams-event"}] =
               Repo.all(EventVideoRoomSchema)
    end

    # Its room id is the event's own Outlook id: deleting it as a room would
    # delete the event.
    test "records nothing for a Teams meeting attached to the grid event itself", %{
      user: user,
      calendar: calendar
    } do
      teams = insert(:video_integration, user: user, provider: "teams")

      assert :ok =
               EventVideoRooms.record(
                 context(:teams, "AAMk-grid-event"),
                 grid_event(user, teams, calendar)
               )

      assert Repo.all(EventVideoRoomSchema) == []
    end
  end

  describe "rescheduled/1" do
    # One meeting's start and end cannot stand for a series.
    test "leaves a separate Teams event where it is when its event recurs", %{
      user: user,
      calendar: calendar
    } do
      room = insert_teams_room(user, calendar, "AAMk-series-meeting", "grid-teams-series")

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-teams-series",
                 all_day: false,
                 start_at: ~U[2026-10-01 09:00:00Z],
                 end_at: ~U[2026-10-01 10:00:00Z],
                 recurrence_rule: "FREQ=WEEKLY;COUNT=4"
               })

      refute_enqueued(worker: VideoSyncWorker)
      assert Repo.reload!(room) == room
    end

    test "leaves a separate Teams event where it is when its event becomes all-day", %{
      user: user,
      calendar: calendar
    } do
      room = insert_teams_room(user, calendar, "AAMk-all-day-meeting", "grid-teams-all-day")

      assert :ok =
               EventVideoRooms.rescheduled(%{
                 calendar_integration_id: calendar.id,
                 uid: "grid-teams-all-day",
                 all_day: true,
                 start_date: ~D[2026-10-05],
                 end_date: ~D[2026-10-06]
               })

      refute_enqueued(worker: VideoSyncWorker)
      assert Repo.reload!(room) == room
    end
  end

  describe "the room sync" do
    # Should one ever be recorded, the room that is its event's own calendar
    # event goes with the event through the calendar, never through Graph:
    # no Graph or token stub is set, so any provider call fails the test.
    test "a delete job for a room that is its event's own id only forgets the record", %{
      user: user,
      calendar: calendar
    } do
      room =
        insert_teams_room(user, calendar, "AAMk-grid-event", "grid-teams-attached",
          provider_event_id: "AAMk-grid-event"
        )

      assert :ok =
               perform_job(VideoSyncWorker, %{"event_room_id" => room.id, "action" => "delete"})

      assert Repo.get(EventVideoRoomSchema, room.id) == nil
    end
  end

  describe "disconnecting the integration" do
    # Recorded to follow its grid event, not to be swept up with the
    # integration: the meeting is still in the organiser's calendar.
    test "leaves a separate Teams event out of the rooms it deletes", %{
      user: user,
      calendar: calendar
    } do
      teams_room = insert_teams_room(user, calendar, "AAMk-upcoming", "grid-teams-upcoming")
      talk = insert(:video_integration, user: user, provider: "nextcloud_talk")

      {:ok, _talk_room} =
        EventVideoRoomQueries.insert(
          room_attrs(user, calendar, talk, "nextcloud_talk", "talk0001", "grid-talk")
        )

      now = ~U[2026-10-01 00:00:00Z]
      teams_id = teams_room.video_integration_id

      assert CalendarGrid.count_event_video_rooms_for_integration(teams_id, :all, now) == 0
      assert CalendarGrid.list_event_video_rooms_for_integration(teams_id, :all, now, 10) == []
      assert CalendarGrid.count_event_video_rooms_for_integration(talk.id, :all, now) == 1
    end
  end

  defp grid_event(user, integration, calendar),
    do: %{
      user_id: user.id,
      video_integration_id: integration.id,
      calendar_integration_id: calendar.id,
      uid: "grid-event",
      provider_event_id: "AAMk-grid-event",
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
        meeting_url: "https://teams.microsoft.com/l/meetup-join/opaque",
        provider_data: %{}
      }
    }

  defp insert_teams_room(user, calendar, room_id, uid, attrs \\ []) do
    teams = insert(:video_integration, user: user, provider: "teams")

    {:ok, room} =
      user
      |> room_attrs(calendar, teams, "teams", room_id, uid)
      |> Map.merge(Map.new(attrs))
      |> EventVideoRoomQueries.insert()

    room
  end

  defp room_attrs(user, calendar, integration, provider, room_id, uid),
    do: %{
      user_id: user.id,
      video_integration_id: integration.id,
      provider: provider,
      calendar_integration_id: calendar.id,
      event_uid: uid,
      room_id: room_id,
      lobby_opens_at: ~U[2026-10-05 09:00:00Z],
      ends_at: ~U[2026-10-05 10:00:00Z]
    }
end
