defmodule Tymeslot.Integrations.Calendar.RecurrenceExpanderCapTest do
  @moduledoc """
  How many occurrences of one series `RecurrenceExpander.expand/4` returns:
  every one in the range, up to one per date of it, or fewer when the caller
  asks for fewer, with a warning whenever a series is cut short. And how far
  `RecurrenceExpander.last_start/2` goes to find where a `COUNT` ends.
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

  describe "last_start/2" do
    defp last_expanded(rule, first_day) do
      rule
      |> old_series(first_day)
      |> RecurrenceExpander.expand(berlin(first_day, ~T[00:00:00]), ~U[2040-01-01 00:00:00Z])
      |> List.last()
      |> Map.fetch!(:start_time)
    end

    test "finds a COUNT's end from a first start long ago without stepping to it" do
      assert RecurrenceExpander.last_start("FREQ=DAILY;COUNT=999999", ~U[1900-01-01 09:00:00Z]) ==
               {:ok, DateTime.new!(Date.add(~D[1900-01-01], 999_998), ~T[09:00:00], "Etc/UTC")}
    end

    test "works out a rule of FREQ and INTERVAL alone as expand/4 steps it, across DST" do
      for rule <- [
            "FREQ=DAILY;INTERVAL=3;COUNT=100",
            "FREQ=WEEKLY;INTERVAL=2;COUNT=30",
            "FREQ=MONTHLY;COUNT=20",
            "FREQ=YEARLY;COUNT=5"
          ] do
        first = berlin(~D[2026-01-15], ~T[09:00:00])

        assert RecurrenceExpander.last_start(rule, first) ==
                 {:ok, last_expanded(rule, ~D[2026-01-15])},
               rule
      end
    end

    test "steps a rule whose periods may lack the first start's day" do
      assert RecurrenceExpander.last_start(
               "FREQ=MONTHLY;COUNT=4",
               berlin(~D[2026-01-31], ~T[09:00:00])
             ) ==
               {:ok, berlin(~D[2026-07-31], ~T[09:00:00])}

      # An all-day series' start is a date, and so is its last.
      assert RecurrenceExpander.last_start("FREQ=MONTHLY;COUNT=2", ~D[2026-01-30]) ==
               {:ok, ~D[2026-03-30]}
    end

    test "steps a rule with BYxxx parts to its end within two years" do
      rule = "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=150"
      first = berlin(~D[2026-01-05], ~T[09:00:00])

      assert RecurrenceExpander.last_start(rule, first) ==
               {:ok, last_expanded(rule, ~D[2026-01-05])}
    end

    test "leaves a stepped COUNT that runs on past two years unknown" do
      assert RecurrenceExpander.last_start(
               "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=250",
               berlin(~D[2026-01-05], ~T[09:00:00])
             ) == :unknown
    end

    test "ends at UNTIL when it comes before COUNT runs out" do
      assert RecurrenceExpander.last_start(
               "FREQ=WEEKLY;BYDAY=MO;COUNT=50;UNTIL=20260302T235959Z",
               ~U[2026-01-05 09:00:00Z]
             ) == {:ok, ~U[2026-03-02 09:00:00Z]}
    end

    test "is unknown without a COUNT, or with one ending past the year 9999" do
      first = ~U[2026-01-05 09:00:00Z]

      assert RecurrenceExpander.last_start("FREQ=DAILY", first) == :unknown
      assert RecurrenceExpander.last_start("FREQ=DAILY;UNTIL=20260302T090000Z", first) == :unknown
      assert RecurrenceExpander.last_start("FREQ=YEARLY;COUNT=99999", first) == :unknown
      assert RecurrenceExpander.last_start("NOT A RULE", first) == :unknown
    end
  end
end
