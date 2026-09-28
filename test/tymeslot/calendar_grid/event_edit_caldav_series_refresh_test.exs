defmodule Tymeslot.CalendarGrid.EventEditCalDAVSeriesRefreshTest do
  @moduledoc """
  A grid edit of a synced CalDAV series that changes none of its timing,
  down to the HTTP client: what is written when the cached document turns
  out to be stale and the series is rewritten from the server's copy, and
  when the edited occurrence's cached start is not its slot.

  Timing the edit did not change is not carried from the cache, so the
  series keeps the timing the server gives it. As in
  `Tymeslot.CalendarGrid.EventEditCalDAVWriteTest`, the `:calendar_module`
  seam points back at the runtime module.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations

  setup :verify_on_exit!

  @series_href "/cal/weekly-standup.ics"
  @series_url "https://caldav.example.com/cal/weekly-standup.ics"

  # A Berlin series on Tuesdays from 8 September 2026, a quarter of an hour
  # long.
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

    %{user: user, integration: integration}
  end

  defp insert_series(%{integration: integration}) do
    occurrence =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "weekly-standup_20260915T090000",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: @series_href,
        summary: "Weekly standup",
        start_at: ~U[2026-09-15 07:00:00.000000Z],
        end_at: ~U[2026-09-15 07:15:00.000000Z],
        all_day: false,
        timezone: "Europe/Berlin",
        recurrence_rule: "FREQ=WEEKLY;BYDAY=TU",
        provider_metadata: %{"uid" => "weekly-standup"},
        etag: "\"etag-1\"",
        raw_ical: @series_ical,
        sync_state: "synced"
      )

    %{occurrence: occurrence}
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

  # The cache holds the series as it was, a quarter of an hour long; another
  # client has since made it half an hour. A rename is written to the
  # server's copy once the cached one is refused, and leaves its length
  # alone: timing the rename did not change is not carried from the cache.
  describe "renaming a CalDAV series lengthened on the server since the last sync" do
    setup :insert_series

    defp lengthened_on_server do
      test_pid = self()

      server_copy =
        String.replace(
          @series_ical,
          "DTEND;TZID=Europe/Berlin:20260908T091500",
          "DTEND;TZID=Europe/Berlin:20260908T093000"
        )

      expect(Tymeslot.HTTPClientMock, :get, fn @series_url, _headers, _opts ->
        {:ok, %Req.Response{status: 200, body: server_copy, headers: %{"etag" => ["\"etag-2\""]}}}
      end)

      # Every write under the cached ETag is refused, every other accepted.
      stub(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        status = if {"If-Match", "\"etag-1\""} in headers, do: 412, else: 201
        {:ok, %Req.Response{status: status, body: "", headers: %{}}}
      end)

      stub(Tymeslot.HTTPClientMock, :delete, fn _url, _headers, _opts ->
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)
    end

    # The last PUT to `url`, the one written from the server's copy.
    defp last_put(url, last \\ nil) do
      receive do
        {:put, ^url, body, headers} -> last_put(url, {body, headers})
        {:put, _other, _body, _headers} -> last_put(url, last)
      after
        0 -> last
      end
    end

    # The last PUT of a split's tail, a new resource beside the series.
    defp last_tail_put(last \\ nil) do
      receive do
        {:put, @series_url, _body, _headers} -> last_tail_put(last)
        {:put, _tail_url, body, headers} -> last_tail_put({body, headers})
      after
        0 -> last
      end
    end

    test "every event keeps the length the server gave the series", %{
      user: user,
      occurrence: occurrence
    } do
      lengthened_on_server()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :all
               )

      assert {body, headers} = last_put(@series_url)
      assert {"If-Match", "\"etag-2\""} in headers
      assert [master] = vevent_blocks(body)
      assert "SUMMARY:Standup" in master
      assert "DTSTART;TZID=Europe/Berlin:20260908T090000" in master
      assert "DTEND;TZID=Europe/Berlin:20260908T093000" in master
    end

    test "this and following events keep the length the server gave the series", %{
      user: user,
      occurrence: occurrence
    } do
      lengthened_on_server()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :following
               )

      # The tail made from the server's copy, the second one written.
      assert {tail, _headers} = last_tail_put()
      assert [tail_master] = vevent_blocks(tail)
      assert "SUMMARY:Standup" in tail_master
      assert "DTSTART;TZID=Europe/Berlin:20260915T090000" in tail_master
      assert "DTEND;TZID=Europe/Berlin:20260915T093000" in tail_master
    end

    test "this event alone keeps the length the server gave the series", %{
      user: user,
      occurrence: occurrence
    } do
      lengthened_on_server()

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Standup"},
                 recurrence_scope: :this_only
               )

      assert {body, headers} = last_put(@series_url)
      assert {"If-Match", "\"etag-2\""} in headers
      assert [master, override] = vevent_blocks(body)
      assert "DTEND;TZID=Europe/Berlin:20260908T093000" in master
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260915T090000" in override
      assert "SUMMARY:Standup" in override
      assert "DTSTART;TZID=Europe/Berlin:20260915T090000" in override
      assert "DTEND;TZID=Europe/Berlin:20260915T093000" in override
    end
  end

  # A daily series at 02:30 in Berlin has an occurrence on 29 March 2026, when
  # the clocks skip from 02:00 to 03:00; the sync places it an hour later, at
  # 03:30. Renaming every event moves none of them.
  describe "renaming a CalDAV series from an occurrence in a DST gap" do
    @gap_ical Enum.join(
                [
                  "BEGIN:VCALENDAR",
                  "VERSION:2.0",
                  "BEGIN:VEVENT",
                  "UID:night-shift",
                  "DTSTAMP:20260301T090000Z",
                  "DTSTART;TZID=Europe/Berlin:20260325T023000",
                  "DTEND;TZID=Europe/Berlin:20260325T030000",
                  "RRULE:FREQ=DAILY",
                  "SUMMARY:Night shift",
                  "END:VEVENT",
                  "END:VCALENDAR"
                ],
                "\r\n"
              ) <> "\r\n"

    test "leaves the series where it was", %{user: user, integration: integration} do
      occurrence =
        insert(:provider_calendar_event,
          calendar_integration: integration,
          uid: "night-shift_20260329T023000",
          provider: "caldav",
          provider_calendar_id: "/cal/",
          provider_event_id: "/cal/night-shift.ics",
          summary: "Night shift",
          # 03:30 in Berlin (UTC+2), where the sync put the 02:30 slot.
          start_at: ~U[2026-03-29 01:30:00.000000Z],
          end_at: ~U[2026-03-29 02:00:00.000000Z],
          all_day: false,
          timezone: "Europe/Berlin",
          recurrence_rule: "FREQ=DAILY",
          provider_metadata: %{"uid" => "night-shift"},
          etag: "\"etag-1\"",
          raw_ical: @gap_ical,
          sync_state: "synced"
        )

      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
        send(test_pid, {:put, url, body, headers})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, _updated} =
               CalendarGrid.update_event(user.id, occurrence, %{summary: "Late shift"},
                 recurrence_scope: :all
               )

      assert_received {:put, "https://caldav.example.com/cal/night-shift.ics", body, _headers}
      assert [master] = vevent_blocks(body)
      assert "SUMMARY:Late shift" in master
      assert "DTSTART;TZID=Europe/Berlin:20260325T023000" in master
      assert "DTEND;TZID=Europe/Berlin:20260325T030000" in master
    end
  end
end
