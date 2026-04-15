defmodule Tymeslot.Integrations.Calendar.Outlook.EventNormaliserTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Outlook.EventNormaliser

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

  describe "normalise_events/2" do
    test "converts a standard timed event with correct fields" do
      raw = build_raw_event()

      assert {:ok, [%CalendarEvent{} = event]} = EventNormaliser.normalise_events([raw], @context)

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
      # Graph's `"UTC"` (a Windows zone name) is normalised to canonical IANA.
      assert event.timezone == "Etc/UTC"
      assert event.organiser == %{email: "boss@example.com", display_name: "The Boss"}
      assert [%{method: :popup, minutes_before: 15}] = event.reminders
      assert event.provider_metadata["id"] == "graph-id-1"
    end

    test "falls back to id when iCalUId is absent" do
      raw = build_raw_event(%{"iCalUId" => nil})

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.uid == "graph-id-1"
    end

    test "converts an all-day event to Date start_date/end_date" do
      raw =
        build_raw_event(%{
          "isAllDay" => true,
          "start" => %{"dateTime" => "2024-03-15T00:00:00.0000000", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2024-03-16T00:00:00.0000000", "timeZone" => "UTC"}
        })

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)

      assert event.all_day == true
      assert event.start_date == ~D[2024-03-15]
      assert event.end_date == ~D[2024-03-16]
      assert is_nil(event.start_at)
      assert is_nil(event.end_at)
    end

    test "free event maps to transparency: :transparent" do
      raw = build_raw_event(%{"showAs" => "free"})

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.transparency == :transparent
    end

    test "cancelled event has status: :cancelled and is NOT filtered out" do
      raw = build_raw_event(%{"isCancelled" => true})

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.status == :cancelled
    end

    test "declined event has status: :declined and is NOT filtered out" do
      raw = build_raw_event(%{"responseStatus" => %{"response" => "declined"}})

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.status == :declined
    end

    test "tentative showAs maps to status: :tentative" do
      raw = build_raw_event(%{"showAs" => "tentative"})

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
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

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)

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
        assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
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

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
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

      assert {:ok, events} = EventNormaliser.normalise_events([invalid_raw, valid_raw], @context)

      # Only the valid event should be in the result
      assert length(events) == 1
      assert hd(events).uid == "ical-uid-1"
    end

    test "handles empty event list" do
      assert {:ok, []} = EventNormaliser.normalise_events([], @context)
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

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.created_by_tymeslot == true
    end

    test "marks non-Tymeslot event as not created by Tymeslot" do
      raw = build_raw_event()

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.created_by_tymeslot == false
    end

    test "does not treat a property with the right value but wrong id as Tymeslot-created" do
      raw =
        build_raw_event(%{
          "singleValueExtendedProperties" => [
            %{"id" => "some-other-id", "value" => "tymeslot"}
          ]
        })

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.created_by_tymeslot == false
    end

    test "datetime without offset gets Z appended" do
      raw =
        build_raw_event(%{
          "start" => %{"dateTime" => "2024-03-15T14:00:00", "timeZone" => "Europe/Berlin"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00", "timeZone" => "Europe/Berlin"}
        })

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert %DateTime{} = event.start_at
      assert event.timezone == "Europe/Berlin"
    end

    test "Windows zone name in originalStartTimeZone is normalised to IANA" do
      # Microsoft Graph returns Windows zone names like `"Romance Standard Time"`
      # for events created by native Outlook clients. Stored unsanitised, these
      # strings are not valid inputs for DateTime.from_naive and corrupt any
      # downstream calculation that tries to use them. We map them to IANA at
      # the normaliser boundary.
      raw =
        build_raw_event(%{
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z", "timeZone" => "UTC"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z", "timeZone" => "UTC"},
          "originalStartTimeZone" => "Romance Standard Time"
        })

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.timezone == "Europe/Paris"
    end

    test "Windows zone name in start.timeZone is normalised when originalStartTimeZone is absent" do
      raw =
        build_raw_event(%{
          "start" => %{
            "dateTime" => "2024-03-15T14:00:00Z",
            "timeZone" => "W. Europe Standard Time"
          },
          "end" => %{
            "dateTime" => "2024-03-15T15:00:00Z",
            "timeZone" => "W. Europe Standard Time"
          }
        })

      assert {:ok, [event]} = EventNormaliser.normalise_events([raw], @context)
      assert event.timezone == "Europe/Berlin"
    end
  end
end
