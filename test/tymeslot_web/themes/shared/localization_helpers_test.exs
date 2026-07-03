defmodule TymeslotWeb.Themes.Shared.LocalizationHelpersTest do
  @moduledoc """
  Covers `format_meeting_datetime/2`, which renders a meeting's start time on
  the payment return pages in the attendee's own timezone rather than raw UTC.
  """

  use ExUnit.Case, async: true

  @moduletag :utils

  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

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
      result = LocalizationHelpers.format_meeting_datetime(~U[2026-06-15 14:00:00Z], nil)

      assert result =~ "14:00"
    end

    test "falls back to UTC when the timezone is unknown" do
      result =
        LocalizationHelpers.format_meeting_datetime(~U[2026-06-15 14:00:00Z], "Not/AZone")

      assert result =~ "14:00"
    end

    test "returns an empty string for an unusable value" do
      assert LocalizationHelpers.format_meeting_datetime(nil, "America/New_York") == ""
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
