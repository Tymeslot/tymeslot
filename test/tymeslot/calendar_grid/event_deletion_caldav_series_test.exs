defmodule Tymeslot.CalendarGrid.EventDeletionCalDAVSeriesTest do
  @moduledoc """
  What a grid delete of a member of a CalDAV series puts on the wire, and
  what it leaves in the cache.

  `EventDeletionTest` stops at the `:calendar_module` seam; this module points
  that seam back at the runtime module so the delete travels the whole way
  down (grid domain, provider adapter, CalDAV writer) and the request the
  server receives can be read. A series is one resource on the server, so the
  scope decides between two very different requests: a rewrite of the
  resource without one occurrence, or a DELETE of the resource.
  """
  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :integration

  import Ecto.Query, only: [select: 3, where: 3]
  import Mox

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.Operations
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Repo

  setup :verify_on_exit!

  @href "/cal/weekly-standup.ics"
  @url "https://caldav.example.com/cal/weekly-standup.ics"

  @series_ical """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Example Corp//Calendar 1.0//EN\r
  BEGIN:VEVENT\r
  UID:weekly-standup\r
  DTSTAMP:20260901T090000Z\r
  DTSTART;TZID=Europe/Berlin:20260908T090000\r
  DTEND;TZID=Europe/Berlin:20260908T091500\r
  RRULE:FREQ=WEEKLY;BYDAY=TU\r
  SUMMARY:Weekly standup\r
  END:VEVENT\r
  BEGIN:VEVENT\r
  UID:weekly-standup\r
  DTSTAMP:20260901T090000Z\r
  RECURRENCE-ID;TZID=Europe/Berlin:20260922T090000\r
  DTSTART;TZID=Europe/Berlin:20260922T140000\r
  DTEND;TZID=Europe/Berlin:20260922T141500\r
  SUMMARY:Weekly standup, afternoon\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

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

    # The rows the sync expanded out of the series above: two plain
    # occurrences carrying the master's rule, and the override, which carries
    # only its recurrence id.
    occurrence = insert_row(integration, "20260915T090000", ~U[2026-09-15 07:00:00.000000Z])
    sibling = insert_row(integration, "20260929T090000", ~U[2026-09-29 07:00:00.000000Z])

    override =
      insert_row(integration, "20260922T090000", ~U[2026-09-22 12:00:00.000000Z],
        recurrence_rule: nil,
        provider_metadata: %{"uid" => "weekly-standup", "recurrence_id" => "20260922T090000"}
      )

    unrelated =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "one-off",
        provider: "caldav",
        provider_calendar_id: "/cal/",
        provider_event_id: "/cal/one-off.ics",
        start_at: ~U[2026-09-16 09:00:00.000000Z],
        end_at: ~U[2026-09-16 10:00:00.000000Z],
        etag: "\"etag-other\"",
        sync_state: "synced"
      )

    %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling,
      override: override,
      unrelated: unrelated
    }
  end

  defp insert_row(integration, key, start_at, attrs \\ []) do
    defaults = %{
      calendar_integration: integration,
      uid: "weekly-standup_#{key}",
      provider: "caldav",
      provider_calendar_id: "/cal/",
      provider_event_id: @href,
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
    }

    insert(:provider_calendar_event, Map.merge(defaults, Map.new(attrs)))
  end

  defp expect_put do
    test_pid = self()

    expect(Tymeslot.HTTPClientMock, :put, fn url, body, headers, _opts ->
      send(test_pid, {:put, url, body, headers})
      {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
    end)
  end

  defp cached_uids(integration) do
    ProviderCalendarEventSchema
    |> where([e], e.calendar_integration_id == ^integration.id)
    |> select([e], e.uid)
    |> Repo.all()
    |> Enum.sort()
  end

  describe "deleting one occurrence" do
    test "PUTs the series back under If-Match with the occurrence excluded", %{
      user: user,
      occurrence: occurrence
    } do
      expect_put()

      assert {:ok, %{uid: uid, linked_meeting: :none}} =
               CalendarGrid.delete_event(user.id, occurrence, :occurrence)

      assert uid == occurrence.uid
      assert_received {:put, @url, body, headers}
      assert {"If-Match", "\"etag-1\""} in headers

      lines = LineFolder.unfold_lines(body)
      assert "EXDATE;TZID=Europe/Berlin:20260915T090000" in lines
      assert "RRULE:FREQ=WEEKLY;BYDAY=TU" in lines
      # The override for another Tuesday stays.
      assert "RECURRENCE-ID;TZID=Europe/Berlin:20260922T090000" in lines
    end

    test "removes its row and gives the rest of the resource the new document", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      sibling: sibling,
      override: override,
      unrelated: unrelated
    } do
      expect_put()

      assert {:ok, _deleted} = CalendarGrid.delete_event(user.id, occurrence, :occurrence)
      assert_received {:put, _url, body, _headers}

      assert cached_uids(integration) ==
               Enum.sort([sibling.uid, override.uid, unrelated.uid])

      for uid <- [sibling.uid, override.uid] do
        {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, uid)
        # The PUT came back without an ETag, so the next write re-reads first.
        assert {row.raw_ical, row.etag} == {body, nil}
      end

      {:ok, other} = ProviderCalendarEventQueries.get_by_uid(integration.id, unrelated.uid)
      assert other.etag == "\"etag-other\""
    end

    test "an occurrence edited on its own loses its override", %{
      user: user,
      integration: integration,
      override: override
    } do
      expect_put()

      assert {:ok, _deleted} = CalendarGrid.delete_event(user.id, override, :occurrence)

      assert_received {:put, @url, body, _headers}
      lines = LineFolder.unfold_lines(body)
      refute "RECURRENCE-ID;TZID=Europe/Berlin:20260922T090000" in lines
      refute "SUMMARY:Weekly standup, afternoon" in lines
      assert "EXDATE;TZID=Europe/Berlin:20260922T090000" in lines

      assert {:error, :not_found} =
               ProviderCalendarEventQueries.get_by_uid(integration.id, override.uid)
    end
  end

  describe "deleting the whole series" do
    test "DELETEs the resource and removes every row of it", %{
      user: user,
      integration: integration,
      occurrence: occurrence,
      unrelated: unrelated
    } do
      test_pid = self()

      expect(Tymeslot.HTTPClientMock, :delete, fn url, _headers, _opts ->
        send(test_pid, {:delete, url})
        {:ok, %Req.Response{status: 204, body: "", headers: %{}}}
      end)

      assert {:ok, %{linked_meeting: :none}} =
               CalendarGrid.delete_event(user.id, occurrence, :series)

      assert_received {:delete, @url}
      assert cached_uids(integration) == [unrelated.uid]
    end
  end

  describe "when the server refuses the delete" do
    # The offline queue would replay it as a DELETE of the whole resource.
    test "an occurrence delete is not queued and the cache is untouched", %{
      user: user,
      integration: integration,
      occurrence: occurrence
    } do
      expect(Tymeslot.HTTPClientMock, :put, fn _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, %{retry: :not_queued}} =
               CalendarGrid.delete_event(user.id, occurrence, :occurrence)

      {:ok, row} = ProviderCalendarEventQueries.get_by_uid(integration.id, occurrence.uid)
      assert {row.sync_state, row.etag, row.raw_ical} == {"synced", "\"etag-1\"", @series_ical}
    end
  end
end
