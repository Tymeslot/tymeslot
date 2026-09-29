defmodule Tymeslot.CalendarGrid.SeriesTransferGoogleTest do
  @moduledoc """
  Moving a Google recurring series to another calendar through
  `CalendarGrid.move_event/3`, down to the HTTP client.

  Within one integration the master is moved with Google's own
  `events.move`, and nothing else is written. Across integrations the
  master is read on the source, inserted into the destination calendar, and
  only then deleted on the source. The two integrations hold different
  access tokens, so every request shows which integration sent it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox
  import Tymeslot.WorkerTestHelpers, only: [running_job: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncRequest

  setup :verify_on_exit!

  @api "https://www.googleapis.com/calendar/v3"
  @source_calendar "team-calendar"
  @destination_calendar "projects@group.calendar.google.com"
  @master_url "#{@api}/calendars/#{@source_calendar}/events/master1"

  @conference %{
    "conferenceId" => "abc-defg-hij",
    "conferenceSolution" => %{"key" => %{"type" => "hangoutsMeet"}, "name" => "Google Meet"},
    "entryPoints" => [
      %{"entryPointType" => "video", "uri" => "https://meet.google.com/abc-defg-hij"}
    ]
  }

  # The master as Google returns it: a weekly series with one occurrence
  # taken out, and a Meet.
  @master %{
    "kind" => "calendar#event",
    "id" => "master1",
    "iCalUID" => "master1@google.com",
    "etag" => "\"3181\"",
    "sequence" => 2,
    "status" => "confirmed",
    "htmlLink" => "https://www.google.com/calendar/event?eid=master1",
    "created" => "2026-09-01T09:00:00.000Z",
    "updated" => "2026-09-02T09:00:00.000Z",
    "organizer" => %{"email" => "source@example.com", "self" => true},
    "creator" => %{"email" => "source@example.com", "self" => true},
    "hangoutLink" => "https://meet.google.com/abc-defg-hij",
    "summary" => "Weekly standup",
    "start" => %{"dateTime" => "2026-10-05T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
    "end" => %{"dateTime" => "2026-10-05T09:30:00+02:00", "timeZone" => "Europe/Berlin"},
    "recurrence" => [
      "RRULE:FREQ=WEEKLY;BYDAY=MO",
      "EXDATE;TZID=Europe/Berlin:20261012T090000"
    ],
    "conferenceData" =>
      Map.put(@conference, "createRequest", %{
        "requestId" => "request-1",
        "status" => %{"statusCode" => "success"}
      })
  }

  @copy %{"id" => "copy1", "iCalUID" => "copy1@google.com"}

  setup do
    previous = Application.get_env(:tymeslot, :google_calendar_api_module)
    Application.put_env(:tymeslot, :google_calendar_api_module, GoogleAPI)
    on_exit(fn -> Application.put_env(:tymeslot, :google_calendar_api_module, previous) end)

    user = insert(:user)
    source = google_integration(user, "source-token")

    row = fn attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: source,
            provider: "google",
            provider_calendar_id: @source_calendar,
            summary: "Weekly standup",
            all_day: false,
            timezone: "Europe/Berlin",
            recurring_event_id: "master1",
            sync_state: "synced"
          },
          attrs
        )
      )
    end

    first =
      row.(%{
        uid: "master1@google.com_20261005T070000Z",
        provider_event_id: "master1_20261005T070000Z",
        start_at: ~U[2026-10-05 07:00:00.000000Z],
        end_at: ~U[2026-10-05 07:30:00.000000Z]
      })

    occurrence =
      row.(%{
        uid: "master1@google.com_20261019T070000Z",
        provider_event_id: "master1_20261019T070000Z",
        start_at: ~U[2026-10-19 07:00:00.000000Z],
        end_at: ~U[2026-10-19 07:30:00.000000Z]
      })

    unrelated =
      row.(%{
        uid: "offsite@google.com",
        provider_event_id: "offsite1",
        recurring_event_id: nil,
        start_at: ~U[2026-10-06 07:00:00.000000Z],
        end_at: ~U[2026-10-06 08:00:00.000000Z]
      })

    %{
      user: user,
      source: source,
      first: first,
      occurrence: occurrence,
      unrelated: unrelated
    }
  end

  defp google_integration(user, token) do
    insert(:calendar_integration,
      user: user,
      provider: "google",
      access_token_encrypted: Encryption.encrypt(token),
      refresh_token_encrypted: Encryption.encrypt("refresh-" <> token),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: "https://www.googleapis.com/auth/calendar"
    )
  end

  # Answers every request through `answer` and records it, in order.
  defp serve(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, headers, _opts ->
      send(test_pid, {:request, method, url, body, headers})

      case answer.(method, url) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body, headers} ->
        [%{method: method, url: url, body: body, token: bearer(headers)} | requests()]
    after
      0 -> []
    end
  end

  defp bearer(headers), do: for({"Authorization", "Bearer " <> token} <- headers, do: token)

  defp split_url(url) do
    %URI{query: query} = uri = URI.parse(url)
    {URI.to_string(%{uri | query: nil}), URI.decode_query(query || "")}
  end

  defp move(user, event, integration, calendar_id) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: calendar_id})
  end

  defp insert_room(user, integration) do
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk")
    ends = DateTime.add(DateTime.utc_now(:second), 30 * 86_400, :second)

    {:ok, room} =
      EventVideoRoomQueries.insert(%{
        user_id: user.id,
        video_integration_id: talk.id,
        provider: "nextcloud_talk",
        calendar_integration_id: integration.id,
        event_uid: "master1@google.com",
        provider_event_id: "master1",
        provider_calendar_id: @source_calendar,
        room_id: "room-#{System.unique_integer([:positive])}",
        lobby_opens_at: DateTime.add(ends, -900, :second),
        ends_at: ends
      })

    room
  end

  defp assert_series_cached(integration, rows) do
    for row <- rows do
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(integration.id, row.uid)
    end
  end

  defp refute_series_cached(integration, rows) do
    for row <- rows do
      assert ProviderCalendarEventQueries.get_by_uid(integration.id, row.uid) ==
               {:error, :not_found}
    end
  end

  defp sync_job(integration),
    do: [worker: SyncGoogleCalendarWorker, args: %{"calendar_integration_id" => integration.id}]

  describe "moving a Google series to another calendar of the same integration" do
    test "moves the master with Google's own move, and writes nothing else", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      serve(fn :post, _url -> {200, Map.put(@master, "organizer", %{"email" => "x"})} end)

      assert {:ok, moved} = move(user, occurrence, source, @destination_calendar)
      assert moved == %{uid: "master1@google.com", integration_id: source.id}

      assert [%{method: :post, url: url, body: "", token: ["source-token"]}] = requests()

      assert split_url(url) ==
               {@master_url <> "/move",
                %{"destination" => @destination_calendar, "sendUpdates" => "none"}}
    end

    test "drops the series' rows, keeps the room on the moved master, and syncs once", %{
      user: user,
      source: source,
      first: first,
      occurrence: occurrence,
      unrelated: unrelated
    } do
      room = insert_room(user, source)
      serve(fn :post, _url -> {200, @master} end)

      assert {:ok, _moved} = move(user, occurrence, source, @destination_calendar)

      refute_series_cached(source, [first, occurrence])
      assert_series_cached(source, [unrelated])

      assert %{
               calendar_integration_id: room_integration_id,
               event_uid: "master1@google.com",
               provider_event_id: "master1",
               provider_calendar_id: @destination_calendar
             } = Repo.reload!(room)

      assert room_integration_id == source.id
      assert [_one] = all_enqueued(sync_job(source))
    end

    test "a sync already running runs again once it finishes", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      running =
        running_job(SyncGoogleCalendarWorker, %{"calendar_integration_id" => source.id})

      serve(fn :post, _url -> {200, @master} end)

      assert {:ok, _moved} = move(user, occurrence, source, @destination_calendar)

      assert all_enqueued(sync_job(source)) == []
      assert {:snooze, _seconds} = SyncRequest.rerun_if_requested(:ok, running)
    end

    test "a move Google refuses leaves everything as it was", %{
      user: user,
      source: source,
      first: first,
      occurrence: occurrence
    } do
      room = insert_room(user, source)
      serve(fn :post, _url -> {404, %{"error" => %{"message" => "Not Found"}}} end)

      assert {:error, :not_found} = move(user, occurrence, source, @destination_calendar)

      assert [%{method: :post}] = requests()
      assert_series_cached(source, [first, occurrence])
      assert Repo.reload!(room).provider_calendar_id == @source_calendar
      assert all_enqueued() == []
    end

    test "a move to the calendar the series is on is refused before anything is sent", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      serve(fn _method, _url -> flunk("nothing may be sent") end)

      assert move(user, occurrence, source, @source_calendar) == {:error, :same_calendar}

      assert requests() == []
      assert_series_cached(source, [occurrence])
      assert all_enqueued() == []
    end
  end

  describe "moving a Google series to a calendar of another Google integration" do
    setup %{user: user} do
      %{destination: google_integration(user, "destination-token")}
    end

    defp across(post_status \\ 200, delete_status \\ 204) do
      fn
        :get, _url -> {200, @master}
        :post, _url -> {post_status, if(post_status == 200, do: @copy, else: %{"error" => %{}})}
        :delete, _url -> {delete_status, nil}
      end
    end

    test "copies the master into the destination, then deletes it at the source", %{
      user: user,
      destination: destination,
      occurrence: occurrence
    } do
      serve(across())

      assert {:ok, moved} = move(user, occurrence, destination, @destination_calendar)
      assert moved == %{uid: "copy1@google.com", integration_id: destination.id}

      assert [
               %{method: :get, url: @master_url, token: ["source-token"]},
               %{method: :post, url: post_url, body: body, token: ["destination-token"]},
               %{method: :delete, url: @master_url, token: ["source-token"]}
             ] = requests()

      assert split_url(post_url) ==
               {"#{@api}/calendars/#{@destination_calendar}/events",
                %{"sendUpdates" => "none", "conferenceDataVersion" => "1"}}

      # The whole series as the source holds it, the taken-out occurrence
      # included, and the Meet's join details without a request for a new
      # one; nothing Google assigns.
      assert Jason.decode!(body) == %{
               "status" => "confirmed",
               "summary" => "Weekly standup",
               "start" => @master["start"],
               "end" => @master["end"],
               "recurrence" => [
                 "RRULE:FREQ=WEEKLY;BYDAY=MO",
                 "EXDATE;TZID=Europe/Berlin:20261012T090000"
               ],
               "conferenceData" => @conference
             }
    end

    test "drops the source's rows, moves the room, and syncs both integrations", %{
      user: user,
      source: source,
      destination: destination,
      first: first,
      occurrence: occurrence,
      unrelated: unrelated
    } do
      room = insert_room(user, source)
      serve(across())

      assert {:ok, _moved} = move(user, occurrence, destination, @destination_calendar)

      refute_series_cached(source, [first, occurrence])
      assert_series_cached(source, [unrelated])

      assert %{
               calendar_integration_id: room_integration_id,
               event_uid: "copy1@google.com",
               provider_event_id: "copy1",
               provider_calendar_id: @destination_calendar
             } = Repo.reload!(room)

      assert room_integration_id == destination.id
      assert_enqueued(sync_job(destination))
      assert_enqueued(sync_job(source))
    end

    test "a copy the destination refuses deletes nothing and leaves everything as it was", %{
      user: user,
      source: source,
      destination: destination,
      first: first,
      occurrence: occurrence
    } do
      room = insert_room(user, source)
      serve(across(404))

      assert {:error, :not_found} = move(user, occurrence, destination, @destination_calendar)

      assert [%{method: :get}, %{method: :post}] = requests()
      assert_series_cached(source, [first, occurrence])
      assert Repo.reload!(room).calendar_integration_id == source.id
      assert all_enqueued() == []
    end

    test "a master the source will not delete is left behind, and the copy kept", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      serve(across(200, 404))

      assert {:ok, moved} = move(user, occurrence, destination, @destination_calendar)

      assert moved == %{
               uid: "copy1@google.com",
               integration_id: destination.id,
               source: :left_behind
             }

      # The copy is never deleted again.
      assert [%{method: :get}, %{method: :post}, %{method: :delete, url: @master_url}] =
               requests()

      assert_enqueued(sync_job(source))
    end

    test "a master Google answers for as deleted is not copied", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      serve(fn :get, _url -> {200, Map.put(@master, "status", "cancelled")} end)

      assert {:error, :not_found} = move(user, occurrence, destination, @destination_calendar)

      assert [%{method: :get}] = requests()
      assert_series_cached(source, [occurrence])
    end

    test "a destination integration of another user is refused before anything is sent", %{
      user: user,
      occurrence: occurrence
    } do
      stranger = google_integration(insert(:user), "stranger-token")
      serve(fn _method, _url -> flunk("nothing may be sent") end)

      assert move(user, occurrence, stranger, @destination_calendar) ==
               {:error, :no_destination_calendar}

      assert requests() == []
    end
  end
end
