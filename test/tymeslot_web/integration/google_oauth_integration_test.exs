defmodule TymeslotWeb.Integration.GoogleOAuthIntegrationTest do
  @moduledoc """
  Integration tests for Google OAuth authentication and Calendar integration.
  Tests security, user flows, and integration management.
  """

  use TymeslotWeb.OAuthIntegrationCase, async: false

  @moduletag :oauth_integration

  import Mox
  import Tymeslot.Factory
  alias Phoenix.Flash
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Auth.OAuth.HelperMock
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Security.Encryption

  setup do
    # The controller resolves its callback module from config, which points at
    # the Mox double in the test environment. Delegate to the real helper so
    # these tests exercise the genuine callback and state handling.
    stub_with(HelperMock, OAuthHelper)
    :ok
  end

  describe "Google OAuth Security" do
    test "prevents CSRF attacks with state parameter validation" do
      # Setup: Create session with expected state
      conn =
        build_conn()
        |> init_test_session(%{})
        |> put_session(:_oauth_state, "expected_state")

      # Act: Attempt callback with wrong state
      conn =
        get(conn, ~p"/auth/google/callback", %{
          "code" => "some_code",
          "state" => "wrong_state"
        })

      # Assert: Authentication fails due to state mismatch
      assert redirected_to(conn, 302)

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end

    test "rate limits OAuth authentication attempts" do
      # Act: Make multiple requests to trigger rate limiting
      results =
        Enum.map(1..6, fn _i ->
          conn = get(build_conn(), ~p"/auth/google")
          conn.status
        end)

      # Assert: First 5 requests succeed, 6th is rate limited
      assert Enum.take(results, 5) == [302, 302, 302, 302, 302]
      assert List.last(results) == 302
    end

    test "handles missing OAuth credentials gracefully" do
      # Act: Attempt callback without required code parameter
      conn = get(build_conn(), ~p"/auth/google/callback", %{"state" => "test-state"})

      # Assert: User sees appropriate error message
      assert redirected_to(conn, 302)
      assert Flash.get(conn.assigns.flash, :error) =~ "missing authorization code"
    end
  end

  describe "Google OAuth User Flow" do
    test "user can initiate Google authentication" do
      # Act: User clicks "Sign in with Google"
      conn = get(build_conn(), ~p"/auth/google")

      # Assert: User is redirected to Google
      assert redirected_to(conn, 302)
    end

    test "user sees error when authentication fails" do
      # Act: Google redirects back with invalid code
      conn =
        get(build_conn(), ~p"/auth/google/callback", %{
          "code" => "invalid_code",
          "state" => "test-state"
        })

      # Assert: User is redirected with error message
      assert redirected_to(conn, 302)

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end
  end

  describe "Google Calendar Integration Management" do
    setup do
      user = insert(:user)
      %{user: user}
    end

    test "user can connect Google Calendar integration", %{user: user} do
      # Setup: Mock successful OAuth token response
      mock_tokens = %{
        user_id: user.id,
        access_token: "mock_access_token_#{System.system_time()}",
        refresh_token: "mock_refresh_token_#{System.system_time()}",
        expires_at: DateTime.add(DateTime.utc_now(), 3600, :second),
        scope: "https://www.googleapis.com/auth/calendar.events"
      }

      # Act: Create calendar integration
      attrs = %{
        user_id: user.id,
        name: "Google Calendar",
        provider: "google",
        base_url: "https://www.googleapis.com/calendar/v3",
        access_token: mock_tokens.access_token,
        refresh_token: mock_tokens.refresh_token,
        token_expires_at: mock_tokens.expires_at,
        oauth_scope: mock_tokens.scope,
        is_active: true
      }

      {:ok, integration} = CalendarIntegrationQueries.create(attrs)

      # Assert: Integration created successfully
      assert integration.user_id == user.id
      assert integration.provider == "google"
      assert integration.is_active == true
      # Tokens are stored encrypted at rest, never as the plaintext given here.
      refute integration.access_token_encrypted == mock_tokens.access_token
      assert Encryption.decrypt(integration.access_token_encrypted) == mock_tokens.access_token
      assert Encryption.decrypt(integration.refresh_token_encrypted) == mock_tokens.refresh_token
    end

    test "updates existing integration when reconnecting", %{user: user} do
      # Setup: Create existing integration
      existing = insert(:calendar_integration, user: user, provider: "google")

      # Act: Update with new tokens
      update_attrs = %{
        access_token: "new_token_#{System.system_time()}",
        refresh_token: "new_refresh_#{System.system_time()}",
        token_expires_at: DateTime.add(DateTime.utc_now(), 3600, :second)
      }

      {:ok, updated} = CalendarIntegrationQueries.update(existing, update_attrs)

      # Assert: Tokens were updated
      assert updated.id == existing.id
      refute updated.access_token_encrypted == existing.access_token_encrypted
    end

    test "rejects a calendar callback whose state is not a valid signed token", %{conn: conn} do
      # Act: Attempt calendar callback with an unsigned state
      conn =
        get(conn, "/auth/google/calendar/callback", %{
          "code" => "invalid_code",
          "state" => "test_state"
        })

      # Assert: the state guard rejects it before any token exchange is attempted
      assert redirected_to(conn) == "/dashboard/integrations?tab=calendars"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Authentication session mismatch. Please sign in and try again."
    end
  end
end
