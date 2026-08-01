defmodule Tymeslot.Integrations.Calendar.Outlook.ProviderTest do
  use Tymeslot.DataCase, async: true
  @moduletag :integrations

  import Tymeslot.Factory
  import Mox

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
          "id" => "event1",
          "subject" => "Meeting 1",
          "body" => %{"content" => nil},
          "location" => %{"displayName" => nil},
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
        },
        %{
          "id" => "event2",
          "subject" => "Meeting 2",
          "body" => %{"content" => nil},
          "location" => %{"displayName" => nil},
          "start" => %{"dateTime" => "2024-03-15T16:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T17:00:00Z"},
          "isCancelled" => false
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
          "id" => "complete-event",
          "subject" => "Complete",
          "body" => %{"content" => "Full details"},
          "location" => %{"displayName" => "Office"},
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
        },
        %{
          "id" => "minimal-event",
          "subject" => nil,
          "body" => %{"content" => nil},
          "location" => %{"displayName" => nil},
          "start" => %{"dateTime" => "2024-03-16T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-16T15:00:00Z"},
          "isCancelled" => false
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
          "id" => "busy-event",
          "subject" => "Busy",
          "body" => %{"content" => "desc"},
          "location" => %{"displayName" => "loc"},
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false,
          "showAs" => "busy",
          "responseStatus" => %{"response" => "accepted"}
        },
        %{
          "id" => "free-event",
          "subject" => "Free",
          "body" => %{"content" => "desc"},
          "location" => %{"displayName" => "loc"},
          "start" => %{"dateTime" => "2024-03-15T16:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T17:00:00Z"},
          "isCancelled" => false,
          "showAs" => "free",
          "responseStatus" => %{"response" => "accepted"}
        },
        %{
          "id" => "declined-event",
          "subject" => "Declined",
          "body" => %{"content" => "desc"},
          "location" => %{"displayName" => "loc"},
          "start" => %{"dateTime" => "2024-03-15T18:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T19:00:00Z"},
          "isCancelled" => false,
          "showAs" => "busy",
          "responseStatus" => %{"response" => "declined"}
        },
        %{
          "id" => "cancelled-event",
          "subject" => "Cancelled",
          "body" => %{"content" => "desc"},
          "location" => %{"displayName" => "loc"},
          "start" => %{"dateTime" => "2024-03-15T20:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T21:00:00Z"},
          "isCancelled" => true,
          "showAs" => "busy",
          "responseStatus" => %{"response" => "accepted"}
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
          "id" => "busy",
          "showAs" => "busy",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
        },
        %{
          "id" => "tentative",
          "showAs" => "tentative",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
        },
        %{
          "id" => "oom",
          "showAs" => "oom",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
        },
        %{
          "id" => "free",
          "showAs" => "free",
          "start" => %{"dateTime" => "2024-03-15T14:00:00Z"},
          "end" => %{"dateTime" => "2024-03-15T15:00:00Z"},
          "isCancelled" => false
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

  describe "check_connectivity/1" do
    test "returns skipped status for any input" do
      assert {:ok, %{status: :skipped, reason: "OAuth providers use token-based auth"}} =
               Provider.check_connectivity(%{})
    end

    test "returns skipped status when called with an integration struct" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook"
        )

      assert {:ok, %{status: :skipped}} = Provider.check_connectivity(integration)
    end
  end

  describe "list_events/3" do
    test "extracts start_time and end_time from opts and delegates to primary events" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "test_token"
        )

      start_time = ~U[2024-03-15 09:00:00Z]
      end_time = ~U[2024-03-15 17:00:00Z]

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _integration,
                                                              ^start_time,
                                                              ^end_time ->
        {:ok, [%{"id" => "evt1", "subject" => "Stand-up"}]}
      end)

      assert {:ok, [%{"id" => "evt1"}]} =
               Provider.list_events(integration,
                 start_time: start_time,
                 end_time: end_time
               )
    end

    test "propagates errors from the underlying API call" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "test_token"
        )

      start_time = ~U[2024-03-15 09:00:00Z]
      end_time = ~U[2024-03-15 17:00:00Z]

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _integration, _start, _end ->
        {:error, :unauthorized, "Token expired"}
      end)

      assert {:error, :unauthorized, _msg} =
               Provider.list_events(integration,
                 start_time: start_time,
                 end_time: end_time
               )
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

      assert {:ok, "Outlook Calendar connected successfully!"} =
               Provider.perform_connection_test(integration)
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

      assert {:error, :unauthorized} = Provider.perform_connection_test(integration)
    end
  end

  describe "discover_calendars/1 read_only mapping" do
    test "marks non-editable calendars as read_only" do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")

      expect(OutlookCalendarAPIMock, :list_calendars, fn _client ->
        {:ok,
         [
           %{"id" => "editable-cal", "name" => "Editable", "canEdit" => true},
           %{"id" => "shared-cal", "name" => "Shared", "canEdit" => false}
         ]}
      end)

      assert {:ok, calendars} = Provider.discover_calendars(integration)

      by_id = Map.new(calendars, &{&1.id, &1})
      refute by_id["editable-cal"].read_only
      assert by_id["shared-cal"].read_only
    end
  end
end
