defmodule Tymeslot.Integrations.Calendar.VTimezoneTest do
  use ExUnit.Case, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.VTimezone

  describe "parse/1" do
    test "keys the map by the sanitised TZID and skips components without a STANDARD offset" do
      content = """
      BEGIN:VTIMEZONE
      TZID: 1
      BEGIN:STANDARD
      TZOFFSETTO:+0100
      RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10
      DTSTART:16010101T030000
      END:STANDARD
      END:VTIMEZONE
      BEGIN:VTIMEZONE
      TZID:Broken
      BEGIN:STANDARD
      RRULE:FREQ=YEARLY;BYDAY=-1SU;BYMONTH=10
      END:STANDARD
      END:VTIMEZONE
      """

      parsed = VTimezone.parse(content)

      assert Map.has_key?(parsed, "1")
      refute Map.has_key?(parsed, "Broken")
    end
  end

  describe "to_utc/2 — fixed offset (no DAYLIGHT)" do
    test "applies the standard offset year-round" do
      tz = standard_only(7200)

      assert {:ok, ~U[2025-07-01 08:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-07-01 10:00:00])
      assert {:ok, ~U[2025-01-01 08:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-01-01 10:00:00])
    end

    test "handles a TZOFFSETTO carrying seconds" do
      # +000000 form seen in real Nextcloud historical blocks → zero offset.
      tz = standard_only(0)
      assert {:ok, ~U[2025-07-01 10:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-07-01 10:00:00])
    end
  end

  describe "to_utc/2 — northern-hemisphere DST" do
    test "selects DAYLIGHT offset in summer and STANDARD in winter" do
      tz = cet()

      # Summer → CEST (UTC+2): 10:00 local is 08:00 UTC
      assert {:ok, ~U[2025-07-01 08:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-07-01 10:00:00])
      # Winter → CET (UTC+1): 10:00 local is 09:00 UTC
      assert {:ok, ~U[2025-01-01 09:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-01-01 10:00:00])
    end
  end

  describe "to_utc/2 — southern-hemisphere DST" do
    test "selects DAYLIGHT across the year boundary (window wraps)" do
      # Sydney-style: DST Oct–Apr. STANDARD +10 (Apr), DAYLIGHT +11 (Oct).
      tz = sydney()

      # January is inside the wrapped DST window → +11: 10:00 local is 23:00 UTC prior day
      assert {:ok, ~U[2024-12-31 23:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-01-01 10:00:00])
      # July is standard → +10: 10:00 local is 00:00 UTC
      assert {:ok, ~U[2025-07-01 00:00:00Z]} = VTimezone.to_utc(tz, ~N[2025-07-01 10:00:00])
    end
  end

  defp standard_only(offset) do
    %VTimezone{standard: %{offset: offset, transition: nil}, daylight: nil}
  end

  defp cet do
    %VTimezone{
      standard: %{offset: 3600, transition: last_sunday(10, {3, 0, 0})},
      daylight: %{offset: 7200, transition: last_sunday(3, {2, 0, 0})}
    }
  end

  defp sydney do
    %VTimezone{
      standard: %{offset: 36_000, transition: first_sunday(4, {3, 0, 0})},
      daylight: %{offset: 39_600, transition: first_sunday(10, {2, 0, 0})}
    }
  end

  defp last_sunday(month, time),
    do: %{month: month, ordinal: -1, weekday: 7, time: time}

  defp first_sunday(month, time),
    do: %{month: month, ordinal: 1, weekday: 7, time: time}
end
