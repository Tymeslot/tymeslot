defmodule Tymeslot.Integrations.Calendar.DefaultsTest do
  use ExUnit.Case, async: true
  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Defaults

  defp entry(attrs), do: CalendarEntry.normalize(attrs)

  defp integration(attrs) do
    struct(
      %CalendarIntegrationSchema{provider: "caldav", calendar_list: [], calendar_paths: []},
      attrs
    )
  end

  # =====================================
  # primary_id/1, selected_id/1, first_id_from_list/1
  # =====================================

  describe "primary_id/1" do
    test "returns the id of the entry marked primary" do
      list = Enum.map([%{id: "a"}, %{id: "b", primary: true}], &entry/1)
      assert Defaults.primary_id(list) == "b"
    end

    test "returns nil when no entry is primary" do
      list = Enum.map([%{id: "a"}, %{id: "b"}], &entry/1)
      assert Defaults.primary_id(list) == nil
    end

    test "returns nil for a non-list" do
      assert Defaults.primary_id(nil) == nil
    end
  end

  describe "selected_id/1" do
    test "returns the id of the first selected entry" do
      list = Enum.map([%{id: "a"}, %{id: "b", selected: true}], &entry/1)
      assert Defaults.selected_id(list) == "b"
    end

    test "returns nil when no entry is selected" do
      list = Enum.map([%{id: "a"}], &entry/1)
      assert Defaults.selected_id(list) == nil
    end

    test "returns nil for a non-list" do
      assert Defaults.selected_id(nil) == nil
    end
  end

  describe "first_id_from_list/1" do
    test "returns the id of the first entry regardless of flags" do
      list = Enum.map([%{id: "a"}, %{id: "b", primary: true}], &entry/1)
      assert Defaults.first_id_from_list(list) == "a"
    end

    test "returns nil for an empty list" do
      assert Defaults.first_id_from_list([]) == nil
    end

    test "returns nil for a non-list" do
      assert Defaults.first_id_from_list(nil) == nil
    end
  end

  # =====================================
  # eligible_for_booking/1
  # =====================================

  describe "eligible_for_booking/1" do
    test "excludes read-only entries" do
      list = Enum.map([%{id: "a", read_only: true}, %{id: "b", read_only: false}], &entry/1)

      assert [%CalendarEntry{id: "b"}] = Defaults.eligible_for_booking(list)
    end

    test "keeps writable entries in their original order" do
      list = Enum.map([%{id: "a"}, %{id: "b"}], &entry/1)

      assert [%CalendarEntry{id: "a"}, %CalendarEntry{id: "b"}] =
               Defaults.eligible_for_booking(list)
    end
  end

  # =====================================
  # default_booking_calendar/2 — the read ladder
  # =====================================

  describe "default_booking_calendar/2" do
    test "prefers the entry matching booking_id over primary/selected" do
      list =
        Enum.map(
          [%{id: "a", primary: true}, %{id: "b", selected: true}, %{id: "c"}],
          &entry/1
        )

      assert %CalendarEntry{id: "c"} = Defaults.default_booking_calendar(list, "c")
    end

    test "falls back to primary when booking_id is nil" do
      list = Enum.map([%{id: "a"}, %{id: "b", primary: true}], &entry/1)

      assert %CalendarEntry{id: "b"} = Defaults.default_booking_calendar(list, nil)
    end

    test "falls back to selected when nothing is primary" do
      list = Enum.map([%{id: "a"}, %{id: "b", selected: true}], &entry/1)

      assert %CalendarEntry{id: "b"} = Defaults.default_booking_calendar(list, nil)
    end

    test "falls back to the first entry when nothing matches, is primary, or is selected" do
      list = Enum.map([%{id: "a"}, %{id: "b"}], &entry/1)

      assert %CalendarEntry{id: "a"} = Defaults.default_booking_calendar(list, nil)
    end

    test "a booking_id matching a read-only entry is treated as no match and falls through the ladder" do
      list =
        Enum.map(
          [%{id: "stale", read_only: true}, %{id: "b", selected: true}],
          &entry/1
        )

      assert %CalendarEntry{id: "b"} = Defaults.default_booking_calendar(list, "stale")
    end

    test "read-only entries are never returned even as the last resort" do
      list = Enum.map([%{id: "a", read_only: true}], &entry/1)

      assert Defaults.default_booking_calendar(list, nil) == nil
    end

    test "returns nil for an empty or nil list" do
      assert Defaults.default_booking_calendar([], nil) == nil
      assert Defaults.default_booking_calendar(nil, nil) == nil
    end
  end

  # =====================================
  # confirmed_booking_calendar/1
  # =====================================

  describe "confirmed_booking_calendar/1" do
    test "returns the entry matching default_booking_calendar_id" do
      list = Enum.map([%{id: "a"}, %{id: "b", primary: true}], &entry/1)

      integration = %{calendar_list: list, default_booking_calendar_id: "a"}

      assert %CalendarEntry{id: "a"} = Defaults.confirmed_booking_calendar(integration)
    end

    test "falls back to primary when default_booking_calendar_id is nil" do
      list = Enum.map([%{id: "a"}, %{id: "b", primary: true}], &entry/1)

      integration = %{calendar_list: list, default_booking_calendar_id: nil}

      assert %CalendarEntry{id: "b"} = Defaults.confirmed_booking_calendar(integration)
    end

    test "does not fall back to selected or first — narrower than default_booking_calendar/2" do
      list = Enum.map([%{id: "a"}, %{id: "b", selected: true}], &entry/1)

      integration = %{calendar_list: list, default_booking_calendar_id: nil}

      assert Defaults.confirmed_booking_calendar(integration) == nil
    end

    test "a stale default_booking_calendar_id pointing at a read-only entry falls through to nil" do
      list = Enum.map([%{id: "stale", read_only: true}], &entry/1)

      integration = %{calendar_list: list, default_booking_calendar_id: "stale"}

      assert Defaults.confirmed_booking_calendar(integration) == nil
    end
  end

  # =====================================
  # resolve_default_calendar_id/1
  # =====================================

  describe "resolve_default_calendar_id/1 — calendar_list priority ladder" do
    test "prefers primary over selected and first" do
      list = Enum.map([%{id: "a", selected: true}, %{id: "b", primary: true}], &entry/1)

      integration = integration(provider: "google", calendar_list: list)

      assert Defaults.resolve_default_calendar_id(integration) == "b"
    end

    test "falls back to selected when nothing is primary" do
      list = Enum.map([%{id: "a"}, %{id: "b", selected: true}], &entry/1)

      integration = integration(provider: "google", calendar_list: list)

      assert Defaults.resolve_default_calendar_id(integration) == "b"
    end

    test "falls back to the first eligible entry when nothing is primary or selected" do
      list = Enum.map([%{id: "a"}, %{id: "b"}], &entry/1)

      integration = integration(provider: "google", calendar_list: list)

      assert Defaults.resolve_default_calendar_id(integration) == "a"
    end

    test "excludes read-only entries from every tier of the ladder, same as the read path" do
      list =
        Enum.map(
          [%{id: "a", primary: true, read_only: true}, %{id: "b", selected: true}],
          &entry/1
        )

      integration = integration(provider: "google", calendar_list: list)

      # The read-only "primary" entry must never be persisted as the default:
      # default_booking_calendar/2 would refuse to honour it, so an id this
      # function hands back must be one the read ladder would actually accept.
      assert Defaults.resolve_default_calendar_id(integration) == "b"

      assert %CalendarEntry{id: "b"} = Defaults.default_booking_calendar(list, "b")
    end

    test "an id resolved here is always accepted by default_booking_calendar/2's read ladder" do
      list =
        Enum.map(
          [
            %{id: "a", read_only: true},
            %{id: "b"},
            %{id: "c", selected: true}
          ],
          &entry/1
        )

      integration = integration(provider: "google", calendar_list: list)

      resolved_id = Defaults.resolve_default_calendar_id(integration)
      assert resolved_id == "c"

      assert %CalendarEntry{id: ^resolved_id} =
               Defaults.default_booking_calendar(list, resolved_id)
    end
  end

  describe "resolve_default_calendar_id/1 — provider fallback when calendar_list is empty" do
    test "google falls back to \"primary\"" do
      integration = integration(provider: "google", calendar_list: [])

      assert Defaults.resolve_default_calendar_id(integration) == "primary"
    end

    test "outlook falls back to \"default\"" do
      integration = integration(provider: "outlook", calendar_list: [])

      assert Defaults.resolve_default_calendar_id(integration) == "default"
    end

    test "an unrecognised provider falls back to the first calendar_paths entry" do
      integration =
        integration(provider: "caldav", calendar_list: [], calendar_paths: ["/cal/a", "/cal/b"])

      assert Defaults.resolve_default_calendar_id(integration) == "/cal/a"
    end

    test "returns nil when there is no calendar_list, no provider fallback, and no calendar_paths" do
      integration = integration(provider: "caldav", calendar_list: [], calendar_paths: [])

      assert Defaults.resolve_default_calendar_id(integration) == nil
    end

    test "a calendar_list containing only read-only entries is treated as having no usable entries, so it falls through to the provider default" do
      list = Enum.map([%{id: "a", primary: true, read_only: true}], &entry/1)

      integration = integration(provider: "google", calendar_list: list)

      assert Defaults.resolve_default_calendar_id(integration) == "primary"
    end
  end
end
