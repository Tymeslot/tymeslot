defmodule Tymeslot.CalendarGrid.CalendarColourClassesTest do
  @moduledoc """
  The order a calendar's colour is decided in: the organiser's per-calendar
  choice, then the integration's own colour, then the rotation that keeps
  adjacent integrations apart.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.CalendarAppearanceSchema

  defp appearance(integration_id, calendar_id, colour) do
    %CalendarAppearanceSchema{
      calendar_integration_id: integration_id,
      provider_calendar_id: calendar_id,
      colour: colour,
      hidden: false
    }
  end

  describe "calendar_colour_classes/1" do
    # The expected classes are spelled out rather than read back from
    # `EventColour.tailwind_class/1`, which is the lookup the code under test
    # performs and so can never disagree with it.
    test "resolves a chosen colour to its palette class" do
      classes = CalendarGrid.calendar_colour_classes([appearance(1, "cal-a", "banana")])

      assert classes == %{{1, "cal-a"} => "bg-calendar-banana"}
    end

    test "omits a calendar with no colour of its own, so the caller falls through" do
      classes = CalendarGrid.calendar_colour_classes([appearance(1, "cal-a", nil)])

      assert classes == %{}
    end

    test "omits a blank colour rather than painting it neutral" do
      classes = CalendarGrid.calendar_colour_classes([appearance(1, "cal-a", "")])

      assert classes == %{}
    end

    test "keys two calendars in one integration separately" do
      classes =
        CalendarGrid.calendar_colour_classes([
          appearance(1, "cal-a", "banana"),
          appearance(1, "cal-b", "grape")
        ])

      assert classes[{1, "cal-a"}] == "bg-calendar-banana"
      assert classes[{1, "cal-b"}] == "bg-calendar-grape"
    end

    test "keeps the same calendar id apart across two integrations" do
      # provider_calendar_id is unique only within an integration, so "primary"
      # from two Google accounts must not collide into one entry.
      classes =
        CalendarGrid.calendar_colour_classes([
          appearance(1, "primary", "banana"),
          appearance(2, "primary", "sage")
        ])

      assert classes[{1, "primary"}] == "bg-calendar-banana"
      assert classes[{2, "primary"}] == "bg-calendar-sage"
    end

    test "is empty when the organiser has chosen nothing" do
      assert CalendarGrid.calendar_colour_classes([]) == %{}
    end
  end

  describe "the integration colour it falls back to" do
    test "still resolves for an integration with its own colour" do
      classes = CalendarGrid.integration_colour_classes([%{id: 1, colour: "tomato"}])

      assert classes[1] == "bg-calendar-tomato"
    end

    test "still rotates for an integration with no colour" do
      classes = CalendarGrid.integration_colour_classes([%{id: 1, colour: nil}])

      assert classes[1] == "bg-calendar-1"
    end
  end
end
