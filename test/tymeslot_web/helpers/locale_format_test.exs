defmodule TymeslotWeb.Helpers.LocaleFormatTest do
  use ExUnit.Case, async: true
  @moduletag :utils

  alias TymeslotWeb.Helpers.LocaleFormat

  describe "format_date/2" do
    test "formats date in English" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "en") == "March 15, 2026"
    end

    test "formats date in German" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "de") == "15. März 2026"
    end

    test "formats date in Ukrainian" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "uk") == "15 березня 2026"
    end

    test "formats date in French" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "fr") == "15 mars 2026"
    end

    test "formats date in Italian" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "it") == "15 marzo 2026"
    end

    test "falls back to English for unknown locale" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "es") == "March 15, 2026"
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

    test "formats time in 24-hour format for French" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "fr") == "14:30"
    end

    test "formats time in 24-hour format for Italian" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "it") == "14:30"
    end

    test "falls back to English for unknown locale" do
      time = ~T[14:30:00]
      assert LocaleFormat.format_time(time, "es") == "02:30 PM"
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

    test "returns Ukrainian month names in genitive case" do
      months = LocaleFormat.get_month_names("uk")
      assert length(months) == 12
      assert Enum.at(months, 0) == "січня"
      assert Enum.at(months, 11) == "грудня"
    end

    test "returns French month names" do
      months = LocaleFormat.get_month_names("fr")
      assert length(months) == 12
      assert Enum.at(months, 0) == "janvier"
      assert Enum.at(months, 2) == "mars"
      assert Enum.at(months, 7) == "août"
      assert Enum.at(months, 11) == "décembre"
    end

    test "returns Italian month names" do
      months = LocaleFormat.get_month_names("it")
      assert length(months) == 12
      assert Enum.at(months, 0) == "gennaio"
      assert Enum.at(months, 2) == "marzo"
      assert Enum.at(months, 7) == "agosto"
      assert Enum.at(months, 11) == "dicembre"
    end

    test "falls back to English for unknown locale" do
      months = LocaleFormat.get_month_names("es")
      assert Enum.at(months, 0) == "January"
    end
  end

  describe "get_month_names/2 short format" do
    test "returns 12 short English month names including Jan and Dec" do
      months = LocaleFormat.get_month_names("en", :short)
      assert length(months) == 12
      assert "Jan" in months
      assert "Dec" in months
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dec"
    end

    test "returns 12 short German month names" do
      months = LocaleFormat.get_month_names("de", :short)
      assert length(months) == 12
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dez"
    end

    test "short names differ from full names for a locale" do
      assert LocaleFormat.get_month_names("de", :short) !=
               LocaleFormat.get_month_names("de", :full)
    end

    test "defaults to full format when not specified" do
      assert LocaleFormat.get_month_names("en") == LocaleFormat.get_month_names("en", :full)
    end

    test "falls back to English for unknown locale in short format" do
      months = LocaleFormat.get_month_names("es", :short)
      assert Enum.at(months, 0) == "Jan"
      assert Enum.at(months, 11) == "Dec"
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

  describe "format_month_name/3 with :short format" do
    test "formats short month names in English" do
      assert LocaleFormat.format_month_name(1, "en", :short) == "Jan"
      assert LocaleFormat.format_month_name(12, "en", :short) == "Dec"
    end

    test "formats short month name in German" do
      assert LocaleFormat.format_month_name(3, "de", :short) == "März"
    end

    test "formats full month name in German" do
      assert LocaleFormat.format_month_name(1, "de", :full) == "Januar"
    end

    test "short differs from full for the same month and locale" do
      short = LocaleFormat.format_month_name(1, "de", :short)
      full = LocaleFormat.format_month_name(1, "de", :full)
      assert short == "Jan"
      assert full == "Januar"
      assert short != full
    end

    test "returns empty string for invalid month numbers in short format" do
      assert LocaleFormat.format_month_name(13, "en", :short) == ""
      assert LocaleFormat.format_month_name(0, "de", :short) == ""
    end

    test "defaults to full format for back-compat when format omitted" do
      assert LocaleFormat.format_month_name(1, "en") == "January"
      assert LocaleFormat.format_month_name(1, "de") == "Januar"
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

      assert LocaleFormat.format_date(date_before, "en") == "March 28, 2026"
      assert LocaleFormat.format_date(date_after, "en") == "March 29, 2026"
    end

    test "formats date during fall DST transition (clock backward)" do
      # In most timezones, DST transitions happen in October/November
      date_before = ~D[2026-10-24]
      date_after = ~D[2026-10-25]

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

      # The transition does not shift the rendered wall-clock components
      assert LocaleFormat.format_date(date_before, "en") == "March 08, 2026"
      assert LocaleFormat.format_time(time_before, "en") == "06:59 AM"
      assert LocaleFormat.format_date(date_after, "en") == "March 08, 2026"
      assert LocaleFormat.format_time(time_after, "en") == "07:01 AM"
    end

    test "handles DateTime during fall DST transition" do
      {:ok, dt_before} = DateTime.new(~D[2026-11-01], ~T[05:59:00], "Etc/UTC")
      {:ok, dt_after} = DateTime.new(~D[2026-11-01], ~T[06:01:00], "Etc/UTC")

      date_before = DateTime.to_date(dt_before)
      time_before = DateTime.to_time(dt_before)
      date_after = DateTime.to_date(dt_after)
      time_after = DateTime.to_time(dt_after)

      assert LocaleFormat.format_date(date_before, "en") == "November 01, 2026"
      assert LocaleFormat.format_time(time_before, "en") == "05:59 AM"
      assert LocaleFormat.format_date(date_after, "en") == "November 01, 2026"
      assert LocaleFormat.format_time(time_after, "en") == "06:01 AM"
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

  describe "French locale" do
    test "returns French full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "dimanche"
      assert Enum.at(weekdays, 1) == "lundi"
      assert Enum.at(weekdays, 6) == "samedi"
    end

    test "returns French short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :short)
      assert Enum.at(weekdays, 0) == "dim"
      assert Enum.at(weekdays, 1) == "lun"
    end

    test "returns French narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("fr", :narrow)
      assert weekdays == ["D", "L", "M", "M", "J", "V", "S"]
    end

    test "formats numbers with space thousand separator and comma decimal" do
      assert LocaleFormat.format_number(1234.56, "fr") == "1 234,56"
    end

    test "formats month name in French" do
      assert LocaleFormat.format_month_name(1, "fr") == "janvier"
      assert LocaleFormat.format_month_name(8, "fr") == "août"
    end

    test "formats weekday name in French" do
      assert LocaleFormat.format_weekday_name(1, "fr", :full) == "lundi"
      assert LocaleFormat.format_weekday_name(7, "fr", :full) == "dimanche"
    end
  end

  describe "Italian locale" do
    test "returns Italian full weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :full)
      assert length(weekdays) == 7
      assert Enum.at(weekdays, 0) == "domenica"
      assert Enum.at(weekdays, 1) == "lunedì"
      assert Enum.at(weekdays, 6) == "sabato"
    end

    test "returns Italian short weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :short)
      assert Enum.at(weekdays, 0) == "dom"
      assert Enum.at(weekdays, 1) == "lun"
    end

    test "returns Italian narrow weekday names" do
      weekdays = LocaleFormat.get_weekday_names("it", :narrow)
      assert weekdays == ["D", "L", "M", "M", "G", "V", "S"]
    end

    test "formats numbers with period thousand separator and comma decimal" do
      assert LocaleFormat.format_number(1234.56, "it") == "1.234,56"
    end

    test "formats month name in Italian" do
      assert LocaleFormat.format_month_name(1, "it") == "gennaio"
      assert LocaleFormat.format_month_name(8, "it") == "agosto"
    end

    test "formats weekday name in Italian" do
      assert LocaleFormat.format_weekday_name(1, "it", :full) == "lunedì"
      assert LocaleFormat.format_weekday_name(7, "it", :full) == "domenica"
    end
  end

  describe "format_integer/2" do
    test "groups thousands using each locale's separator" do
      assert LocaleFormat.format_integer(1500, "en") == "1,500"
      assert LocaleFormat.format_integer(1500, "de") == "1.500"
      assert LocaleFormat.format_integer(1500, "it") == "1.500"
      assert LocaleFormat.format_integer(1500, "cs") == "1 500"
      assert LocaleFormat.format_integer(1500, "uk") == "1 500"
      assert LocaleFormat.format_integer(1500, "fr") == "1 500"
    end

    test "leaves values below a thousand ungrouped" do
      assert LocaleFormat.format_integer(450, "cs") == "450"
      assert LocaleFormat.format_integer(999, "en") == "999"
      assert LocaleFormat.format_integer(0, "en") == "0"
    end

    test "groups every three places in longer numbers" do
      assert LocaleFormat.format_integer(450_000, "cs") == "450 000"
      assert LocaleFormat.format_integer(1_234_567, "en") == "1,234,567"
    end

    test "keeps the sign outside the grouping" do
      # A sign left in the digit run would be chunked like a digit, misplacing
      # the separator whenever the digit count is a multiple of three.
      assert LocaleFormat.format_integer(-1234, "en") == "-1,234"
      assert LocaleFormat.format_integer(-123_456, "en") == "-123,456"
      assert LocaleFormat.format_integer(-1_234_567, "cs") == "-1 234 567"
    end
  end

  describe "group_separator/1" do
    test "reports the same separator format_integer/2 applies" do
      for locale <- ~w(en de it cs uk fr) do
        separator = LocaleFormat.group_separator(locale)
        assert LocaleFormat.format_integer(1000, locale) == "1" <> separator <> "000"
      end
    end
  end

  describe "format_number/3 decimal places" do
    test "defaults to two decimals" do
      assert LocaleFormat.format_number(1234.5, "en") == "1,234.50"
    end

    test "honours an explicit decimal count" do
      assert LocaleFormat.format_number(520.0, "en", 1) == "520.0"
      assert LocaleFormat.format_number(2080.0, "cs", 1) == "2 080,0"
    end

    test "omits the decimal separator entirely for zero decimals" do
      assert LocaleFormat.format_number(1234.5, "cs", 0) == "1 235"
      assert LocaleFormat.format_number(999.4, "en", 0) == "999"
    end

    test "accepts integers as well as floats" do
      assert LocaleFormat.format_number(1500, "cs", 0) == "1 500"
    end
  end

  describe "locale parameter edge cases" do
    test "handles nil locale gracefully" do
      date = ~D[2026-03-15]
      time = ~T[14:30:00]

      # Should fall back to English
      assert LocaleFormat.format_date(date, nil) == "March 15, 2026"
      assert LocaleFormat.format_time(time, nil) == "02:30 PM"
    end

    test "handles empty string locale" do
      date = ~D[2026-03-15]
      assert LocaleFormat.format_date(date, "") == "March 15, 2026"
    end

    test "handles unusual but valid dates" do
      # Leap year
      leap_date = ~D[2024-02-29]
      assert LocaleFormat.format_date(leap_date, "en") == "February 29, 2024"

      # New Year
      new_year = ~D[2026-01-01]
      assert LocaleFormat.format_date(new_year, "en") == "January 01, 2026"

      # New Year's Eve
      nye = ~D[2026-12-31]
      assert LocaleFormat.format_date(nye, "en") == "December 31, 2026"
    end
  end
end
