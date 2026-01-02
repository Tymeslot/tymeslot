defmodule Tymeslot.Integrations.Calendar.Outlook.ProviderTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  import Mox

  alias Tymeslot.Integrations.Calendar.Outlook.Provider

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

      expect(OutlookCalendarAPIMock, :create_event, fn _int, _attrs -> {:ok, %{id: "fallback_id"}} end)

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

      expect(OutlookCalendarAPIMock, :delete_event, fn _int, "calendar123", "event123" -> {:ok, :deleted} end)

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

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _, _, _ -> {:ok, []} end)

      assert {:ok, "Outlook Calendar connection successful"} = Provider.test_connection(integration)
    end

    test "test_connection handles unauthorized error" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token: "test_token"
        )

      expect(OutlookCalendarAPIMock, :list_primary_events, fn _, _, _ ->
        {:error, :unauthorized, "token expired"}
      end)

      assert {:error, :unauthorized} = Provider.test_connection(integration)
    end
  end
end
