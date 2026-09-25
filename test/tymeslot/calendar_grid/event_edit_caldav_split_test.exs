defmodule Tymeslot.CalendarGrid.EventEditCalDAVSplitTest do
  @moduledoc """
  What a grid edit of one occurrence of a synced CalDAV series and every
  following one puts on the wire, and what it leaves behind: the following
  occurrences created as a new resource beside the series, the series ended
  before them, the series' cached rows dropped for a full sync, and its
  video room handed on to the new resource.

  Like `Tymeslot.CalendarGrid.EventEditCalDAVWriteTest`, the
  `:calendar_module` seam points back at the runtime module, so the edit
  travels the whole way down to the HTTP client.
  """
  use Tymeslot.DataCase, async: false
  use Oban.Testing, repo: Tymeslot.Repo

  @moduletag :calendar
  @moduletag :video
  @moduletag :integration

  import Mox

  alias Ecto.Changeset
  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EventVideoRoomQueries
  alias Tymeslot.CalendarGrid.EventVideoRooms
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Workers.SyncCalDavCalendarWorker
  alias Tymeslot.Workers.VideoSyncWorker

  setup :verify_on_exit!

  # A Berlin series on Tuesdays from 8 September 2026, whose 29 September
  # occurrence was deleted earlier.
  @series_href "/cal/weekly-standup.ics"
  @series_url "https://caldav.example.com/cal/weekly-standup.ics"
  @series_ical Enum.join(
                 [
                   "BEGIN:VCALENDAR",
                   "VERSION:2.0",
                   "BEGIN:VEVENT",
                   "UID:weekly-standup",
                   "DTSTAMP:20260901T090000Z",
                   "DTSTART;TZID=Europe/Berlin:20260908T090000",
                   "DTEND;TZID=Europe/Berlin:20260908T091500",
                   "RRULE:FREQ=WEEKLY;BYDAY=TU",
                   "EXDATE;TZID=Europe/Berlin:20260929T090000",
                   "SUMMARY:Weekly standup",
                   "END:VEVENT",
                   "END:VCALENDAR"
                 ],
                 "\r\n"
               ) <> "\r\n"

  setup do
    previous_module = Application.get_env(:tymeslot, :calendar_module)
    Application.put_env(:tymeslot, :calendar_module, Operations)

    on_exit(fn ->
      if previous_module do
        Application.put_env(:tymeslot, :calendar_module, previous_module)
      else
        Application.delete_env(:tymeslot, :calendar_module)
      end
    end)

    user = insert(:user)

    integration =
      insert(:calendar_integration,
        user: user,
        provider: "caldav",
        base_url: "https://caldav.example.com",
        calendar_paths: ["/cal/"]
      )

    unrelated =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "sprint-review",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/sprint-review.ics",
        summary: "Sprint review",
        start_at: ~U[2026-09-10 09:00:00.000000Z],
        end_at: ~U[2026-09-10 10:00:00.000000Z],
        all_day: false,
        sync_state: "synced"
      )

    row = fn key, start_at ->
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "weekly-standup_#{key}",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: @series_href,
        summary: "Weekly standup",
        start_at: start_at,
        end_at: DateTime.add(start_at, 15, :minute),
        all_day: false,
        timezone: "Europe/Berlin",
        recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
        provider_metadata: %{"uid" => "weekly-standup"},
        etag: "\"etag-1\"",
        raw_ical: @series_ical,
        sync_state: "synced"
      )
    end

    %{
      user: user,
      integration: integration,
      event: unrelated,
      row: row,
      occurrence: row.("20260915T090000", ~U[2026-09-15 07:00:00.000000Z]),
      sibling: row.("20260922T090000", ~U[2026-09-22 07:00:00.000000Z])
    }
  end

  defp expect_series_put do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, headers})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp vevent_blocks(body) do
    body
    |> LineFolder.unfold_lines()
    |> Enum.chunk_while(
      nil,
      fn
        "BEGIN:VEVENT", nil -> {:cont, ["BEGIN:VEVENT"]}
        "END:VEVENT", acc when is_list(acc) -> {:cont, Enum.reverse(["END:VEVENT" | acc]), nil}
        line, acc when is_list(acc) -> {:cont, [line | acc]}
        _line, nil -> {:cont, nil}
      end,
      fn _unterminated -> {:cont, nil} end
    )
  end

  defp caldav_sync_job(integration),
    do: [
      worker: SyncCalDavCalendarWorker,
      args: %{"calendar_integration_id" => integration.id, "force_full_fetch" => true}
    ]

  describe "editing one occurrence of a synced CalDAV series and every following one" do
    # Answers the tail's create, then the series' own write, reporting each.
    defp expect_split_puts(
           tail_answer \\ {:ok, %Req.Response{status: 201, body: "", headers: %{}}}
         ) do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        tail_answer
      end)

      expect_series_put()
    end

    defp tail_uid(body) do
      body |> LineFolder.unfold_lines() |> Enum.find_value(&uid_value/1)
    end

    defp uid_value("UID:" <> uid), do: uid
    defp uid_value(_line), do: nil

    test "creates the following occurrences beside the series, then ends the series", %{
      user: user,
      occurrence: occurrence
    } do
      expect_split_puts()

      # 11:00 in Berlin (UTC+2) on 15 September: two hours later.
      assert {:ok, _updated} =
               CalendarGrid.update_event(
                 user.id,
                 occurrence,
                 %{
                   summary: "Standup",
                   start_at: ~U[2026-09-15 09:00:00.000000Z],
                   end_at: ~U[2026-09-15 09:15:00.000000Z]
                 },
                 recurrence_scope: :following
               )

      assert_received {:put, tail_url, tail, tail_headers}
      uid = tail_uid(tail)
      assert tail_url == "https://caldav.example.com/cal/#{uid}.ics"
      assert {"If-None-Match", "*"} in tail_headers

      assert [tail_master] = vevent_blocks(tail)
      assert "DTSTART;TZID=Europe/Berlin:20260915T110000" in tail_master
      assert "SUMMARY:Standup" in tail_master
      assert "EXDATE;TZID=Europe/Berlin:20260929T110000" in tail_master

      assert_received {:put, @series_url, head, head_headers}
      assert {"If-Match", "\"etag-1\""} in head_headers
      assert [head_master] = vevent_blocks(head)
      # 15 September, 09:00 in Berlin, is 07:00 UTC.
      assert "RRULE:FREQ=WEEKLY;BYDAY=TU;UNTIL=20260915T065959Z" in head_master
      assert "SUMMARY:Weekly standup" in head_master
      refute Enum.any?(head_master, &String.starts_with?(&1, "EXDATE"))
    end

    test "the series' rows are dropped and a full sync of the integration is requested", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling,
      event: unrelated
    } do
      expect_split_puts()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      for uid <- [occurrence.uid, sibling.uid] do
        assert ProviderCalendarEventQueries.get_by_uid(integration.id, uid) ==
                 {:error, :not_found}
      end

      assert {:ok, _other} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, unrelated.uid)

      assert_enqueued(caldav_sync_job(integration))
    end

    # Under `verify_on_exit!` a write of the series itself would fail the test.
    test "a tail that cannot be created is not queued, leaves the rows and requests no sync", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling
    } do
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      for uid <- [occurrence.uid, sibling.uid] do
        {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)

        assert {row.summary, row.sync_state, row.etag, row.raw_ical} ==
                 {"Weekly standup", "synced", "\"etag-1\"", @series_ical}
      end

      refute_enqueued(worker: SyncCalDavCalendarWorker)
    end

    test "from the series' first occurrence, every occurrence is edited", %{
      user: user,
      integration: integration,
      row: row
    } do
      first = row.("20260908T090000", ~U[2026-09-08 07:00:00.000000Z])

      expect_series_put()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, first, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      assert_received {:put, @series_url, body, _headers}
      assert [master] = vevent_blocks(body)
      assert "SUMMARY:Standup" in master
      assert "RRULE:FREQ=WEEKLY;BYDAY=TU" in master

      assert ProviderCalendarEventQueries.get_by_uid(integration.id, first.uid) ==
               {:error, :not_found}

      assert_enqueued(caldav_sync_job(integration))
    end

    test "the series' video room moves to the following occurrences and is kept for them", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      # The organiser's calendar last synced now, so a room whose event the
      # cache no longer holds would count as over.
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
          event_uid: "weekly-standup",
          provider_event_id: @series_href,
          room_id: "room-weekly-standup",
          lobby_opens_at: DateTime.add(ended, -900, :second),
          ends_at: ended
        })

      expect_split_puts()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      assert_received {:put, _tail_url, tail, _headers}
      uid = tail_uid(tail)

      # A row of the tail, as the requested sync caches it.
      tail_row =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "#{uid}_20260922T090000",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/#{uid}.ics",
          summary: "Standup",
          start_at: ~U[2026-09-22 07:00:00.000000Z],
          end_at: ~U[2026-09-22 07:15:00.000000Z],
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
          sync_state: "synced"
        )

      assert [%{id: room_id}] = EventVideoRooms.rooms_on_integration(tail_row, talk.id)
      assert room_id == room.id

      room = room |> Repo.reload!() |> Repo.preload(:calendar_integration)
      assert EventVideoRooms.check_expired(room) == :kept

      # Deleting the earlier occurrences as a whole leaves the room.
      EventVideoRooms.series_deleted(occurrence)

      refute_enqueued(
        worker: VideoSyncWorker,
        args: %{"event_room_id" => room.id, "action" => "delete"}
      )
    end
  end
end
