defmodule Tymeslot.Integrations.Calendar.DebugSchedule do
  @moduledoc """
  Pure generator of synthetic busy calendar events for development and testing.

  Single source of truth for the "debug calendar" event set. Given a recurring
  `pattern`, a list of explicit `rules`, a datetime range and a timezone, it
  returns plain event maps in the shape the booking/availability pipeline
  consumes (deduped by `{uid, start_time}` downstream).

  This module is pure — it holds no state and performs no side effects, so it is
  compiled in every environment and fully unit-testable. The live, mutable rule
  set lives in `Tymeslot.Dev.Calendar.Store` (dev-only); the `:debug` calendar
  provider drives the default pattern through here too, so both paths return
  identical events.

  ## Patterns

    * `:default` — a realistic recurring weekly shape, keyed on each date's day
      of week (so it is always relative to "now" and never falls outside the
      booking window): Monday light, Tuesday busy, Wednesday all-day, Thursday
      free, Friday afternoon, weekend free.
    * `:empty` — no recurring events; only explicit rules apply.

  ## Rules

    * `{:block_date, date}` — the whole day is busy.
    * `{:busy, date, start_time, end_time}` — a single busy period.
  """

  @type pattern :: :default | :empty
  @type rule :: {:block_date, Date.t()} | {:busy, Date.t(), Time.t(), Time.t()}
  @type event :: %{
          uid: String.t(),
          summary: String.t(),
          start_time: DateTime.t(),
          end_time: DateTime.t(),
          status: String.t()
        }

  @doc """
  Builds the busy events overlapping `[range_start, range_end)` in `timezone`.

  Combines the recurring `pattern` with the explicit `rules`, keeps only events
  that overlap the requested range, and returns them sorted by start time.
  """
  @spec events(pattern(), [rule()], DateTime.t(), DateTime.t(), String.t()) :: [event()]
  def events(pattern, rules, %DateTime{} = range_start, %DateTime{} = range_end, timezone)
      when is_atom(pattern) and is_list(rules) and is_binary(timezone) do
    generated =
      pattern_events(pattern, range_start, range_end, timezone) ++ rule_events(rules, timezone)

    in_range(generated, range_start, range_end)
  end

  @doc """
  Keeps only the events overlapping `[range_start, range_end)`, sorted by start
  time. Used to merge externally-supplied events (e.g. ones created in-app) into
  the same range/order as the generated set.
  """
  @spec in_range([map()], DateTime.t(), DateTime.t()) :: [map()]
  def in_range(events, %DateTime{} = range_start, %DateTime{} = range_end) do
    events
    |> Enum.filter(&overlaps?(&1, range_start, range_end))
    |> Enum.sort_by(& &1.start_time, DateTime)
  end

  # --- Recurring pattern -----------------------------------------------------

  defp pattern_events(:empty, _range_start, _range_end, _timezone), do: []

  defp pattern_events(:default, range_start, range_end, timezone) do
    range_start
    |> DateTime.to_date()
    |> Date.range(DateTime.to_date(range_end))
    |> Enum.flat_map(&events_for_date(&1, timezone))
  end

  # Mirrors the historical debug pattern so the shape stays familiar.
  defp events_for_date(date, timezone) do
    case Date.day_of_week(date) do
      1 ->
        [
          busy(date, ~T[09:00:00], ~T[10:00:00], "Monday Morning Standup", timezone),
          busy(date, ~T[14:00:00], ~T[15:00:00], "Project Review", timezone)
        ]

      2 ->
        [
          busy(date, ~T[09:00:00], ~T[09:30:00], "Quick Check-in", timezone),
          busy(date, ~T[10:00:00], ~T[11:00:00], "Client Meeting", timezone),
          busy(date, ~T[12:00:00], ~T[13:00:00], "Lunch Meeting", timezone),
          busy(date, ~T[15:00:00], ~T[16:00:00], "Team Sync", timezone),
          busy(date, ~T[16:30:00], ~T[17:00:00], "Wrap-up Call", timezone)
        ]

      3 ->
        [busy(date, ~T[09:00:00], ~T[17:00:00], "Company All-Hands", timezone)]

      5 ->
        [
          busy(date, ~T[13:00:00], ~T[14:00:00], "Weekly Planning", timezone),
          busy(date, ~T[15:30:00], ~T[16:30:00], "Sprint Retrospective", timezone)
        ]

      _free_day ->
        []
    end
  end

  # --- Explicit rules --------------------------------------------------------

  defp rule_events(rules, timezone), do: Enum.map(rules, &rule_event(&1, timezone))

  defp rule_event({:block_date, date}, timezone) do
    start_time = to_datetime(date, ~T[00:00:00], timezone)
    end_time = to_datetime(Date.add(date, 1), ~T[00:00:00], timezone)

    %{
      uid: "debug-block-#{Date.to_iso8601(date)}",
      summary: "Blocked (dev)",
      start_time: start_time,
      end_time: end_time,
      status: "confirmed"
    }
  end

  defp rule_event({:busy, date, start_time, end_time}, timezone) do
    %{
      uid: "debug-busy-#{Date.to_iso8601(date)}-#{Time.to_iso8601(start_time)}",
      summary: "Busy (dev)",
      start_time: to_datetime(date, start_time, timezone),
      end_time: to_datetime(date, end_time, timezone),
      status: "confirmed"
    }
  end

  # --- Helpers ---------------------------------------------------------------

  defp busy(date, start_time, end_time, summary, timezone) do
    %{
      uid: "debug-#{Date.to_iso8601(date)}-#{Time.to_iso8601(start_time)}",
      summary: summary,
      start_time: to_datetime(date, start_time, timezone),
      end_time: to_datetime(date, end_time, timezone),
      status: "confirmed"
    }
  end

  # Event overlaps the range when it starts before the range ends and ends after
  # the range begins. Half-open on the upper bound to avoid double-counting a
  # boundary instant.
  defp overlaps?(event, range_start, range_end) do
    DateTime.compare(event.start_time, range_end) == :lt and
      DateTime.compare(event.end_time, range_start) == :gt
  end

  # Resolves a wall-clock date/time in the given zone, degrading gracefully over
  # DST gaps/overlaps and falling back to UTC if the zone is unknown.
  defp to_datetime(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} -> datetime
      {:ambiguous, datetime, _later} -> datetime
      {:gap, _just_before, datetime} -> datetime
      {:error, _reason} -> utc_datetime(date, time)
    end
  end

  defp utc_datetime(date, time) do
    {:ok, datetime} = DateTime.new(date, time, "Etc/UTC")
    datetime
  end
end
