defmodule Tymeslot.Integrations.Calendar.Google.ProviderTest do
  use Tymeslot.DataCase, async: true

  import Tymeslot.Factory
  import Mox

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
      assert %DateTime{} = result.start_time
      assert %DateTime{} = result.end_time
      # All-day events should start at midnight
      assert result.start_time.hour == 0
      assert result.start_time.minute == 0
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
      assert Enum.all?(results, fn event -> %DateTime{} = event.start_time end)
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

      expect(GoogleCalendarAPIMock, :create_event, fn _int, "primary", _attrs -> {:ok, %{id: "new_id"}} end)

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

      expect(GoogleCalendarAPIMock, :delete_event, fn _int, "primary", "event123" -> {:ok, :deleted} end)

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

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _, _, _ -> {:ok, []} end)

      assert {:ok, "Google Calendar connection successful"} = Provider.test_connection(integration)
    end

    test "test_connection handles unauthorized error" do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "google",
          access_token: "test_token"
        )

      expect(GoogleCalendarAPIMock, :list_primary_events, fn _, _, _ ->
        {:error, :unauthorized, "token expired"}
      end)

      assert {:error, :unauthorized} = Provider.test_connection(integration)
    end
  end
end
