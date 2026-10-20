defmodule Tymeslot.CalendarGrid.ColourTokensTest do
  @moduledoc """
  The CSS colour tokens the client-drawn grid paints with. They must resolve
  exactly as the Tailwind classes of `calendar_colour_classes/2` do: the
  event's own colour, then its calendar's, then its account's, then the
  neutral fallback.
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

  describe "for_calendars/2" do
    defp account(id, calendar_ids, colour \\ nil) do
      %{
        id: id,
        colour: colour,
        calendar_list: Enum.map(calendar_ids, &%{"id" => &1, "selected" => true})
      }
    end

    test "a chosen colour wins; the account's first calendar falls through to the account" do
      appearances = [
        %{calendar_integration_id: 1, provider_calendar_id: "home", colour: "sage"},
        %{calendar_integration_id: 1, provider_calendar_id: "work", colour: nil}
      ]

      assert ColourTokens.for_calendars([account(1, ["work", "home"])], appearances) == %{
               {1, "home"} => "calendar-sage"
             }
    end

    test "further calendars of one account take rotation tokens no account uses" do
      tokens = ColourTokens.for_calendars([account(1, ["work", "family", "gym"])], [])

      assert tokens == %{{1, "family"} => "calendar-2", {1, "gym"} => "calendar-3"}
    end

    test "the spare tokens skip every account's colour and every chosen one" do
      appearances = [%{calendar_integration_id: 2, provider_calendar_id: "a", colour: "sage"}]
      integrations = [account(2, ["a", "b"]), account(1, ["x", "y"], "tomato")]

      tokens = ColourTokens.for_calendars(integrations, appearances)

      # Account 1 is tomato, account 2 takes the rotation's second slot.
      assert tokens == %{
               {1, "y"} => "calendar-1",
               {2, "a"} => "calendar-sage",
               {2, "b"} => "calendar-3"
             }
    end

    test "unselected calendars get nothing" do
      integration = %{
        id: 1,
        colour: nil,
        calendar_list: [
          %{"id" => "work", "selected" => true},
          %{"id" => "old", "selected" => false}
        ]
      }

      assert ColourTokens.for_calendars([integration], []) == %{}
    end
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
