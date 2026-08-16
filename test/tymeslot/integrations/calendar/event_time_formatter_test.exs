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

  # `RecurringSeries.parse_point/1` normalises a series master's DTSTART to UTC
  # with `shift_zone!(at, "Etc/UTC")`, discarding the IANA label the provider
  # sent. That looks like it should mistime a series spanning a DST change —
  # "every Tuesday at 09:00" landing an hour out for half the year — and it does
  # not, because shifting to UTC preserves the absolute instant and the label
  # travels separately on the payload's `:timezone`. Reapplying it here picks
  # the offset in force on each occurrence's own date.
  #
  # Pinned because the reasoning is not visible from either side alone: the
  # normalisation looks lossy where it sits, and this function looks like plain
  # formatting where it sits.
  describe "format_with_timezone/3 — a UTC instant re-anchored across a DST boundary" do
    test "the same wall-clock hour survives on both sides of the change" do
      # Europe/Tallinn is EET (+02) in January and EEST (+03) in July. Both of
      # these are 09:00 local, expressed as the UTC instant the master carries.
      winter = EventTimeFormatter.format_with_timezone(~U[2027-01-06 07:00:00Z], "Europe/Tallinn")
      summer = EventTimeFormatter.format_with_timezone(~U[2027-07-07 06:00:00Z], "Europe/Tallinn")

      assert winter["dateTime"] == "2027-01-06T09:00:00"
      assert summer["dateTime"] == "2027-07-07T09:00:00"

      # The label, not the offset, is what lets the target expand the rule.
      assert winter["timeZone"] == "Europe/Tallinn"
      assert summer["timeZone"] == "Europe/Tallinn"
    end

    test "a fixed UTC instant does move in wall-clock terms across the change" do
      # The counterweight: if the two above passed because the function ignored
      # the zone, this would pass too. The same instant is 14:00 in winter and
      # 15:00 in summer, so a test asserting otherwise would be asserting that
      # the shift never happens.
      winter = EventTimeFormatter.format_with_timezone(~U[2027-01-06 12:00:00Z], "Europe/Tallinn")
      summer = EventTimeFormatter.format_with_timezone(~U[2027-07-07 12:00:00Z], "Europe/Tallinn")

      assert winter["dateTime"] == "2027-01-06T14:00:00"
      assert summer["dateTime"] == "2027-07-07T15:00:00"
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
      assert result["dateTime"] == "2026-04-18T10:00:00"
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
