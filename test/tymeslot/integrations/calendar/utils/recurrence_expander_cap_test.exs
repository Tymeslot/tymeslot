defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderCapTest do
  @moduledoc """
  How many occurrences of one series `RecurrenceExpander.expand/4` returns:
  every one in the range, up to one per date of it, or fewer when the caller
  asks for fewer, with a warning whenever a series is cut short.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.ICalNormaliser
  alias Tymeslot.Integrations.Calendar.RecurrenceExpander
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Test.LogCapture

  @week_start ~U[2026-10-05 00:00:00Z]
  @week_end ~U[2026-10-11 23:59:59Z]

  defp berlin(date, time), do: DateTime.new!(date, time, "Europe/Berlin")

  defp old_series(rule, first_day) do
    %{
      uid: "old-series",
      summary: "Standing meeting",
      start_time: berlin(first_day, ~T[09:00:00]),
      end_time: berlin(first_day, ~T[09:30:00]),
      recurrence_rule: rule
    }
  end

  defp dates(occurrences), do: Enum.map(occurrences, &DateTime.to_date(&1.start_time))

  test "a daily series fills a range of several years, however long it has run" do
    occurrences =
      "FREQ=DAILY"
      |> old_series(~D[2023-10-02])
      |> RecurrenceExpander.expand(~U[2026-01-01 00:00:00Z], ~U[2030-12-31 23:59:59Z])

    assert length(occurrences) == Date.diff(~D[2030-12-31], ~D[2026-01-01]) + 1
    assert hd(dates(occurrences)) == ~D[2026-01-01]
    assert List.last(dates(occurrences)) == ~D[2030-12-31]
  end

  # The sync expands every series over its whole window, 730 days. A cap of
  # 500 occurrences, counted from the window's start, cut a daily series
  # without an end off about 134 days ahead, with nothing said.
  test "the sync caches a daily series without an end to the end of its window" do
    {window_start, window_end} = Sync.window()
    first = window_start |> DateTime.to_date() |> Date.add(-30)

    {:ok, events} =
      "FREQ=DAILY"
      |> old_series(first)
      |> List.wrap()
      |> ICalNormaliser.normalise_events(
        %{calendar_integration_id: 1, provider_calendar_id: "/cal/", synced_at: window_start},
        :caldav
      )

    last_start = events |> Enum.map(& &1.start_at) |> Enum.max(DateTime)
    assert DateTime.diff(window_end, last_start, :hour) < 24
    assert length(events) > 700
  end

  test "a series cut short by the caller's cap says so" do
    LogCapture.attach(level: :warning)

    occurrences =
      "FREQ=DAILY"
      |> old_series(~D[2023-10-02])
      |> RecurrenceExpander.expand(@week_start, @week_end, max_occurrences: 3)

    assert length(occurrences) == 3
    assert hd(dates(occurrences)) == DateTime.to_date(@week_start)

    LogCapture.await_log("Recurrence expansion stopped after 3 occurrences")
  end
end
