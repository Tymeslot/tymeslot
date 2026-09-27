defmodule Tymeslot.CalendarGrid.SeriesTransferOutlookTest do
  @moduledoc """
  Moving an Outlook recurring series to another calendar through
  `CalendarGrid.move_event/3`, down to the HTTP client.

  Graph has no move for events, so within one integration and across two
  alike the master is read on the source, created in the destination
  calendar, and only then deleted on the source. The two integrations hold
  different access tokens, so every request shows which integration sent
  it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker

  setup :verify_on_exit!

  @graph "https://graph.microsoft.com/v1.0"
  @zone "W. Europe Standard Time"
  @master_calendar "team-calendar"
  @destination_calendar "projects-calendar"
  @master_url "#{@graph}/me/events/master-1"

  @recurrence %{
    "pattern" => %{
      "type" => "weekly",
      "interval" => 1,
      "daysOfWeek" => ["monday"],
      "firstDayOfWeek" => "sunday"
    },
    "range" => %{
      "type" => "endDate",
      "startDate" => "2026-10-05",
      "endDate" => "2027-03-29",
      "recurrenceTimeZone" => @zone
    }
  }

  @attendee_address %{"address" => "guest@example.com", "name" => "Guest"}

  # The master as Graph returns it to a client that asks for UTC: a weekly
  # Monday series at 09:00 in Berlin, with a guest and a Teams meeting.
  @master %{
    "id" => "master-1",
    "iCalUId" => "040000008200E00074C5B7101A82E008",
    "changeKey" => "DwAAABYAAAA",
    "webLink" => "https://outlook.office365.com/owa/?itemid=master-1",
    "createdDateTime" => "2026-09-20T10:00:00Z",
    "type" => "seriesMaster",
    "seriesMasterId" => nil,
    "subject" => "Weekly standup",
    "body" => %{"contentType" => "text", "content" => "Agenda"},
    "showAs" => "busy",
    "isAllDay" => false,
    "isCancelled" => false,
    "isOnlineMeeting" => true,
    "onlineMeetingProvider" => "teamsForBusiness",
    "onlineMeeting" => %{"joinUrl" => "https://teams.microsoft.com/l/meetup-join/1"},
    "organizer" => %{"emailAddress" => %{"address" => "owner@example.com"}},
    "attendees" => [
      %{
        "type" => "required",
        "status" => %{"response" => "accepted", "time" => "2026-09-21T10:00:00Z"},
        "emailAddress" => @attendee_address
      }
    ],
    "start" => %{"dateTime" => "2026-10-05T07:00:00.0000000", "timeZone" => "UTC"},
    "end" => %{"dateTime" => "2026-10-05T07:30:00.0000000", "timeZone" => "UTC"},
    "originalStartTimeZone" => @zone,
    "originalEndTimeZone" => @zone,
    "recurrence" => @recurrence
  }

  # Everything of the master a create is given: its writable fields, the
  # guest without their response, its timing on the series' own wall clock
  # and its own recurrence; no ids and no online meeting.
  @copy_body %{
    "subject" => "Weekly standup",
    "body" => %{"contentType" => "text", "content" => "Agenda"},
    "showAs" => "busy",
    "isAllDay" => false,
    "attendees" => [%{"type" => "required", "emailAddress" => @attendee_address}],
    "start" => %{"dateTime" => "2026-10-05T09:00:00", "timeZone" => @zone},
    "end" => %{"dateTime" => "2026-10-05T09:30:00", "timeZone" => @zone},
    "recurrence" => @recurrence
  }

  @copy %{"id" => "copy-1", "iCalUId" => "040000008200E00074C5B7101A82E009"}

  setup do
    previous = Application.get_env(:tymeslot, :outlook_calendar_api_module)
    Application.put_env(:tymeslot, :outlook_calendar_api_module, OutlookAPI)
    on_exit(fn -> Application.put_env(:tymeslot, :outlook_calendar_api_module, previous) end)

    user = insert(:user)
    source = outlook_integration(user, "source-token")

    # The delta sync caches every Outlook row as on "primary", whichever
    # calendar holds its series.
    row = fn attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: source,
            provider: "outlook",
            provider_calendar_id: "primary",
            summary: "Weekly standup",
            all_day: false,
            timezone: "Europe/Berlin",
            recurring_event_id: "master-1",
            provider_metadata: %{"type" => "occurrence"},
            sync_state: "synced"
          },
          attrs
        )
      )
    end

    first =
      row.(%{
        uid: "standup_20261005T070000Z",
        provider_event_id: "occurrence-1",
        start_at: ~U[2026-10-05 07:00:00.000000Z],
        end_at: ~U[2026-10-05 07:30:00.000000Z]
      })

    occurrence =
      row.(%{
        uid: "standup_20261019T070000Z",
        provider_event_id: "occurrence-3",
        start_at: ~U[2026-10-19 07:00:00.000000Z],
        end_at: ~U[2026-10-19 07:30:00.000000Z]
      })

    unrelated =
      row.(%{
        uid: "offsite",
        provider_event_id: "offsite-1",
        recurring_event_id: nil,
        provider_metadata: %{},
        start_at: ~U[2026-10-06 07:00:00.000000Z],
        end_at: ~U[2026-10-06 08:00:00.000000Z]
      })

    %{user: user, source: source, first: first, occurrence: occurrence, unrelated: unrelated}
  end

  defp outlook_integration(user, token, attrs \\ []) do
    insert(
      :calendar_integration,
      [
        user: user,
        provider: "outlook",
        access_token_encrypted: Encryption.encrypt(token),
        refresh_token_encrypted: Encryption.encrypt("refresh-" <> token),
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
        oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite"
      ] ++ attrs
    )
  end

  # Answers every request through `answer` and records it, in order.
  defp serve(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, headers, _opts ->
      send(test_pid, {:request, method, url, body, headers})

      case answer.(method, path(url)) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body, headers} ->
        [%{method: method, url: path(url), body: body, token: bearer(headers)} | requests()]
    after
      0 -> []
    end
  end

  defp path(url), do: URI.to_string(%{URI.parse(url) | query: nil})

  defp bearer(headers), do: for({"Authorization", "Bearer " <> token} <- headers, do: token)

  # Graph as it answers a move: the master, the calendar holding it, the
  # account's calendars, the copy, and the delete.
  defp graph(overrides \\ %{}) do
    answers =
      Map.merge(
        %{
          master: {200, @master},
          calendar: {200, %{"id" => @master_calendar}},
          calendars:
            {200,
             %{
               "value" => [
                 %{"id" => @master_calendar, "isDefaultCalendar" => false},
                 %{"id" => "default-calendar", "isDefaultCalendar" => true}
               ]
             }},
          create: {201, @copy},
          delete: {204, nil}
        },
        overrides
      )

    fn
      :get, @master_url -> answers.master
      :get, @master_url <> "/calendar" -> answers.calendar
      :get, @graph <> "/me/calendars" -> answers.calendars
      :post, _url -> answers.create
      :delete, _url -> answers.delete
    end
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
        event_uid: "040000008200E00074C5B7101A82E008",
        provider_event_id: "master-1",
        provider_calendar_id: "primary",
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
    do: [
      worker: RefreshOutlookCalendarWorker,
      args: %{"calendar_integration_id" => integration.id}
    ]

  describe "moving an Outlook series to another calendar of the same integration" do
    test "creates the series in the destination calendar, then deletes the master", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      serve(graph())

      assert {:ok, moved} = move(user, occurrence, source, @destination_calendar)
      assert moved == %{uid: @copy["iCalUId"], integration_id: source.id}

      assert [
               %{method: :get, url: @master_url, token: ["source-token"]},
               %{method: :get, url: @master_url <> "/calendar", token: ["source-token"]},
               %{method: :post, url: post_url, body: body, token: ["source-token"]},
               %{method: :delete, url: @master_url, token: ["source-token"]}
             ] = requests()

      assert post_url == "#{@graph}/me/calendars/#{@destination_calendar}/events"
      assert Jason.decode!(body) == @copy_body
    end

    test "drops the series' rows, moves the room to the copy, and syncs once", %{
      user: user,
      source: source,
      first: first,
      occurrence: occurrence,
      unrelated: unrelated
    } do
      room = insert_room(user, source)
      serve(graph())

      assert {:ok, _moved} = move(user, occurrence, source, @destination_calendar)

      refute_series_cached(source, [first, occurrence])
      assert_series_cached(source, [unrelated])

      assert %{
               calendar_integration_id: room_integration_id,
               event_uid: "040000008200E00074C5B7101A82E009",
               provider_event_id: "copy-1",
               provider_calendar_id: @destination_calendar
             } = Repo.reload!(room)

      assert room_integration_id == source.id
      assert [_one] = all_enqueued(sync_job(source))
    end

    test "a move to the calendar the rows name is refused before anything is sent", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      occurrence =
        occurrence |> Changeset.change(provider_calendar_id: @master_calendar) |> Repo.update!()

      serve(fn _method, _url -> flunk("nothing may be sent") end)

      assert move(user, occurrence, source, @master_calendar) == {:error, :same_calendar}

      assert requests() == []
      assert_series_cached(source, [occurrence])
      assert all_enqueued() == []
    end

    test "a move to the calendar Graph says holds the master is refused before any write", %{
      user: user,
      source: source,
      occurrence: occurrence
    } do
      serve(graph())

      assert move(user, occurrence, source, @master_calendar) == {:error, :same_calendar}

      assert [%{method: :get}, %{method: :get, url: @master_url <> "/calendar"}] = requests()
      assert_series_cached(source, [occurrence])
      assert all_enqueued() == []
    end
  end

  describe "moving an Outlook series to a calendar of another Outlook integration" do
    setup %{user: user} do
      %{destination: outlook_integration(user, "destination-token")}
    end

    test "reads the master at the source, creates it at the destination, deletes it at the source",
         %{user: user, destination: destination, occurrence: occurrence} do
      serve(graph())

      assert {:ok, moved} = move(user, occurrence, destination, @destination_calendar)
      assert moved == %{uid: @copy["iCalUId"], integration_id: destination.id}

      assert [
               %{method: :get, url: @master_url, token: ["source-token"]},
               %{method: :post, url: post_url, body: body, token: ["destination-token"]},
               %{method: :delete, url: @master_url, token: ["source-token"]}
             ] = requests()

      assert post_url == "#{@graph}/me/calendars/#{@destination_calendar}/events"
      assert Jason.decode!(body) == @copy_body
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
      serve(graph())

      assert {:ok, _moved} = move(user, occurrence, destination, @destination_calendar)

      refute_series_cached(source, [first, occurrence])
      assert_series_cached(source, [unrelated])

      assert %{
               calendar_integration_id: room_integration_id,
               event_uid: "040000008200E00074C5B7101A82E009",
               provider_event_id: "copy-1",
               provider_calendar_id: @destination_calendar
             } = Repo.reload!(room)

      assert room_integration_id == destination.id
      assert_enqueued(sync_job(destination))
      assert_enqueued(sync_job(source))
    end

    test "a destination named only as \"primary\" is the account's default calendar", %{
      user: user,
      occurrence: occurrence
    } do
      destination =
        outlook_integration(user, "destination-token", default_booking_calendar_id: nil)

      serve(graph())

      # No calendar picked, and no booking calendar: the grid names none.
      assert {:ok, _moved} = move(user, occurrence, destination, nil)

      assert [
               %{method: :get, url: @master_url},
               %{method: :get, url: "#{@graph}/me/calendars", token: ["destination-token"]},
               %{method: :post, url: post_url, token: ["destination-token"]},
               %{method: :delete}
             ] = requests()

      assert post_url == "#{@graph}/me/calendars/default-calendar/events"
    end

    test "a copy the destination refuses deletes nothing and leaves everything as it was", %{
      user: user,
      source: source,
      destination: destination,
      first: first,
      occurrence: occurrence
    } do
      room = insert_room(user, source)
      serve(graph(%{create: {500, %{"error" => %{"code" => "ErrorInternalServerError"}}}}))

      assert {:error, :network_error} =
               move(user, occurrence, destination, @destination_calendar)

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
      serve(graph(%{delete: {500, %{"error" => %{"code" => "ErrorInternalServerError"}}}}))

      assert {:ok, moved} = move(user, occurrence, destination, @destination_calendar)

      assert moved == %{
               uid: @copy["iCalUId"],
               integration_id: destination.id,
               source: :left_behind
             }

      # The copy is never deleted again.
      assert [%{method: :get}, %{method: :post}, %{method: :delete, url: @master_url}] =
               requests()

      assert_enqueued(sync_job(source))
    end

    test "a master Graph answers for as cancelled is not copied", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      serve(graph(%{master: {200, Map.put(@master, "isCancelled", true)}}))

      assert {:error, :not_found} = move(user, occurrence, destination, @destination_calendar)

      assert [%{method: :get}] = requests()
      assert_series_cached(source, [occurrence])
    end

    test "a series whose zone cannot be read is refused before anything is written", %{
      user: user,
      destination: destination,
      occurrence: occurrence
    } do
      unreadable = Map.put(@master, "originalStartTimeZone", "tzone://Microsoft/Custom")
      serve(graph(%{master: {200, unreadable}}))

      assert {:error, :unreadable_timing} =
               move(user, occurrence, destination, @destination_calendar)

      assert [%{method: :get}] = requests()
    end

    test "a destination integration of another user is refused before anything is sent", %{
      user: user,
      occurrence: occurrence
    } do
      stranger = outlook_integration(insert(:user), "stranger-token")
      serve(fn _method, _url -> flunk("nothing may be sent") end)

      assert move(user, occurrence, stranger, @destination_calendar) ==
               {:error, :no_destination_calendar}

      assert requests() == []
    end
  end
end
