defmodule Tymeslot.Utils.DateTimeUtilsTest do
  use ExUnit.Case, async: true

  @moduletag :utils

  use ExUnitProperties

  alias Tymeslot.Utils.DateTimeUtils
  alias Tymeslot.Utils.DateTimeUtils.Display
  alias Tymeslot.Utils.DateTimeUtils.Duration

  describe "parse_duration/1" do
    test "parses time durations (PT)" do
      assert {:ok, 3600} == Duration.parse("PT1H")
      assert {:ok, 90} == Duration.parse("PT1M30S")
      assert {:ok, 5400} == Duration.parse("PT1H30M")
      assert {:ok, 3661} == Duration.parse("PT1H1M1S")
    end

    test "parses day and week durations (P)" do
      assert {:ok, 86_400} == Duration.parse("P1D")
      assert {:ok, 604_800} == Duration.parse("P1W")
      assert {:ok, 691_200} == Duration.parse("P1W1D")
    end

    test "returns error for invalid formats" do
      assert {:error, "Invalid duration format"} == Duration.parse("invalid")
      assert {:error, "Invalid duration format"} == Duration.parse("")

      assert {:error, "Unsupported or invalid duration format"} ==
               Duration.parse("P")
    end

    property "never crashes and returns either ok or error for random strings" do
      check all(s <- string(:ascii)) do
        assert {status, _payload} = Duration.parse(s)
        assert status in [:ok, :error]
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
        assert {:ok, ^expected_seconds} = Duration.parse(duration_str)
      end
    end

    property "correctly parses generated P durations" do
      check all(
              w <- integer(0..52),
              d <- integer(0..31)
            ) do
        duration_str = "P#{w}W#{d}D"
        expected_seconds = w * 604_800 + d * 86_400
        assert {:ok, ^expected_seconds} = Duration.parse(duration_str)
      end
    end

    test "handles unsupported P components gracefully (e.g. months)" do
      # Now returns error for unsupported components because of regex anchors
      assert {:error, _reason} = Duration.parse("P1M")
      assert {:error, _reason} = Duration.parse("P1Y")
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

  describe "format_duration/1" do
    test "formats duration string" do
      assert Duration.format("15min") == "15 minutes"
      assert Duration.format("30min") == "30 minutes"
      assert Duration.format("60min") == "1 hour"
      assert Duration.format("90min") == "1.5 hours"
      assert Duration.format("120min") == "2 hours"
    end

    test "formats duration integer" do
      assert Duration.format(15) == "15 minutes"
      assert Duration.format(30) == "30 minutes"
      assert Duration.format(60) == "1 hour"
      assert Duration.format(90) == "1.5 hours"
      assert Duration.format(120) == "2 hours"
    end

    test "returns unknown for invalid inputs" do
      assert Duration.format("invalid") == "Unknown duration"
      assert Duration.format(nil) == "Unknown duration"
    end
  end

  describe "format_date_string/1" do
    test "formats ISO date string" do
      assert Display.format_date_string("2024-11-25") == "November 25, 2024"
    end

    test "returns input for invalid date" do
      assert Display.format_date_string("not-a-date") == "not-a-date"
    end

    test "returns fallback for non-string" do
      assert Display.format_date_string(nil) == "Invalid date"
    end
  end

  describe "group_slots_by_period/1" do
    test "sorts slots within a period chronologically, not lexicographically" do
      # "7:30 AM" lexicographically sorts after "11:30 AM" because "7" > "1",
      # but chronologically it must come first.
      slots = ["11:30 AM", "7:30 AM", "9:00 AM", "8:00 AM"]
      result = Display.group_slots_by_period(slots)
      assert result["Morning"] == ["7:30 AM", "8:00 AM", "9:00 AM", "11:30 AM"]
    end

    test "sorts within each period independently" do
      slots = ["3:00 PM", "1:00 PM", "8:00 PM", "6:00 PM", "10:00 AM", "7:00 AM"]
      result = Display.group_slots_by_period(slots)
      assert result["Morning"] == ["7:00 AM", "10:00 AM"]
      assert result["Afternoon"] == ["1:00 PM", "3:00 PM"]
      assert result["Evening"] == ["6:00 PM", "8:00 PM"]
    end

    test "handles 24h format times correctly" do
      slots = ["14:00", "07:30", "09:00", "13:00"]
      result = Display.group_slots_by_period(slots)
      assert result["Morning"] == ["07:30", "09:00"]
      assert result["Afternoon"] == ["13:00", "14:00"]
    end

    test "slots before 5am are grouped as Early Morning" do
      slots = ["02:00", "03:30", "04:45"]
      result = Display.group_slots_by_period(slots)
      assert result["Early Morning"] == ["02:00", "03:30", "04:45"]
      refute Map.has_key?(result, "Night")
    end

    test "slots from 21:00 onwards are grouped as Late Night" do
      slots = ["21:00", "22:30", "23:45"]
      result = Display.group_slots_by_period(slots)
      assert result["Late Night"] == ["21:00", "22:30", "23:45"]
      refute Map.has_key?(result, "Night")
    end

    test "early morning and late night slots are in separate groups" do
      slots = ["03:00", "22:00"]
      result = Display.group_slots_by_period(slots)
      assert result["Early Morning"] == ["03:00"]
      assert result["Late Night"] == ["22:00"]
    end

    test "5:00 AM boundary falls into Morning, not Early Morning" do
      slots = ["05:00"]
      result = Display.group_slots_by_period(slots)
      assert result["Morning"] == ["05:00"]
      refute Map.has_key?(result, "Early Morning")
    end
  end

  describe "convert_to_utc/2" do
    test "converts naive datetime with valid IANA timezone to UTC" do
      # Europe/Brussels is UTC+2 in summer (CEST)
      naive = ~N[2024-07-15 14:00:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, "Europe/Brussels")
      assert utc.time_zone == "Etc/UTC"
      assert utc.hour == 12
      assert utc.day == 15
    end

    test "strips surrounding double-quotes from TZID before converting (regression #38)" do
      # Zimbra and some CalDAV clients emit TZID="Europe/Brussels"
      naive = ~N[2024-07-15 14:00:00]
      assert {:ok, utc_quoted} = DateTimeUtils.convert_to_utc(naive, ~s("Europe/Brussels"))
      assert {:ok, utc_plain} = DateTimeUtils.convert_to_utc(naive, "Europe/Brussels")
      assert utc_quoted == utc_plain
    end

    test "normalises Windows zone name to IANA and converts correctly" do
      # "Romance Standard Time" maps to "Europe/Paris" (UTC+2 in summer)
      naive = ~N[2024-07-15 14:00:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, "Romance Standard Time")
      assert utc.time_zone == "Etc/UTC"
      # Europe/Paris is CEST (UTC+2) in July
      assert utc.hour == 12
    end

    test "falls back to UTC when timezone is nil" do
      naive = ~N[2024-01-01 10:00:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, nil)
      assert utc.time_zone == "Etc/UTC"
      assert utc.hour == 10
    end

    test "falls back to UTC and logs a warning for empty timezone string" do
      naive = ~N[2024-01-01 10:00:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, "   ")
      assert utc.time_zone == "Etc/UTC"
      assert utc.hour == 10
    end

    test "DST fall-back: ambiguous local time returns ok with the earlier (pre-clock-change) UTC offset" do
      # 2024-10-27 01:30 Europe/London is ambiguous: exists as both BST (+01:00) and GMT (+00:00)
      # The earlier occurrence is BST, so UTC result should be 00:30
      naive = ~N[2024-10-27 01:30:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, "Europe/London")
      assert utc.time_zone == "Etc/UTC"
      # BST is UTC+1, so 01:30 BST → 00:30 UTC
      assert utc.hour == 0
      assert utc.minute == 30
    end

    test "DST spring-forward: gap time returns ok resolving to just_after" do
      # 2024-03-31 01:30 Europe/London does not exist — clocks jumped from 01:00 GMT to 02:00 BST
      # just_after is 02:00:00 BST (UTC+1), i.e. 01:00 UTC
      naive = ~N[2024-03-31 01:30:00]
      assert {:ok, utc} = DateTimeUtils.convert_to_utc(naive, "Europe/London")
      assert utc.time_zone == "Etc/UTC"
      # just_after is 02:00 BST = 01:00 UTC
      assert utc.hour == 1
      assert utc.minute == 0
    end
  end

  describe "to_datetime/1" do
    test "passes DateTime through unchanged" do
      dt = ~U[2026-04-07 14:30:00Z]
      assert DateTimeUtils.to_datetime(dt) == dt
    end

    test "converts Date to midnight UTC" do
      date = ~D[2026-04-07]
      assert DateTimeUtils.to_datetime(date) == ~U[2026-04-07 00:00:00Z]
    end

    test "returns nil for nil" do
      assert DateTimeUtils.to_datetime(nil) == nil
    end
  end
end
