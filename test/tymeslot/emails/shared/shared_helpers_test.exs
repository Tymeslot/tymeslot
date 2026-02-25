defmodule Tymeslot.Emails.Shared.SharedHelpersTest do
  use Tymeslot.DataCase, async: true
  @moduletag :emails

  alias Tymeslot.Emails.Shared.SharedHelpers
  alias TymeslotWeb.Endpoint

  describe "format_date/1" do
    test "formats Date struct correctly" do
      date = ~D[2024-11-25]
      assert SharedHelpers.format_date(date) == "November 25, 2024"
    end

    test "formats DateTime struct correctly" do
      datetime = ~U[2024-11-25 14:30:00Z]
      assert SharedHelpers.format_date(datetime) == "November 25, 2024"
    end

    test "formats NaiveDateTime struct correctly" do
      naive_datetime = ~N[2024-11-25 14:30:00]
      assert SharedHelpers.format_date(naive_datetime) == "November 25, 2024"
    end

    test "handles different months correctly" do
      dates = [
        {~D[2024-01-15], "January 15, 2024"},
        {~D[2024-02-29], "February 29, 2024"},
        {~D[2024-12-31], "December 31, 2024"}
      ]

      for {date, expected} <- dates do
        assert SharedHelpers.format_date(date) == expected
      end
    end
  end

  describe "format_date_short/1" do
    test "formats Date struct in short format" do
      date = ~D[2024-11-25]
      assert SharedHelpers.format_date_short(date) == "Nov 25"
    end

    test "formats DateTime struct in short format" do
      datetime = ~U[2024-11-25 14:30:00Z]
      assert SharedHelpers.format_date_short(datetime) == "Nov 25"
    end

    test "formats NaiveDateTime struct in short format" do
      naive_datetime = ~N[2024-11-25 14:30:00]
      assert SharedHelpers.format_date_short(naive_datetime) == "Nov 25"
    end

    test "handles different months correctly" do
      dates = [
        {~D[2024-01-15], "Jan 15"},
        {~D[2024-02-01], "Feb 1"},
        {~D[2024-12-31], "Dec 31"}
      ]

      for {date, expected} <- dates do
        assert SharedHelpers.format_date_short(date) == expected
      end
    end
  end

  describe "format_time/1" do
    test "formats time with timezone" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = SharedHelpers.format_time(datetime)

      assert result =~ "02:30 PM"
      assert result =~ "EST" or result =~ "EDT"
    end

    test "formats time with UTC timezone" do
      datetime = ~U[2024-11-25 14:30:00Z]
      result = SharedHelpers.format_time(datetime)

      assert result =~ "02:30 PM"
      assert result =~ "UTC"
    end

    test "handles AM times correctly" do
      datetime = ~U[2024-11-25 09:15:00Z]
      result = SharedHelpers.format_time(datetime)

      assert result =~ "09:15 AM"
    end
  end

  describe "format_time_range/2" do
    test "formats time range correctly" do
      start_time = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      end_time = DateTime.from_naive!(~N[2024-11-25 15:30:00], "America/New_York")

      result = SharedHelpers.format_time_range(start_time, end_time)

      assert result =~ "02:30 PM - 03:30 PM"
      assert result =~ "EST" or result =~ "EDT"
    end

    test "formats time range across different hours" do
      start_time = ~U[2024-11-25 09:00:00Z]
      end_time = ~U[2024-11-25 10:30:00Z]

      result = SharedHelpers.format_time_range(start_time, end_time)

      assert result =~ "09:00 AM - 10:30 AM"
    end

    test "shows timezone only on end time" do
      start_time = ~U[2024-11-25 14:30:00Z]
      end_time = ~U[2024-11-25 15:30:00Z]

      result = SharedHelpers.format_time_range(start_time, end_time)

      # Start time should not have timezone
      assert result =~ ~r/\d{2}:\d{2} (AM|PM) - \d{2}:\d{2} (AM|PM)/
    end
  end

  describe "format_datetime/1" do
    test "formats complete datetime" do
      datetime = DateTime.from_naive!(~N[2024-11-25 14:30:00], "America/New_York")
      result = SharedHelpers.format_datetime(datetime)

      assert result =~ "November 25, 2024"
      assert result =~ " at "
      assert result =~ "02:30 PM"
    end

    test "combines date and time formatting" do
      datetime = ~U[2024-01-15 09:00:00Z]
      result = SharedHelpers.format_datetime(datetime)

      assert result == "January 15, 2024 at 09:00 AM UTC"
    end
  end

  describe "get_app_url/0" do
    test "returns a valid URL string" do
      url = SharedHelpers.get_app_url()

      assert is_binary(url)
      assert url =~ ~r/^https?:\/\//
    end

    test "returns URL from endpoint configuration" do
      url = SharedHelpers.get_app_url()

      # Should be the same as calling Endpoint.url/0 directly
      assert url == Endpoint.url()
    end
  end

  describe "build_url/1" do
    test "builds URL with root path" do
      url = SharedHelpers.build_url("/")

      assert url =~ ~r/^https?:\/\//
      assert String.ends_with?(url, "/")
    end

    test "builds URL with specific path" do
      url = SharedHelpers.build_url("/meetings/123")

      assert url =~ ~r/^https?:\/\//
      assert String.ends_with?(url, "/meetings/123")
    end

    test "handles paths without leading slash" do
      url = SharedHelpers.build_url("meetings/123")

      assert url =~ ~r/^https?:\/\//
      assert String.ends_with?(url, "meetings/123")
    end

    test "combines app URL and path correctly" do
      app_url = SharedHelpers.get_app_url()
      path = "/test/path"

      url = SharedHelpers.build_url(path)

      assert url == "#{app_url}#{path}"
    end
  end

  describe "format_duration/1" do
    test "formats single minute" do
      assert SharedHelpers.format_duration(1) == "1 minute"
    end

    test "formats 30 minutes" do
      assert SharedHelpers.format_duration(30) == "30 minutes"
    end

    test "formats 60 minutes" do
      assert SharedHelpers.format_duration(60) == "1 hour"
    end

    test "formats 90 minutes" do
      assert SharedHelpers.format_duration(90) == "1.5 hours"
    end

    test "formats zero minutes" do
      assert SharedHelpers.format_duration(0) == "0 minutes"
    end
  end

  describe "calendar_links/1" do
    setup do
      meeting_details = %{
        title: "Team Meeting",
        start_time: ~U[2024-11-25 14:30:00Z],
        end_time: ~U[2024-11-25 15:30:00Z],
        description: "Discuss project updates",
        location: "Conference Room A"
      }

      %{meeting_details: meeting_details}
    end

    test "generates all calendar provider links", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      assert Map.has_key?(links, :google)
      assert Map.has_key?(links, :outlook)
      assert Map.has_key?(links, :yahoo)
    end

    test "generates valid Google Calendar URL", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      assert links.google =~ "https://calendar.google.com/calendar/render"
      assert links.google =~ "action=TEMPLATE"
      assert links.google =~ URI.encode_www_form(details.title)
      assert links.google =~ URI.encode_www_form(details.description)
      assert links.google =~ URI.encode_www_form(details.location)
    end

    test "generates valid Outlook Calendar URL", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      assert links.outlook =~ "https://outlook.live.com/calendar/0/deeplink/compose"
      assert links.outlook =~ "subject="
      assert links.outlook =~ "startdt="
      assert links.outlook =~ "enddt="
    end

    test "generates valid Yahoo Calendar URL", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      assert links.yahoo =~ "https://calendar.yahoo.com"
      assert links.yahoo =~ "v=60"
      assert links.yahoo =~ "title="
      assert links.yahoo =~ "st="
      assert links.yahoo =~ "et="
    end

    test "includes meeting details in URLs", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      for url <- [links.google, links.outlook, links.yahoo] do
        assert is_binary(url)
        assert String.length(url) > 0
      end
    end

    test "formats datetime correctly in URLs", %{meeting_details: details} do
      links = SharedHelpers.calendar_links(details)

      # Calendar URLs use a specific datetime format (YYYYMMDDTHHmmssZ)
      # The format should not contain hyphens or colons
      # The slash is URL encoded as %2F
      assert links.google =~ ~r/dates=\d{8}T\d{6}(%2F|\/)\d{8}T\d{6}/
    end
  end

  describe "truncate/2" do
    test "returns full text when shorter than max length" do
      text = "Short text"
      assert SharedHelpers.truncate(text, 20) == "Short text"
    end

    test "returns full text when exactly max length" do
      text = "Exactly twenty chars"
      assert SharedHelpers.truncate(text, 20) == "Exactly twenty chars"
    end

    test "truncates text longer than max length" do
      text = "This is a very long text that needs truncation"
      result = SharedHelpers.truncate(text, 20)

      assert String.length(result) == 20
      assert String.ends_with?(result, "...")
    end

    test "truncates and adds ellipsis correctly" do
      text = "This is a long text"
      result = SharedHelpers.truncate(text, 10)

      # Should be 10 chars total: 7 chars + "..."
      assert result == "This is..."
      assert String.length(result) == 10
    end

    test "handles empty string" do
      assert SharedHelpers.truncate("", 10) == ""
    end

    test "handles max length of 3 (minimum for ellipsis)" do
      text = "Long text"
      assert SharedHelpers.truncate(text, 3) == "..."
    end
  end

  describe "sanitize_for_email/1" do
    test "returns empty string for nil" do
      assert SharedHelpers.sanitize_for_email(nil) == ""
    end

    test "returns trimmed text for clean input" do
      assert SharedHelpers.sanitize_for_email("Clean text") == "Clean text"
    end

    test "trims whitespace from text" do
      assert SharedHelpers.sanitize_for_email("  Text with spaces  ") == "Text with spaces"
    end

    test "escapes HTML special characters" do
      text = "<script>alert('XSS')</script>"
      result = SharedHelpers.sanitize_for_email(text)

      assert result == "&lt;script&gt;alert(&#39;XSS&#39;)&lt;/script&gt;"
      refute result =~ "<script>"
    end

    test "escapes ampersands" do
      text = "Tom & Jerry"
      result = SharedHelpers.sanitize_for_email(text)

      assert result == "Tom &amp; Jerry"
    end

    test "escapes quotes" do
      text = "He said \"Hello\""
      result = SharedHelpers.sanitize_for_email(text)

      assert result =~ "&quot;" or result =~ "&#34;"
    end

    test "handles combination of trim and escape" do
      text = "  <b>Bold text</b>  "
      result = SharedHelpers.sanitize_for_email(text)

      assert result == "&lt;b&gt;Bold text&lt;/b&gt;"
      refute result =~ "  "
    end

    test "handles already safe text" do
      text = "Regular text without special chars"
      result = SharedHelpers.sanitize_for_email(text)

      assert result == text
    end

    test "handles empty string" do
      assert SharedHelpers.sanitize_for_email("") == ""
    end
  end

  describe "format_date_short/2" do
    test "English locale uses abbreviated month name" do
      assert SharedHelpers.format_date_short(~D[2024-11-25], "en") == "Nov 25"
      assert SharedHelpers.format_date_short(~D[2024-01-05], "en") == "Jan 5"
      assert SharedHelpers.format_date_short(~D[2024-12-31], "en") == "Dec 31"
    end

    test "de/uk locales use dot-separated day.month. format" do
      for locale <- ["de", "uk"] do
        assert SharedHelpers.format_date_short(~D[2024-11-25], locale) == "25.11.",
               "Expected 25.11. for locale #{locale}"

        assert SharedHelpers.format_date_short(~D[2024-01-05], locale) == "5.1.",
               "Expected 5.1. for locale #{locale}"
      end
    end

    test "French locale uses slash-separated day/month format" do
      assert SharedHelpers.format_date_short(~D[2024-11-25], "fr") == "25/11"
      assert SharedHelpers.format_date_short(~D[2024-01-05], "fr") == "5/1"
    end

    test "works with DateTime input" do
      assert SharedHelpers.format_date_short(~U[2024-11-25 14:30:00Z], "en") == "Nov 25"
      assert SharedHelpers.format_date_short(~U[2024-11-25 14:30:00Z], "de") == "25.11."
    end

    test "works with NaiveDateTime input" do
      assert SharedHelpers.format_date_short(~N[2024-11-25 14:30:00], "fr") == "25/11"
    end
  end

  describe "format_time/2" do
    test "formats time in 12-hour format for English" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = SharedHelpers.format_time(datetime, "en")
      assert result =~ "02:30 PM"
    end

    test "formats time in 24-hour format for German" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = SharedHelpers.format_time(datetime, "de")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "formats time in 24-hour format for French" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = SharedHelpers.format_time(datetime, "fr")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "formats time in 24-hour format for Ukrainian" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = SharedHelpers.format_time(datetime, "uk")
      assert result =~ "14:30"
      refute result =~ "PM"
    end

    test "includes timezone abbreviation" do
      datetime = ~U[2026-01-15 14:30:00Z]
      result = SharedHelpers.format_time(datetime, "en")
      assert result =~ "UTC"
    end
  end

  describe "format_duration/2" do
    test "formats durations in English" do
      assert SharedHelpers.format_duration(1, "en") == "1 minute"
      assert SharedHelpers.format_duration(30, "en") == "30 minutes"
      assert SharedHelpers.format_duration(60, "en") == "1 hour"
      assert SharedHelpers.format_duration(90, "en") == "1.5 hours"
      assert SharedHelpers.format_duration(120, "en") == "2 hours"
    end

    test "formats durations in German" do
      assert SharedHelpers.format_duration(1, "de") == "1 Minute"
      assert SharedHelpers.format_duration(30, "de") == "30 Minuten"
      assert SharedHelpers.format_duration(60, "de") == "1 Stunde"
      assert SharedHelpers.format_duration(120, "de") == "2 Stunden"
    end

    test "formats durations in French" do
      assert SharedHelpers.format_duration(1, "fr") == "1 minute"
      assert SharedHelpers.format_duration(30, "fr") == "30 minutes"
      assert SharedHelpers.format_duration(60, "fr") == "1 heure"
      assert SharedHelpers.format_duration(120, "fr") == "2 heures"
    end

    test "formats durations in Ukrainian" do
      assert SharedHelpers.format_duration(1, "uk") == "1 хвилина"
      assert SharedHelpers.format_duration(30, "uk") == "30 хвилин"
      assert SharedHelpers.format_duration(60, "uk") == "1 година"
      assert SharedHelpers.format_duration(120, "uk") == "2 години"
    end
  end
end
