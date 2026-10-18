defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.SharedToUtcTest do
  @moduledoc """
  Unit tests for `Shared.to_utc/4` DST edge-case handling (issues #1 and #3).

  Uses real IANA timezone data (via Tz) — no mocking needed since these are
  pure data transformations. The dates are chosen to fall precisely in the
  known DST transition windows for each timezone.
  """

  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  describe "to_utc/4 — normal (non-DST) times" do
    test "returns {:ok, utc_datetime} for a regular time" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-06-15], 10, 30, "Europe/London")
      assert dt.hour == 9
      assert dt.minute == 30
      assert dt.time_zone == "Etc/UTC"
    end

    test "returns {:ok, utc_datetime} for Etc/UTC with no conversion needed" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-06-15], 14, 0, "Etc/UTC")
      assert dt.hour == 14
      assert dt.minute == 0
      assert dt.time_zone == "Etc/UTC"
    end
  end

  describe "to_utc/4 — spring-forward gap (America/New_York, 2026-03-08 02:xx)" do
    # At 02:00 on 2026-03-08 the clock jumps to 03:00 (UTC-5 → UTC-4).
    # Times 02:00–02:59 do not exist in America/New_York that day.
    test "gap time returns {:ok, just_after} rather than crashing" do
      # 02:30 falls in the skipped hour — should resolve to 03:00 (just_after).
      result = Shared.to_utc(~D[2026-03-08], 2, 30, "America/New_York")
      assert {:ok, dt} = result
      # just_after is 03:00 EDT (UTC-4) = 07:00 UTC
      assert dt.hour == 7
      assert dt.minute == 0
      assert dt.time_zone == "Etc/UTC"
    end

    test "00:30 (before gap) is unaffected and resolves correctly" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-03-08], 0, 30, "America/New_York")
      # 00:30 EST (UTC-5) = 05:30 UTC
      assert dt.hour == 5
      assert dt.minute == 30
    end

    test "03:30 (after gap) resolves correctly" do
      assert {:ok, dt} = Shared.to_utc(~D[2026-03-08], 3, 30, "America/New_York")
      # 03:30 EDT (UTC-4) = 07:30 UTC
      assert dt.hour == 7
      assert dt.minute == 30
    end
  end

  describe "to_utc/4 — fall-back ambiguity (America/New_York, 2026-11-01 01:xx)" do
    # At 02:00 on 2026-11-01 the clock falls back to 01:00 (UTC-4 → UTC-5).
    # Times 01:00–01:59 exist twice — once in EDT (UTC-4) and once in EST (UTC-5).
    test "ambiguous time returns {:ok, first (DST side)} rather than crashing" do
      # 01:30 is ambiguous; we expect the DST-side (first) = UTC-4 = 05:30 UTC.
      result = Shared.to_utc(~D[2026-11-01], 1, 30, "America/New_York")
      assert {:ok, dt} = result
      # first = EDT side (UTC-4): 01:30 EDT = 05:30 UTC
      assert dt.hour == 5
      assert dt.minute == 30
      assert dt.time_zone == "Etc/UTC"
    end
  end
end
