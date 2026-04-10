defmodule Tymeslot.Integrations.Calendar.Google.ProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Google.Provider

  setup :verify_on_exit!

  describe "needs_scope_upgrade?/1" do
    test "returns true when integration lacks calendar scope" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope: "https://www.googleapis.com/auth/userinfo.email"
        )

      assert Provider.needs_scope_upgrade?(integration)
    end

    test "returns false when integration has calendar scope" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope:
            "https://www.googleapis.com/auth/calendar https://www.googleapis.com/auth/userinfo.email"
        )

      refute Provider.needs_scope_upgrade?(integration)
    end

    test "returns false when scope contains calendar.events" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope: "https://www.googleapis.com/auth/calendar.events"
        )

      refute Provider.needs_scope_upgrade?(integration)
    end

    test "returns false when scope is nil" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope: nil
        )

      refute Provider.needs_scope_upgrade?(integration)
    end

    test "returns false for non-struct map" do
      integration = %{oauth_scope: "https://www.googleapis.com/auth/userinfo.email"}

      # Function only checks structs, returns false for plain maps
      refute Provider.needs_scope_upgrade?(integration)
    end

    test "returns false for schema struct with calendar scope" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          oauth_scope: "https://www.googleapis.com/auth/calendar"
        )

      refute Provider.needs_scope_upgrade?(integration)
    end
  end

  describe "validate_oauth_scope/1" do
    test "accepts valid calendar scope" do
      config = %{oauth_scope: "https://www.googleapis.com/auth/calendar"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts calendar.events scope" do
      config = %{oauth_scope: "https://www.googleapis.com/auth/calendar.events"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts scope containing 'calendar' keyword" do
      config = %{oauth_scope: "openid profile email calendar"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts multiple scopes including calendar" do
      config = %{
        oauth_scope:
          "https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/calendar"
      }

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "rejects scope without calendar permission" do
      config = %{oauth_scope: "https://www.googleapis.com/auth/userinfo.email"}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "calendar permission")
    end

    test "rejects nil oauth_scope" do
      config = %{oauth_scope: nil}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "Invalid oauth_scope format")
    end

    test "rejects missing oauth_scope key" do
      config = %{}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "Invalid oauth_scope format")
    end

    test "rejects non-string oauth_scope" do
      config = %{oauth_scope: [:calendar]}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "Invalid oauth_scope format")
    end
  end

  describe "normalise_events/2" do
    setup do
      context = %{
        calendar_integration_id: 42,
        provider_calendar_id: "primary",
        synced_at: ~U[2026-04-08 12:00:00Z]
      }

      %{context: context}
    end

    test "normalises a standard timed event with all fields", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)

      assert %Tymeslot.Integrations.Calendar.CalendarEvent{} = event
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

      assert event.colour == "5"
      assert event.etag == "\"etag-abc\""
      assert event.recurrence_rule == "RRULE:FREQ=DAILY"
      assert event.provider_metadata["recurringEventId"] == "recurring-123"
    end

    test "normalises an all-day event", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)

      assert event.all_day == true
      assert event.start_date == ~D[2026-04-10]
      assert event.end_date == ~D[2026-04-11]
      assert is_nil(event.start_at)
      assert is_nil(event.end_at)
    end

    test "normalises a cancelled event", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)

      assert event.status == :cancelled
    end

    test "normalises a transparent (free) event", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)

      assert event.transparency == :transparent
      refute CalendarEvent.blocking?(event)
    end

    test "normalises event with multiple attendees", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)

      assert length(event.attendees) == 3

      alice = Enum.find(event.attendees, &(&1.email == "alice@example.com"))
      assert alice.display_name == "Alice"
      assert alice.response_status == :accepted
      assert alice.optional == false

      bob = Enum.find(event.attendees, &(&1.email == "bob@example.com"))
      assert bob.response_status == :declined
      assert bob.optional == true
    end

    test "falls back to id when iCalUID is missing", %{context: context} do
      raw_events = [
        %{
          "id" => "fallback-id",
          "summary" => "No iCalUID",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)
      assert event.uid == "fallback-id"
    end

    test "skips invalid event with no UID and continues processing", %{context: context} do
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

      assert {:ok, events} = Provider.normalise_events(raw_events, context)
      assert length(events) == 1
      assert hd(events).uid == "valid-uid@google.com"
    end

    test "returns empty list when all events are invalid", %{context: context} do
      raw_events = [
        %{"summary" => "No UID"},
        %{"summary" => "Also No UID"}
      ]

      assert {:ok, []} = Provider.normalise_events(raw_events, context)
    end

    test "returns empty list for empty input", %{context: context} do
      assert {:ok, []} = Provider.normalise_events([], context)
    end

    test "detects Tymeslot-created event via extendedProperties", %{context: context} do
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

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)
      assert event.created_by_tymeslot == true
    end

    test "marks non-Tymeslot event as not created by Tymeslot", %{context: context} do
      raw_events = [
        %{
          "iCalUID" => "other-uid@google.com",
          "id" => "other-id",
          "summary" => "External Meeting",
          "start" => %{"dateTime" => "2026-04-08T10:00:00Z"},
          "end" => %{"dateTime" => "2026-04-08T11:00:00Z"}
        }
      ]

      assert {:ok, [event]} = Provider.normalise_events(raw_events, context)
      assert event.created_by_tymeslot == false
    end
  end

  describe "convert_event/1" do
    test "converts Google Calendar event with all fields" do
      google_event = %{
        "id" => "event123",
        "summary" => "Team Meeting",
        "description" => "Quarterly planning",
        "location" => "Conference Room A",
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
        "status" => "confirmed"
      }

      result = Provider.convert_event(google_event)

      assert result.uid == "event123"
      assert result.summary == "Team Meeting"
      assert result.description == "Quarterly planning"
      assert result.location == "Conference Room A"
      assert result.status == "confirmed"
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "converts Google Calendar event with minimal fields" do
      google_event = %{
        "id" => "event456",
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z"}
      }

      result = Provider.convert_event(google_event)

      assert result.uid == "event456"
      assert is_nil(result.summary)
      assert is_nil(result.description)
      assert is_nil(result.location)
      assert is_nil(result.status)
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "parses dateTime format correctly" do
      google_event = %{
        "id" => "event789",
        "start" => %{"dateTime" => "2024-03-15T14:30:00+01:00"},
        "end" => %{"dateTime" => "2024-03-15T15:30:00+01:00"}
      }

      result = Provider.convert_event(google_event)

      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "parses all-day event with date format" do
      google_event = %{
        "id" => "event-allday",
        "summary" => "All Day Event",
        "start" => %{"date" => "2024-03-15"},
        "end" => %{"date" => "2024-03-16"}
      }

      result = Provider.convert_event(google_event)

      assert result.uid == "event-allday"
      assert %Date{} = result.start_time
      assert %Date{} = result.end_time
      assert result.start_time.year == 2024
      assert result.start_time.month == 3
      assert result.start_time.day == 15
    end

    test "handles invalid datetime gracefully" do
      google_event = %{
        "id" => "event-invalid",
        "start" => %{"dateTime" => "invalid-date"},
        "end" => %{"dateTime" => "invalid-date"}
      }

      result = Provider.convert_event(google_event)

      assert result.uid == "event-invalid"
      assert is_nil(result.start_time)
      assert is_nil(result.end_time)
    end

    test "handles missing start/end times" do
      google_event = %{
        "id" => "event-no-times",
        "summary" => "No Times"
      }

      result = Provider.convert_event(google_event)

      assert result.uid == "event-no-times"
      assert is_nil(result.start_time)
      assert is_nil(result.end_time)
    end

    test "sets transparency to nil when field is absent (default is busy)" do
      google_event = %{
        "id" => "event-no-transparency",
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z"}
      }

      result = Provider.convert_event(google_event)

      assert is_nil(result.transparency)
    end

    test "preserves transparency: transparent for free events" do
      google_event = %{
        "id" => "free-event",
        "summary" => "Free Holiday",
        "start" => %{"date" => "2024-03-15"},
        "end" => %{"date" => "2024-03-16"},
        "transparency" => "transparent"
      }

      result = Provider.convert_event(google_event)

      assert result.transparency == "transparent"
    end

    test "preserves transparency: opaque for explicitly busy events" do
      google_event = %{
        "id" => "busy-event",
        "summary" => "Busy Meeting",
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
        "transparency" => "opaque"
      }

      result = Provider.convert_event(google_event)

      assert result.transparency == "opaque"
    end
  end

  describe "convert_events/1" do
    test "converts multiple Google Calendar events" do
      google_events = [
        %{
          "id" => "event1",
          "summary" => "Meeting 1",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"}
        },
        %{
          "id" => "event2",
          "summary" => "Meeting 2",
          "start" => %{"dateTime" => "2024-03-15T16:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T17:00:00Z"}
        }
      ]

      results = Provider.convert_events(google_events)

      assert length(results) == 2
      assert Enum.at(results, 0).uid == "event1"
      assert Enum.at(results, 1).uid == "event2"
    end

    test "handles empty event list" do
      assert [] = Provider.convert_events([])
    end

    test "converts events with mixed date formats" do
      google_events = [
        %{
          "id" => "datetime-event",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"}
        },
        %{
          "id" => "date-event",
          "start" => %{"date" => "2024-03-16"},
          "end" => %{"date" => "2024-03-17"}
        }
      ]

      results = Provider.convert_events(google_events)

      assert length(results) == 2
      assert Enum.at(results, 0).uid == "datetime-event"
      assert Enum.at(results, 1).uid == "date-event"
      assert %DateTime{} = Enum.at(results, 0).start_time
      assert %Date{} = Enum.at(results, 1).start_time
    end
  end

  describe "get_calendar_api_module/0" do
    test "returns the configured Google CalendarAPI mock" do
      assert Provider.get_calendar_api_module() == GoogleCalendarAPIMock
    end
  end

  describe "CRUD operations delegation" do
    test "call_create_event uses primary calendar and mocks API call" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: nil
        )

      event_attrs = %{
        summary: "New Event",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(GoogleCalendarAPIMock, :create_event, fn _int, "primary", _attrs ->
        {:ok, %{id: "new_id"}}
      end)

      assert {:ok, %{id: "new_id"}} = Provider.call_create_event(integration, event_attrs)
    end

    test "call_create_event uses default booking calendar when set" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: "work-calendar@example.com"
        )

      event_attrs = %{
        summary: "Work Event",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(GoogleCalendarAPIMock, :create_event, fn _int, "work-calendar@example.com", _attrs ->
        {:ok, %{id: "work_id"}}
      end)

      assert {:ok, %{id: "work_id"}} = Provider.call_create_event(integration, event_attrs)
    end

    test "call_update_event delegates to mock with correct calendar" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          default_booking_calendar_id: "calendar123"
        )

      expect(GoogleCalendarAPIMock, :update_event, fn _int, "calendar123", "event123", _attrs ->
        {:ok, %{id: "event123"}}
      end)

      assert {:ok, %{id: "event123"}} =
               Provider.call_update_event(integration, "event123", %{summary: "Updated"})
    end

    test "call_delete_event delegates to mock" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google"
        )

      expect(GoogleCalendarAPIMock, :delete_event, fn _int, "primary", "event123" ->
        {:ok, :deleted}
      end)

      assert {:ok, :deleted} = Provider.call_delete_event(integration, "event123")
    end
  end

  describe "connection testing" do
    test "test_connection succeeds when API call succeeds" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "test_token"
        )

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _integration,
                                                             _start_date,
                                                             _end_date ->
        {:ok, []}
      end)

      assert {:ok, "Google Calendar connection successful"} =
               Provider.test_connection(integration)
    end

    test "test_connection handles unauthorized error" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "test_token"
        )

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _integration,
                                                             _start_date,
                                                             _end_date ->
        {:error, :unauthorized, "token expired"}
      end)

      assert {:error, :unauthorized} = Provider.test_connection(integration)
    end
  end
end
