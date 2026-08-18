defmodule TymeslotWeb.Themes.Shared.LocalizationHelpersTest do
  @moduledoc """
  Covers `format_meeting_datetime/2`, which renders a meeting's start time on
  the payment return pages in the attendee's own timezone rather than raw UTC,
  and its compact sibling used by lists that repeat the date on every row.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  setup do
    on_exit(fn -> Gettext.put_locale(TymeslotWeb.Gettext, "en") end)
    :ok
  end

  describe "format_meeting_datetime/2" do
    test "shifts a UTC datetime into the attendee's timezone" do
      # 14:00 UTC in June is 10:00 in New York (EDT, UTC-4).
      result =
        LocalizationHelpers.format_meeting_datetime(
          ~U[2026-06-15 14:00:00Z],
          "America/New_York"
        )

      assert result =~ "10:00"
      refute result =~ "14:00"
      assert result =~ "15"
      assert result =~ "June"
      assert result =~ "2026"
    end

    test "accepts a naive datetime as UTC and shifts it" do
      result =
        LocalizationHelpers.format_meeting_datetime(
          ~N[2026-06-15 14:00:00],
          "America/New_York"
        )

      assert result =~ "10:00"
      refute result =~ "14:00"
    end

    test "falls back to UTC when the timezone is missing" do
      # This page is attendee-facing, so the clock follows the visitor's own
      # language: 14:00 UTC reads as 2:00 PM in English, 14:00 in German.
      Gettext.put_locale(TymeslotWeb.Gettext, "en")

      assert LocalizationHelpers.format_meeting_datetime(~U[2026-06-15 14:00:00Z], nil) =~
               "2:00 PM"

      Gettext.put_locale(TymeslotWeb.Gettext, "de")
      assert LocalizationHelpers.format_meeting_datetime(~U[2026-06-15 14:00:00Z], nil) =~ "14:00"
    end

    test "falls back to UTC when the timezone is unknown" do
      Gettext.put_locale(TymeslotWeb.Gettext, "en")

      assert LocalizationHelpers.format_meeting_datetime(~U[2026-06-15 14:00:00Z], "Not/AZone") =~
               "2:00 PM"
    end

    test "returns an empty string for an unusable value" do
      assert LocalizationHelpers.format_meeting_datetime(nil, "America/New_York") == ""
    end
  end

  describe "format_meeting_datetime_compact/2" do
    test "shifts into the attendee's timezone and names the weekday" do
      # 14:00 UTC in June is 10:00 in New York (EDT, UTC-4); 2026-06-15 is a Monday.
      result =
        LocalizationHelpers.format_meeting_datetime_compact(
          ~U[2026-06-15 14:00:00Z],
          "America/New_York"
        )

      assert result == "Monday 15 June, 10:00 AM"
    end

    test "drops the year and the timezone the long form carries" do
      long =
        LocalizationHelpers.format_meeting_datetime(
          ~U[2026-06-15 14:00:00Z],
          "America/New_York"
        )

      compact =
        LocalizationHelpers.format_meeting_datetime_compact(
          ~U[2026-06-15 14:00:00Z],
          "America/New_York"
        )

      # The caller states the zone once for the whole list, so carrying it per
      # row is exactly the width this format exists to save.
      assert long =~ "2026"
      assert long =~ "EDT"
      refute compact =~ "2026"
      refute compact =~ "EDT"
    end

    test "accepts a naive datetime as UTC and shifts it" do
      assert LocalizationHelpers.format_meeting_datetime_compact(
               ~N[2026-06-15 14:00:00],
               "America/New_York"
             ) == "Monday 15 June, 10:00 AM"
    end

    test "falls back to UTC when the timezone is missing or unknown" do
      # 14:00 UTC stays 14:00, rendered on the English 12-hour clock.
      assert LocalizationHelpers.format_meeting_datetime_compact(~U[2026-06-15 14:00:00Z], nil) ==
               "Monday 15 June, 02:00 PM"

      assert LocalizationHelpers.format_meeting_datetime_compact(
               ~U[2026-06-15 14:00:00Z],
               "Not/AZone"
             ) == "Monday 15 June, 02:00 PM"
    end

    test "follows the visitor's locale for weekday, month and clock" do
      Gettext.put_locale(TymeslotWeb.Gettext, "de")

      assert LocalizationHelpers.format_meeting_datetime_compact(
               ~U[2026-06-15 14:00:00Z],
               "America/New_York"
             ) == "Montag, 15. Juni, 10:00"
    end

    test "returns an empty string for an unusable value" do
      assert LocalizationHelpers.format_meeting_datetime_compact(nil, "America/New_York") == ""
    end
  end

  describe "format_full_date_label/1" do
    test "builds a weekday + date label from an ISO date string" do
      # 2026-06-15 is a Monday.
      assert LocalizationHelpers.format_full_date_label("2026-06-15") ==
               "Monday, June 15, 2026"
    end

    test "accepts a Date struct" do
      assert LocalizationHelpers.format_full_date_label(~D[2026-06-15]) ==
               "Monday, June 15, 2026"
    end

    test "returns an empty string for nil" do
      assert LocalizationHelpers.format_full_date_label(nil) == ""
    end

    test "falls back to the raw input when the string is not a valid date" do
      assert LocalizationHelpers.format_full_date_label("not-a-date") == "not-a-date"
    end
  end
end
