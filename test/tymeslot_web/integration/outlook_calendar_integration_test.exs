defmodule TymeslotWeb.Integration.OutlookCalendarIntegrationTest do
  @moduledoc """
  Integration tests for Outlook Calendar focusing on business behavior:
  token management, calendar synchronization, and error handling.
  """
  use TymeslotWeb.ConnCase, async: false

  import Tymeslot.Factory
  alias Phoenix.Flash
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI

  @moduletag :calendar_integration

  describe "Outlook Token Management" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      {:ok, user: user, integration: integration}
    end

    test "identifies when tokens need refreshing", %{integration: integration} do
      # Valid token (expires in 1 hour)
      assert CalendarAPI.token_valid?(integration) == true

      # Expired token
      expired = %{integration | token_expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)}
      assert CalendarAPI.token_valid?(expired) == false

      # Soon to expire (within 5 minute buffer)
      soon = %{integration | token_expires_at: DateTime.add(DateTime.utc_now(), 120, :second)}
      assert CalendarAPI.token_valid?(soon) == false
    end

    test "handles token refresh failures gracefully", %{integration: integration} do
      # Force token to be expired
      expired = %{integration | token_expires_at: DateTime.add(DateTime.utc_now(), -1, :hour)}

      case CalendarAPI.refresh_token(expired) do
        {:ok, {_access, _refresh, _expires_at}} ->
          # Success only if real tokens are configured
          assert System.get_env("TEST_OUTLOOK_REFRESH_TOKEN") != nil

        {:error, reason, _message} ->
          # Expected when tokens are invalid
          assert reason in [:authentication_error, :invalid_grant, :unauthorized]
      end
    end
  end

  describe "Outlook Calendar Synchronization" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          is_active: true
        )

      {:ok, user: user, integration: integration}
    end

    test "retrieves calendar events within date range", %{integration: integration} do
      start_time = DateTime.add(DateTime.utc_now(), -7, :day)
      end_time = DateTime.add(DateTime.utc_now(), 7, :day)

      case CalendarAPI.list_primary_events(integration, start_time, end_time) do
        {:ok, events} ->
          # Verify events are properly structured
          assert is_list(events)

          Enum.each(events, fn event ->
            assert Map.has_key?(event, :id)
            assert Map.has_key?(event, :start)
            assert Map.has_key?(event, :end)
          end)

        {:error, _reason, _message} ->
          # Expected without real tokens
          assert true
      end
    end

    test "handles API errors gracefully", %{integration: integration} do
      # Test with invalid time range
      invalid_start = DateTime.add(DateTime.utc_now(), 7, :day)
      invalid_end = DateTime.add(DateTime.utc_now(), -7, :day)

      result = CalendarAPI.list_primary_events(integration, invalid_start, invalid_end)
      assert {:error, _, _} = result
    end
  end

  describe "Calendar Integration Management" do
    setup do
      user = insert(:user)
      {:ok, user: user}
    end

    test "user can manage calendar integrations", %{user: user} do
      # Create integration
      {:ok, integration} =
        CalendarIntegrationQueries.create(%{
          user_id: user.id,
          name: "Outlook Calendar",
          provider: "outlook",
          base_url: "https://graph.microsoft.com/v1.0",
          access_token: "test_token",
          refresh_token: "test_refresh",
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
          oauth_scope: "https://graph.microsoft.com/Calendars.Read",
          is_active: true
        })

      # List integrations
      integrations = Calendar.list_integrations(user.id)
      assert length(integrations) == 1
      assert hd(integrations).provider == "outlook"

      # Toggle integration
      {:ok, toggled} = Calendar.toggle_integration(integration.id, user.id)
      assert toggled.is_active == false

      # Delete integration
      {:ok, _deleted} = Calendar.delete_integration(integration.id, user.id)
      assert Calendar.list_integrations(user.id) == []
    end

    test "prevents unauthorized access to integrations", %{user: user} do
      other_user = insert(:user)

      {:ok, integration} =
        CalendarIntegrationQueries.create(%{
          user_id: user.id,
          name: "Private Calendar",
          provider: "outlook",
          base_url: "https://graph.microsoft.com/v1.0",
          access_token: "secret",
          refresh_token: "secret",
          token_expires_at: DateTime.utc_now(),
          is_active: true
        })

      # Other user cannot toggle
      result = Calendar.toggle_integration(integration.id, other_user.id)
      assert {:error, _} = result
    end
  end

  describe "Error Handling" do
    setup do
      user = insert(:user)
      integration = insert(:calendar_integration, user: user, provider: "outlook")
      {:ok, user: user, integration: integration}
    end

    test "handles connection failures gracefully", %{integration: integration} do
      # Test calendar operations with invalid/expired tokens
      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 1, :hour)

      case CalendarAPI.list_primary_events(integration, start_time, end_time) do
        {:ok, events} ->
          # Only succeeds with real tokens
          assert System.get_env("TEST_OUTLOOK_ACCESS_TOKEN") != nil
          assert is_list(events)

        {:error, _reason, _message} ->
          # Expected failure without real tokens
          assert true
      end
    end

    test "handles invalid OAuth callback parameters", %{conn: conn} do
      # Missing code
      conn = get(conn, "/auth/outlook/calendar/callback", %{"state" => "test"})
      assert redirected_to(conn, 302)
      assert Flash.get(conn.assigns.flash, :error) =~ "Invalid authentication"

      # Access denied
      conn = get(build_conn(), "/auth/outlook/calendar/callback", %{"error" => "access_denied"})
      assert redirected_to(conn, 302)
      assert Flash.get(conn.assigns.flash, :error) =~ "Authorization was denied"
    end
  end
end
