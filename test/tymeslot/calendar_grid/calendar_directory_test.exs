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

  describe "calendar keys" do
    test "a key names the account and the calendar, and reads back" do
      key = CalendarDirectory.key(1, "work")

      assert key == "1:work"
      assert CalendarDirectory.parse_key(key) == {:ok, 1, "work"}
    end

    test "a calendar id may itself hold a colon" do
      assert CalendarDirectory.parse_key("1:team:2026") == {:ok, 1, "team:2026"}
    end

    test "anything else does not read" do
      for key <- ["work", "x:work", "1:", ":work", nil, 1] do
        assert CalendarDirectory.parse_key(key) == :error
      end
    end
  end

  describe "writable_calendars/1" do
    test "keeps an account's synced calendars that take writes" do
      assert [%{id: "work"}] = CalendarDirectory.writable_calendars(@google)
    end

    test "is empty for a provider that takes no writes" do
      assert CalendarDirectory.writable_calendars(@feed) == []
    end
  end

  describe "choices/1" do
    test "lists the calendars a create can target, hidden ones included, in rail order" do
      accounts = accounts([], MapSet.new([{1, "work"}]))

      assert CalendarDirectory.choices(accounts) == [
               %{key: "1:work", name: "Work", account: "Work account", colour: "calendar-tomato"}
             ]
    end
  end

  describe "default_calendar/1" do
    test "is the first account's booking calendar, else its first writable one" do
      assert CalendarDirectory.default_calendar([@feed, @google]) == "1:work"

      with_booking =
        Map.merge(@google, %{
          default_booking_calendar_id: "team",
          calendar_list: @google.calendar_list ++ [%{"id" => "team", "selected" => true}]
        })

      assert CalendarDirectory.default_calendar([with_booking]) == "1:team"
    end

    test "is nil when nothing can be written to" do
      assert CalendarDirectory.default_calendar([@feed]) == nil
    end
  end

  describe "whether a calendar blocks bookings" do
    test "a calendar set to show only does not; one left to block does" do
      google = %{
        @google
        | calendar_list: [
            %{"id" => "work", "name" => "Work", "selected" => true},
            %{
              "id" => "holidays",
              "name" => "Holidays",
              "selected" => true,
              "blocks_availability" => false
            }
          ]
      }

      [account] = CalendarDirectory.accounts([google], %{}, %{}, [], MapSet.new())

      assert Enum.map(account.calendars, &{&1.id, &1.blocks}) ==
               [{"work", true}, {"holidays", false}]
    end

    test "an Exchange mailbox blocks through its main calendar alone" do
      exchange = %{
        id: 3,
        name: "Mailbox",
        provider: "exchange",
        calendar_list: [
          %{"id" => "main", "name" => "Calendar", "selected" => true, "primary" => true},
          %{"id" => "team", "name" => "Team", "selected" => true}
        ]
      }

      [account] = CalendarDirectory.accounts([exchange], %{}, %{}, [], MapSet.new())

      assert Enum.map(account.calendars, &{&1.id, &1.blocks}) == [{"main", true}, {"team", false}]
    end

    test "an Exchange mailbox that lists no main calendar blocks through every folder" do
      exchange = %{
        id: 4,
        name: "Mailbox",
        provider: "exchange",
        calendar_list: [
          %{"id" => "team", "name" => "Team", "selected" => true},
          %{"id" => "rota", "name" => "Rota", "selected" => true}
        ]
      }

      [account] = CalendarDirectory.accounts([exchange], %{}, %{}, [], MapSet.new())

      assert Enum.map(account.calendars, & &1.blocks) == [true, true]
    end
  end
end
