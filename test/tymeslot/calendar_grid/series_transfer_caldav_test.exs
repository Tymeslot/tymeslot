defmodule Tymeslot.CalendarGrid.SeriesTransferCalDAVTest do
  @moduledoc """
  Moving a CalDAV recurring series to a calendar on another CalDAV server
  through `CalendarGrid.move_event/3`, down to the HTTP client: the series'
  resource copied under a new UID into the destination collection, on the
  destination's server with its own credentials, and only then deleted on
  the source's, under the ETag the copy was made from.

  The two integrations live on different hosts with different passwords, so
  every request shows which integration's client sent it.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalDAV.QueueQueries
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.Encryption
  alias Tymeslot.Workers.SyncCalDavCalendarWorker

  setup :verify_on_exit!

  @source_base "https://source.example.org"
  @destination_base "https://dest.example.net"
  @series_href "/cal/standup.ics"
  @series_url @source_base <> @series_href

  # A weekly series with one occurrence moved to the afternoon.
  @series_ical Enum.join(
                 [
                   "BEGIN:VCALENDAR",
                   "VERSION:2.0",
                   "BEGIN:VEVENT",
                   "UID:standup@example.com",
                   "DTSTAMP:20260901T090000Z",
                   "DTSTART;TZID=Europe/Berlin:20261005T090000",
                   "DTEND;TZID=Europe/Berlin:20261005T093000",
                   "RRULE:FREQ=WEEKLY;BYDAY=MO",
                   "SUMMARY:Weekly standup",
                   "END:VEVENT",
                   "BEGIN:VEVENT",
                   "UID:standup@example.com",
                   "RECURRENCE-ID;TZID=Europe/Berlin:20261012T090000",
                   "DTSTAMP:20260901T090000Z",
                   "DTSTART;TZID=Europe/Berlin:20261012T140000",
                   "DTEND;TZID=Europe/Berlin:20261012T143000",
                   "SUMMARY:Weekly standup (afternoon)",
                   "END:VEVENT",
                   "END:VCALENDAR"
                 ],
                 "\r\n"
               ) <> "\r\n"

  setup do
    for base <- [@source_base, @destination_base] do
      CalendarCircuitBreaker.reset_for_url(:caldav, base)
      CalendarCircuitBreaker.reset_for_url(:radicale, base)
    end

    user = insert(:user)

    source =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: @source_base,
        calendar_paths: ["/cal/"],
        password_encrypted: Encryption.encrypt("source-secret")
      )

    destination =
      insert(:calendar_integration,
        user: user,
        provider: "radicale",
        base_url: @destination_base,
        calendar_paths: ["/dav/home/", "/dav/team/"],
        password_encrypted: Encryption.encrypt("destination-secret")
      )

    row = fn attrs ->
      insert(
        :provider_calendar_event,
        Map.merge(
          %{
            calendar_integration: source,
            provider: "caldav",
            provider_calendar_id: "/cal/",
            provider_event_id: @series_href,
            summary: "Weekly standup",
            start_at: ~U[2026-10-05 07:00:00.000000Z],
            end_at: ~U[2026-10-05 07:30:00.000000Z],
            all_day: false,
            timezone: "Europe/Berlin",
            etag: "\"etag-1\"",
            raw_ical: @series_ical,
            sync_state: "synced"
          },
          attrs
        )
      )
    end

    series =
      row.(%{uid: "standup@example.com", recurrence_rule: "FREQ=WEEKLY;BYDAY=MO"})

    occurrence =
      row.(%{
        uid: "standup@example.com_20261012T090000",
        start_at: ~U[2026-10-12 12:00:00.000000Z],
        end_at: ~U[2026-10-12 12:30:00.000000Z],
        provider_metadata: %{"recurrence_id" => "20261012T090000", "uid" => "standup@example.com"}
      })

    unrelated =
      row.(%{uid: "offsite@example.com", provider_event_id: "/cal/offsite.ics", raw_ical: nil})

    %{
      user: user,
      source: source,
      destination: destination,
      series: series,
      occurrence: occurrence,
      unrelated: unrelated
    }
  end

  defp basic(integration, password) do
    username = Encryption.decrypt(integration.username_encrypted)
    "Basic " <> Base.encode64("#{username}:#{password}")
  end

  defp header(headers, name), do: for({^name, value} <- headers, do: value)

  # Every PUT and DELETE, in the order they were sent.
  defp expect_put(answer) do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:http, :put, url, body, headers})
      answer
    end)
  end

  defp stub_delete(answer) do
    test_pid = self()

    stub(Tymeslot.HTTPClientMock, :delete, fn url, headers, _opts ->
      send(test_pid, {:http, :delete, url, nil, headers})
      answer
    end)
  end

  defp requests(acc \\ []) do
    receive do
      {:http, method, url, body, headers} -> requests([{method, url, body, headers} | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp ok(status), do: {:ok, %Req.Response{status: status, body: "", headers: %{}}}

  defp move(user, event, integration, calendar_id) do
    CalendarGrid.move_event(user.id, event, %{integration: integration, calendar_id: calendar_id})
  end

  defp uids(document) do
    for "UID:" <> uid <- LineFolder.unfold_lines(document), do: uid
  end

  defp insert_room(user, integration, attrs) do
    talk = insert(:video_integration, user: user, provider: "nextcloud_talk")
    ends = DateTime.add(DateTime.utc_now(:second), 30 * 86_400, :second)

    {:ok, room} =
      EventVideoRoomQueries.insert(
        Map.merge(
          %{
            user_id: user.id,
            video_integration_id: talk.id,
            provider: "nextcloud_talk",
            calendar_integration_id: integration.id,
            room_id: "room-#{System.unique_integer([:positive])}",
            lobby_opens_at: DateTime.add(ends, -900, :second),
            ends_at: ends
          },
          attrs
        )
      )

    room
  end

  defp sync_job(integration),
    do: [
      worker: SyncCalDavCalendarWorker,
      args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
    ]

  describe "moving a CalDAV series to a calendar on another server" do
    test "copies the series to the destination server, then deletes it on the source's", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      expect_put(ok(201))
      stub_delete(ok(204))

      assert {:ok, %{uid: uid, integration_id: integration_id}} =
               move(user, occurrence, destination, "/dav/team/")

      assert integration_id == destination.id

      assert [
               {:put, put_url, copy, put_headers},
               {:delete, @series_url, nil, delete_headers}
             ] = requests()

      assert put_url == "#{@destination_base}/dav/team/#{uid}.ics"
      assert header(put_headers, "If-None-Match") == ["*"]
      assert header(put_headers, "Authorization") == [basic(destination, "destination-secret")]

      assert header(delete_headers, "If-Match") == [~s("etag-1")]
      assert header(delete_headers, "Authorization") == [basic(source, "source-secret")]

      # The whole series, the override included, under the new UID.
      assert uids(copy) == [uid, uid]
      assert copy == String.replace(@series_ical, "UID:standup@example.com", "UID:" <> uid)
    end

    test "copies the server's document when the cache holds no ETag for it", %{
      user: user,
      destination: destination,
      series: series
    } do
      series |> Changeset.change(etag: nil) |> Repo.update!()
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        send(test_pid, {:http, :get, url, nil, []})

        {:ok,
         %Req.Response{
           status: 200,
           body: String.replace(@series_ical, "Weekly standup", "Daily standup"),
           headers: %{"etag" => [~s("etag-2")]}
         }}
      end)

      expect_put(ok(201))
      stub_delete(ok(204))

      assert {:ok, %{uid: uid}} = move(user, series, destination, "/dav/home/")

      assert [
               {:get, @series_url, nil, _get_headers},
               {:put, _put_url, copy, _put_headers},
               {:delete, @series_url, nil, delete_headers}
             ] = requests()

      assert copy =~ "SUMMARY:Daily standup"
      assert uids(copy) == [uid, uid]
      assert header(delete_headers, "If-Match") == [~s("etag-2")]
    end

    test "drops the source's rows, moves the rooms and syncs both integrations", %{
      user: user,
      source: source,
      destination: destination,
      series: series,
      occurrence: occurrence,
      unrelated: unrelated
    } do
      room =
        insert_room(user, source, %{
          event_uid: "standup@example.com",
          provider_event_id: @series_href,
          provider_calendar_id: "/cal/"
        })

      expect_put(ok(201))
      stub_delete(ok(204))

      assert {:ok, %{uid: uid} = moved} = move(user, occurrence, destination, "/dav/team/")
      refute Map.has_key?(moved, :source)

      for row <- [series, occurrence] do
        assert ProviderCalendarEventQueries.get_by_uid(source.id, row.uid) == {:error, :not_found}
      end

      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, unrelated.uid)

      assert %{
               calendar_integration_id: room_integration_id,
               event_uid: ^uid,
               provider_event_id: room_href,
               provider_calendar_id: "/dav/team/"
             } = Repo.reload!(room)

      assert room_integration_id == destination.id
      assert room_href == "/dav/team/#{uid}.ics"

      assert_enqueued(sync_job(destination))
      assert_enqueued(sync_job(source))
    end

    test "a copy the destination refuses deletes nothing and leaves everything as it was", %{
      user: user,
      source: source,
      destination: destination,
      series: series,
      occurrence: occurrence
    } do
      room =
        insert_room(user, source, %{
          event_uid: "standup@example.com",
          provider_event_id: @series_href
        })

      expect_put(ok(403))
      stub_delete(ok(204))

      assert {:error, :forbidden} = move(user, occurrence, destination, "/dav/team/")

      assert [{:put, _url, _copy, _headers}] = requests()

      for row <- [series, occurrence] do
        assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, row.uid)
      end

      assert Repo.reload!(room).calendar_integration_id == source.id
      assert all_enqueued() == []
    end

    test "a series changed on the source since the cache read it is moved from the server's copy",
         %{user: user, source: source, destination: destination, occurrence: occurrence} do
      room =
        insert_room(user, source, %{
          event_uid: "standup@example.com",
          provider_event_id: @series_href,
          provider_calendar_id: "/cal/"
        })

      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :get, fn url, _headers, _opts ->
        send(test_pid, {:http, :get, url, nil, []})

        {:ok,
         %Req.Response{
           status: 200,
           body: String.replace(@series_ical, "Weekly standup", "Daily standup"),
           headers: %{"etag" => [~s("etag-2")]}
         }}
      end)

      expect(Tymeslot.HTTPClientMock, :put, 2, fn url, body, headers, _opts ->
        send(test_pid, {:http, :put, url, body, headers})
        ok(201)
      end)

      # The original changed on the server since the cache read it, so the
      # delete under the cached ETag is refused; every other is accepted.
      stub(Tymeslot.HTTPClientMock, :delete, fn url, headers, _opts ->
        send(test_pid, {:http, :delete, url, nil, headers})
        if header(headers, "If-Match") == [~s("etag-1")], do: ok(412), else: ok(204)
      end)

      assert {:ok, %{uid: uid} = moved} = move(user, occurrence, destination, "/dav/team/")
      refute Map.has_key?(moved, :source)

      assert [
               {:put, stale_url, _stale_copy, _headers},
               {:delete, @series_url, nil, _stale_delete},
               {:delete, stale_url, nil, _discard_headers},
               {:get, @series_url, nil, _get_headers},
               {:put, put_url, copy, _put_headers},
               {:delete, @series_url, nil, delete_headers}
             ] = requests()

      # The stale copy is gone again; the one that stays is the server's.
      assert stale_url != put_url
      assert put_url == "#{@destination_base}/dav/team/#{uid}.ics"
      assert copy =~ "SUMMARY:Daily standup"
      assert uids(copy) == [uid, uid]
      assert header(delete_headers, "If-Match") == [~s("etag-2")]

      assert %{event_uid: ^uid, provider_event_id: room_href} = Repo.reload!(room)
      assert room_href == "/dav/team/#{uid}.ics"
    end

    test "a series still changing on the source is not moved, and no copy stays", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :get, fn _url, _headers, _opts ->
        {:ok,
         %Req.Response{status: 200, body: @series_ical, headers: %{"etag" => [~s("etag-2")]}}}
      end)

      expect(Tymeslot.HTTPClientMock, :put, 2, fn url, body, headers, _opts ->
        send(test_pid, {:http, :put, url, body, headers})
        ok(201)
      end)

      # Every delete of the original is refused; the copies' are accepted.
      stub(Tymeslot.HTTPClientMock, :delete, fn url, headers, _opts ->
        send(test_pid, {:http, :delete, url, nil, headers})
        if url == @series_url, do: ok(412), else: ok(204)
      end)

      assert {:error, :precondition_failed} = move(user, occurrence, destination, "/dav/team/")

      sent = requests()
      copies = for {:put, url, _body, _headers} <- sent, do: url
      deleted = for {:delete, url, _body, _headers} <- sent, url != @series_url, do: url

      # Both copies were deleted again, so nothing of the series is left on
      # the destination, and the source's rows stay.
      assert length(copies) == 2
      assert deleted == copies
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, occurrence.uid)
      assert all_enqueued() == []
    end

    test "an original the source will not delete is left behind, and the copy kept", %{
      user: user,
      source: source,
      destination: destination,
      occurrence: occurrence
    } do
      expect_put(ok(201))
      stub_delete(ok(403))

      assert {:ok, %{uid: uid, source: :left_behind}} =
               move(user, occurrence, destination, "/dav/team/")

      assert [{:put, put_url, _copy, _put_headers}, {:delete, @series_url, nil, _delete_headers}] =
               requests()

      assert put_url == "#{@destination_base}/dav/team/#{uid}.ics"

      # Nothing queues the delete for a later replay, which would delete the
      # whole resource; the source's sync brings the original back instead.
      assert QueueQueries.list_pending(source.id) == []
      assert_enqueued(sync_job(source))
    end

    test "a collection the destination does not write to is refused before anything is sent",
         %{user: user, source: source, destination: destination, occurrence: occurrence} do
      stub_delete(ok(204))

      assert {:error, :no_destination_calendar} =
               move(user, occurrence, destination, "/dav/someone-else/")

      assert requests() == []
      assert {:ok, _row} = ProviderCalendarEventQueries.get_by_uid(source.id, occurrence.uid)
      assert all_enqueued() == []
    end
  end
end
