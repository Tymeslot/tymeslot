defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.EventPositioningTest do
  use ExUnit.Case, async: true

  @moduletag :unit
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.EventColour
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers.EventPositioning

  describe "top_rem/2" do
    test "positions event using UTC hours when no timezone given" do
      dt = ~U[2026-03-12 06:00:00Z]
      # 6h * 60 / 60 * 4 = 24.0
      assert EventPositioning.top_rem(dt) == 24.0
    end

    test "converts to user timezone before computing position" do
      # 06:00 UTC = 09:00 in Etc/GMT-3 (UTC+3)
      dt = ~U[2026-03-12 06:00:00Z]
      # 9h * 60 / 60 * 4 = 36.0
      assert EventPositioning.top_rem(dt, "Etc/GMT-3") == 36.0
    end

    test "handles negative offset timezones correctly" do
      # 18:00 UTC = 13:00 in America/New_York (UTC-5 in March)
      dt = ~U[2026-03-12 18:00:00Z]
      # America/New_York is UTC-4 in March (DST) → 14:00 local
      # 14h * 60 / 60 * 4 = 56.0
      assert EventPositioning.top_rem(dt, "America/New_York") == 56.0
    end

    test "midnight UTC renders at top of grid" do
      dt = ~U[2026-03-12 00:00:00Z]
      assert EventPositioning.top_rem(dt) == 0.0
    end
  end

  describe "top_rem/2 - DST-aware timezone conversion" do
    test "10:00 UTC positions at 6:00 AM in America/New_York during EDT (UTC-4)" do
      # 2026-03-12 is during EDT (DST started 2026-03-08)
      # 10:00 UTC = 06:00 EDT (UTC-4)
      dt = ~U[2026-03-12 10:00:00Z]
      # 6h * 4rem/h = 24.0
      assert EventPositioning.top_rem(dt, "America/New_York") == 24.0
    end

    test "10:00 UTC positions at 5:00 AM in America/New_York during EST (UTC-5)" do
      # 2026-01-15 is during EST (standard time)
      # 10:00 UTC = 05:00 EST (UTC-5)
      dt = ~U[2026-01-15 10:00:00Z]
      # 5h * 4rem/h = 20.0
      assert EventPositioning.top_rem(dt, "America/New_York") == 20.0
    end

    test "event at 23:30 UTC in UTC+2 wraps to next day 01:30" do
      # 23:30 UTC = 01:30 next day in Etc/GMT-2 (UTC+2)
      dt = ~U[2026-03-12 23:30:00Z]
      # 1h30m = 90 minutes → 90/60 * 4 = 6.0
      assert EventPositioning.top_rem(dt, "Etc/GMT-2") == 6.0
    end
  end

  describe "color_for_event/2" do
    test "uses the per-integration colour when the event has no colour override" do
      assigns = %{integration_colors: %{42 => "bg-calendar-3"}}
      event = %{calendar_integration_id: 42, colour: nil}

      assert EventPositioning.color_for_event(assigns, event) == "bg-calendar-3"
    end

    test "prefers the event's palette colour override over the integration colour" do
      assigns = %{integration_colors: %{42 => "bg-calendar-3"}}
      event = %{calendar_integration_id: 42, colour: "tomato"}

      assert EventPositioning.color_for_event(assigns, event) ==
               EventColour.tailwind_class("tomato")
    end

    test "falls back to a neutral class for an unrecognised stored colour value" do
      # Inbound Google stores a raw colorId (e.g. "11") which is not a palette
      # key — it must resolve gracefully rather than crash.
      assigns = %{integration_colors: %{42 => "bg-calendar-3"}}
      event = %{calendar_integration_id: 42, colour: "11"}

      assert EventPositioning.color_for_event(assigns, event) == "bg-calendar-fallback"
    end

    test "falls back to a neutral class for an integration the map does not cover" do
      # An event whose calendar was hidden or removed since the colours were
      # resolved still has to render.
      assigns = %{integration_colors: %{42 => "bg-calendar-3"}}
      event = %{calendar_integration_id: 99, colour: nil}

      assert EventPositioning.color_for_event(assigns, event) == "bg-calendar-fallback"
    end
  end

  describe "height_rem/2" do
    test "1-hour event returns 4.0rem" do
      start_dt = ~U[2026-03-12 10:00:00Z]
      end_dt = ~U[2026-03-12 11:00:00Z]
      assert EventPositioning.height_rem(start_dt, end_dt) == 4.0
    end

    test "very short event returns minimum floor of 0.5rem" do
      start_dt = ~U[2026-03-12 10:00:00Z]
      end_dt = ~U[2026-03-12 10:00:30Z]
      assert EventPositioning.height_rem(start_dt, end_dt) == 0.5
    end

    test "multi-hour event scales proportionally" do
      start_dt = ~U[2026-03-12 09:00:00Z]
      end_dt = ~U[2026-03-12 12:00:00Z]
      # 3h * 4rem/h = 12.0
      assert EventPositioning.height_rem(start_dt, end_dt) == 12.0
    end
  end
end
