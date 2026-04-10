defmodule Tymeslot.Integrations.Calendar.Outlook.ProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Outlook.Provider

  setup :set_mox_from_context
  setup :verify_on_exit!

  describe "validate_oauth_scope/1" do
    test "accepts valid Calendars.ReadWrite scope" do
      config = %{oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts Calendars.ReadWrite.Shared scope" do
      config = %{oauth_scope: "https://graph.microsoft.com/Calendars.ReadWrite.Shared"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts scope containing Calendars.ReadWrite keyword" do
      config = %{oauth_scope: "openid profile Calendars.ReadWrite"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts Calendars.Read scope" do
      config = %{oauth_scope: "Calendars.Read"}

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "accepts multiple scopes including Calendars.ReadWrite" do
      config = %{
        oauth_scope: "User.Read Calendars.ReadWrite Mail.Read"
      }

      assert :ok = Provider.validate_oauth_scope(config)
    end

    test "rejects scope without calendar permission" do
      config = %{oauth_scope: "https://graph.microsoft.com/User.Read"}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "Calendars.ReadWrite")
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
      config = %{oauth_scope: [:calendars]}

      assert {:error, message} = Provider.validate_oauth_scope(config)
      assert String.contains?(message, "Invalid oauth_scope format")
    end
  end

  describe "convert_event/1" do
    test "converts Outlook event with all fields" do
      outlook_event = %{
        id: "event123",
        summary: "Team Meeting",
        description: "Quarterly planning",
        location: "Conference Room A",
        start: %{
          "dateTime" => "2024-03-15T14:00:00Z",
          "timeZone" => "UTC"
        },
        end: %{
          "dateTime" => "2024-03-15T15:00:00Z",
          "timeZone" => "UTC"
        },
        status: "confirmed"
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event123"
      assert result.summary == "Team Meeting"
      assert result.description == "Quarterly planning"
      assert result.location == "Conference Room A"
      assert result.status == "confirmed"
      assert result.show_as == nil
      assert result.response_status == nil
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "converts Outlook event with minimal fields" do
      outlook_event = %{
        id: "event456",
        summary: nil,
        description: nil,
        location: nil,
        start: %{"dateTime" => "2024-03-15T14:00:00Z"},
        end: %{"dateTime" => "2024-03-15T15:00:00Z"},
        status: nil
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event456"
      assert is_nil(result.summary)
      assert is_nil(result.description)
      assert is_nil(result.location)
      assert is_nil(result.status)
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "parses dateTime with timezone correctly" do
      outlook_event = %{
        id: "event789",
        summary: "Meeting",
        description: nil,
        location: nil,
        start: %{
          "dateTime" => "2024-03-15T14:30:00-08:00",
          "timeZone" => "Pacific Standard Time"
        },
        end: %{
          "dateTime" => "2024-03-15T15:30:00-08:00",
          "timeZone" => "Pacific Standard Time"
        },
        status: nil
      }

      result = Provider.convert_event(outlook_event)

      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "parses dateTime without timezone" do
      outlook_event = %{
        id: "event-no-tz",
        summary: "No Timezone Event",
        description: nil,
        location: nil,
        start: %{"dateTime" => "2024-03-15T14:00:00Z"},
        end: %{"dateTime" => "2024-03-15T15:00:00Z"},
        status: nil
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event-no-tz"
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
    end

    test "handles invalid datetime gracefully" do
      outlook_event = %{
        id: "event-invalid",
        summary: nil,
        description: nil,
        location: nil,
        start: %{"dateTime" => "invalid-date"},
        end: %{"dateTime" => "invalid-date"},
        status: nil
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event-invalid"
      assert is_nil(result.start_time)
      assert is_nil(result.end_time)
    end

    test "handles missing start/end times" do
      outlook_event = %{
        id: "event-no-times",
        summary: "No Times",
        description: nil,
        location: nil,
        start: nil,
        end: nil,
        status: nil
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event-no-times"
      assert is_nil(result.start_time)
      assert is_nil(result.end_time)
    end

    test "handles all-day events correctly" do
      outlook_event = %{
        id: "event-allday",
        summary: "All Day",
        description: nil,
        location: nil,
        start: %{"dateTime" => "2024-03-15T00:00:00.0000000"},
        end: %{"dateTime" => "2024-03-16T00:00:00.0000000"},
        is_all_day: true,
        status: "confirmed"
      }

      result = Provider.convert_event(outlook_event)

      assert result.uid == "event-allday"
      assert %Date{} = result.start_time
      assert %Date{} = result.end_time
      assert result.start_time == ~D[2024-03-15]
      assert result.end_time == ~D[2024-03-16]
    end
  end

  describe "convert_events/1" do
    test "converts multiple Outlook events" do
      outlook_events = [
        %{
          id: "event1",
          summary: "Meeting 1",
          description: nil,
          location: nil,
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"},
          status: nil
        },
        %{
          id: "event2",
          summary: "Meeting 2",
          description: nil,
          location: nil,
          start: %{"dateTime" => "2024-03-15T16:00:00Z"},
          end: %{"dateTime" => "2024-03-15T17:00:00Z"},
          status: nil
        }
      ]

      results = Provider.convert_events(outlook_events)

      assert length(results) == 2
      assert Enum.at(results, 0).uid == "event1"
      assert Enum.at(results, 1).uid == "event2"
    end

    test "handles empty event list" do
      assert [] = Provider.convert_events([])
    end

    test "converts events with varying data completeness" do
      outlook_events = [
        %{
          id: "complete-event",
          summary: "Complete",
          description: "Full details",
          location: "Office",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"},
          status: "confirmed"
        },
        %{
          id: "minimal-event",
          summary: nil,
          description: nil,
          location: nil,
          start: %{"dateTime" => "2024-03-16T14:00:00Z"},
          end: %{"dateTime" => "2024-03-16T15:00:00Z"},
          status: nil
        }
      ]

      results = Provider.convert_events(outlook_events)

      assert length(results) == 2
      assert Enum.at(results, 0).summary == "Complete"
      assert is_nil(Enum.at(results, 1).summary)
    end

    test "filters out declined and cancelled events at the provider level" do
      outlook_events = [
        %{
          id: "busy-event",
          summary: "Busy",
          description: "desc",
          location: "loc",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"},
          status: "confirmed",
          show_as: "busy"
        },
        %{
          id: "free-event",
          summary: "Free",
          description: "desc",
          location: "loc",
          start: %{"dateTime" => "2024-03-15T16:00:00Z"},
          end: %{"dateTime" => "2024-03-15T17:00:00Z"},
          status: "confirmed",
          show_as: "free"
        },
        %{
          id: "declined-event",
          summary: "Declined",
          description: "desc",
          location: "loc",
          start: %{"dateTime" => "2024-03-15T18:00:00Z"},
          end: %{"dateTime" => "2024-03-15T19:00:00Z"},
          status: "confirmed",
          show_as: "busy",
          response_status: "declined"
        },
        %{
          id: "cancelled-event",
          summary: "Cancelled",
          description: "desc",
          location: "loc",
          start: %{"dateTime" => "2024-03-15T20:00:00Z"},
          end: %{"dateTime" => "2024-03-15T21:00:00Z"},
          status: "cancelled",
          show_as: "busy"
        }
      ]

      results = Provider.convert_events(outlook_events)

      # declined and cancelled are filtered at the provider level
      # free events pass through with transparency: "transparent" for the availability layer
      assert [busy, free] = results
      assert busy.uid == "busy-event"
      assert free.uid == "free-event"
    end

    test "sets transparency: opaque for busy events and transparent for free events" do
      events = [
        %{
          id: "busy",
          show_as: "busy",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"}
        },
        %{
          id: "tentative",
          show_as: "tentative",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"}
        },
        %{
          id: "oom",
          show_as: "oom",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"}
        },
        %{
          id: "free",
          show_as: "free",
          start: %{"dateTime" => "2024-03-15T14:00:00Z"},
          end: %{"dateTime" => "2024-03-15T15:00:00Z"}
        }
      ]

      results = Provider.convert_events(events)

      assert [busy, tentative, oom, free] = results
      assert busy.transparency == "opaque"
      assert tentative.transparency == "opaque"
      assert oom.transparency == "opaque"
      assert free.transparency == "transparent"
    end
  end

  describe "normalise_events/2" do
    @synced_at ~U[2024-03-15 12:00:00Z]

    @context %{
      calendar_integration_id: 42,
      provider_calendar_id: "cal-123",
      synced_at: @synced_at
    }

    defp build_raw_event(overrides \\ %{}) do
      Map.merge(
        %{
          "id" => "graph-id-1",
          "iCalUId" => "ical-uid-1",
          "subject" => "Team Standup",
          "body" => %{"content" => "Daily sync"},
          "location" => %{"displayName" => "Room 42"},
          "showAs" => "busy",
          "sensitivity" => "normal",
          "isAllDay" => false,
          "isCancelled" => false,
          "responseStatus" => %{"response" => "accepted"},
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"},
          "organizer" => %{
            "emailAddress" => %{"address" => "boss@example.com", "name" => "The Boss"}
          },
          "attendees" => [],
          "reminderMinutesBeforeStart" => 15,
          "recurrence" => nil,
          "seriesMasterId" => nil
        },
        overrides
      )
    end

    test "converts a standard timed event with correct fields" do
      raw = build_raw_event()

      assert {:ok, [%CalendarEvent{} = event]} = Provider.normalise_events([raw], @context)

      assert event.uid == "ical-uid-1"
      assert event.provider == :outlook
      assert event.calendar_integration_id == 42
      assert event.provider_calendar_id == "cal-123"
      assert event.synced_at == @synced_at
      assert event.summary == "Team Standup"
      assert event.description == "Daily sync"
      assert event.location == "Room 42"
      assert event.visibility == :public
      assert event.transparency == :opaque
      assert event.status == :confirmed
      assert event.all_day == false
      assert %DateTime{} = event.start_at
      assert %DateTime{} = event.end_at
      assert event.timezone == "UTC"
      assert event.organiser == %{email: "boss@example.com", display_name: "The Boss"}
      assert [%{method: :popup, minutes_before: 15}] = event.reminders
      assert event.provider_metadata["id"] == "graph-id-1"
    end

    test "falls back to id when iCalUId is absent" do
      raw = build_raw_event(%{"iCalUId" => nil})

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.uid == "graph-id-1"
    end

    test "converts an all-day event to Date start_date/end_date" do
      raw =
        build_raw_event(%{
          "isAllDay" => true,
          "start" => %{"dateTime" => "2024-03-15T00:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2024-03-16T00:00:00.0000000", "timeZone" => "UTC"}
        })

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)

      assert event.all_day == true
      assert event.start_date == ~D[2024-03-15]
      assert event.end_date == ~D[2024-03-16]
      assert is_nil(event.start_at)
      assert is_nil(event.end_at)
    end

    test "free event maps to transparency: :transparent" do
      raw = build_raw_event(%{"showAs" => "free"})

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.transparency == :transparent
    end

    test "cancelled event has status: :cancelled and is NOT filtered out" do
      raw = build_raw_event(%{"isCancelled" => true})

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.status == :cancelled
    end

    test "declined event has status: :declined and is NOT filtered out" do
      raw = build_raw_event(%{"responseStatus" => %{"response" => "declined"}})

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.status == :declined
    end

    test "tentative showAs maps to status: :tentative" do
      raw = build_raw_event(%{"showAs" => "tentative"})

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.status == :tentative
    end

    test "maps attendees with correct fields" do
      raw =
        build_raw_event(%{
          "attendees" => [
            %{
              "emailAddress" => %{"address" => "alice@example.com", "name" => "Alice"},
              "status" => %{"response" => "accepted"},
              "type" => "required"
            },
            %{
              "emailAddress" => %{"address" => "bob@example.com", "name" => "Bob"},
              "status" => %{"response" => "tentativelyAccepted"},
              "type" => "optional"
            }
          ]
        })

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)

      assert [alice, bob] = event.attendees
      assert alice.email == "alice@example.com"
      assert alice.display_name == "Alice"
      assert alice.response_status == :accepted
      assert alice.optional == false

      assert bob.email == "bob@example.com"
      assert bob.response_status == :tentative
      assert bob.optional == true
    end

    test "maps sensitivity to visibility" do
      for {sensitivity, expected} <- [
            {"normal", :public},
            {"private", :private},
            {"confidential", :confidential}
          ] do
        raw = build_raw_event(%{"sensitivity" => sensitivity})
        assert {:ok, [event]} = Provider.normalise_events([raw], @context)
        assert event.visibility == expected
      end
    end

    test "maps recurrence pattern" do
      raw =
        build_raw_event(%{
          "recurrence" => %{
            "pattern" => %{"type" => "daily", "interval" => 2},
            "range" => %{"type" => "endDate"}
          }
        })

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.recurrence_rule == "FREQ=DAILY;INTERVAL=2;RANGE_TYPE=endDate"
    end

    test "invalid event is skipped with warning and admin alert" do
      # An event with no uid will fail CalendarEvent.new/1 validation
      invalid_raw = %{
        "id" => nil,
        "iCalUId" => nil,
        "subject" => "Bad Event",
        "isAllDay" => false,
        "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"},
        "showAs" => "busy",
        "isCancelled" => false,
        "responseStatus" => %{"response" => "accepted"}
      }

      valid_raw = build_raw_event()

      assert {:ok, events} = Provider.normalise_events([invalid_raw, valid_raw], @context)

      # Only the valid event should be in the result
      assert length(events) == 1
      assert hd(events).uid == "ical-uid-1"
    end

    test "handles empty event list" do
      assert {:ok, []} = Provider.normalise_events([], @context)
    end

    test "detects Tymeslot-created event via singleValueExtendedProperties" do
      raw =
        build_raw_event(%{
          "singleValueExtendedProperties" => [
            %{
              "id" => "String {00020329-0000-0000-C000-000000000046} Name createdBy",
              "value" => "tymeslot"
            }
          ]
        })

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.created_by_tymeslot == true
    end

    test "marks non-Tymeslot event as not created by Tymeslot" do
      raw = build_raw_event()

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert event.created_by_tymeslot == false
    end

    test "datetime without offset gets Z appended" do
      raw =
        build_raw_event(%{
          "start" => %{"dateTime" => "2024-03-15T14:00:00", "timeZone" => "Europe/Berlin"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00", "timeZone" => "Europe/Berlin"}
        })

      assert {:ok, [event]} = Provider.normalise_events([raw], @context)
      assert %DateTime{} = event.start_at
      assert event.timezone == "Europe/Berlin"
    end
  end

  describe "get_calendar_api_module/0" do
    test "returns the configured Outlook CalendarAPI mock" do
      assert Provider.get_calendar_api_module() == OutlookCalendarAPIMock
    end
  end

  describe "CRUD operations delegation" do
    test "call_create_event uses default booking calendar when set" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          default_booking_calendar_id: "work-calendar-id"
        )

      event_attrs = %{
        summary: "Work Event",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(OutlookCalendarAPIMock, :create_event, fn _int, "work-calendar-id", _attrs ->
        {:ok, %{id: "outlook_id"}}
      end)

      assert {:ok, %{id: "outlook_id"}} = Provider.call_create_event(integration, event_attrs)
    end

    test "call_create_event uses default API method when no calendar ID set" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          default_booking_calendar_id: nil
        )

      event_attrs = %{
        summary: "Event without calendar",
        start_time: DateTime.utc_now(),
        end_time: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      expect(OutlookCalendarAPIMock, :create_event, fn _int, _attrs ->
        {:ok, %{id: "fallback_id"}}
      end)

      assert {:ok, %{id: "fallback_id"}} = Provider.call_create_event(integration, event_attrs)
    end

    test "call_update_event uses calendar ID when available" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          default_booking_calendar_id: "calendar123"
        )

      expect(OutlookCalendarAPIMock, :update_event, fn _int, "calendar123", "event123", _attrs ->
        {:ok, %{id: "event123"}}
      end)

      assert {:ok, %{id: "event123"}} =
               Provider.call_update_event(integration, "event123", %{summary: "Updated"})
    end

    test "call_delete_event uses calendar ID when available" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          default_booking_calendar_id: "calendar123"
        )

      expect(OutlookCalendarAPIMock, :delete_event, fn _int, "calendar123", "event123" ->
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
          provider: "outlook",
          access_token: "test_token"
        )

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _integration,
                                                              _start_date,
                                                              _end_date ->
        {:ok, []}
      end)

      assert {:ok, "Outlook Calendar connection successful"} =
               Provider.test_connection(integration)
    end

    test "test_connection handles unauthorized error" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "test_token"
        )

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _integration,
                                                              _start_date,
                                                              _end_date ->
        {:error, :unauthorized, "token expired"}
      end)

      assert {:error, :unauthorized} = Provider.test_connection(integration)
    end
  end
end
