defmodule Tymeslot.Emails.Shared.FormattingTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.Formatting

  describe "format_datetime/2" do
    test "formats complete datetime" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = Formatting.format_datetime(datetime, "en")

      assert result =~ "November 25, 2024"
      assert result =~ " at "
      assert result =~ "02:30 PM"
    end

    test "combines date and time formatting" do
      assert Formatting.format_datetime(~U[2024-01-15 09:00:00Z], "en") ==
               "January 15, 2024 at 09:00 AM UTC"
    end

    # The payment timestamp on a paid booking confirmation used to render through
    # a hardcoded-English helper while the date beside it was localised, so a
    # German reader saw "15. Januar 2024 at 02:30 PM UTC".
    test "localises the date, the clock, and the joining word together" do
      assert Formatting.format_datetime(~U[2024-01-15 14:30:00Z], "de") ==
               "15. Januar 2024 um 14:30 UTC"
    end
  end

  describe "format_time_short/2" do
    test "renders a zero-padded day, short month, 24-hour UTC clock" do
      assert Formatting.format_time_short(~U[2026-03-05 14:30:00Z], "en") ==
               "05 Mar 2026, 14:30 UTC"
    end

    test "localises the month abbreviation" do
      assert Formatting.format_time_short(~U[2026-03-25 14:30:00Z], "de") ==
               "25 März 2026, 14:30 UTC"

      assert Formatting.format_time_short(~U[2026-12-25 14:30:00Z], "de") ==
               "25 Dez 2026, 14:30 UTC"
    end

    test "falls back to to_string/1 for non-DateTime values" do
      assert Formatting.format_time_short(nil, "de") == ""
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

    test "carries a non-UTC zone abbreviation through" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = Formatting.format_time(datetime, "en")

      assert result =~ "02:30 PM"
      assert result =~ "EST" or result =~ "EDT"
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
