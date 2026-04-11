defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.TimeFormattingTest do
  use Tymeslot.DataCase, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Phoenix.HTML, as: PhoenixHTML
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.TimeFormatting

  # ── format_display_time_range/3 ──────────────────────────────────────

  describe "format_display_time_range/3" do
    test "formats a same-day event using display times" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 09:00:00Z],
        end_at: ~U[2026-04-10 10:00:00Z],
        display_start_at: ~U[2026-04-10 09:00:00Z],
        display_end_at: ~U[2026-04-10 10:00:00Z]
      }

      assert TimeFormatting.format_display_time_range(event, "12h", "Etc/UTC") ==
               "9:00 AM – 10:00 AM"
    end

    test "formats a same-day event in 24h format" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 09:00:00Z],
        end_at: ~U[2026-04-10 10:00:00Z],
        display_start_at: ~U[2026-04-10 09:00:00Z],
        display_end_at: ~U[2026-04-10 10:00:00Z]
      }

      assert TimeFormatting.format_display_time_range(event, "24h", "Etc/UTC") ==
               "09:00 – 10:00"
    end

    test "includes date for multi-day events" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 22:00:00Z],
        end_at: ~U[2026-04-11 02:00:00Z],
        display_start_at: ~U[2026-04-10 22:00:00Z],
        display_end_at: ~U[2026-04-11 02:00:00Z]
      }

      result = TimeFormatting.format_display_time_range(event, "12h", "Etc/UTC")
      assert result =~ "Apr 10"
      assert result =~ "Apr 11"
      assert result =~ "–"
    end

    test "returns 'All day' for all-day events" do
      event = %{
        all_day: true,
        start_at: ~U[2026-04-10 00:00:00Z],
        end_at: ~U[2026-04-11 00:00:00Z]
      }

      assert TimeFormatting.format_display_time_range(event, "12h", "Etc/UTC") == "All day"
    end

    test "converts to the specified timezone" do
      # 23:00 UTC on Apr 10 → 01:00 CEST on Apr 11
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 23:00:00Z],
        end_at: ~U[2026-04-11 01:00:00Z],
        display_start_at: ~U[2026-04-10 23:00:00Z],
        display_end_at: ~U[2026-04-11 01:00:00Z]
      }

      # In Europe/Berlin (CEST, UTC+2), both times land on Apr 11 → same-day
      result = TimeFormatting.format_display_time_range(event, "24h", "Europe/Berlin")
      assert result == "01:00 – 03:00"
    end

    test "falls back to start_at/end_at when display fields are absent" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 14:00:00Z],
        end_at: ~U[2026-04-10 15:00:00Z]
      }

      assert TimeFormatting.format_display_time_range(event, "24h", "Etc/UTC") ==
               "14:00 – 15:00"
    end
  end

  # ── format_time_range_in_tz/3 ───────────────────────────────────────

  describe "format_time_range_in_tz/3" do
    test "converts UTC event to the specified timezone" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 12:00:00Z],
        end_at: ~U[2026-04-10 13:00:00Z]
      }

      # Europe/Berlin is CEST (UTC+2) in April
      result = TimeFormatting.format_time_range_in_tz(event, "Europe/Berlin", "24h")
      assert result == "14:00 – 15:00"
    end

    test "returns 'All day' for all-day events regardless of timezone" do
      event = %{
        all_day: true,
        start_at: ~U[2026-04-10 00:00:00Z],
        end_at: ~U[2026-04-11 00:00:00Z]
      }

      assert TimeFormatting.format_time_range_in_tz(event, "America/New_York", "12h") ==
               "All day"
    end

    test "formats in 12h mode by default" do
      event = %{
        all_day: false,
        start_at: ~U[2026-04-10 14:00:00Z],
        end_at: ~U[2026-04-10 15:30:00Z]
      }

      result = TimeFormatting.format_time_range_in_tz(event, "Etc/UTC")
      assert result == "2:00 PM – 3:30 PM"
    end
  end

  # ── tz_abbr/1 ───────────────────────────────────────────────────────

  describe "tz_abbr/1" do
    test "returns UTC for Etc/UTC" do
      assert TimeFormatting.tz_abbr("Etc/UTC") == "UTC"
    end

    test "returns a known abbreviation for Europe/London" do
      abbr = TimeFormatting.tz_abbr("Europe/London")
      assert abbr in ["GMT", "BST"]
    end

    test "returns the input string for an invalid timezone" do
      assert TimeFormatting.tz_abbr("Not/A/Timezone") == "Not/A/Timezone"
    end
  end

  # ── datetime_to_local_parts/2 ───────────────────────────────────────

  describe "datetime_to_local_parts/2" do
    test "returns ISO date and HH:MM time for a valid datetime" do
      dt = ~U[2026-04-10 14:30:00Z]
      result = TimeFormatting.datetime_to_local_parts(dt, "Etc/UTC")

      assert result == %{date: "2026-04-10", time: "14:30"}
    end

    test "converts to the specified timezone" do
      dt = ~U[2026-04-10 23:30:00Z]
      # Europe/Berlin CEST (UTC+2) → 2026-04-11 01:30
      result = TimeFormatting.datetime_to_local_parts(dt, "Europe/Berlin")

      assert result == %{date: "2026-04-11", time: "01:30"}
    end

    test "returns empty strings for nil datetime" do
      assert TimeFormatting.datetime_to_local_parts(nil, "Etc/UTC") == %{date: "", time: ""}
    end
  end

  # ── url?/1 ──────────────────────────────────────────────────────────

  describe "url?/1" do
    test "returns true for https URLs" do
      assert TimeFormatting.url?("https://example.com")
    end

    test "returns true for http URLs" do
      assert TimeFormatting.url?("http://foo")
    end

    test "returns false for plain text" do
      refute TimeFormatting.url?("not a url")
    end

    test "returns false for ftp URLs" do
      refute TimeFormatting.url?("ftp://files.example.com")
    end
  end

  # ── linkify_text/1 ─────────────────────────────────────────────────

  describe "linkify_text/1" do
    test "wraps a URL in an anchor tag" do
      result = TimeFormatting.linkify_text("Visit https://example.com today")
      html = PhoenixHTML.safe_to_string(result)

      assert html =~ ~s(href="https://example.com")
      assert html =~ ~s(target="_blank")
      assert html =~ "Visit"
      assert html =~ "today"
    end

    test "returns plain text unchanged when no URLs are present" do
      result = TimeFormatting.linkify_text("Just some text")
      html = PhoenixHTML.safe_to_string(result)

      assert html == "Just some text"
    end

    test "handles multiple URLs in the same text" do
      result =
        TimeFormatting.linkify_text("See https://one.com and http://two.com for details")

      html = PhoenixHTML.safe_to_string(result)

      assert html =~ ~s(href="https://one.com")
      assert html =~ ~s(href="http://two.com")
    end

    test "escapes angle brackets to prevent XSS" do
      result = TimeFormatting.linkify_text("<script>alert('xss')</script>")
      html = PhoenixHTML.safe_to_string(result)

      refute html =~ "<script>"
      assert html =~ "&lt;script&gt;"
    end
  end
end
