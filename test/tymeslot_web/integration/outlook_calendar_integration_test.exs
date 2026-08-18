defmodule TymeslotWeb.Integration.OutlookCalendarIntegrationTest do
  @moduledoc """
  Integration tests for Outlook Calendar focusing on business behavior:
  token management, calendar synchronization, and error handling.
  """
  use TymeslotWeb.ConnCase, async: false

  import Mox
  import Tymeslot.Factory

  alias Phoenix.Flash
  alias Tymeslot.HTTPClientMock
  alias Tymeslot.Integrations.Calendar
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Security.Encryption

  @moduletag :calendar_integration
  @moduletag :calendar
  @moduletag :integrations

  @token_url "https://login.microsoftonline.com/common/oauth2/v2.0/token"

  setup :verify_on_exit!

  # Microsoft credentials fall back to OUTLOOK_CLIENT_ID/SECRET when
  # `:outlook_oauth` is unset, so the refresh path takes a different branch
  # depending on whether the developer's shell happens to export them. Pin the
  # config so every run reaches the HTTP call.
  defp pin_microsoft_credentials(_context) do
    prior = Application.get_env(:tymeslot, :outlook_oauth)

    Application.put_env(:tymeslot, :outlook_oauth,
      client_id: "test-client-id",
      client_secret: "test-client-secret"
    )

    on_exit(fn ->
      if prior,
        do: Application.put_env(:tymeslot, :outlook_oauth, prior),
        else: Application.delete_env(:tymeslot, :outlook_oauth)
    end)

    :ok
  end

  describe "Outlook Token Management" do
    setup :pin_microsoft_credentials

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

      expect(HTTPClientMock, :request, fn :post, @token_url, body, _headers, _opts ->
        assert body =~ "grant_type=refresh_token"

        {:ok,
         %Req.Response{
           status: 400,
           body: Jason.encode!(%{"error" => "invalid_grant"})
         }}
      end)

      # Microsoft answers a revoked or expired refresh token with 400; the API
      # translates that into a reauth-worthy :unauthorized rather than a
      # retryable network error.
      assert CalendarAPI.refresh_token(expired) ==
               {:error, :unauthorized, "Token refresh failed"}
    end
  end

  describe "Outlook Calendar Synchronization" do
    setup do
      user = insert(:user)

      # A live access token keeps these tests on the Graph call itself rather
      # than diverting through the token-refresh path.
      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          is_active: true,
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      {:ok, user: user, integration: integration}
    end

    test "retrieves calendar events within date range", %{integration: integration} do
      start_time = DateTime.add(DateTime.utc_now(), -7, :day)
      end_time = DateTime.add(DateTime.utc_now(), 7, :day)

      graph_event = %{
        "id" => "AAMkAGI=",
        "subject" => "Quarterly review",
        "start" => %{"dateTime" => "2024-03-15T14:00:00", "timeZone" => "UTC"},
        "end" => %{"dateTime" => "2024-03-15T15:00:00", "timeZone" => "UTC"}
      }

      expect(HTTPClientMock, :request, fn :get, url, _body, headers, _opts ->
        assert String.starts_with?(url, "https://graph.microsoft.com/v1.0/me/calendarView")
        assert url =~ "startDateTime=#{URI.encode_www_form(DateTime.to_iso8601(start_time))}"
        assert url =~ "endDateTime=#{URI.encode_www_form(DateTime.to_iso8601(end_time))}"

        assert Enum.any?(headers, fn {k, v} ->
                 String.downcase(k) == "authorization" and v == "Bearer valid_token"
               end)

        {:ok, %Req.Response{status: 200, body: Jason.encode!(%{"value" => [graph_event]})}}
      end)

      # Graph events are returned verbatim; the string-keyed shape is what
      # `convert_to_common_format/1` downstream expects.
      assert CalendarAPI.list_primary_events(integration, start_time, end_time) ==
               {:ok, [graph_event]}
    end

    test "surfaces a Graph rejection of an inverted time range", %{integration: integration} do
      # Graph, not Tymeslot, validates the range: start after end comes back
      # as a 400 that the API maps to a network error.
      invalid_start = DateTime.add(DateTime.utc_now(), 7, :day)
      invalid_end = DateTime.add(DateTime.utc_now(), -7, :day)

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:ok,
         %Req.Response{
           status: 400,
           body:
             Jason.encode!(%{
               "error" => %{
                 "code" => "ErrorInvalidTimeRange",
                 "message" => "The start time must be before the end time."
               }
             })
         }}
      end)

      assert CalendarAPI.list_primary_events(integration, invalid_start, invalid_end) ==
               {:error, :network_error, "HTTP 400 (see logs for details)"}
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
      assert {:error, _error_reason} = result
    end
  end

  describe "Error Handling" do
    setup do
      user = insert(:user)

      integration =
        insert(:calendar_integration,
          user: user,
          provider: "outlook",
          access_token_encrypted: Encryption.encrypt("valid_token"),
          token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
        )

      {:ok, user: user, integration: integration}
    end

    test "handles connection failures gracefully", %{integration: integration} do
      start_time = DateTime.utc_now()
      end_time = DateTime.add(start_time, 1, :hour)

      expect(HTTPClientMock, :request, fn :get, _url, _body, _headers, _opts ->
        {:error, %Req.TransportError{reason: :econnrefused}}
      end)

      assert {:error, :network_error, message} =
               CalendarAPI.list_primary_events(integration, start_time, end_time)

      assert message =~ "Network error:"
      assert message =~ "econnrefused"
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
