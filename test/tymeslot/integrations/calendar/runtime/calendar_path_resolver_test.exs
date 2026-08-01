defmodule Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolverTest do
  @moduledoc """
  Tests `Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver` — the
  pure helper that picks which CalDAV path to write bookings to given an
  integration's stored configuration.
  """

  use ExUnit.Case, async: true

  @moduletag :calendar
  @moduletag :unit

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Runtime.CalendarPathResolver

  describe "resolve/1" do
    test "returns the path of the matching calendar from calendar_list" do
      integration = %{
        default_booking_calendar_id: "cal-2",
        calendar_list: [
          %CalendarEntry{id: "cal-1", path: "/dav/cal-1"},
          %CalendarEntry{id: "cal-2", path: "/dav/cal-2"}
        ],
        calendar_paths: ["/dav/fallback"]
      }

      assert "/dav/cal-2" = CalendarPathResolver.resolve(integration)
    end

    test "supports atom-keyed calendar entries" do
      integration = %{
        default_booking_calendar_id: "cal-1",
        calendar_list: [%{id: "cal-1", path: "/dav/cal-1"}],
        calendar_paths: []
      }

      assert "/dav/cal-1" = CalendarPathResolver.resolve(integration)
    end

    test "returns nil when calendar_list is present but no entry matches the default booking calendar" do
      integration = %{
        default_booking_calendar_id: "cal-missing",
        calendar_list: [%CalendarEntry{id: "cal-1", path: "/dav/cal-1"}],
        calendar_paths: ["/dav/fallback"]
      }

      assert nil == CalendarPathResolver.resolve(integration)
    end

    test "returns the first calendar_paths entry when no default booking calendar is set" do
      integration = %{
        default_booking_calendar_id: nil,
        calendar_list: [%CalendarEntry{id: "cal-1", path: "/dav/cal-1"}],
        calendar_paths: ["/dav/first", "/dav/second"]
      }

      assert "/dav/first" = CalendarPathResolver.resolve(integration)
    end

    test "returns nil when neither default nor calendar_paths are configured" do
      integration = %{
        default_booking_calendar_id: nil,
        calendar_list: nil,
        calendar_paths: nil
      }

      assert nil == CalendarPathResolver.resolve(integration)
    end

    test "returns nil when calendar_paths is empty and no default is set" do
      integration = %{
        default_booking_calendar_id: nil,
        calendar_list: [],
        calendar_paths: []
      }

      assert nil == CalendarPathResolver.resolve(integration)
    end

    test "falls back to id when calendar_list entry has nil path" do
      # CalDAV's XML discovery emits maps with `id` set to the href but no
      # `path` field, so existing rows in the database have `\"path\": null`.
      # The resolver must still produce a usable booking target.
      integration = %{
        default_booking_calendar_id: "/calendars/MK43327/8538e694/",
        calendar_list: [
          %CalendarEntry{
            id: "/calendars/MK43327/8538e694/",
            path: nil,
            name: "Mark AhaSend",
            selected: true
          }
        ],
        calendar_paths: []
      }

      assert "/calendars/MK43327/8538e694/" =
               CalendarPathResolver.resolve(integration)
    end
  end
end
