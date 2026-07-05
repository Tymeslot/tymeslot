defmodule Tymeslot.Integrations.Calendar.Google.EventNormaliserTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Google.EventNormaliser

  @context %{
    calendar_integration_id: 42,
    provider_calendar_id: "primary",
    synced_at: ~U[2026-04-08 12:00:00Z]
  }

  describe "normalise_events/2" do
    test "normalises a standard timed event with all fields" do
      raw_events = [
        %{
          "iCalUID" => "ical-uid-123@google.com",
          "id" => "event-id-123",
          "summary" => "Team Standup",
          "description" => "Daily sync",
          "location" => "Room 4B",
          "visibility" => "private",
          "transparency" => "opaque",
          "status" => "confirmed",
          "start" => %{
            "dateTime" => "2026-04-08T10:00:00+02:00",
            "timeZone" => "Europe/Berlin"
          },
          "end" => %{"dateTime" => "2026-04-08T10:30:00+02:00"},
          "organizer" => %{
            "email" => "boss@example.com",
            "displayName" => "The Boss"
          },
          "attendees" => [
            %{
              "email" => "dev@example.com",
              "displayName" => "Dev",
              "responseStatus" => "accepted",
              "optional" => false
            }
          ],
          "reminders" => %{
            "overrides" => [%{"method" => "popup", "minutes" => 10}]
          },
          "colorId" => "5",
          "etag" => "\"etag-abc\"",
          "recurrence" => ["RRULE:FREQ=DAILY"],
          "recurringEventId" => "recurring-123"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert %CalendarEvent{} = event
      assert event.uid == "ical-uid-123@google.com"
      assert event.provider == :google
      assert event.calendar_integration_id == 42
      assert event.provider_calendar_id == "primary"
      assert event.synced_at == ~U[2026-04-08 12:00:00Z]
      assert event.summary == "Team Standup"
      assert event.description == "Daily sync"
      assert event.location == "Room 4B"
      assert event.visibility == :private
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.all_day == false
      # Shifted to UTC: 10:00+02:00 → 08:00Z
      assert event.start_at == ~U[2026-04-08 08:00:00Z]
      assert event.end_at == ~U[2026-04-08 08:30:00Z]
      assert event.timezone == "Europe/Berlin"
      assert event.organiser == %{email: "boss@example.com", display_name: "The Boss"}

      assert [attendee] = event.attendees
      assert attendee.email == "dev@example.com"
      assert attendee.display_name == "Dev"
      assert attendee.response_status == :accepted
      assert attendee.optional == false

      assert [reminder] = event.reminders
      assert reminder.method == :popup
      assert reminder.minutes_before == 10

      assert event.colour == "banana"
      assert event.etag == "\"etag-abc\""
      assert event.recurrence_rule == "RRULE:FREQ=DAILY"
      assert event.provider_metadata["recurringEventId"] == "recurring-123"
    end

    test "normalises an all-day event" do
      raw_events = [
        %{
          "iCalUID" => "allday-uid@google.com",
          "id" => "allday-id",
          "summary" => "Bank Holiday",
          "start" => %{"date" => "2026-04-10"},
          "end" => %{"date" => "2026-04-11"},
          "status" => "confirmed"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.all_day == true
      assert event.start_date == ~D[2026-04-10]
      assert event.end_date == ~D[2026-04-11]
      assert is_nil(event.start_at)
      assert is_nil(event.end_at)
    end

    test "normalises a cancelled event" do
      raw_events = [
        %{
          "iCalUID" => "cancelled-uid@google.com",
          "id" => "cancelled-id",
          "summary" => "Cancelled Meeting",
          "start" => %{"dateTime" => "2026-04-08T14:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T15:00:00Z"},
          "status" => "cancelled"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.status == :cancelled
    end

    test "normalises a transparent (free) event" do
      raw_events = [
        %{
          "iCalUID" => "free-uid@google.com",
          "id" => "free-id",
          "summary" => "Lunch",
          "start" => %{"dateTime" => "2026-04-08T12:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T13:00:00Z"},
          "transparency" => "transparent"
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert event.transparency == :transparent
      refute CalendarEvent.blocking?(event)
    end

    test "normalises event with multiple attendees" do
      raw_events = [
        %{
          "iCalUID" => "attendees-uid@google.com",
          "id" => "attendees-id",
          "summary" => "Group Call",
          "start" => %{"dateTime" => "2026-04-08T16:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T17:00:00Z"},
          "attendees" => [
            %{
              "email" => "alice@example.com",
              "displayName" => "Alice",
              "responseStatus" => "accepted"
            },
            %{
              "email" => "bob@example.com",
              "responseStatus" => "declined",
              "optional" => true
            },
            %{
              "email" => "charlie@example.com",
              "responseStatus" => "tentative"
            }
          ]
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)

      assert length(event.attendees) == 3

      alice = Enum.find(event.attendees, &(&1.email == "alice@example.com"))
      assert alice.display_name == "Alice"
      assert alice.response_status == :accepted
      assert alice.optional == false

      bob = Enum.find(event.attendees, &(&1.email == "bob@example.com"))
      assert bob.response_status == :declined
      assert bob.optional == true
    end

    test "falls back to id when iCalUID is missing" do
      raw_events = [
        %{
          "id" => "fallback-id",
          "summary" => "No iCalUID",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.uid == "fallback-id"
    end

    test "skips invalid event with no UID and continues processing" do
      raw_events = [
        %{
          "summary" => "No UID Event",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        },
        %{
          "iCalUID" => "valid-uid@google.com",
          "id" => "valid-id",
          "summary" => "Valid Event",
          "start" => %{"dateTime" => "2026-04-08T12:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T13:00:00Z"}
        }
      ]

      assert {:ok, events} = EventNormaliser.normalise_events(raw_events, @context)
      assert length(events) == 1
      assert hd(events).uid == "valid-uid@google.com"
    end

    test "returns empty list when all events are invalid" do
      raw_events = [
        %{"summary" => "No UID"},
        %{"summary" => "Also No UID"}
      ]

      assert {:ok, []} = EventNormaliser.normalise_events(raw_events, @context)
    end

    test "returns empty list for empty input" do
      assert {:ok, []} = EventNormaliser.normalise_events([], @context)
    end

    test "detects Tymeslot-created event via extendedProperties" do
      raw_events = [
        %{
          "iCalUID" => "tymeslot-uid@google.com",
          "id" => "tymeslot-id",
          "summary" => "Booking",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"},
          "extendedProperties" => %{"private" => %{"createdBy" => "tymeslot"}}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.created_by_tymeslot == true
    end

    test "marks non-Tymeslot event as not created by Tymeslot" do
      raw_events = [
        %{
          "iCalUID" => "other-uid@google.com",
          "id" => "other-id",
          "summary" => "External Meeting",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.created_by_tymeslot == false
    end

    test "maps an unknown Google colorId to nil colour" do
      raw_events = [
        %{
          "iCalUID" => "evt-x@google.com",
          "id" => "evt-x",
          "summary" => "X",
          "colorId" => "999",
          "start" => %{"dateTime" => "2026-07-02T10:00:00Z"},
          "end" => %{"dateTime" => "2026-07-02T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = EventNormaliser.normalise_events(raw_events, @context)
      assert event.colour == nil
    end
  end
end
