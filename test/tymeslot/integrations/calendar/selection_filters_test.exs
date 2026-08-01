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
