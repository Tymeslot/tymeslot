defmodule Tymeslot.CalendarGrid.CalendarDirectoryTest do
  @moduledoc """
  The calendars the new rail lists, grouped by account, with the colour,
  read-only and hidden state each row needs, and the count the filter chip
  shows when the rail is collapsed.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.CalendarGrid.CalendarDirectory

  @google %{
    id: 1,
    name: "Work account",
    provider: "google",
    calendar_list: [
      %{"id" => "work", "name" => "Work", "selected" => true},
      %{"id" => "old", "name" => "Old", "selected" => false},
      %{"id" => "shared", "name" => "Shared", "selected" => true, "read_only" => true}
    ]
  }

  @feed %{
    id: 2,
    name: "Holidays",
    provider: "ics_url",
    calendar_list: [%{"id" => "feed", "name" => "Public holidays", "selected" => true}]
  }

  defp accounts(hidden_ids \\ [], hidden_keys \\ MapSet.new()) do
    CalendarDirectory.accounts(
      [@google, @feed],
      %{1 => "calendar-2", 2 => "calendar-5"},
      %{{1, "work"} => "calendar-tomato"},
      hidden_ids,
      hidden_keys
    )
  end

  test "lists each account with only the calendars it syncs" do
    [google, _feed] = accounts()

    assert google.name == "Work account"
    assert Enum.map(google.calendars, & &1.id) == ["work", "shared"]
  end

  test "a calendar's chosen colour wins over its account's" do
    [google, _feed] = accounts()

    assert Enum.map(google.calendars, & &1.colour) == ["calendar-tomato", "calendar-2"]
    assert google.colour == "calendar-2"
  end

  test "marks read-only calendars, and accounts whose provider takes no writes" do
    [google, feed] = accounts()

    assert Enum.map(google.calendars, & &1.read_only) == [false, true]
    refute google.read_only
    assert feed.read_only
    assert Enum.all?(feed.calendars, & &1.read_only)
  end

  test "carries the hidden state of accounts and calendars" do
    [google, feed] = accounts([2], MapSet.new([{1, "shared"}]))

    assert Enum.map(google.calendars, & &1.hidden) == [false, true]
    refute google.hidden
    assert feed.hidden
  end

  test "hidden_count/1 counts a hidden account's calendars and single hidden calendars" do
    assert CalendarDirectory.hidden_count(accounts()) == 0
    assert CalendarDirectory.hidden_count(accounts([2], MapSet.new([{1, "shared"}]))) == 2
    assert CalendarDirectory.hidden_count(accounts([1], MapSet.new([{1, "shared"}]))) == 2
  end

  test "an account with no calendar list counts as one calendar when hidden" do
    bare = %{id: 3, name: "Bare", provider: "caldav", calendar_list: []}
    accounts = CalendarDirectory.accounts([bare], %{}, %{}, [3], MapSet.new())

    assert [%{calendars: [], colour: "calendar-fallback"}] = accounts
    assert CalendarDirectory.hidden_count(accounts) == 1
  end
end
