defmodule TymeslotWeb.Dashboard.CalendarGrid.EventVideoRoomSyncTest do
  @moduledoc """
  What the calendar grid's own edits do to a Nextcloud Talk conversation made
  for one of its events: deleting the event deletes the conversation, moving it
  moves the conversation's lobby, moving it to another calendar keeps the
  conversation with it, and switching an event's video to Talk records the
  conversation so it is deleted later. The grid's asynchronous paths run as in
  production; only the calendar provider and the HTTP client are stubbed.
  """

  # Not async: the grid's edits call the providers from supervised tasks, which
  # needs the global Mox mode.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Phoenix.Component
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRoomSchema
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Moves
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.VideoSync
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NotificationFlows

  @rooms_path "/ocs/v2.php/apps/spreed/api/v4/room"

  # The grid's edits report back from a supervised task, which a loaded
  # machine can take longer than ExUnit's default wait to finish.
  @task_timeout 2_000

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "google",
        oauth_scope: "https://www.googleapis.com/auth/calendar",
        default_booking_calendar_id: "primary",
        is_active: true
      )

    event =
      insert(:provider_calendar_event,
        calendar_integration: calendar,
        provider: "google",
        summary: "Planning",
        description: "",
        location: "",
        attendees: [],
        start_at: ~U[2026-10-05 09:00:00.000000Z],
        end_at: ~U[2026-10-05 10:00:00.000000Z],
        all_day: false
      )

    socket =
      Component.assign(%Phoenix.LiveView.Socket{}, current_user: user, integrations: [calendar])

    %{user: user, calendar: calendar, event: event, socket: socket}
  end

  test "deleting a grid event deletes its conversation on the server", %{
    user: user,
    calendar: calendar,
    event: event
  } do
    host = "grid-delete.example.com"
    room = insert_room(user, event, host)

    expect(GoogleCalendarAPIMock, :delete_event, fn _integration, "primary", uid ->
      assert uid == event.uid
      :ok
    end)

    assert {:ok, _result} =
             EventDelete.run_delete_event(%{
               uid: event.uid,
               provider_event_id: nil,
               calendar_integration_id: calendar.id,
               user_id: user.id
             })

    assert_enqueued(
      worker: VideoSyncWorker,
      args: %{"event_room_id" => room.id, "action" => "delete"}
    )

    expect(HTTPClientMock, :request, fn :delete, url, _body, _headers, _opts ->
      assert url == "https://#{host}#{@rooms_path}/grid0001"
      {:ok, %Req.Response{status: 200, body: ocs(nil)}}
    end)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
    assert Repo.get(EventVideoRoomSchema, room.id) == nil
  end

  # The event is still in the calendar, so its join link must keep working.
  test "a grid delete the calendar refuses leaves the conversation alone", %{
    user: user,
    calendar: calendar,
    event: event
  } do
    room = insert_room(user, event, "grid-delete-failed.example.com")

    expect(GoogleCalendarAPIMock, :delete_event, fn _integration, "primary", _uid ->
      {:error, :unauthorized, "Token expired or invalid"}
    end)

    assert {:error, _reason, _context} =
             EventDelete.run_delete_event(%{
               uid: event.uid,
               provider_event_id: nil,
               calendar_integration_id: calendar.id,
               user_id: user.id
             })

    refute_enqueued(worker: VideoSyncWorker)
    assert Repo.get(EventVideoRoomSchema, room.id)
  end

  test "dragging a grid event moves its conversation's lobby to the new start", %{
    user: user,
    event: event,
    socket: socket
  } do
    host = "grid-drag.example.com"
    room = insert_room(user, event, host)

    new_start = ~U[2026-10-06 14:00:00Z]
    new_end = ~U[2026-10-06 15:00:00Z]

    expect(Tymeslot.CalendarMock, :update_event, fn uid, _event_data, _context ->
      assert uid == event.uid
      :ok
    end)

    optimistic = %{event | start_at: new_start, end_at: new_end}
    _socket = Updates.update_event_async(socket, event, optimistic, new_start, new_end)

    assert_receive {:event_update_result, :ok}, @task_timeout

    assert %{lobby_opens_at: ^new_start, ends_at: ^new_end} = Repo.reload!(room)

    expect(HTTPClientMock, :request, fn :put, url, body, _headers, _opts ->
      assert url == "https://#{host}#{@rooms_path}/grid0001/webinar/lobby"
      assert Jason.decode!(body) == %{"state" => 1, "timer" => DateTime.to_unix(new_start)}
      {:ok, %Req.Response{status: 200, body: ocs(%{})}}
    end)

    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
  end

  test "a grid edit the calendar refuses leaves the conversation's times alone", %{
    user: user,
    event: event,
    socket: socket
  } do
    room = insert_room(user, event, "grid-drag-refused.example.com")
    new_start = ~U[2026-10-06 14:00:00Z]

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, _event_data, _context ->
      {:error, :server_error}
    end)

    optimistic = %{event | start_at: new_start}
    _socket = Updates.update_event_async(socket, event, optimistic, new_start, event.end_at)

    assert_receive {:event_update_result, {:error, _details}}, @task_timeout

    assert Repo.reload!(room).lobby_opens_at == ~U[2026-10-05 09:00:00Z]
    refute_enqueued(worker: VideoSyncWorker)
  end

  test "moving a grid event to another calendar keeps its conversation with it", %{
    user: user,
    event: event,
    socket: socket
  } do
    room = insert_room(user, event, "grid-relocate.example.com")
    destination = insert(:calendar_integration, user: user, is_active: true)
    socket = Component.assign(socket, :integrations, [destination | socket.assigns.integrations])

    expect(GoogleCalendarAPIMock, :delete_event, fn _integration, "primary", _uid -> :ok end)

    expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
      {:ok, "relocated-uid"}
    end)

    _socket = Moves.move_event_async(socket, event, destination.id, [])

    assert_receive {:event_move_result, {:ok, uid: "relocated-uid", integration_id: _id}},
                   @task_timeout

    # Written under a new uid, which the destination calendar answered with
    # its own identifier.
    assert %{calendar_integration_id: calendar_integration_id, provider_event_id: "relocated-uid"} =
             moved = Repo.reload!(room)

    refute moved.event_uid == event.uid

    assert calendar_integration_id == destination.id
  end

  test "switching an event's video to Talk records the new conversation", %{
    user: user,
    calendar: calendar,
    event: event,
    socket: socket
  } do
    host = "grid-switch.example.com"
    talk = insert_talk_integration(user, host)
    rooms_url = "https://#{host}#{@rooms_path}"

    # Plays the organiser's Nextcloud server, which holds no conversation
    # until one is created.
    stub(HTTPClientMock, :request, fn
      :get, _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: ocs([])}}

      :post, ^rooms_url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 201, body: ocs(%{"token" => "swit0001"})}}
    end)

    updated = Map.put(event, :video_integration_id, talk.id)
    _socket = VideoSync.sync_video_integration_async(socket, event, updated)

    event_id = event.id
    assert_receive {:video_sync_result, ^event_id, {:ok, _url}}, @task_timeout

    assert [
             %EventVideoRoomSchema{
               room_id: "swit0001",
               video_integration_id: video_integration_id,
               lobby_opens_at: ~U[2026-10-05 09:00:00Z],
               ends_at: ~U[2026-10-05 10:00:00Z]
             }
           ] = EventVideoRoomQueries.list_for_identifiers(calendar.id, [event.uid])

    assert video_integration_id == talk.id
  end

  describe "a conversation made with a new grid event" do
    # Google hands back its own event id, and a sync then caches the event
    # under its iCalUID with that id as `provider_event_id`: neither is the uid
    # the event was written under.
    test "on a Google calendar follows the synced event through a drag and a delete", %{
      user: user,
      calendar: calendar,
      socket: socket
    } do
      host = "grid-google.example.com"
      talk = insert_talk_integration(user, host)
      play_nextcloud(host, "goog0001")

      expect(Tymeslot.CalendarMock, :create_event, fn _event_data, _context ->
        {:ok, %{uid: "googlehex0001", summary: "Planning"}}
      end)

      assert {:ok, %{video_room_id: "goog0001"}} = create_grid_event(user, calendar, talk)

      synced =
        insert(:provider_calendar_event,
          calendar_integration: calendar,
          provider: "google",
          uid: "googlehex0001@google.com",
          provider_event_id: "googlehex0001",
          summary: "Planning",
          description: "",
          location: "",
          attendees: [],
          start_at: ~U[2026-10-05 09:00:00.000000Z],
          end_at: ~U[2026-10-05 10:00:00.000000Z]
        )

      # A drag moves the conversation's lobby with the event.
      new_start = ~U[2026-10-06 14:00:00Z]
      new_end = ~U[2026-10-06 15:00:00Z]
      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _event_data, _context -> :ok end)

      optimistic = %{synced | start_at: new_start, end_at: new_end}
      _socket = Updates.update_event_async(socket, synced, optimistic, new_start, new_end)
      assert_receive {:event_update_result, :ok}, @task_timeout

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
      assert_received {:nextcloud, :put, lobby_url, %{"timer" => timer}}
      assert lobby_url == "https://#{host}#{@rooms_path}/goog0001/webinar/lobby"
      assert timer == DateTime.to_unix(new_start)

      # Deleting the event deletes the conversation.
      expect(GoogleCalendarAPIMock, :delete_event, fn _integration, "primary", _id -> :ok end)

      assert {:ok, _result} =
               synced
               |> NotificationFlows.build_delete_payload(user.id, false)
               |> EventDelete.run_delete_event()

      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :video_rooms)
      assert_received {:nextcloud, :delete, delete_url, nil}
      assert delete_url == "https://#{host}#{@rooms_path}/goog0001"
      assert Repo.all(EventVideoRoomSchema) == []
    end

    # A CalDAV series is cached as its occurrences, each under the series uid
    # followed by the occurrence's start.
    test "on a CalDAV series stays with the series its occurrences are cached as", %{
      user: user,
      socket: socket
    } do
      host = "grid-caldav.example.com"
      talk = insert_talk_integration(user, host)
      calendar = insert(:calendar_integration, user: user, provider: "caldav", is_active: true)
      socket = Component.assign(socket, :integrations, [calendar])
      play_nextcloud(host, "cald0001")

      expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
        {:ok, event_data.uid}
      end)

      assert {:ok, %{uid: uid, video_room_id: "cald0001"}} =
               create_grid_event(user, calendar, talk, recurrence_rule: "FREQ=WEEKLY;COUNT=3")

      [room] = Repo.all(EventVideoRoomSchema)
      assert %{event_uid: ^uid, lobby_opens_at: ~U[2026-10-05 09:00:00Z]} = room
      assert %DateTime{} = room.ends_at

      [_first, second, _third] =
        for {day, n} <- [{5, 1}, {12, 2}, {19, 3}] do
          start_at = DateTime.new!(Date.new!(2026, 10, day), ~T[09:00:00], "Etc/UTC")

          insert(:provider_calendar_event,
            calendar_integration: calendar,
            provider: "caldav",
            uid: "#{uid}_202610#{String.pad_leading("#{day}", 2, "0")}T090000",
            provider_event_id: "/calendars/organiser/#{uid}.ics",
            recurrence_rule: "FREQ=WEEKLY;COUNT=3",
            summary: "Planning #{n}",
            description: "",
            location: "",
            attendees: [],
            start_at: start_at,
            end_at: DateTime.add(start_at, 3600, :second)
          )
        end

      # Dragging the second occurrence to before the first opens the lobby
      # earlier, and never brings the room's deletion forward.
      new_start = ~U[2026-10-04 09:00:00Z]
      expect(Tymeslot.CalendarMock, :update_event, fn _uid, _event_data, _context -> :ok end)

      optimistic = %{second | start_at: new_start, end_at: ~U[2026-10-04 10:00:00Z]}

      _socket =
        Updates.update_event_async(
          socket,
          second,
          optimistic,
          new_start,
          ~U[2026-10-04 10:00:00Z],
          recurrence_scope: "this"
        )

      assert_receive {:event_update_result, :ok}, @task_timeout

      moved = Repo.reload!(room)
      assert moved.lobby_opens_at == new_start
      refute DateTime.before?(moved.ends_at, room.ends_at)

      # Deleting one occurrence keeps the conversation the others still use.
      assert :ok =
               second
               |> NotificationFlows.build_delete_payload(user.id, false)
               |> CalendarGrid.delete_event_video_rooms()

      refute_enqueued(worker: VideoSyncWorker, args: %{"action" => "delete"})
      assert Repo.get(EventVideoRoomSchema, room.id)
    end
  end

  defp create_grid_event(user, calendar, talk, extra \\ []) do
    EventCreation.run_create_event(%{
      creating:
        Map.merge(
          %{
            title: "Planning",
            integration_id: calendar.id,
            calendar_id: "primary",
            attendees: [],
            video_integration_id: talk.id
          },
          Map.new(extra)
        ),
      user_id: user.id,
      start_at: ~U[2026-10-05 09:00:00Z],
      end_at: ~U[2026-10-05 10:00:00Z]
    })
  end

  # Plays the organiser's Nextcloud server: no conversation exists until one is
  # created, and every request reaches the test.
  defp play_nextcloud(host, token) do
    test = self()
    rooms_url = "https://#{host}#{@rooms_path}"

    stub(HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test, {:nextcloud, method, url, if(body == "", do: nil, else: Jason.decode!(body))})

      case {method, url} do
        {:get, _url} -> {:ok, %Req.Response{status: 200, body: ocs([])}}
        {:post, ^rooms_url} -> {:ok, %Req.Response{status: 201, body: ocs(%{"token" => token})}}
        _other -> {:ok, %Req.Response{status: 200, body: ocs(nil)}}
      end
    end)
  end

  defp insert_room(user, event, host) do
    talk = insert_talk_integration(user, host)

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: event.calendar_integration_id,
        event_uid: event.uid,
        room_id: "grid0001",
        lobby_opens_at: ~U[2026-10-05 09:00:00Z],
        ends_at: ~U[2026-10-05 10:00:00Z]
      })

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
