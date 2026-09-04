defmodule Tymeslot.Integrations.Calendar.SelectionEventsTest do
  @moduledoc """
  `Selection`'s two event-facing questions: whether a cached event should be
  shown, and whether it may be written back.

  Split from `SelectionTest`, which covers the selection list itself — what a
  discovery run does to it, what a form submission does to it, what is
  persisted. These two ask the opposite question, of one event against an
  already-settled list, and share the CalDAV-versus-id matching rule that
  `calendar_for_event/2` owns.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :calendar

  alias Tymeslot.Integrations.Calendar.CalendarEntry
  alias Tymeslot.Integrations.Calendar.Selection

  describe "event_visible?/2" do
    test "returns true for legacy integrations with nil calendar_list" do
      event = %{provider_calendar_id: "anything", provider_event_id: "anything"}
      assert Selection.event_visible?(event, %{calendar_list: nil}) == true
    end

    test "returns true for legacy integrations with empty calendar_list" do
      event = %{provider_calendar_id: "anything", provider_event_id: "anything"}
      assert Selection.event_visible?(event, %{calendar_list: []}) == true
    end

    test "returns false when no calendar is selected" do
      event = %{provider_calendar_id: "primary", provider_event_id: "abc"}

      integration = %{
        calendar_list: Enum.map([%{id: "primary", selected: false}], &CalendarEntry.normalize/1)
      }

      assert Selection.event_visible?(event, integration) == false
    end

    test "matches by provider_calendar_id against the selected entries' ids" do
      event = %{provider_calendar_id: "work@example.com", provider_event_id: "evt-1"}

      integration = %{
        calendar_list:
          Enum.map(
            [
              %{id: "work@example.com", selected: true},
              %{id: "personal@example.com", selected: false}
            ],
            &CalendarEntry.normalize/1
          )
      }

      assert Selection.event_visible?(event, integration) == true
    end

    test "excludes events whose provider_calendar_id matches a deselected entry" do
      event = %{provider_calendar_id: "personal@example.com", provider_event_id: "evt-1"}

      integration = %{
        calendar_list:
          Enum.map(
            [
              %{id: "work@example.com", selected: true},
              %{id: "personal@example.com", selected: false}
            ],
            &CalendarEntry.normalize/1
          )
      }

      assert Selection.event_visible?(event, integration) == false
    end

    test "falls back to provider_event_id prefix for CalDAV multi-calendar integrations" do
      event = %{
        provider_calendar_id: "/calendars/user/work/",
        provider_event_id: "/calendars/user/personal/evt-123.ics"
      }

      integration = %{
        calendar_list:
          Enum.map(
            [
              %{
                id: "/calendars/user/work/",
                path: "/calendars/user/work/",
                selected: true
              },
              %{
                id: "/calendars/user/personal/",
                path: "/calendars/user/personal/",
                selected: true
              }
            ],
            &CalendarEntry.normalize/1
          )
      }

      assert Selection.event_visible?(event, integration) == true
    end

    test "excludes CalDAV events whose href is under a deselected path" do
      event = %{
        provider_calendar_id: "/calendars/user/work/",
        provider_event_id: "/calendars/user/personal/evt-123.ics"
      }

      integration = %{
        calendar_list:
          Enum.map(
            [
              %{
                id: "/calendars/user/work/",
                path: "/calendars/user/work/",
                selected: true
              },
              %{
                id: "/calendars/user/personal/",
                path: "/calendars/user/personal/",
                selected: false
              }
            ],
            &CalendarEntry.normalize/1
          )
      }

      assert Selection.event_visible?(event, integration) == false
    end
  end

  describe "event_writable?/2" do
    test "refuses every calendar under a read-only provider" do
      event = %{provider_calendar_id: "feed", provider_event_id: "evt-1"}

      integration = %{
        provider: "ics_url",
        calendar_list: Enum.map([%{id: "feed", selected: true}], &CalendarEntry.normalize/1)
      }

      refute Selection.event_writable?(event, integration)
    end

    test "refuses a read-only calendar on a writable provider" do
      event = %{provider_calendar_id: "shared@example.com", provider_event_id: "evt-1"}

      integration = %{
        provider: "google",
        calendar_list:
          Enum.map(
            [
              %{id: "own@example.com", selected: true, read_only: false},
              %{id: "shared@example.com", selected: true, read_only: true}
            ],
            &CalendarEntry.normalize/1
          )
      }

      refute Selection.event_writable?(event, integration)
    end

    test "allows a writable calendar on the same account" do
      event = %{provider_calendar_id: "own@example.com", provider_event_id: "evt-1"}

      integration = %{
        provider: "google",
        calendar_list:
          Enum.map(
            [
              %{id: "own@example.com", selected: true, read_only: false},
              %{id: "shared@example.com", selected: true, read_only: true}
            ],
            &CalendarEntry.normalize/1
          )
      }

      assert Selection.event_writable?(event, integration)
    end

    test "resolves a CalDAV event by href prefix rather than provider_calendar_id" do
      # The row is tagged with the integration's first collection, but the
      # href says the event lives in the read-only one. Matching on the tag
      # would call it writable.
      event = %{
        provider_calendar_id: "/calendars/user/work/",
        provider_event_id: "/calendars/user/shared/evt-123.ics"
      }

      integration = %{
        provider: "caldav",
        calendar_list:
          Enum.map(
            [
              %{id: "/calendars/user/work/", path: "/calendars/user/work/", selected: true},
              %{
                id: "/calendars/user/shared/",
                path: "/calendars/user/shared/",
                selected: true,
                read_only: true
              }
            ],
            &CalendarEntry.normalize/1
          )
      }

      refute Selection.event_writable?(event, integration)
    end

    test "allows an event whose originating calendar cannot be resolved" do
      # Rows predating per-calendar tagging match no entry. Refusing those
      # would make ordinary calendars uneditable.
      event = %{provider_calendar_id: nil, provider_event_id: "evt-1"}

      integration = %{
        provider: "google",
        calendar_list:
          Enum.map([%{id: "own@example.com", selected: true}], &CalendarEntry.normalize/1)
      }

      assert Selection.event_writable?(event, integration)
    end

    test "still refuses an untaggable event on a read-only provider" do
      event = %{provider_calendar_id: nil, provider_event_id: "evt-1"}

      refute Selection.event_writable?(event, %{provider: "ics_url", calendar_list: []})
    end
  end
end
