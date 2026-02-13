defmodule Tymeslot.Utils.DateTimeUtilsTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Tymeslot.Utils.DateTimeUtils

  describe "parse_duration/1" do
    test "parses time durations (PT)" do
      assert {:ok, 3600} == DateTimeUtils.parse_duration("PT1H")
      assert {:ok, 90} == DateTimeUtils.parse_duration("PT1M30S")
      assert {:ok, 5400} == DateTimeUtils.parse_duration("PT1H30M")
      assert {:ok, 3661} == DateTimeUtils.parse_duration("PT1H1M1S")
    end

    test "parses day and week durations (P)" do
      assert {:ok, 86_400} == DateTimeUtils.parse_duration("P1D")
      assert {:ok, 604_800} == DateTimeUtils.parse_duration("P1W")
      assert {:ok, 691_200} == DateTimeUtils.parse_duration("P1W1D")
    end

    test "returns error for invalid formats" do
      assert {:error, "Invalid duration format"} == DateTimeUtils.parse_duration("invalid")
      assert {:error, "Invalid duration format"} == DateTimeUtils.parse_duration("")

      assert {:error, "Unsupported or invalid duration format"} ==
               DateTimeUtils.parse_duration("P")
    end

    property "never crashes and returns either ok or error for random strings" do
      check all(s <- string(:ascii)) do
        result = DateTimeUtils.parse_duration(s)
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end
    end

    property "correctly parses generated PT durations" do
      check all(
              h <- integer(0..1000),
              m <- integer(0..59),
              s <- integer(0..59)
            ) do
        duration_str = "PT#{h}H#{m}M#{s}S"
        expected_seconds = h * 3600 + m * 60 + s
        assert {:ok, ^expected_seconds} = DateTimeUtils.parse_duration(duration_str)
      end
    end

    property "correctly parses generated P durations" do
      check all(
              w <- integer(0..52),
              d <- integer(0..31)
            ) do
        duration_str = "P#{w}W#{d}D"
        expected_seconds = w * 604_800 + d * 86_400
        assert {:ok, ^expected_seconds} = DateTimeUtils.parse_duration(duration_str)
      end
    end

    test "handles unsupported P components gracefully (e.g. months)" do
      # Now returns error for unsupported components because of regex anchors
      assert {:error, _} = DateTimeUtils.parse_duration("P1M")
      assert {:error, _} = DateTimeUtils.parse_duration("P1Y")
    end
  end

  describe "create_datetime_safe/3" do
    test "handles standard time correctly" do
      date = ~D[2024-06-01]
      time = ~T[12:00:00]
      timezone = "Europe/London"

      dt = DateTimeUtils.create_datetime_safe(date, time, timezone)
      assert dt.year == 2024
      assert dt.month == 6
      assert dt.day == 1
      assert dt.hour == 12
      assert dt.time_zone == "Europe/London"
    end

    test "handles spring forward gap (non-existing time)" do
      # In Europe/London, 2024-03-31 01:00:00 moved to 02:00:00
      # 01:30:00 does not exist
      date = ~D[2024-03-31]
      time = ~T[01:30:00]
      timezone = "Europe/London"

      dt = DateTimeUtils.create_datetime_safe(date, time, timezone)

      # Should shift forward by 1 hour
      assert dt.hour == 2
      assert dt.minute == 30
      assert dt.time_zone == "Europe/London"
    end

    test "handles fall back ambiguity (repeated time)" do
      # In Europe/London, 2024-10-27 02:00:00 moved back to 01:00:00
      # 01:30:00 occurs twice
      date = ~D[2024-10-27]
      time = ~T[01:30:00]
      timezone = "Europe/London"

      dt = DateTimeUtils.create_datetime_safe(date, time, timezone)

      # Should pick the first occurrence (BST)
      assert dt.hour == 1
      assert dt.minute == 30
      assert dt.zone_abbr == "BST"
      assert dt.time_zone == "Europe/London"
    end

    test "falls back to UTC for invalid timezone" do
      date = ~D[2024-01-01]
      time = ~T[12:00:00]
      timezone = "Invalid/Timezone"

      dt = DateTimeUtils.create_datetime_safe(date, time, timezone)
      assert dt.time_zone == "Etc/UTC"
      assert dt.hour == 12
    end
  end

  describe "parse_time_string/1" do
    test "parses 12h time strings" do
      assert {:ok, ~T[14:30:00]} == DateTimeUtils.parse_time_string("2:30 PM")
      assert {:ok, ~T[02:30:00]} == DateTimeUtils.parse_time_string("2:30 AM")
      assert {:ok, ~T[00:00:00]} == DateTimeUtils.parse_time_string("12:00 AM")
      assert {:ok, ~T[12:00:00]} == DateTimeUtils.parse_time_string("12:00 PM")
    end

    test "parses 24h time strings" do
      assert {:ok, ~T[14:30:00]} == DateTimeUtils.parse_time_string("14:30")
      assert {:ok, ~T[09:00:00]} == DateTimeUtils.parse_time_string("09:00")
    end

    test "parses map input (demo data format)" do
      assert {:ok, ~T[22:30:00]} ==
               DateTimeUtils.parse_time_string(%{time: "10:30 pm", available: true})

      assert {:ok, ~T[09:00:00]} == DateTimeUtils.parse_time_string(%{time: "9:00 am"})
    end

    test "returns error for invalid input" do
      assert {:error, :invalid_time_format} == DateTimeUtils.parse_time_string("invalid")
      assert {:error, :invalid_time_format} == DateTimeUtils.parse_time_string("")

      assert {:error, :invalid_time_format} ==
               DateTimeUtils.parse_time_string(%{not_time: "10:00"})
    end
  end
end
