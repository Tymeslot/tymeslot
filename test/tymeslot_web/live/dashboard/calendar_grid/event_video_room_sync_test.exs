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

    assert %{starts_at: ^new_start, ends_at: ^new_end} = Repo.reload!(room)

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

    assert Repo.reload!(room).starts_at == ~U[2026-10-05 09:00:00Z]
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

    assert %{calendar_integration_id: calendar_integration_id, event_uid: "relocated-uid"} =
             Repo.reload!(room)

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
               starts_at: ~U[2026-10-05 09:00:00Z],
               ends_at: ~U[2026-10-05 10:00:00Z]
             }
           ] = EventVideoRoomQueries.list_for_event(calendar.id, event.uid)

    assert video_integration_id == talk.id
  end

  defp insert_room(user, event, host) do
    talk = insert_talk_integration(user, host)

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        calendar_integration_id: event.calendar_integration_id,
        event_uid: event.uid,
        room_id: "grid0001",
        starts_at: ~U[2026-10-05 09:00:00Z],
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
