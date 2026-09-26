defmodule Tymeslot.Integrations.Calendar.SelectionFiltersTest do
  use ExUnit.Case, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Selection

  # =====================================
  # selected_calendars/1
  # =====================================

  describe "selected_calendars/1" do
    test "returns entries with selected: true" do
      list =
        Enum.map(
          [
            %{id: "a", selected: true},
            %{id: "b", selected: false},
            %{id: "c", selected: true}
          ],
          &CalendarEntry.normalize/1
        )

      assert [%CalendarEntry{id: "a", selected: true}, %CalendarEntry{id: "c", selected: true}] =
               Selection.selected_calendars(list)
    end

    test "includes read-only entries, unlike writable_calendars/1" do
      list =
        Enum.map(
          [%{id: "a", selected: true, read_only: true}],
          &CalendarEntry.normalize/1
        )

      assert [%CalendarEntry{id: "a", read_only: true}] = Selection.selected_calendars(list)
    end

    test "returns [] for nil" do
      assert Selection.selected_calendars(nil) == []
    end

    test "returns [] when no entry is selected" do
      list = Enum.map([%{id: "a", selected: false}], &CalendarEntry.normalize/1)
      assert Selection.selected_calendars(list) == []
    end
  end

  # =====================================
  # writable_calendars/1
  # =====================================

  describe "writable_calendars/1" do
    test "excludes selected entries that are read-only" do
      list =
        Enum.map(
          [
            %{id: "a", selected: true, read_only: false},
            %{id: "b", selected: true, read_only: true}
          ],
          &CalendarEntry.normalize/1
        )

      assert [%CalendarEntry{id: "a"}] = Selection.writable_calendars(list)
    end

    test "returns [] for nil" do
      assert Selection.writable_calendars(nil) == []
    end
  end

  # =====================================
  # writable_integrations/1
  # =====================================

  describe "writable_integrations/1" do
    test "drops a connection whose calendars are all read-only" do
      # What a subscribed ICS feed looks like: one synthetic entry, read-only.
      feed = %{
        id: 1,
        provider: "ics_url",
        calendar_list: entries([%{id: "ics", selected: true, read_only: true}])
      }

      account = %{
        id: 2,
        provider: "caldav",
        calendar_list: entries([%{id: "main", selected: true, read_only: false}])
      }

      assert [%{id: 2}] = Selection.writable_integrations([feed, account])
    end

    test "keeps a connection whose calendars have not been discovered yet" do
      # An empty list means "not discovered", not "nothing writable": the
      # provider's own default is written to instead.
      assert [%{id: 1}, %{id: 2}] =
               Selection.writable_integrations([
                 %{id: 1, provider: "caldav", calendar_list: nil},
                 %{id: 2, provider: "caldav", calendar_list: []}
               ])
    end

    test "keeps a connection with one writable calendar among read-only ones" do
      mixed =
        entries([
          %{id: "shared", selected: true, read_only: true},
          %{id: "mine", selected: true, read_only: false}
        ])

      assert [%{id: 1}] =
               Selection.writable_integrations([
                 %{id: 1, provider: "caldav", calendar_list: mixed}
               ])
    end

    test "drops a connection whose only writable calendar is deselected" do
      # A calendar the host has switched off is not a place to put an event.
      list = entries([%{id: "off", selected: false, read_only: false}])

      assert Selection.writable_integrations([%{id: 1, provider: "caldav", calendar_list: list}]) ==
               []
    end

    test "drops a read-only provider even when its calendars were never listed" do
      # A subscription is read-only by provider, not only by its synthetic
      # entry, so a missing list must not make it look undiscovered.
      assert Selection.writable_integrations([
               %{id: 1, provider: "ics_url", calendar_list: nil},
               %{id: 2, provider: "caldav", calendar_list: nil}
             ]) == [%{id: 2, provider: "caldav", calendar_list: nil}]
    end
  end

  defp entries(maps), do: Enum.map(maps, &CalendarEntry.normalize/1)

  # =====================================
  # find_calendar_by_path/2
  # =====================================

  describe "find_calendar_by_path/2" do
    test "matches on path when present" do
      list = Enum.map([%{id: "a", path: "/cal/a/"}], &CalendarEntry.normalize/1)

      assert %CalendarEntry{id: "a"} =
               Selection.find_calendar_by_path(list, "/cal/a/event123.ics")
    end

    test "falls back to id when path is nil (legacy CalDAV rows)" do
      list = Enum.map([%{id: "/cal/a/", path: nil}], &CalendarEntry.normalize/1)

      assert %CalendarEntry{id: "/cal/a/"} =
               Selection.find_calendar_by_path(list, "/cal/a/event123.ics")
    end

    test "returns nil when nothing matches" do
      list = Enum.map([%{id: "a", path: "/cal/a/"}], &CalendarEntry.normalize/1)

      assert Selection.find_calendar_by_path(list, "/cal/b/event123.ics") == nil
    end
  end
end
