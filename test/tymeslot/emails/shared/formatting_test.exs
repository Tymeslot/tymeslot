defmodule Tymeslot.Emails.Shared.FormattingTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting

  describe "format_date/1" do
    test "formats Date struct correctly" do
      date = ~D[2024-11-25]
      assert Formatting.format_date(date) == "November 25, 2024"
    end

    test "formats DateTime struct correctly" do
      datetime = ~U[2024-11-25 14:30:00Z]
      assert Formatting.format_date(datetime) == "November 25, 2024"
    end

    test "formats NaiveDateTime struct correctly" do
      naive_datetime = ~N[2024-11-25 14:30:00]
      assert Formatting.format_date(naive_datetime) == "November 25, 2024"
    end

    test "handles different months correctly" do
      dates = [
        {~D[2024-01-15], "January 15, 2024"},
        {~D[2024-02-29], "February 29, 2024"},
        {~D[2024-12-31], "December 31, 2024"}
      ]

      for {date, expected} <- dates do
        assert Formatting.format_date(date) == expected
      end
    end
  end

  describe "format_date_short/1" do
    test "formats Date struct in short format" do
      date = ~D[2024-11-25]
      assert Formatting.format_date_short(date) == "Nov 25"
    end

    test "formats DateTime struct in short format" do
      datetime = ~U[2024-11-25 14:30:00Z]
      assert Formatting.format_date_short(datetime) == "Nov 25"
    end

    test "formats NaiveDateTime struct in short format" do
      naive_datetime = ~N[2024-11-25 14:30:00]
      assert Formatting.format_date_short(naive_datetime) == "Nov 25"
    end

    test "handles different months correctly" do
      dates = [
        {~D[2024-01-15], "Jan 15"},
        {~D[2024-02-01], "Feb 1"},
        {~D[2024-12-31], "Dec 31"}
      ]

      for {date, expected} <- dates do
        assert Formatting.format_date_short(date) == expected
      end
    end
  end

  describe "format_time/1" do
    test "formats time with timezone" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = Formatting.format_time(datetime)

      assert result =~ "02:30 PM"
      # 25 November is after the first Sunday of November, so New York is on EST.
      assert result =~ "EST"
    end

    test "formats time with UTC timezone" do
      datetime = ~U[2024-11-25 14:30:00Z]
      result = Formatting.format_time(datetime)

      assert result =~ "02:30 PM"
      assert result =~ "UTC"
    end

    test "handles AM times correctly" do
      datetime = ~U[2024-11-25 09:15:00Z]
      result = Formatting.format_time(datetime)

      assert result =~ "09:15 AM"
    end
  end

  describe "format_time_range/2" do
    test "formats time range correctly" do
      start_time = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      end_time = DateTime.from_naive!(~N[2024-11-25 15:30:00], "America/New_York")

      result = Formatting.format_time_range(start_time, end_time)

      assert result =~ "02:30 PM - 03:30 PM"
      # 25 November is after the first Sunday of November, so New York is on EST.
      assert result =~ "EST"
    end

    test "formats time range across different hours" do
      start_time = ~U[2024-11-25 09:00:00Z]
      end_time = ~U[2024-11-25 10:30:00Z]

      result = Formatting.format_time_range(start_time, end_time)

      assert result =~ "09:00 AM - 10:30 AM"
    end

    test "shows timezone only on end time" do
      start_time = ~U[2024-11-25 14:30:00Z]
      end_time = ~U[2024-11-25 15:30:00Z]

      result = Formatting.format_time_range(start_time, end_time)

      # Start time should not have timezone
      assert result =~ ~r/\d{2}:\d{2} (AM|PM) - \d{2}:\d{2} (AM|PM)/
    end
  end

  describe "format_datetime/1" do
    test "formats complete datetime" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = Formatting.format_datetime(datetime)

      assert result =~ "November 25, 2024"
      assert result =~ " at "
      assert result =~ "02:30 PM"
    end

    test "combines date and time formatting" do
      datetime = ~U[2024-01-15 09:00:00Z]
      result = Formatting.format_datetime(datetime)

      assert result == "January 15, 2024 at 09:00 AM UTC"
    end
  end

  describe "format_duration/1" do
    test "formats single minute" do
      assert Formatting.format_duration(1) == "1 minute"
    end

    test "formats 30 minutes" do
      assert Formatting.format_duration(30) == "30 minutes"
    end

    test "formats 60 minutes" do
      assert Formatting.format_duration(60) == "1 hour"
    end

    test "formats 90 minutes" do
      assert Formatting.format_duration(90) == "1.5 hours"
    end

    test "formats zero minutes" do
      assert Formatting.format_duration(0) == "0 minutes"
    end
  end

  describe "truncate/2" do
    test "returns full text when shorter than max length" do
      text = "Short text"
      assert Formatting.truncate(text, 20) == "Short text"
    end

    test "returns full text when exactly max length" do
      text = "Exactly twenty chars"
      assert Formatting.truncate(text, 20) == "Exactly twenty chars"
    end

    test "truncates text longer than max length" do
      text = "This is a very long text that needs truncation"
      result = Formatting.truncate(text, 20)

      assert String.length(result) == 20
      assert String.ends_with?(result, "...")
    end

    test "truncates and adds ellipsis correctly" do
      text = "This is a long text"
      result = Formatting.truncate(text, 10)

      # Should be 10 chars total: 7 chars + "..."
      assert result == "This is..."
      assert String.length(result) == 10
    end

    test "handles empty string" do
      assert Formatting.truncate("", 10) == ""
    end

    test "handles max length of 3 (minimum for ellipsis)" do
      text = "Long text"
      assert Formatting.truncate(text, 3) == "..."
    end
  end

  describe "format_date_short/2" do
    test "English locale uses abbreviated month name" do
      assert Formatting.format_date_short(~D[2024-11-25], "en") == "Nov 25"
      assert Formatting.format_date_short(~D[2024-01-05], "en") == "Jan 5"
      assert Formatting.format_date_short(~D[2024-12-31], "en") == "Dec 31"
    end

    test "de/uk locales use dot-separated day.month. format" do
      for locale <- ["de", "uk"] do
        assert Formatting.format_date_short(~D[2024-11-25], locale) == "25.11.",
               "Expected 25.11. for locale #{locale}"

        assert Formatting.format_date_short(~D[2024-01-05], locale) == "5.1.",
               "Expected 5.1. for locale #{locale}"
      end
    end

    test "French locale uses slash-separated day/month format" do
      assert Formatting.format_date_short(~D[2024-11-25], "fr") == "25/11"
      assert Formatting.format_date_short(~D[2024-01-05], "fr") == "5/1"
    end

    test "Italian locale uses slash-separated day/month format" do
      assert Formatting.format_date_short(~D[2024-11-25], "it") == "25/11"
      assert Formatting.format_date_short(~D[2024-01-05], "it") == "5/1"
    end

    test "works with DateTime input" do
      assert Formatting.format_date_short(~U[2024-11-25 14:30:00Z], "en") == "Nov 25"
      assert Formatting.format_date_short(~U[2024-11-25 14:30:00Z], "de") == "25.11."
    end

    test "works with NaiveDateTime input" do
      assert Formatting.format_date_short(~N[2024-11-25 14:30:00], "fr") == "25/11"
    end
  end

  describe "format_time/2" do
    test "formats time in 12-hour format for English" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = Formatting.format_time(datetime, "en")
      assert result =~ "02:30 PM"
    end

    test "formats time in 24-hour format for German" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = Formatting.format_time(datetime, "de")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "formats time in 24-hour format for French" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = Formatting.format_time(datetime, "fr")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "formats time in 24-hour format for Ukrainian" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = Formatting.format_time(datetime, "uk")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "includes timezone abbreviation" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = Formatting.format_time(datetime, "en")
      assert result =~ "UTC"
    end
  end

  describe "format_duration/2" do
    test "formats durations in English" do
      assert Formatting.format_duration(1, "en") == "1 minute"
      assert Formatting.format_duration(30, "en") == "30 minutes"
      assert Formatting.format_duration(60, "en") == "1 hour"
      assert Formatting.format_duration(90, "en") == "1.5 hours"
      assert Formatting.format_duration(120, "en") == "2 hours"
    end

    test "formats durations in German" do
      assert Formatting.format_duration(1, "de") == "1 Minute"
      assert Formatting.format_duration(30, "de") == "30 Minuten"
      assert Formatting.format_duration(60, "de") == "1 Stunde"
      assert Formatting.format_duration(120, "de") == "2 Stunden"
    end

    test "formats durations in French" do
      assert Formatting.format_duration(1, "fr") == "1 minute"
      assert Formatting.format_duration(30, "fr") == "30 minutes"
      assert Formatting.format_duration(60, "fr") == "1 heure"
      assert Formatting.format_duration(120, "fr") == "2 heures"
    end

    test "formats durations in Ukrainian" do
      assert Formatting.format_duration(1, "uk") == "1 хвилина"
      assert Formatting.format_duration(30, "uk") == "30 хвилин"
      assert Formatting.format_duration(60, "uk") == "1 година"
      assert Formatting.format_duration(120, "uk") == "2 години"
    end

    test "parses simple numeric strings" do
      assert Formatting.format_duration("30", "en") == "30 minutes"
      assert Formatting.format_duration("30 minutes", "en") == "30 minutes"
    end

    test "returns the raw string for unparseable input instead of '0 minutes'" do
      assert Formatting.format_duration("1h30", "en") == "1h30"
      assert Formatting.format_duration("garbage", "en") == "garbage"
      refute Formatting.format_duration("garbage", "en") =~ "minute"
    end

    test "returns empty string for nil or non-string, non-integer input" do
      assert Formatting.format_duration(nil, "en") == ""
      assert Formatting.format_duration(-15, "en") == ""
    end
  end

  describe "format_date/2" do
    test "formats Date in German locale" do
      assert Formatting.format_date(~D[2024-11-25], "de") == "25. November 2024"
      assert Formatting.format_date(~D[2024-01-15], "de") == "15. Januar 2024"
    end

    test "formats Date in French locale" do
      assert Formatting.format_date(~D[2024-11-25], "fr") == "25 novembre 2024"
      assert Formatting.format_date(~D[2024-01-15], "fr") == "15 janvier 2024"
    end

    test "formats Date in English locale" do
      assert Formatting.format_date(~D[2024-11-25], "en") == "November 25, 2024"
    end

    test "formats DateTime in German locale" do
      assert Formatting.format_date(~U[2024-11-25 14:30:00Z], "de") == "25. November 2024"
    end

    test "formats NaiveDateTime in German locale" do
      assert Formatting.format_date(~N[2024-11-25 14:30:00], "de") == "25. November 2024"
    end
  end

  describe "format_weekday/2" do
    test "returns uppercased English weekday for English locale" do
      # 2025-01-06 is a Monday
      assert Formatting.format_weekday(~D[2025-01-06], "en") == "MONDAY"
      # 2025-01-08 is a Wednesday
      assert Formatting.format_weekday(~D[2025-01-08], "en") == "WEDNESDAY"
      # 2025-01-11 is a Saturday
      assert Formatting.format_weekday(~D[2025-01-11], "en") == "SATURDAY"
    end

    test "returns uppercased weekday for non-English locale" do
      assert Formatting.format_weekday(~D[2025-01-06], "de") == "MONTAG"
    end

    test "works with DateTime input" do
      assert Formatting.format_weekday(~U[2025-01-06 09:00:00Z], "en") == "MONDAY"
    end

    test "works with NaiveDateTime input" do
      assert Formatting.format_weekday(~N[2025-01-06 09:00:00], "en") == "MONDAY"
    end
  end

  describe "format_location/1" do
    test "returns video label for location_type :video" do
      assert Formatting.format_location(%{location_type: :video}) == "Video Call"
    end

    test "returns phone label for location_type :phone" do
      assert Formatting.format_location(%{location_type: :phone}) == "Phone Call"
    end

    test "returns the raw location string for other location types" do
      assert Formatting.format_location(%{location: "Room 42"}) == "Room 42"

      assert Formatting.format_location(%{location_type: :in_person, location: "Office"}) ==
               "Office"
    end

    test "returns TBD when location is nil" do
      assert Formatting.format_location(%{}) == "TBD"
      assert Formatting.format_location(%{location: nil}) == "TBD"
    end
  end

  describe "format_currency/2" do
    test "formats standard currencies in cents" do
      assert Formatting.format_currency(1000, "eur") == "€10.00"
      assert Formatting.format_currency(1250, "usd") == "$12.50"
      assert Formatting.format_currency(999, "gbp") == "£9.99"
    end

    test "formats zero-decimal currencies without division" do
      assert Formatting.format_currency(1500, "jpy") == "¥1500"
      assert Formatting.format_currency(1000, "krw") == "₩1000"
    end

    test "defaults to EUR when currency is nil" do
      assert Formatting.format_currency(500, nil) == "€5.00"
    end

    test "handles zero amounts" do
      assert Formatting.format_currency(0, "usd") == "$0.00"
      assert Formatting.format_currency(0, "jpy") == "¥0"
    end

    test "handles negative amounts (refunds)" do
      assert Formatting.format_currency(-1000, "eur") == "€-10.00"
      assert Formatting.format_currency(-500, "jpy") == "¥-500"
    end

    test "falls back to upper-cased ISO code for unknown currencies" do
      assert Formatting.format_currency(1234, "xyz") == "XYZ 12.34"
    end

    test "0 cents formats as zero with two decimal places" do
      assert Formatting.format_currency(0, "eur") == "€0.00"
    end

    test "1 cent formats correctly without truncating the leading zero in minor units" do
      assert Formatting.format_currency(1, "eur") == "€0.01"
    end

    test "99 cents formats correctly" do
      assert Formatting.format_currency(99, "eur") == "€0.99"
    end

    test "100 cents formats as 1.00" do
      assert Formatting.format_currency(100, "eur") == "€1.00"
    end

    test "9_999_999 cents formats without floating-point rounding errors" do
      assert Formatting.format_currency(9_999_999, "eur") == "€99999.99"
    end

    test "-50 cents (partial refund display) formats with leading sign" do
      assert Formatting.format_currency(-50, "eur") == "€-0.50"
    end
  end
end
