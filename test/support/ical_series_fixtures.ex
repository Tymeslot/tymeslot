defmodule Tymeslot.Test.ICalSeriesFixtures do
  @moduledoc """
  A weekly Berlin series stored as one CalDAV resource, and the helpers the
  `ICalBuilder.Series` tests read their results with: the documents are built
  here once, and a result is fed back through the parser and normaliser the
  sync uses, so a test asserts what the grid will show rather than how the
  document looks.
  """

  import ExUnit.Assertions

  alias Tymeslot.Integrations.Calendar.CalDAV.EventProcessor
  alias Tymeslot.Integrations.Calendar.ICalBuilder.LineFolder
  alias Tymeslot.Integrations.Calendar.ICalNormaliser

  @context %{
    calendar_integration_id: 1,
    provider_calendar_id: "/cal/primary",
    synced_at: ~U[2026-09-01 00:00:00Z]
  }

  @vtimezone """
  BEGIN:VTIMEZONE
  TZID:Europe/Berlin
  BEGIN:DAYLIGHT
  TZOFFSETFROM:+0100
  TZOFFSETTO:+0200
  TZNAME:CEST
  DTSTART:19700329T020000
  RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU
  END:DAYLIGHT
  BEGIN:STANDARD
  TZOFFSETFROM:+0200
  TZOFFSETTO:+0100
  TZNAME:CET
  DTSTART:19701025T030000
  RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU
  END:STANDARD
  END:VTIMEZONE
  """

  @doc "The Europe/Berlin `VTIMEZONE` the series documents carry."
  @spec vtimezone() :: String.t()
  def vtimezone, do: @vtimezone

  @doc "Wraps `body` in a `VCALENDAR`, with CRLF line endings."
  @spec calendar(String.t()) :: String.t()
  def calendar(body) do
    document = """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//Example Corp//Calendar 1.0//EN
    #{body}END:VCALENDAR
    """

    String.replace(document, ~r/\r?\n/, "\r\n")
  end

  @doc "The weekly master `VEVENT`, starting at `dtstart`, with `extra` lines."
  @spec master(String.t(), String.t()) :: String.t()
  def master(dtstart, extra \\ "") do
    """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTAMP:20260401T090000Z
    #{dtstart}
    DURATION:PT30M
    RRULE:FREQ=WEEKLY
    SUMMARY:Weekly sync
    #{extra}END:VEVENT
    """
  end

  @doc "An override `VEVENT` for the slot `recurrence_id` names."
  @spec override(String.t(), String.t()) :: String.t()
  def override(recurrence_id, summary \\ "Weekly sync, moved") do
    """
    BEGIN:VEVENT
    UID:weekly-sync@example.com
    DTSTAMP:20260401T090000Z
    #{recurrence_id}
    DTSTART;TZID=Europe/Berlin:20260101T150000
    DURATION:PT30M
    SUMMARY:#{summary}
    END:VEVENT
    """
  end

  @doc "The weekly series from 4 May 2026, 10:00 in Berlin."
  @spec berlin_series(String.t()) :: String.t()
  def berlin_series(extra \\ ""),
    do: calendar(@vtimezone <> master("DTSTART;TZID=Europe/Berlin:20260504T100000", extra))

  @doc "A Berlin series whose master starts at `dtstart`."
  @spec berlin_series_from(String.t()) :: String.t()
  def berlin_series_from(dtstart), do: calendar(@vtimezone <> master(dtstart))

  @doc "The unfolded, non-blank content lines of `document`."
  @spec lines(String.t()) :: [String.t()]
  def lines(document), do: Enum.reject(LineFolder.unfold_lines(document), &(&1 == ""))

  @doc "The `VEVENT` blocks of `document`, each as its unfolded lines."
  @spec vevents(String.t()) :: [[String.t()]]
  def vevents(document) do
    document
    |> lines()
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

  @doc "`date` as an iCalendar date stamp, `YYYYMMDD`."
  @spec stamp(Date.t()) :: String.t()
  def stamp(%Date{} = date), do: Calendar.strftime(date, "%Y%m%d")

  @doc """
  The Monday of the week holding the next 15 July, and the Monday 26 weeks
  earlier: summer and winter in Berlin, both inside the sync's window
  whatever the date the suite runs on.
  """
  @spec winter_and_summer_mondays() :: {Date.t(), Date.t()}
  def winter_and_summer_mondays do
    today = Date.utc_today()
    july = Date.new!(today.year, 7, 15)
    july = if Date.compare(july, today) == :lt, do: Date.new!(today.year + 1, 7, 15), else: july
    summer = Date.beginning_of_week(july)
    {Date.add(summer, -26 * 7), summer}
  end

  @doc "The events the sync makes of `document`, by uid."
  @spec normalised(String.t()) :: %{String.t() => map()}
  def normalised(document) do
    assert {:ok, raws} = EventProcessor.parse_ical_events(document)
    assert {:ok, events} = ICalNormaliser.normalise_events(raws, @context, :caldav)
    Map.new(events, &{&1.uid, &1})
  end
end
