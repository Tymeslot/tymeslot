defmodule Tymeslot.CalendarGrid.TeamsSeparateEventCleanupTest do
  @moduledoc """
  The separate Outlook event a Teams meeting gets when it cannot be attached
  to the grid event itself: the Teams integration is on another Microsoft
  account than the Outlook calendar, or the calendar is not Outlook at all.

  That event is the Teams room. Once the grid event no longer uses it
  (deleted, switched to another provider or to none, or given a fresh Teams
  room) it should be deleted, and when the grid event moves in time it should
  move too, as a booking's own Teams event does. The meeting attached to the
  grid event itself must never be deleted as a room, since its id is the grid
  event's own.

  Every scenario is set up through `CalendarGrid.change_event_video/3`, so
  whatever that path records about the room is what the later action sees.
  The calendar is stubbed at `Tymeslot.CalendarMock`; the Teams provider runs
  for real against Microsoft Graph stubbed at `Tymeslot.HTTPClientMock`. Room
  work queued on `Tymeslot.Workers.VideoSyncWorker` is drained before the
  Graph requests are read, so the assertions hold whether the clean-up runs
  inline or queued. The stubbed join links are opaque, as Teams' own are:
  nothing in them names the event they live on.
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
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption

  setup :verify_on_exit!

  @calendar_account "entra-oid-organiser"
  @graph "https://graph.microsoft.com/v1.0"
  @grid_event_id "AAMk-grid-event"
  @mirotalk_url "https://video.example.com/join/room-123"

  setup do
    user = insert(:user)

    calendar =
      insert(:calendar_integration,
        user: user,
        provider: "outlook",
        provider_account_id: @calendar_account,
        default_booking_calendar_id: "outlook-calendar-1"
      )

    stub(Tymeslot.TeamsOAuthHelperMock, :validate_token, fn _config -> {:ok, :valid} end)
    stub_graph()

    %{
      user: user,
      calendar: calendar,
      own_teams: insert_teams(user, @calendar_account),
      other_teams: insert_teams(user, "entra-oid-other")
    }
  end

  describe "a grid event whose Teams meeting is a separate event on another account" do
    setup ctx do
      %{event: with_separate_teams(ctx, insert_event(ctx.calendar), ctx.other_teams)}
    end

    test "deleting the grid event deletes the separate Teams event", ctx do
      expect_calendar_delete()

      assert {:ok, _deleted} = CalendarGrid.delete_event(ctx.user.id, ctx.event)
      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
      refute_grid_event_deleted_on_graph()
    end

    test "switching to no video deletes the separate Teams event", ctx do
      expect_calendar_update()

      assert {:ok, nil} = CalendarGrid.change_event_video(ctx.user.id, ctx.event, nil)
      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
      refute_grid_event_deleted_on_graph()
    end

    test "switching to another provider deletes the separate Teams event", ctx do
      mirotalk = insert_mirotalk(ctx.user)
      expect_calendar_update()

      assert {:ok, @mirotalk_url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, mirotalk.id)

      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
      refute_grid_event_deleted_on_graph()
    end

    test "a fresh Teams room on a third account replaces and deletes the old one", ctx do
      third = insert_teams(ctx.user, "entra-oid-third")
      expect_calendar_update()

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, ctx.event, third.id)
      assert url == join_url("AAMk-own-event-2")

      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
      refute {:delete, own_event_url(2)} in graph_calls()
      refute_grid_event_deleted_on_graph()
    end

    test "switching to Teams attached from the calendar's own account deletes the old event",
         ctx do
      expect_calendar_update()

      assert {:ok, url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, ctx.own_teams.id)

      assert url == join_url(@grid_event_id)

      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
      refute_grid_event_deleted_on_graph()
    end

    test "rescheduling the grid event moves the separate Teams event with it", ctx do
      expect_calendar_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(ctx.user.id, ctx.event, %{
                 start_at: ~U[2030-06-02 14:00:00.000000Z],
                 end_at: ~U[2030-06-02 15:00:00.000000Z]
               })

      drain_room_jobs()

      patches = for {:patch, url, body} <- graph_requests(), url == own_event_url(1), do: body

      assert [body | _later] = patches
      moved = Jason.decode!(body)
      assert %{"start" => %{"dateTime" => "2030-06-02T14:00:00" <> _offset}} = moved
      assert %{"end" => %{"dateTime" => "2030-06-02T15:00:00" <> _end_offset}} = moved

      # The move carries no title, so the event keeps the one it was made
      # with rather than falling back to a generic one.
      refute Map.has_key?(moved, "subject")
    end

    test "changing only the end moves the separate Teams event's end", ctx do
      expect_calendar_update()

      assert {:ok, _updated} =
               CalendarGrid.update_event(ctx.user.id, ctx.event, %{
                 end_at: ~U[2030-06-01 11:30:00.000000Z]
               })

      drain_room_jobs()

      patches = for {:patch, url, body} <- graph_requests(), url == own_event_url(1), do: body

      assert [body | _later] = patches
      assert %{"end" => %{"dateTime" => "2030-06-01T11:30:00" <> _offset}} = Jason.decode!(body)
    end
  end

  describe "a Google grid event whose Teams meeting is a separate Outlook event" do
    test "deleting the grid event deletes the separate Teams event", ctx do
      google =
        insert(:calendar_integration,
          user: ctx.user,
          provider: "google",
          provider_account_id: "google-sub-1",
          default_booking_calendar_id: "primary"
        )

      event =
        insert_event(google, %{
          uid: "google-grid-event",
          provider: "google",
          provider_event_id: "google-grid-event",
          provider_calendar_id: "primary"
        })

      event = with_separate_teams(ctx, event, ctx.own_teams)
      expect_calendar_delete()

      assert {:ok, _deleted} = CalendarGrid.delete_event(ctx.user.id, event)
      drain_room_jobs()

      assert {:delete, own_event_url(1)} in graph_calls()
    end
  end

  # Regression guard: the attached meeting's room id is the grid event's own
  # Outlook id, so a clean-up that deletes Teams rooms by id must not reach it.
  describe "a grid event whose Teams meeting is attached to it" do
    setup ctx do
      event = insert_event(ctx.calendar)

      assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, ctx.own_teams.id)
      assert url == join_url(@grid_event_id)
      assert [{:patch, _attach_url}] = graph_calls()
      flush_graph()

      %{event: reload(event)}
    end

    test "deleting it deletes the event only through the calendar", ctx do
      expect_calendar_delete()

      assert {:ok, _deleted} = CalendarGrid.delete_event(ctx.user.id, ctx.event)
      drain_room_jobs()

      assert graph_calls() == []
    end

    test "switching to no video leaves the Outlook event on Graph", ctx do
      assert {:ok, nil} = CalendarGrid.change_event_video(ctx.user.id, ctx.event, nil)
      drain_room_jobs()

      assert graph_calls() == []
      assert {nil, nil} == video_of(reload(ctx.event))
    end

    test "switching to another provider leaves the Outlook event on Graph", ctx do
      mirotalk = insert_mirotalk(ctx.user)
      expect_calendar_update()

      assert {:ok, @mirotalk_url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, mirotalk.id)

      drain_room_jobs()

      refute_grid_event_deleted_on_graph()
    end

    test "switching to a separate Teams room on another account leaves the grid event", ctx do
      expect_calendar_update()

      assert {:ok, url} =
               CalendarGrid.change_event_video(ctx.user.id, ctx.event, ctx.other_teams.id)

      assert url == join_url("AAMk-own-event-1")
      drain_room_jobs()

      refute_grid_event_deleted_on_graph()
    end
  end

  # Gives `event` a separate Teams meeting through the grid's own path and
  # returns its cached row, with the Graph requests so far consumed.
  defp with_separate_teams(ctx, event, teams) do
    expect_calendar_update()

    assert {:ok, url} = CalendarGrid.change_event_video(ctx.user.id, event, teams.id)
    assert url == join_url("AAMk-own-event-1")
    assert [{:post, "#{@graph}/me/events"}] = graph_calls()
    flush_graph()

    row = reload(event)
    assert video_of(row) == {url, teams.id}
    row
  end

  # Graph as the Teams provider sees it: a POST creates an event of its own
  # with a new id each time, and any other request addresses an event by the
  # id at the end of its path. Every request is reported to the test.
  defp stub_graph do
    test_pid = self()
    created = :counters.new(1, [])

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:graph, method, url, body})

      event_id =
        case method do
          :post ->
            :counters.add(created, 1, 1)
            "AAMk-own-event-#{:counters.get(created, 1)}"

          _other ->
            url |> String.split("/") |> List.last() |> URI.decode()
        end

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

    stub(Tymeslot.HTTPClientMock, :post, fn _url, _body, _headers, _opts ->
      body = Jason.encode!(%{"room_id" => "room-123", "meeting_url" => @mirotalk_url})
      {:ok, %Req.Response{status: 200, body: body}}
    end)
  end

  defp expect_calendar_update do
    stub(Tymeslot.CalendarMock, :update_event, fn _uid, _payload, _context -> :ok end)
  end

  defp expect_calendar_delete do
    expect(Tymeslot.CalendarMock, :delete_event, fn _uid, _context, _opts -> :ok end)
  end

  defp drain_room_jobs, do: Oban.drain_queue(queue: :video_rooms, with_recursion: true)

  defp refute_grid_event_deleted_on_graph do
    refute {:delete, "#{@graph}/me/events/#{@grid_event_id}"} in graph_calls()
  end

  defp insert_teams(user, account_id) do
    insert(:video_integration,
      user: user,
      name: "Teams #{account_id}",
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

  defp insert_mirotalk(user), do: insert(:video_integration, user: user, provider: "mirotalk")

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

  defp video_of(row), do: {row.video_link, row.video_integration_id}

  defp own_event_url(n), do: "#{@graph}/me/events/AAMk-own-event-#{n}"

  # Opaque, as a real Teams join link is: it does not carry the id of the
  # Outlook event the meeting lives on.
  defp join_url(event_id) do
    token = :sha256 |> :crypto.hash(event_id) |> Base.encode16(case: :lower) |> binary_part(0, 24)
    "https://teams.microsoft.com/l/meetup-join/19%3ameeting_#{token}%40thread.v2/0"
  end

  defp graph_calls, do: for({method, url, _body} <- graph_requests(), do: {method, url})

  defp flush_graph do
    receive do
      {:graph, _method, _url, _body} -> flush_graph()
    after
      0 -> :ok
    end
  end

  # The Graph requests received so far, in order. Messages are left in the
  # mailbox, so repeated reads see the same list.
  defp graph_requests do
    {:messages, messages} = Process.info(self(), :messages)
    for {:graph, method, url, body} <- messages, do: {method, url, body}
  end
end
