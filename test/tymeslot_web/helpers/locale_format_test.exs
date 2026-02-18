defmodule TymeslotWeb.Helpers.LocaleFormatTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  describe "format_date/2" do
    test "formats date in English" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "en") == "March 15, 2026"
    end

    test "formats date in German (note: Calendar.strftime doesn't localize month names)" do
      date = ~D[2026-03-15]
      # Calendar.strftime doesn't use locale-aware month names, it uses system locale
      # For proper localization, use LocaleFormat.get_month_names/1 directly
      assert LocaleFormat.format_date(date, "de") == "15. March 2026"
    end

    test "formats date in Ukrainian (note: Calendar.strftime doesn't localize month names)" do
      date = ~D[2026-03-15]
      # Note: Calendar.strftime doesn't localize month names
      # This test documents current behavior - LocaleFormat.get_month_names should be used instead
      assert LocaleFormat.format_date(date, "uk") == "15 March 2026"
    end

    test "falls back to English for unknown locale" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "fr") == "March 15, 2026"
    end
  end

  describe "format_time/2" do
    test "formats time in 12-hour format for English" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "en") == "02:30 PM"
    end

    test "formats time in 24-hour format for German" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "de") == "14:30"
    end

    test "formats time in 24-hour format for Ukrainian" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "uk") == "14:30"
    end

    test "handles midnight correctly in English" do
      time = ~T[00:00:00]
      assert LocaleFormat.format_time(time, "en") == "12:00 AM"
    end

    test "handles midnight correctly in German" do
      time = ~T[00:00:00]
      assert LocaleFormat.format_time(time, "de") == "00:00"
    end

    test "handles noon correctly in English" do
      time = ~T[12:00:00]
      assert LocaleFormat.format_time(time, "en") == "12:00 PM"
    end

    test "falls back to English for unknown locale" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "fr") == "02:30 PM"
    end
  end

  describe "get_month_names/1" do
    test "returns English month names" do
      months = LocaleFormat.get_month_names("en")
      assert length(months) == 12
      assert Enum.at(months, 0) == "January"
      assert Enum.at(months, 11) == "December"
    end

    test "returns German month names" do
      months = LocaleFormat.get_month_names("de")
      assert length(months) == 12
      assert Enum.at(months, 0) == "Januar"
      assert Enum.at(months, 2) == "März"
      assert Enum.at(months, 11) == "Dezember"
    end

    test "returns Ukrainian month names" do
      months = LocaleFormat.get_month_names("uk")
      assert length(months) == 12
      assert Enum.at(months, 0) == "Січень"
      assert Enum.at(months, 11) == "Грудень"
    end

    test "falls back to English for unknown locale" do
      months = LocaleFormat.get_month_names("fr")
      assert Enum.at(months, 0) == "January"
    end
  end

  describe "get_weekday_names/2" do
    test "returns English full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "Sunday"
      assert Enum.at(weekdays, 1) == "Monday"
    end

    test "returns German full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("de", :full)
      assert Enum.at(weekdays, 0) == "Sonntag"
      assert Enum.at(weekdays, 1) == "Montag"
    end

    test "returns short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :short)
      assert Enum.at(weekdays, 0) == "Sun"
      assert Enum.at(weekdays, 1) == "Mon"
    end

    test "returns narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("en", :narrow)
      assert Enum.at(weekdays, 0) == "S"
      assert Enum.at(weekdays, 1) == "M"
    end

    test "defaults to short format when not specified" do
      weekdays = LocaleFormat.get_weekday_names("en")
      assert Enum.at(weekdays, 0) == "Sun"
    end
  end

  describe "format_month_name/2" do
    test "formats valid month numbers" do
      assert LocaleFormat.format_month_name(1, "en") == "January"
      assert LocaleFormat.format_month_name(12, "en") == "December"
      assert LocaleFormat.format_month_name(3, "de") == "März"
    end

    test "returns empty string for invalid month numbers" do
      assert LocaleFormat.format_month_name(0, "en") == ""
      assert LocaleFormat.format_month_name(13, "en") == ""
      assert LocaleFormat.format_month_name(-1, "en") == ""
    end

    test "handles edge case month numbers" do
      assert LocaleFormat.format_month_name(nil, "en") == ""
      assert LocaleFormat.format_month_name("invalid", "en") == ""
    end
  end

  describe "format_weekday_name/3" do
    test "formats valid weekday numbers (ISO 8601: 1=Monday, 7=Sunday)" do
      assert LocaleFormat.format_weekday_name(1, "en", :full) == "Monday"
      assert LocaleFormat.format_weekday_name(7, "en", :full) == "Sunday"
    end

    test "converts ISO weekday to correct array index" do
      # ISO: 1=Monday, but our array is 0=Sunday
      assert LocaleFormat.format_weekday_name(1, "en", :short) == "Mon"
      assert LocaleFormat.format_weekday_name(7, "en", :short) == "Sun"
    end

    test "returns empty string for invalid weekday numbers" do
      assert LocaleFormat.format_weekday_name(0, "en", :full) == ""
      assert LocaleFormat.format_weekday_name(8, "en", :full) == ""
      assert LocaleFormat.format_weekday_name(-1, "en", :full) == ""
    end

    test "handles edge case weekday numbers" do
      assert LocaleFormat.format_weekday_name(nil, "en", :full) == ""
      assert LocaleFormat.format_weekday_name("invalid", "en", :full) == ""
    end

    test "defaults to short format when not specified" do
      result = LocaleFormat.format_weekday_name(1, "en")
      assert result == "Mon"
    end
  end

  describe "DST transition handling" do
    test "formats date during spring DST transition (clock forward)" do
      # In most timezones, DST transitions happen in March/April
      # Date formatting should not be affected by DST transitions
      date_before = ~D[2026-03-28]
      date_after = ~D[2026-03-29]

      assert is_binary(LocaleFormat.format_date(date_before, "en"))
      assert is_binary(LocaleFormat.format_date(date_after, "en"))
      assert LocaleFormat.format_date(date_before, "en") == "March 28, 2026"
      assert LocaleFormat.format_date(date_after, "en") == "March 29, 2026"
    end

    test "formats date during fall DST transition (clock backward)" do
      # In most timezones, DST transitions happen in October/November
      date_before = ~D[2026-10-24]
      date_after = ~D[2026-10-25]

      assert is_binary(LocaleFormat.format_date(date_before, "en"))
      assert is_binary(LocaleFormat.format_date(date_after, "en"))
      assert LocaleFormat.format_date(date_before, "en") == "October 24, 2026"
      assert LocaleFormat.format_date(date_after, "en") == "October 25, 2026"
    end

    test "formats time during DST transition - Time type is DST-agnostic" do
      # Time (without timezone) should always format consistently
      time = ~T[02:30:00]

      assert LocaleFormat.format_time(time, "en") == "02:30 AM"
      assert LocaleFormat.format_time(time, "de") == "02:30"
      assert LocaleFormat.format_time(time, "uk") == "02:30"
    end

    test "handles DateTime during spring DST transition" do
      # Create DateTimes around DST transition in US Eastern time
      # Note: This uses UTC, actual DST handling is done by Tzdata in other parts of the app
      {:ok, dt_before} = DateTime.new(~D[2026-03-08], ~T[06:59:00], "Etc/UTC")
      {:ok, dt_after} = DateTime.new(~D[2026-03-08], ~T[07:01:00], "Etc/UTC")

      # Extract date and time components for formatting
      date_before = DateTime.to_date(dt_before)
      time_before = DateTime.to_time(dt_before)
      date_after = DateTime.to_date(dt_after)
      time_after = DateTime.to_time(dt_after)

      # Both should format without errors
      assert is_binary(LocaleFormat.format_date(date_before, "en"))
      assert is_binary(LocaleFormat.format_time(time_before, "en"))
      assert is_binary(LocaleFormat.format_date(date_after, "en"))
      assert is_binary(LocaleFormat.format_time(time_after, "en"))
    end

    test "handles DateTime during fall DST transition" do
      {:ok, dt_before} = DateTime.new(~D[2026-11-01], ~T[05:59:00], "Etc/UTC")
      {:ok, dt_after} = DateTime.new(~D[2026-11-01], ~T[06:01:00], "Etc/UTC")

      date_before = DateTime.to_date(dt_before)
      time_before = DateTime.to_time(dt_before)
      date_after = DateTime.to_date(dt_after)
      time_after = DateTime.to_time(dt_after)

      assert is_binary(LocaleFormat.format_date(date_before, "en"))
      assert is_binary(LocaleFormat.format_time(time_before, "en"))
      assert is_binary(LocaleFormat.format_date(date_after, "en"))
      assert is_binary(LocaleFormat.format_time(time_after, "en"))
    end

    test "month names remain consistent across DST transitions" do
      # Month names should not be affected by DST
      march = LocaleFormat.format_month_name(3, "en")
      october = LocaleFormat.format_month_name(10, "en")

      assert march == "March"
      assert october == "October"
    end

    test "weekday names remain consistent across DST transitions" do
      # Weekday names should not be affected by DST
      monday = LocaleFormat.format_weekday_name(1, "en", :full)
      sunday = LocaleFormat.format_weekday_name(7, "en", :full)

      assert monday == "Monday"
      assert sunday == "Sunday"
    end
  end

  describe "locale parameter edge cases" do
    test "handles nil locale gracefully" do
      date = ~D[2026-03-15]
      time = ~T[14:30:00]

      # Should fall back to English
      assert is_binary(LocaleFormat.format_date(date, nil))
      assert is_binary(LocaleFormat.format_time(time, nil))
    end

    test "handles empty string locale" do
      date = ~D[2026-03-15]
      assert is_binary(LocaleFormat.format_date(date, ""))
    end

    test "handles unusual but valid dates" do
      # Leap year
      leap_date = ~D[2024-02-29]
      assert is_binary(LocaleFormat.format_date(leap_date, "en"))

      # New Year
      new_year = ~D[2026-01-01]
      assert LocaleFormat.format_date(new_year, "en") == "January 01, 2026"

      # New Year's Eve
      nye = ~D[2026-12-31]
      assert LocaleFormat.format_date(nye, "en") == "December 31, 2026"
    end
  end
end
