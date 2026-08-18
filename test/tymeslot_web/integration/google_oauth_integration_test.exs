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

  # `RateLimiter.OAuth.check_initiation/1` allows this many initiations per IP
  # per 600s window; the next one is refused.
  @initiation_limit 10

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

    test "rate limits OAuth initiation once the per-IP allowance is spent" do
      enable_social_auth(:google_enabled)

      # Act: Spend the whole per-IP initiation allowance, then ask once more.
      allowed = Enum.map(1..@initiation_limit, fn _i -> get(build_conn(), ~p"/auth/google") end)
      blocked = get(build_conn(), ~p"/auth/google")

      # Assert: Every allowed attempt hands the visitor to Google, with no error
      for conn <- allowed do
        assert redirected_to(conn, 302) =~ "google.com"
        assert is_nil(Flash.get(conn.assigns.flash, :error))
      end

      # Assert: The one over the limit is turned back to the login page instead.
      # Both outcomes are 302s, so the destination and the flash are what
      # distinguish them.
      assert redirected_to(blocked, 302) == "/auth/login"

      assert Flash.get(blocked.assigns.flash, :error) ==
               "Too many OAuth attempts. Please try again later."
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
      enable_social_auth(:google_enabled)
      put_env("GOOGLE_CLIENT_ID", "test-google-client-id")

      # Act: User clicks "Sign in with Google"
      conn = get(build_conn(), ~p"/auth/google")

      # Assert: the redirect is Google's authorize endpoint, carrying every
      # parameter the handshake needs. A 302 on its own proves nothing here:
      # the "provider not available" and rate-limited paths are 302s too.
      uri = conn |> redirected_to(302) |> URI.parse()
      query = URI.decode_query(uri.query)
      {stored_state, _issued_at} = get_session(conn, :_oauth_state)

      assert "#{uri.scheme}://#{uri.host}#{uri.path}" ==
               "https://accounts.google.com/o/oauth2/v2/auth"

      assert query["client_id"] == "test-google-client-id"
      assert query["response_type"] == "code"
      assert query["scope"] == "email profile"
      assert query["prompt"] == "select_account"
      assert query["redirect_uri"] =~ "/auth/google/callback"

      # The state travelling to Google must be the one the server stored, or
      # the callback's CSRF check could never match it.
      assert query["state"] == stored_state
      assert stored_state != ""
    end

    test "callback with no stored state is rejected before the code is exchanged" do
      # Act: Google redirects back, but this browser's session carries no
      # `:_oauth_state` — the initiation leg never ran, or the session was lost.
      conn =
        get(build_conn(), ~p"/auth/google/callback", %{
          "code" => "invalid_code",
          "state" => "test-state"
        })

      # Assert: the state gate turns the visitor back. The exact wording matters:
      # a failed *token exchange* flashes "An error occurred during Google
      # authentication.", so this message is what proves "invalid_code" was
      # never sent to Google at all.
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

  # Provider availability comes from env vars, so it cannot be assumed. Turn the
  # provider on for the duration of the test that needs the request to reach the
  # rate limiter rather than the "not available" redirect.
  defp enable_social_auth(provider_key) do
    original = Application.get_env(:tymeslot, :social_auth, [])
    Application.put_env(:tymeslot, :social_auth, Keyword.put(original, provider_key, true))
    on_exit(fn -> Application.put_env(:tymeslot, :social_auth, original) end)
  end

  # The OAuth client reads its credentials straight from the environment, so a
  # test that asserts on the client_id has to own the value it expects.
  defp put_env(name, value) do
    original = System.get_env(name)
    System.put_env(name, value)

    on_exit(fn ->
      case original do
        nil -> System.delete_env(name)
        original -> System.put_env(name, original)
      end
    end)
  end
end
