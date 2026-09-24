defmodule Tymeslot.CalendarGrid.EventVideoTeamsTest do
  @moduledoc """
  Microsoft Teams on a dashboard calendar grid event in an Outlook calendar.

  A Teams meeting is an Outlook event with an online meeting switched on.
  When the Teams integration and the Outlook calendar belong to the same
  Microsoft account, the meeting is attached to the grid event itself rather
  than written as a second event beside it, both when the event is created
  with Teams and when Teams is chosen for an existing event. On another
  account the meeting still needs an event of its own.

  The Outlook calendar is stubbed at `Tymeslot.CalendarMock`; the Teams
  provider runs for real, with Microsoft Graph stubbed at
  `Tymeslot.HTTPClientMock`, so every Graph request the provider makes is
  reported to the test in the order it was made.
  """

  # Not async: room creation runs through the application-wide Teams circuit
  # breaker, which DataCase resets only between non-async modules.
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventCreation
  alias Tymeslot.Integrations.Calendar.CreatedEvent
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.VideoSyncWorker
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.CreateExecution

  setup :verify_on_exit!

  @account "entra-oid-organiser"
  @graph "https://graph.microsoft.com/v1.0"
  @grid_event_id "AAMk-grid-event"
  @own_event_id "AAMk-own-event"
  @zoom_url "https://zoom.us/j/86360699337"

  setup do
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        provider_account_id: @account,
        default_booking_calendar_id: "outlook-calendar-1"
      )

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)

    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:graph, method, url, body})
      event_id = graph_event_id(method, url)

      {:ok,
       %Req.Response{
         status: if(method == :post, do: 201, else: 200),
         body:
           Jason.encode!(%{
             "id" => event_id,
             "onlineMeeting" => %{"joinUrl" => join_url(event_id)}
           })
       }}
    end)

    %{user: user, calendar: calendar, teams: insert_teams(user, @account)}
  end

  describe "creating an Outlook event with Teams from the calendar's own account" do
    test "writes one event and attaches the meeting to it", ctx do
      expect_create()

      assert {:ok, result} = EventCreation.run_create_event(create_payload(ctx, ctx.teams))

      assert_received {:create, event_data}
      refute Map.has_key?(event_data, :conference_data)
      assert event_data.description == "Agenda"

      # Only the online meeting, on the event Outlook just named: a POST to
      # /me/events would be the second event this avoids.
      assert [{:patch, url, body}] = graph_requests()
      assert url == "#{@graph}/me/events/#{@grid_event_id}"
      assert Jason.decode!(body)["isOnlineMeeting"] == true

      assert result.meeting_url == join_url(@grid_event_id)
    end

    test "caches the Teams link on the grid event", ctx do
      expect_create()

      assert {:ok, result} = EventCreation.run_create_event(create_payload(ctx, ctx.teams))
      {:noreply, _socket} = CreateExecution.handle_create_result({:ok, result}, build_socket())

      {:ok, cached} = ProviderCalendarEventQueries.get_by_uid(ctx.calendar.id, result.uid)

      assert {cached.video_link, cached.video_integration_id} ==
               {join_url(@grid_event_id), ctx.teams.id}
    end
  end

  describe "creating an Outlook event with Teams from another account" do
    test "still gives the meeting an event of its own, linked from the description", ctx do
      other = insert_teams(ctx.user, "entra-oid-other")
      expect_create()

      assert {:ok, result} = EventCreation.run_create_event(create_payload(ctx, other))

      # The meeting's own event exists first, so its link can go into the
      # description the calendar is given.
      assert [{:graph, :post, url, _body}, {:create, event_data}] = mailbox()
      assert url == "#{@graph}/me/events"
      assert event_data.description == "Agenda\n\nJoin video call: #{join_url(@own_event_id)}"
      assert result.meeting_url == join_url(@own_event_id)
    end
  end

  describe "choosing Teams from the calendar's own account for an existing Outlook event" do
    test "attaches the meeting to the event and caches its link", ctx do
      event = insert_event(ctx.calendar)
      expect(Tymeslot.CalendarMock, :update_event, 0, fn _uid, _payload, _context -> :ok end)

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.teams.id)
      assert url == join_url(@grid_event_id)

      assert [{:patch, patched, _body}] = graph_requests()
      assert patched == "#{@graph}/me/events/#{@grid_event_id}"

      row = reload(event)
      assert {row.video_link, row.video_integration_id} == {url, ctx.teams.id}
    end

    test "takes the previous room's line out first, and writes none for the meeting", ctx do
      zoom = insert(:video_integration, user: ctx.user, provider: "zoom")

      event =
        insert_event(ctx.calendar, %{
          description: "Agenda\n\nJoin video call: #{@zoom_url}",
          video_link: @zoom_url,
          video_integration_id: zoom.id
        })

      expect_update()

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.teams.id)

      # The description write comes before the attach, so it cannot overwrite
      # the join details Outlook adds to the event with the meeting.
      assert [{:update, payload}, {:graph, :patch, _url, _body}] = mailbox()
      assert payload.description == "Agenda"
      refute Map.has_key?(payload, :conference_data)

      assert CalendarGrid.changed_event(ctx.user.id, event, ctx.teams.id, url).description ==
               "Agenda"

      assert_enqueued(worker: VideoSyncWorker, args: %{"room_id" => "86360699337"})
    end

    test "leaves the event without video when the meeting could not be attached", ctx do
      zoom = insert(:video_integration, user: ctx.user, provider: "zoom")

      event =
        insert_event(ctx.calendar, %{
          description: "Agenda\n\nJoin video call: #{@zoom_url}",
          video_link: @zoom_url,
          video_integration_id: zoom.id
        })

      expect_update()

      stub(Tymeslot.HTTPClientMock, :request, fn :patch, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 403,
           body: Jason.encode!(%{"error" => %{"code" => "ErrorAccessDenied", "message" => "No"}})
         }}
      end)

      assert {:error, {:http_error, 403, _message}} =
               CalendarGrid.change_event_video(ctx.user.id, event, ctx.teams.id)

      row = reload(event)
      assert {row.video_link, row.video_integration_id} == {nil, nil}
      assert_enqueued(worker: VideoSyncWorker, args: %{"room_id" => "86360699337"})
    end

    test "gives the meeting its own event while the Outlook event's id is unknown", ctx do
      event = insert_event(ctx.calendar, %{provider_event_id: nil})
      expect_update()

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.teams.id)
      assert url == join_url(@own_event_id)

      assert [{:graph, :post, "#{@graph}/me/events", _body}, {:update, payload}] = mailbox()
      assert payload.description == "Agenda\n\nJoin video call: #{url}"
    end
  end

  describe "choosing Teams from another account for an existing Outlook event" do
    test "gives the meeting an event of its own, linked from the description", ctx do
      other = insert_teams(ctx.user, "entra-oid-other")
      event = insert_event(ctx.calendar)
      expect_update()

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, other.id)

      assert [{:graph, :post, "#{@graph}/me/events", _body}, {:update, payload}] = mailbox()
      assert payload.description == "Agenda\n\nJoin video call: #{url}"
    end
  end

  # The attached meeting's room id is the grid event's own Outlook id, so
  # deleting it as a room would delete the event.
  describe "an Outlook event whose Teams meeting is attached to it" do
    setup ctx do
      event =
        insert_event(ctx.calendar, %{
          video_link: join_url(@grid_event_id),
          video_integration_id: ctx.teams.id
        })

      %{event: event}
    end

    test "moving it to None deletes nothing on Graph and queues no room delete", ctx do
      assert {:ok, nil} = CalendarGrid.change_event_video(ctx.user.id, ctx.event, nil)

      assert graph_requests() == []
      refute_enqueued(worker: VideoSyncWorker)

      row = reload(ctx.event)
      assert {row.video_link, row.video_integration_id} == {nil, nil}
    end

    test "moving it to another room keeps the event and writes the new link", ctx do
      mirotalk = insert(:video_integration, user: ctx.user, provider: "mirotalk")
      new_url = "https://video.example.com/join/room-123"
      body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => new_url})

      stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: body}}
      end)

      expect_update()

      assert {:ok, ^new_url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, mirotalk.id)

      assert [{:update, payload}] = mailbox()
      assert payload.description == "Agenda\n\nJoin video call: #{new_url}"
      refute_enqueued(worker: VideoSyncWorker)
    end

    test "deleting it deletes the event once, through the calendar only", ctx do
      test_pid = self()

      expect(Tymeslot.CalendarMock, :delete_event, fn uid, _context, _opts ->
        send(test_pid, {:deleted, uid})
        :ok
      end)

      assert {:ok, _deleted} = CalendarGrid.delete_event(ctx.user.id, ctx.event)

      assert_received {:deleted, _uid}
      assert graph_requests() == []
      refute_enqueued(worker: VideoSyncWorker)
    end
  end

  defp insert_teams(user, account_id) do
    insert(:video_integration,
      user: user,
      name: "Teams",
      provider: "teams",
      base_url: nil,
      api_key_encrypted: nil,
      access_token_encrypted: Encryption.encrypt("graph-access-token"),
      refresh_token_encrypted: Encryption.encrypt("graph-refresh-token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
      oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite offline_access",
      provider_account_id: account_id
    )
  end

  defp create_payload(ctx, video) do
    %{
      creating: %{
        title: "Planning",
        description: "Agenda",
        integration_id: ctx.calendar.id,
        calendar_id: "outlook-calendar-1",
        attendees: [],
        video_integration_id: video.id
      },
      user_id: ctx.user.id,
      start_at: ~U[2030-06-01 09:00:00Z],
      end_at: ~U[2030-06-01 10:00:00Z]
    }
  end

  # Outlook answers a create with the event it made: its Graph id, and the
  # iCalendar UID its sync keys the event by.
  defp expect_create do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :create_event, fn event_data, _context ->
      send(test_pid, {:create, event_data})

      {:ok,
       CreatedEvent.from_provider_event(%{
         uid: @grid_event_id,
         ical_uid: "040000008200E00074C5B7101A82E008-grid",
         summary: event_data.summary
       })}
    end)
  end

  defp expect_update do
    test_pid = self()

    expect(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      send(test_pid, {:update, payload})
      :ok
    end)
  end

  defp insert_event(calendar, attrs \\ %{}) do
    defaults = %{
      calendar_integration: calendar,
      uid: "040000008200E00074C5B7101A82E008-existing",
      provider: "outlook",
      provider_event_id: @grid_event_id,
      provider_calendar_id: "outlook-calendar-1",
      summary: "Planning",
      description: "Agenda",
      start_at: ~U[2030-06-01 09:00:00.000000Z],
      end_at: ~U[2030-06-01 10:00:00.000000Z],
      all_day: false,
      sync_state: "synced"
    }

    insert(:provider_calendar_event, Map.merge(defaults, attrs))
  end

  defp reload(event) do
    {:ok, row} = ProviderCalendarEventQueries.get_by_uid(event.calendar_integration_id, event.uid)
    row
  end

  defp build_socket, do: %Phoenix.LiveView.Socket{assigns: %{__changed__: %{}, flash: %{}}}

  # A new event is created as the room's own; any other request addresses an
  # existing event by the id at the end of its path.
  defp graph_event_id(:post, _url), do: @own_event_id
  defp graph_event_id(_method, url), do: url |> String.split("/") |> List.last() |> URI.decode()

  defp join_url(event_id), do: "https://teams.microsoft.com/l/meetup-join/#{event_id}"

  defp graph_requests do
    for {:graph, method, url, body} <- mailbox(), do: {method, url, body}
  end

  # Every message the test has received so far, in the order it arrived.
  defp mailbox do
    receive do
      message -> [message | mailbox()]
    after
      0 -> []
    end
  end
end
