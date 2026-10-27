defmodule Tymeslot.Integrations.Calendar.SelectionFiltersTest do
  use ExUnit.Case, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.AvailabilityView
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
  # blocking
  # =====================================

  describe "blocking_calendars/1" do
    test "keeps selected calendars that block, read-only ones included" do
      list =
        entries([
          %{id: "work", selected: true},
          %{id: "shared", selected: true, read_only: true},
          %{id: "holidays", selected: true, blocks_availability: false},
          %{id: "old", selected: false, blocks_availability: true}
        ])

      assert Enum.map(Selection.blocking_calendars(list), & &1.id) == ["work", "shared"]
    end

    test "returns [] for nil" do
      assert Selection.blocking_calendars(nil) == []
    end
  end

  describe "AvailabilityView.of/1" do
    test "narrows the list and the paths to the blocking calendars" do
      integration = %{
        id: 1,
        calendar_paths: ["/cal/work/", "/cal/holidays/"],
        calendar_list:
          entries([
            %{id: "/cal/work/", path: "/cal/work/", selected: true},
            %{
              id: "/cal/holidays/",
              path: "/cal/holidays/",
              selected: true,
              blocks_availability: false
            }
          ])
      }

      view = AvailabilityView.of(integration)

      assert Enum.map(view.calendar_list, & &1.id) == ["/cal/work/"]
      assert view.calendar_paths == ["/cal/work/"]
    end

    test "drops an integration whose selected calendars all show only" do
      # Passed on with an empty list, Google and Outlook would read the
      # account's primary calendar instead.
      integration = %{
        id: 1,
        calendar_list: entries([%{id: "work", selected: true, blocks_availability: false}])
      }

      assert AvailabilityView.of(integration) == nil
    end

    test "leaves an integration with nothing selected unchanged, as it was read before" do
      # Google and Outlook read the account's primary calendar then.
      integration = %{
        id: 1,
        calendar_list: entries([%{id: "work", selected: false, blocks_availability: false}])
      }

      assert AvailabilityView.of(integration) == integration
    end

    test "leaves an integration that predates calendar selection unchanged" do
      for list <- [nil, []] do
        integration = %{id: 1, calendar_list: list, calendar_paths: ["/cal/a/"]}
        assert AvailabilityView.of(integration) == integration
      end
    end
  end

  describe "AvailabilityView for an Exchange mailbox" do
    test "reads it whole unless its main calendar is set not to block" do
      mailbox = fn main ->
        %{
          id: 9,
          provider: "exchange",
          calendar_list:
            entries([
              Map.merge(%{id: "main", primary: true}, main),
              %{id: "team", selected: true, blocks_availability: false}
            ])
        }
      end

      for main <- [%{selected: false}, %{selected: false, blocks_availability: true}] do
        integration = mailbox.(main)
        assert AvailabilityView.of(integration) == integration
        assert AvailabilityView.rules([integration]) == %{9 => :all}
      end

      show_only = mailbox.(%{selected: true, blocks_availability: false})
      assert AvailabilityView.of(show_only) == nil
      assert AvailabilityView.rules([show_only]) == %{9 => :none}
    end

    test "reads a mailbox that names no main calendar whole" do
      integration = %{
        id: 9,
        provider: "exchange",
        calendar_list: entries([%{id: "team", selected: true, blocks_availability: false}])
      }

      assert AvailabilityView.of(integration) == integration
    end
  end

  describe "AvailabilityView.rules/1" do
    test "matches only the blocking calendars, beside the wider visibility rule" do
      integration = %{
        id: 7,
        calendar_list:
          entries([
            %{id: "work", selected: true},
            %{id: "holidays", selected: true, blocks_availability: false}
          ])
      }

      assert AvailabilityView.rules([integration]) ==
               %{7 => {:selected, [%{id: "work", prefix: "work"}]}}

      assert %{7 => {:selected, [_work, _holidays]}} = Selection.visibility_rules([integration])
    end

    test "is :none when nothing blocks and :all without a calendar list" do
      show_only = %{
        id: 1,
        calendar_list: entries([%{id: "a", selected: true, blocks_availability: false}])
      }

      nothing_selected = %{id: 3, calendar_list: entries([%{id: "b", selected: false}])}

      assert AvailabilityView.rules([show_only, %{id: 2, calendar_list: nil}, nothing_selected]) ==
               %{1 => :none, 2 => :all, 3 => :all}
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
