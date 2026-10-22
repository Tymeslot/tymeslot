defmodule Tymeslot.CalendarGrid.ProviderWritersContractTest do
  @moduledoc """
  Ties the fields a grid edit can change to the provider writers that put
  them on the wire.

  Each writer declares the fields it writes on its own, and silently ignores
  a key it does not know, while the cache row is updated as if the edit had
  been written. So every field an edit can change, and every key
  `ProviderPayload.from_event/1` emits, must be written by each writer or
  named here as one it leaves out on purpose. A writer "writes" a key when
  changing that key alone changes what it produces.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :integrations

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.ProviderPayload
  alias Tymeslot.CalendarGrid.SeriesEdit
  alias Tymeslot.Integrations.Calendar.Google.SeriesPatch, as: GoogleSeriesPatch
  alias Tymeslot.Integrations.Calendar.ICalBuilder
  alias Tymeslot.Integrations.Calendar.ICalBuilder.Patcher
  alias Tymeslot.Integrations.Calendar.Outlook.SeriesPatch, as: OutlookSeriesPatch

  @event %{
    summary: "Board meeting",
    description: "Agenda",
    location: "Room 1",
    all_day: false,
    start_at: ~U[2030-01-15 09:00:00Z],
    end_at: ~U[2030-01-15 10:00:00Z],
    start_date: nil,
    end_date: nil,
    attendees: [%{email: "ann@example.com", display_name: "Ann", response_status: :accepted}],
    reminders: [%{method: :popup, minutes_before: 15}],
    recurrence_rule: "FREQ=WEEKLY",
    recurrence_exceptions: [],
    colour: "tomato",
    transparency: :opaque,
    visibility: :public,
    status: "confirmed",
    provider_event_id: "/cal/board.ics",
    provider_calendar_id: "/cal/",
    created_by_tymeslot: true
  }

  # A value for each payload key other than the one `@event` gives it.
  @changed %{
    summary: "Renamed",
    description: "New agenda",
    location: "Room 2",
    start_time: ~U[2030-01-15 10:00:00Z],
    end_time: ~U[2030-01-15 12:00:00Z],
    all_day: true,
    attendees: [%{email: "bob@example.com", display_name: "Bob", response_status: :accepted}],
    reminders: [%{method: :popup, minutes_before: 30}],
    recurrence_rule: "FREQ=DAILY",
    recurrence_exceptions: [~U[2030-01-22 09:00:00Z]],
    colour: "sage",
    transparency: :transparent,
    visibility: :private,
    status: "tentative",
    provider_event_id: "/cal/other.ics",
    calendar_id: "/other/",
    created_by_tymeslot: false
  }

  # The keys that say where the write goes, which no writer puts into the
  # event itself.
  @addressing [:provider_event_id, :calendar_id]

  # The cache's timing fields, which the payload carries as `:start_time` and
  # `:end_time`, a `Date` for an all-day event and a `DateTime` otherwise.
  @timing %{
    start_at: :start_time,
    end_at: :end_time,
    start_date: :start_time,
    end_date: :end_time
  }

  @stored_document """
  BEGIN:VCALENDAR\r
  VERSION:2.0\r
  PRODID:-//Example//EN\r
  BEGIN:VEVENT\r
  UID:board\r
  DTSTAMP:20300101T000000Z\r
  DTSTART:20300115T090000Z\r
  DTEND:20300115T100000Z\r
  SUMMARY:Board meeting\r
  RRULE:FREQ=WEEKLY\r
  END:VEVENT\r
  END:VCALENDAR\r
  """

  defp payload do
    {:ok, payload} = ProviderPayload.from_event(@event)
    payload
  end

  # The payload keys a single-event writer leaves alone: those whose change
  # does not change what it writes. DTSTAMP is the time of writing, so it is
  # left out of the comparison.
  defp unwritten_keys(writer) do
    payload = payload()
    written = writer.(payload)

    payload
    |> Map.keys()
    |> Enum.filter(&(writer.(Map.put(payload, &1, Map.fetch!(@changed, &1))) == written))
    |> MapSet.new()
  end

  defp without_dtstamp(document) do
    document
    |> String.split("\r\n")
    |> Enum.reject(&String.starts_with?(&1, "DTSTAMP:"))
  end

  describe "the payload" do
    test "carries every field an edit can change" do
      payload_keys = Map.keys(payload())

      missing =
        EventEdit.editable_fields()
        |> Enum.map(&Map.get(@timing, &1, &1))
        |> Enum.reject(&(&1 in payload_keys))

      assert missing == []
    end

    test "has a changed value for every key it carries, so each is probed" do
      assert Enum.sort(Map.keys(payload())) == Enum.sort(Map.keys(@changed))
    end
  end

  describe "a CalDAV write" do
    # `:created_by_tymeslot` marks a Google or Outlook event as Tymeslot's;
    # a CalDAV document carries no such mark, its origin being read from
    # the document itself on sync.
    @caldav_left_out MapSet.new(@addressing ++ [:created_by_tymeslot])

    test "a patch of the stored document writes every key but those it leaves out" do
      assert unwritten_keys(&without_dtstamp(Patcher.patch(@stored_document, &1))) ==
               @caldav_left_out
    end

    test "a document built from the payload writes every key but those it leaves out" do
      assert unwritten_keys(&without_dtstamp(ICalBuilder.build_simple_event("board", &1))) ==
               @caldav_left_out
    end
  end

  describe "a series edit" do
    # A series edit refuses a change between all-day and timed (an occurrence
    # cannot leave its series' kind), and writes timing and the repeat rule
    # through the series' own move, not as fields.
    test "writes every field an edit can change as a field, its timing, or its rule" do
      refused = [:all_day]
      moved = Map.keys(@timing) ++ [:recurrence_rule]

      unhandled =
        EventEdit.editable_fields() -- (SeriesEdit.override_fields() ++ moved ++ refused)

      assert unhandled == []
    end

    test "on Google writes every field it writes as it is" do
      assert unwritten_series_fields(&GoogleSeriesPatch.build(google_master(), &1)) == []
    end

    # Graph has no colour of its own for an event, only categories.
    test "on Outlook writes every field it writes as it is, colour aside" do
      assert unwritten_series_fields(&OutlookSeriesPatch.build(outlook_master(), &1)) == [
               :colour
             ]
    end
  end

  # The override fields whose change alone does not change the series body.
  defp unwritten_series_fields(build) do
    {:ok, unchanged} = build.(series_edit(%{}))

    Enum.filter(SeriesEdit.override_fields(), fn field ->
      {:ok, body} = build.(series_edit(%{field => Map.fetch!(@changed, field)}))
      body == unchanged
    end)
  end

  defp series_edit(changes) do
    start = ~U[2026-11-02 08:00:00Z]
    finish = ~U[2026-11-02 09:00:00Z]

    %{
      scope: :all,
      master_id: "series1",
      start: start,
      end: finish,
      changes: Map.merge(%{start_time: start, end_time: finish}, changes)
    }
  end

  defp google_master do
    %{
      "id" => "series1",
      "summary" => "Weekly sync",
      "start" => %{"dateTime" => "2026-06-01T09:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "end" => %{"dateTime" => "2026-06-01T10:00:00+02:00", "timeZone" => "Europe/Berlin"},
      "recurrence" => ["RRULE:FREQ=WEEKLY;BYDAY=MO"]
    }
  end

  defp outlook_master do
    %{
      "id" => "series1",
      "type" => "seriesMaster",
      "subject" => "Weekly sync",
      "isAllDay" => false,
      "start" => %{"dateTime" => "2026-06-01T07:00:00.0000000", "timeZone" => "UTC"},
      "end" => %{"dateTime" => "2026-06-01T08:00:00.0000000", "timeZone" => "UTC"},
      "originalStartTimeZone" => "W. Europe Standard Time",
      "recurrence" => %{
        "pattern" => %{
          "type" => "weekly",
          "interval" => 1,
          "daysOfWeek" => ["monday"],
          "firstDayOfWeek" => "sunday"
        },
        "range" => %{
          "type" => "endDate",
          "startDate" => "2026-06-01",
          "endDate" => "2026-12-31",
          "recurrenceTimeZone" => "W. Europe Standard Time"
        }
      }
    }
  end
end
