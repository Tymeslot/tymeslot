defmodule Tymeslot.CalendarGrid.AllDayTest do
  @moduledoc """
  Converting a calendar event between all-day and timed. `end_date` and
  `end_at` are both exclusive, so the classic mistake is a day too many.
  """
  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.AllDay

  describe "toggle/2, timed to all-day" do
    test "an evening event ending at local midnight covers its one day" do
      event = timed(~U[2026-10-05 20:00:00Z], ~U[2026-10-05 22:00:00Z])

      # 22:00 to 00:00 in Berlin (UTC+2).
      assert %{all_day: true, start_date: ~D[2026-10-05], end_date: ~D[2026-10-06]} =
               AllDay.toggle(event, "Europe/Berlin")
    end

    test "a 24-hour event from midnight to midnight covers its one day" do
      event = timed(~U[2026-10-05 00:00:00Z], ~U[2026-10-06 00:00:00Z])

      assert %{start_date: ~D[2026-10-05], end_date: ~D[2026-10-06]} =
               AllDay.toggle(event, "Etc/UTC")
    end

    test "a multi-day event covers every day it touches" do
      event = timed(~U[2026-10-05 10:00:00Z], ~U[2026-10-07 15:00:00Z])

      assert %{start_date: ~D[2026-10-05], end_date: ~D[2026-10-08]} =
               AllDay.toggle(event, "Etc/UTC")
    end

    test "a zero-length event covers the day it sits on" do
      event = timed(~U[2026-10-05 10:00:00Z], ~U[2026-10-05 10:00:00Z])

      assert %{start_date: ~D[2026-10-05], end_date: ~D[2026-10-06]} =
               AllDay.toggle(event, "Etc/UTC")
    end

    test "reads the days on the given zone's calendar" do
      # 00:30 to 01:30 on the 5th in Berlin is the 4th in UTC.
      event = timed(~U[2026-10-04 22:30:00Z], ~U[2026-10-04 23:30:00Z])

      assert %{start_date: ~D[2026-10-05], end_date: ~D[2026-10-06]} =
               AllDay.toggle(event, "Europe/Berlin")
    end
  end

  describe "toggle/2, all-day to timed" do
    test "runs 09:00 to 10:00 local, from the first day to the last it covered" do
      event = %{
        all_day: true,
        start_date: ~D[2026-10-05],
        end_date: ~D[2026-10-07],
        start_at: nil,
        end_at: nil
      }

      assert %{all_day: false, start_at: start_at, end_at: end_at, start_date: nil, end_date: nil} =
               AllDay.toggle(event, "Europe/Berlin")

      assert start_at == ~U[2026-10-05 07:00:00.000000Z]
      assert end_at == ~U[2026-10-06 08:00:00.000000Z]
    end
  end

  describe "start_date/2" do
    test "is an all-day event's own first day" do
      assert AllDay.start_date(%{start_date: ~D[2026-10-05]}, "Pacific/Auckland") ==
               ~D[2026-10-05]
    end

    test "is the day a timed event starts on in the series' zone, not in UTC" do
      # 00:30 on the 5th in Berlin.
      event = %{start_date: nil, start_at: ~U[2026-10-04 22:30:00Z]}

      assert AllDay.start_date(event, "Europe/Berlin") == ~D[2026-10-05]
      assert AllDay.start_date(event, nil) == ~D[2026-10-04]
    end

    test "is nil for an event with neither" do
      assert AllDay.start_date(%{start_date: nil, start_at: nil}, "Etc/UTC") == nil
    end
  end

  defp timed(start_at, end_at),
    do: %{all_day: false, start_at: start_at, end_at: end_at, start_date: nil, end_date: nil}
end
