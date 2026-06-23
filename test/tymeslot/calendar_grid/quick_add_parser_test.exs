defmodule Tymeslot.CalendarGrid.QuickAddParserTest do
  @moduledoc """
  Tests for the natural-language quick-add parser.

  The parser turns a single line of free text ("Lunch with Sam tomorrow 1pm for
  90m") into a structured event draft. It must be deterministic, so every test
  passes a fixed `:now` rather than letting the parser read the wall clock — an
  off-by-one in the relative-day or time-of-day maths shows up to users as an
  event scheduled on the wrong day or hour.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.QuickAddParser

  # Monday, 2026-06-22 at 09:00 UTC. Anchoring weekday tests to a known weekday
  # keeps "next Thursday" etc. unambiguous.
  @now ~U[2026-06-22 09:00:00Z]
  @opts [now: @now, timezone: "Etc/UTC"]

  describe "time-of-day" do
    test "\"3pm\" → today at 15:00, default one-hour duration" do
      result = QuickAddParser.parse("Standup 3pm", @opts)

      assert result.title == "Standup"
      assert result.all_day == false
      assert result.start_at == ~U[2026-06-22 15:00:00Z]
      assert result.end_at == ~U[2026-06-22 16:00:00Z]
    end

    test "\"3:30pm\" parses minutes" do
      result = QuickAddParser.parse("Call 3:30pm", @opts)

      assert result.title == "Call"
      assert result.start_at == ~U[2026-06-22 15:30:00Z]
      assert result.end_at == ~U[2026-06-22 16:30:00Z]
    end

    test "\"15:00\" 24-hour clock" do
      result = QuickAddParser.parse("Review 15:00", @opts)

      assert result.title == "Review"
      assert result.start_at == ~U[2026-06-22 15:00:00Z]
      assert result.end_at == ~U[2026-06-22 16:00:00Z]
    end

    test "\"9am\" maps to 09:00, not noon" do
      result = QuickAddParser.parse("Coffee 9am", @opts)

      assert result.start_at == ~U[2026-06-22 09:00:00Z]
    end

    test "12pm is noon and 12am is midnight" do
      noon = QuickAddParser.parse("Lunch 12pm", @opts)
      midnight = QuickAddParser.parse("Reset 12am", @opts)

      assert noon.start_at == ~U[2026-06-22 12:00:00Z]
      assert midnight.start_at == ~U[2026-06-22 00:00:00Z]
    end
  end

  describe "relative day" do
    test "\"tomorrow\" advances the date" do
      result = QuickAddParser.parse("Demo tomorrow 10am", @opts)

      assert result.title == "Demo"
      assert result.start_at == ~U[2026-06-23 10:00:00Z]
    end

    test "\"today\" keeps the current date" do
      result = QuickAddParser.parse("Sync today 2pm", @opts)

      assert result.start_at == ~U[2026-06-22 14:00:00Z]
    end

    test "full weekday name resolves to the next such weekday" do
      # @now is Monday 2026-06-22; the next Thursday is 2026-06-25.
      result = QuickAddParser.parse("1:1 Thursday 11am", @opts)

      assert result.title == "1:1"
      assert result.start_at == ~U[2026-06-25 11:00:00Z]
    end

    test "abbreviated weekday name resolves the same way" do
      result = QuickAddParser.parse("1:1 Thu 11am", @opts)

      assert result.start_at == ~U[2026-06-25 11:00:00Z]
    end

    test "naming today's weekday jumps a full week ahead" do
      # @now is Monday; "Monday" means next Monday, 2026-06-29.
      result = QuickAddParser.parse("Planning Monday 9am", @opts)

      assert result.start_at == ~U[2026-06-29 09:00:00Z]
    end
  end

  describe "duration" do
    test "\"for 30m\" sets a 30-minute span" do
      result = QuickAddParser.parse("Chat 3pm for 30m", @opts)

      assert result.start_at == ~U[2026-06-22 15:00:00Z]
      assert result.end_at == ~U[2026-06-22 15:30:00Z]
    end

    test "\"for 2h\" sets a two-hour span" do
      result = QuickAddParser.parse("Workshop 1pm for 2h", @opts)

      assert result.start_at == ~U[2026-06-22 13:00:00Z]
      assert result.end_at == ~U[2026-06-22 15:00:00Z]
    end

    test "duration without a time is ignored (no time parsed → title only)" do
      result = QuickAddParser.parse("Errand for 30m", @opts)

      assert result.title == "Errand for 30m"
      assert is_nil(result.start_at)
    end
  end

  describe "all day" do
    test "\"all day\" sets all_day with a date, not a datetime" do
      result = QuickAddParser.parse("Conference tomorrow all day", @opts)

      assert result.title == "Conference"
      assert result.all_day == true
      assert result.start_date == ~D[2026-06-23]
      assert result.end_date == ~D[2026-06-23]
      assert is_nil(result.start_at)
    end

    test "\"all day\" without a relative day uses today" do
      result = QuickAddParser.parse("Holiday all day", @opts)

      assert result.all_day == true
      assert result.start_date == ~D[2026-06-22]
    end
  end

  describe "title extraction" do
    test "no parseable tokens → whole text as title, no time" do
      result = QuickAddParser.parse("Some freeform note", @opts)

      assert result.title == "Some freeform note"
      assert result.all_day == false
      assert is_nil(result.start_at)
      assert is_nil(result.start_date)
    end

    test "blank text → empty title, no time" do
      result = QuickAddParser.parse("   ", @opts)

      assert result.title == ""
      assert is_nil(result.start_at)
    end

    test "matched tokens are stripped from the title, surrounding words preserved" do
      result = QuickAddParser.parse("Lunch with Sam tomorrow 1pm for 90m", @opts)

      assert result.title == "Lunch with Sam"
      assert result.start_at == ~U[2026-06-23 13:00:00Z]
      assert result.end_at == ~U[2026-06-23 14:30:00Z]
    end

    test "title surrounding whitespace is collapsed" do
      result = QuickAddParser.parse("Gym   6pm", @opts)

      assert result.title == "Gym"
    end
  end

  describe "timezone handling" do
    test "the time is interpreted in the caller's timezone" do
      opts = [now: @now, timezone: "America/New_York"]
      result = QuickAddParser.parse("Standup 3pm", opts)

      # 15:00 in New York (EDT, UTC-4 in June) is 19:00 UTC.
      assert result.start_at == ~U[2026-06-22 19:00:00Z]
      assert result.end_at == ~U[2026-06-22 20:00:00Z]
    end
  end
end
