defmodule Tymeslot.CalendarGrid.EventEditProviderSplitTest do
  @moduledoc """
  An edit of one occurrence of a Google or Outlook recurring event and every
  following one, from the grid down to the wire.

  As in `Tymeslot.CalendarGrid.EventEditProviderSeriesTest`, only the HTTP
  client is mocked: the master is read with a `GET`, and its occurrences
  changed on their own with another, the following occurrences are created
  as a new series with a `POST`, and the master is then ended with a
  `PATCH` of its recurrence; a `DELETE` of the new series undoes it when the
  master cannot be ended. Every request is recorded in the order it was
  made. Carrying the changed occurrences to the new series is pinned in
  `Tymeslot.CalendarGrid.EventEditProviderSplitExceptionsTest`.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleAPI
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookAPI
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.RefreshOutlookCalendarWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  setup :verify_on_exit!

  defp swap_env(key, module) do
    previous = Application.get_env(:tymeslot, key)
    Application.put_env(:tymeslot, key, module)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:tymeslot, key, previous),
        else: Application.delete_env(:tymeslot, key)
    end)
  end

  setup do
    swap_env(:calendar_module, Operations)
    swap_env(:google_calendar_api_module, GoogleAPI)
    swap_env(:outlook_calendar_api_module, OutlookAPI)

    %{user: insert(:user)}
  end

  defp insert_integration(user, provider, scope) do
    insert(:calendar_integration,
      user: user,
      provider: provider,
      access_token_encrypted: Encryption.encrypt("valid_token"),
      refresh_token_encrypted: Encryption.encrypt("refresh_token"),
      token_expires_at: DateTime.add(DateTime.utc_now(), 3600),
      oauth_scope: scope
    )
  end

  # The first occurrence of a weekly Monday 09:00 Berlin series, and the
  # occurrence of 2 November, after the change to winter time, which the
  # tests split at.
  defp insert_rows(integration, provider, master_id, metadata) do
    row = fn attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: integration,
            provider: provider,
            provider_calendar_id: "team-calendar",
            summary: "Weekly sync",
            all_day: false,
            timezone: "Europe/Berlin",
            recurring_event_id: master_id,
            provider_metadata: metadata,
            sync_state: "synced"
          },
          attrs
        )
      )
    end

    %{
      first:
        row.(%{
          uid: "weekly_20260601T070000Z",
          provider_event_id: "#{master_id}_20260601T070000Z",
          start_at: ~U[2026-06-01 07:00:00.000000Z],
          end_at: ~U[2026-06-01 08:00:00.000000Z]
        }),
      occurrence:
        row.(%{
          uid: "weekly_20261102T080000Z",
          provider_event_id: "#{master_id}_20261102T080000Z",
          start_at: ~U[2026-11-02 08:00:00.000000Z],
          end_at: ~U[2026-11-02 09:00:00.000000Z]
        })
    }
  end

  # Answers every request through `answer` and records it, in order.
  defp serve(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :request, fn method, url, body, _headers, _opts ->
      send(test_pid, {:request, method, url, body})

      case answer.(method, url) do
        {status, nil} -> {:ok, %Req.Response{status: status, body: ""}}
        {status, reply} -> {:ok, %Req.Response{status: status, body: Jason.encode!(reply)}}
      end
    end)
  end

  defp requests do
    receive do
      {:request, method, url, body} -> [{method, url, body} | requests()]
    after
      0 -> []
    end
  end

  defp methods(requests), do: Enum.map(requests, &elem(&1, 0))

  defp body_of(requests, method),
    do: requests |> Enum.find(&(elem(&1, 0) == method)) |> elem(2) |> Jason.decode!()

  defp an_hour_later,
    do: %{start_at: ~U[2026-11-02 09:00:00.000000Z], end_at: ~U[2026-11-02 10:00:00.000000Z]}

  describe "this and every following occurrence of a Google series" do
    @google_master %{
      "id" => "series1",
      "iCalUID" => "series1@google.com",
      "etag" => "\"3181\"",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=30"]
    }

    @tail %{"id" => "tail1", "iCalUID" => "tail1@google.com"}

    @events_url "https://www.googleapis.com/calendar/v3/calendars/team-calendar/events"
    @master_url @events_url <> "/series1"

    setup %{user: user} do
      integration = insert_integration(user, "google", "https://www.googleapis.com/auth/calendar")
      Map.put(insert_rows(integration, "google", "series1", %{}), :integration, integration)
    end

    defp google(patch_status \\ 200, post_status \\ 200) do
      fn
        :get, _url -> {200, @google_master}
        :post, _url -> {post_status, if(post_status == 200, do: @tail, else: %{"error" => %{}})}
        :patch, _url -> {patch_status, if(patch_status == 200, do: @google_master, else: %{})}
        :delete, _url -> {204, nil}
      end
    end

    test "creates the tail with the edit, then ends the master before the slot", %{
      user: user,
      occurrence: occurrence
    } do
      serve(google())

      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 Map.put(an_hour_later(), :summary, "Standup"),
                 recurrence_scope: :following
               )

      sent = requests()
      assert methods(sent) == [:get, :get, :post, :patch]

      assert [
               {:get, @master_url, _get},
               {:get, list_url, _list},
               {:post, post_url, _tail},
               {:patch, patch_url, _head}
             ] = sent

      assert String.starts_with?(list_url, @events_url <> "?")
      assert list_url =~ "iCalUID=series1%40google.com"
      assert list_url =~ "showDeleted=true"

      assert String.starts_with?(post_url, @events_url <> "?")
      assert patch_url == @master_url <> "?sendUpdates=none"

      tail = body_of(sent, :post)
      assert tail["summary"] == "Standup"

      assert tail["start"] == %{
               "dateTime" => "2026-11-02T10:00:00",
               "timeZone" => "Europe/Berlin"
             }

      assert tail["end"] == %{"dateTime" => "2026-11-02T11:00:00", "timeZone" => "Europe/Berlin"}
      assert tail["recurrence"] == ["RRULE:FREQ=WEEKLY;BYDAY=MO;COUNT=8"]
      refute Map.has_key?(tail, "id") or Map.has_key?(tail, "iCalUID")

      assert body_of(sent, :patch) == %{
               "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO;UNTIL=20261102T075959Z"]
             }
    end

    test "drops the series' rows, requests a sync, and hands the video room to the tail", %{
      user: user,
      integration: integration,
      first: first,
      occurrence: occurrence
    } do
      integration =
        integration
        |> Changeset.change(last_external_sync_at: DateTime.utc_now(:second))
        |> Repo.update!()

      talk = insert(:video_integration, user: user, provider: "nextcloud_talk")
      ended = DateTime.add(DateTime.utc_now(:second), -8 * 86_400, :second)

      {:ok, room} =
        EventVideoRoomQueries.insert(%{
          user_id: user.id,
          video_integration_id: talk.id,
          provider: "nextcloud_talk",
          calendar_integration_id: integration.id,
          event_uid: "weekly-sync-uid",
          provider_event_id: "series1",
          provider_calendar_id: "team-calendar",
          room_id: "room-weekly-sync",
          lobby_opens_at: DateTime.add(ended, -900, :second),
          ends_at: ended
        })

      serve(google())

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      for uid <- [first.uid, occurrence.uid] do
        assert ProviderCalendarEventQueries.get_by_uid(integration.id, uid) ==
                 {:error, :not_found}
      end

      assert_enqueued(
        worker: SyncGoogleCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )

      # A row of the tail, as the requested sync caches it.
      tail_row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          provider: "google",
          provider_calendar_id: "team-calendar",
          uid: "tail1@google.com_20261109T080000Z",
          provider_event_id: "tail1_20261109T080000Z",
          recurring_event_id: "tail1",
          summary: "Standup",
          start_at: ~U[2026-11-09 08:00:00.000000Z],
          end_at: ~U[2026-11-09 09:00:00.000000Z],
          all_day: false,
          sync_state: "synced"
        )

      assert [%{id: room_id}] = EventVideoRooms.rooms_on_integration(tail_row, talk.id)
      assert room_id == room.id

      room = room |> Repo.reload!() |> Repo.preload(:calendar_integration)
      assert room.event_uid == "tail1@google.com"
      assert room.provider_event_id == "tail1"
      assert EventVideoRooms.check_expired(room) == :kept
    end

    test "deletes the tail again when the master cannot be ended, and reports it", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve(google(500))

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      sent = requests()
      assert methods(sent) == [:get, :get, :post, :patch, :delete]
      assert {:delete, @events_url <> "/tail1", _body} = List.last(sent)

      assert {:ok, %{summary: "Weekly sync", sync_state: "synced"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)

      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    test "writes nothing else when the tail cannot be created", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve(google(200, 500))

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      assert methods(requests()) == [:get, :get, :post]
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
      refute_enqueued(worker: SyncGoogleCalendarWorker)
    end

    test "an edit from the first occurrence on is written to the master alone", %{
      user: user,
      first: first
    } do
      serve(google())

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, first, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      sent = requests()
      assert methods(sent) == [:get, :patch]
      assert body_of(sent, :patch) == %{"summary" => "Standup"}
    end
  end

  describe "this and every following occurrence of an Outlook series" do
    @zone "W. Europe Standard Time"

    @outlook_master %{
      "id" => "master-1",
      "iCalUId" => "040000008200E00074C5B7101A82E008",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "isOnlineMeeting" => false,
      "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => @zone,
      "recurrence" => %{
        "pattern" => %{"type" => "weekly", "interval" => 1, "daysOfWeek" => ["monday"]},
        "range" => %{
          "type" => "numbered",
          "startDate" => "2026-06-01",
          "numberOfOccurrences" => 30
        }
      }
    }

    @outlook_tail %{"id" => "tail-1", "iCalUId" => "040000008200E00074C5B7101A82E009"}

    @graph "https://graph.microsoft.com/v1.0"

    setup %{user: user} do
      integration =
        insert_integration(user, "outlook", "https://graph.microsoft.com/Calendars.ReadWrite")

      # The delta sync caches every Outlook row as on "primary", whichever
      # calendar holds its series; this one lives in another.
      rows =
        integration
        |> insert_rows("outlook", "master-1", %{"type" => "occurrence"})
        |> Map.new(fn {name, row} ->
          {name, row |> Changeset.change(provider_calendar_id: "primary") |> Repo.update!()}
        end)

      Map.put(rows, :integration, integration)
    end

    @master_calendar {200, %{"id" => "team-calendar"}}

    defp outlook(patch_status, calendar \\ @master_calendar) do
      fn
        :get, url ->
          if String.contains?(url, "/master-1/calendar"),
            do: calendar,
            else: {200, @outlook_master}

        :post, _url ->
          {201, @outlook_tail}

        :patch, _url ->
          {patch_status, if(patch_status == 200, do: @outlook_master, else: %{})}

        :delete, _url ->
          {204, nil}
      end
    end

    test "creates the tail in the calendar Graph says holds the master, then ends its range", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve(outlook(200))

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      sent = requests()

      assert [
               {:get, @graph <> "/me/events/master-1", _get},
               {:get, @graph <> "/me/events/master-1/calendar" <> _select, _calendar},
               {:get, @graph <> "/me/events/master-1?" <> exceptions, _exceptions},
               {:post, @graph <> "/me/calendars/team-calendar/events", _tail},
               {:patch, @graph <> "/me/events/master-1", _head}
             ] = sent

      assert exceptions =~ "expand=exceptionOccurrences"
      assert exceptions =~ "cancelledOccurrences"

      tail = body_of(sent, :post)
      assert tail["subject"] == "Standup"
      assert tail["start"] == %{"dateTime" => "2026-11-02T09:00:00", "timeZone" => @zone}

      assert tail["recurrence"]["range"] == %{
               "type" => "numbered",
               "startDate" => "2026-11-02",
               "numberOfOccurrences" => 8
             }

      assert body_of(sent, :patch)["recurrence"]["range"] == %{
               "type" => "endDate",
               "startDate" => "2026-06-01",
               "endDate" => "2026-11-01"
             }

      assert ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid) ==
               {:error, :not_found}

      assert_enqueued(
        worker: RefreshOutlookCalendarWorker,
        args: %{"calendar_integration_id" => integration.id}
      )
    end

    test "deletes the tail again when the master cannot be ended", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      serve(outlook(500))

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      sent = requests()
      assert methods(sent) == [:get, :get, :get, :post, :patch, :delete]
      assert {:delete, @graph <> "/me/events/tail-1", _body} = List.last(sent)

      assert {:ok, %{summary: "Weekly sync"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)

      refute_enqueued(worker: RefreshOutlookCalendarWorker)
    end

    test "is refused before anything is written when the master's calendar cannot be read", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      for calendar <- [{200, %{}}, {404, %{"error" => %{"code" => "ErrorItemNotFound"}}}] do
        serve(outlook(200, calendar))

        assert {:error, %{retry: :not_queued}} =
                 CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                   recurrence_scope: :following
                 )

        assert methods(requests()) == [:get, :get]
      end

      assert {:ok, %{summary: "Weekly sync"}} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)

      refute_enqueued(worker: RefreshOutlookCalendarWorker)
    end
  end
end
