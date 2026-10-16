defmodule Tymeslot.CalendarGrid.ColourTokensTest do
  @moduledoc """
  The CSS colour tokens the client-drawn grid paints with. They must resolve
  exactly as the old grid's Tailwind classes do: the event's own colour, then
  its calendar's, then its account's, then the neutral fallback.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.ColourTokens

  test "an account's own colour becomes its palette token" do
    assert ColourTokens.for_integrations([%{id: 1, colour: "tomato"}]) == %{
             1 => "calendar-tomato"
           }
  end

  test "accounts without a colour rotate through the numbered tokens in id order" do
    assert ColourTokens.for_integrations([%{id: 9, colour: nil}, %{id: 5, colour: nil}]) ==
             %{5 => "calendar-1", 9 => "calendar-2"}
  end

  test "only calendars with a chosen colour get a token" do
    appearances = [
      %{calendar_integration_id: 1, provider_calendar_id: "work", colour: "sage"},
      %{calendar_integration_id: 1, provider_calendar_id: "home", colour: nil}
    ]

    assert ColourTokens.for_calendars(appearances) == %{{1, "work"} => "calendar-sage"}
  end

  describe "for_event/3" do
    @integrations %{1 => "calendar-2"}
    @calendars %{{1, "work"} => "calendar-sage"}

    test "the event's own colour wins" do
      event = %{calendar_integration_id: 1, provider_calendar_id: "work", colour: "grape"}
      assert ColourTokens.for_event(event, @integrations, @calendars) == "calendar-grape"
    end

    test "then the calendar's" do
      event = %{calendar_integration_id: 1, provider_calendar_id: "work", colour: nil}
      assert ColourTokens.for_event(event, @integrations, @calendars) == "calendar-sage"
    end

    test "then the account's" do
      event = %{calendar_integration_id: 1, provider_calendar_id: "home", colour: nil}
      assert ColourTokens.for_event(event, @integrations, @calendars) == "calendar-2"
    end

    test "an unknown provider colour paints neutral rather than failing" do
      event = %{calendar_integration_id: 1, provider_calendar_id: "home", colour: "#ff00ff"}
      assert ColourTokens.for_event(event, @integrations, @calendars) == "calendar-fallback"
    end

    test "an event from no known account paints neutral" do
      event = %{calendar_integration_id: 99, provider_calendar_id: nil, colour: nil}
      assert ColourTokens.for_event(event, @integrations, @calendars) == "calendar-fallback"
    end

    test "bookings get their own token" do
      assert ColourTokens.for_event(%{kind: :booking}, @integrations, @calendars) == "booking"
    end
  end
end
