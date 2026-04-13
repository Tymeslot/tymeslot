defmodule Tymeslot.Integrations.Calendar.EventTimeFormatterTest do
  use ExUnit.Case, async: true

  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.EventTimeFormatter

  describe "format_with_timezone/3 — nil" do
    test "returns nil for nil input" do
      assert EventTimeFormatter.format_with_timezone(nil, "UTC") == nil
    end
  end

  describe "format_with_timezone/3 — Date (all-day events)" do
    test "returns date-only map for Date struct" do
      assert EventTimeFormatter.format_with_timezone(~D[2026-04-18], nil) ==
               %{"date" => "2026-04-18"}
    end

    test "ignores timezone for Date structs" do
      assert EventTimeFormatter.format_with_timezone(~D[2026-04-18], "Europe/Ljubljana") ==
               %{"date" => "2026-04-18"}
    end
  end

  describe "format_with_timezone/3 — DateTime with explicit timezone" do
    test "shifts to the given timezone and strips trailing Z" do
      result =
        EventTimeFormatter.format_with_timezone(
          ~U[2026-04-18 10:00:00Z],
          "Europe/Ljubljana"
        )

      assert result["timeZone"] == "Europe/Ljubljana"
      refute String.ends_with?(result["dateTime"], "Z")
    end

    test "returns dateTime and timeZone for UTC" do
      result = EventTimeFormatter.format_with_timezone(~U[2026-04-18 10:00:00Z], "Etc/UTC")

      assert result["timeZone"] == "Etc/UTC"
      assert result["dateTime"] == "2026-04-18T10:00:00"
    end
  end

  describe "format_with_timezone/3 — DateTime without timezone" do
    test "returns dateTime without timeZone by default" do
      result = EventTimeFormatter.format_with_timezone(~U[2026-04-18 10:00:00Z], nil)

      assert Map.has_key?(result, "dateTime")
      refute Map.has_key?(result, "timeZone")
    end

    test "preserves the Z/offset when no timeZone is emitted (valid RFC3339)" do
      result = EventTimeFormatter.format_with_timezone(~U[2026-04-18 10:00:00Z], nil)

      assert result["dateTime"] == "2026-04-18T10:00:00Z"
    end

    test "includes timeZone when include_when_missing? is true" do
      result =
        EventTimeFormatter.format_with_timezone(
          ~U[2026-04-18 10:00:00Z],
          nil,
          include_when_missing?: true
        )

      assert result["timeZone"] == "UTC"
      assert Map.has_key?(result, "dateTime")
    end

    test "strips trailing Z when include_when_missing? adds a timeZone" do
      result =
        EventTimeFormatter.format_with_timezone(
          ~U[2026-04-18 10:00:00Z],
          nil,
          include_when_missing?: true
        )

      refute String.ends_with?(result["dateTime"], "Z")
    end
  end

  describe "format_with_timezone/3 — ISO8601 string" do
    test "parses a valid ISO8601 string and formats it" do
      result = EventTimeFormatter.format_with_timezone("2026-04-18T10:00:00Z", "Etc/UTC")

      assert result["timeZone"] == "Etc/UTC"
      assert is_binary(result["dateTime"])
    end

    test "returns fallback map for invalid string" do
      result = EventTimeFormatter.format_with_timezone("not-a-date", nil)

      assert result["dateTime"] == "not-a-date"
    end
  end

  describe "format_with_timezone/3 — invalid input" do
    test "returns nil for unsupported types" do
      assert EventTimeFormatter.format_with_timezone(12_345, nil) == nil
      assert EventTimeFormatter.format_with_timezone(%{}, nil) == nil
    end
  end
end
