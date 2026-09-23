defmodule TymeslotWeb.OAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :auth

  import Tymeslot.Factory, only: [insert: 2]
  import Tymeslot.Test.OAuthProviderStub

  alias Phoenix.Flash
  alias Plug.Conn
  alias Plug.Test
  alias Req.Test, as: ReqTest
  alias Tymeslot.Auth.Session
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Test.LogCapture

  setup do
    original_social_auth = Application.get_env(:tymeslot, :social_auth)

    try do
      :meck.unload(RateLimiter)
    rescue
      _other -> :ok
    end

    :meck.new(RateLimiter, [:passthrough])

    # Ensure dashboard cache is running for invalidate_integration_status
    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(RateLimiter)
      rescue
        _other -> :ok
      end

      if is_nil(original_social_auth) do
        Application.delete_env(:tymeslot, :social_auth)
      else
        Application.put_env(:tymeslot, :social_auth, original_social_auth)
      end
    end)

    :ok
  end

  describe "GET /auth/:provider" do
    test "initiates github auth", %{conn: conn} do
      # Mock social auth config
      Application.put_env(:tymeslot, :social_auth, github_enabled: true)

      conn = get(conn, ~p"/auth/github")

      # Should redirect to github
      assert redirected_to(conn) =~ "github.com/login/oauth/authorize"
    end

    test "initiates google auth", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, google_enabled: true)

      conn = get(conn, ~p"/auth/google")

      assert redirected_to(conn) =~ "accounts.google.com/o/oauth2/v2/auth"
    end

    test "redirects if provider disabled", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, github_enabled: false)

      conn = get(conn, ~p"/auth/github")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "GitHub authentication is not available"
    end

    test "handles unsupported provider", %{conn: conn} do
      conn = get(conn, ~p"/auth/unsupported")
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Unsupported OAuth provider"
    end

    test "handles rate limited initiation", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, github_enabled: true)

      :meck.expect(RateLimiter, :check_oauth_initiation_rate_limit, fn _ip ->
        {:error, :rate_limited, "Too many attempts"}
      end)

      conn = get(conn, ~p"/auth/github")
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many OAuth attempts"
    end

    test "initiates generic oauth auth when enabled", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, oauth_enabled: true)

      Application.put_env(:tymeslot, :oauth_provider,
        client_id: "test-id",
        client_secret: "test-secret",
        site: "https://idp.example.com",
        authorize_url: "https://idp.example.com/authorize",
        token_url: "https://idp.example.com/token",
        userinfo_url: "https://idp.example.com/userinfo",
        scope: "openid email profile"
      )

      on_exit(fn -> Application.delete_env(:tymeslot, :oauth_provider) end)

      conn = get(conn, ~p"/auth/oauth")

      assert redirected_to(conn) =~ "idp.example.com/authorize"
    end

    test "redirects if generic oauth provider disabled", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, oauth_enabled: false)

      conn = get(conn, ~p"/auth/oauth")

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "SSO authentication is not available"
    end
  end

  describe "GET /auth/:provider/callback" do
    setup :setup_providers

    test "successful login: puts success flash and redirects", %{conn: conn} do
      insert(:user, provider: "github", github_user_id: "123")
      stub_github(%{"id" => 123}, [])

      conn = sign_in(conn, "github")

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with GitHub."
      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :user_token)
    end

    test "registration required: stores data in session and redirects to /auth/complete-registration",
         %{conn: conn} do
      stub_github(%{"id" => 123, "name" => "Test User"}, [
        %{"email" => "user@example.com", "primary" => true, "verified" => true}
      ])

      conn = sign_in(conn, "github", %{"registration_path" => "/custom/registration"})

      # A registration_path parameter is ignored.
      assert redirected_to(conn) == "/auth/complete-registration"
      assert session_data = get_session(conn, :pending_oauth_registration)
      assert session_data.provider == "github"
      assert session_data.email == "user@example.com"
      assert session_data.provider_uid == "123"
    end

    test "a provider switched off mid-flow signs no one in", %{conn: conn} do
      insert(:user, provider: "github", github_user_id: "130")
      stub_github(%{"id" => 130}, [])

      start = get(conn, ~p"/auth/github")
      %{"state" => state} = start |> redirected_to(302) |> authorise_params()

      social_auth = Application.get_env(:tymeslot, :social_auth)

      Application.put_env(
        :tymeslot,
        :social_auth,
        Keyword.put(social_auth, :github_enabled, false)
      )

      conn =
        start
        |> recycle()
        |> get(~p"/auth/github/callback", %{"code" => "code", "state" => state})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) == "GitHub authentication is not available"
      refute get_session(conn, :user_token)
    end

    test "invalid state: puts security error flash and redirects to login", %{conn: conn} do
      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end

    test "OAuth error: puts provider error flash and redirects to login", %{conn: conn} do
      stub_provider(%{"/token" => &Conn.send_resp(&1, 400, ~s({"error":"invalid_grant"}))})

      conn = sign_in(conn, "google")

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with Google."
    end

    test "general error: puts provider error flash and redirects to login", %{conn: conn} do
      stub_provider(%{
        "/login/oauth/access_token" => &ReqTest.transport_error(&1, :timeout)
      })

      conn = sign_in(conn, "github")

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "An error occurred during GitHub authentication."
    end

    test "session failed: puts session failure flash and redirects to login", %{conn: conn} do
      insert(:user, provider: "github", github_user_id: "124")
      stub_github(%{"id" => 124}, [])

      # Nothing a test can arrange makes a real session insert fail.
      :meck.new(Session, [:passthrough])
      on_exit(fn -> :meck.unload() end)
      :meck.expect(Session, :create_session, fn _conn, _user -> {:error, :db_error, "failed"} end)

      conn = sign_in(conn, "github")

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "session creation failed"
    end

    test "an unverified account is sent to the verify-email screen", %{conn: conn} do
      insert(:user, provider: "github", github_user_id: "125", verified_at: nil)
      stub_github(%{"id" => 125}, [])

      conn = sign_in(conn, "github")

      assert redirected_to(conn) == "/auth/verify-email"
      refute get_session(conn, :user_token)

      assert Flash.get(conn.assigns.flash, :info) ==
               "Please verify your email address before signing in. We've sent you a new verification link."
    end

    test "rejects OAuth callback without authorization code", %{conn: conn} do
      conn = get(conn, ~p"/auth/google/callback", %{"state" => "some_state"})

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Google authentication failed - missing authorization code"
    end

    test "handles user cancellation gracefully", %{conn: conn} do
      conn =
        get(conn, ~p"/auth/google/callback", %{
          "error" => "access_denied",
          "error_description" => "User denied access"
        })

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "Google authentication failed - missing authorization code"
    end

    test "handles rate limited callback", %{conn: conn} do
      :meck.expect(RateLimiter, :check_oauth_callback_rate_limit, fn _ip ->
        {:error, :rate_limited, "Too many attempts"}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many authentication attempts"
    end

    test "redirects to login with info flash when registration is disabled for new user", %{
      conn: conn
    } do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        if is_nil(original),
          do: Application.delete_env(:tymeslot, :registration_enabled),
          else: Application.put_env(:tymeslot, :registration_enabled, original)
      end)

      stub_github(%{"id" => 126}, [])

      conn = sign_in(conn, "github")

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end

    test "redirects to login with an error when the email belongs to another sign-in method",
         %{conn: conn} do
      insert(:user, email: "taken@example.com", provider: "google", google_user_id: "g-1")

      stub_github(%{"id" => 127}, [
        %{"email" => "taken@example.com", "primary" => true, "verified" => true}
      ])

      conn = sign_in(conn, "github")

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "already associated with another account"
    end

    test "successful generic oauth callback redirects to dashboard", %{conn: conn} do
      insert(:user, provider: "oauth", provider_uid: "sub-1")
      stub_sso(%{"sub" => "sub-1"})

      conn = sign_in(conn, "oauth")

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with SSO."
      assert redirected_to(conn) == "/dashboard"
    end

    test "respects valid internal success_path", %{conn: conn} do
      insert(:user, provider: "github", github_user_id: "128")
      stub_github(%{"id" => 128}, [])

      conn = sign_in(conn, "github", %{"success_path" => "/settings"})

      assert redirected_to(conn) == "/settings"
    end

    for evil <- ["/%2f%2fevil.com", "https://evil.com/steal", "//evil.com/steal"] do
      test "rejects the open redirect #{evil} via success_path", %{conn: conn} do
        insert(:user, provider: "github", github_user_id: "129")
        stub_github(%{"id" => 129}, [])

        conn = sign_in(conn, "github", %{"success_path" => unquote(evil)})

        assert redirected_to(conn) == "/dashboard"
      end
    end

    test "rejects a callback for an unknown provider before the rate limit or callback handler",
         %{conn: conn} do
      :meck.expect(RateLimiter, :check_oauth_callback_rate_limit, fn _ip ->
        flunk("an unknown provider must be rejected before rate limiting")
      end)

      conn =
        get(conn, "/auth/unsupported/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/auth/login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Unsupported OAuth provider: unsupported"
    end

    test "generic oauth callback without code redirects with error", %{conn: conn} do
      conn = get(conn, ~p"/auth/oauth/callback", %{"state" => "some_state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "SSO authentication failed"
    end
  end

  describe "POST /auth/complete social auth auditing" do
    defp social_auth_events do
      LogCapture.drain()
      |> Enum.map(&LogCapture.user_metadata/1)
      |> Enum.filter(&(&1[:event_type] in ["social_auth_success", "social_auth_failure"]))
    end

    test "first-time signup logs a social_auth_success entry", %{conn: conn} do
      Application.put_env(:tymeslot, :social_auth, github_enabled: true)

      session_data = %{
        provider: "github",
        email: "new@example.com",
        name: "New User",
        email_from_provider: true,
        github_user_id: "12345",
        created_at: System.system_time(:second)
      }

      conn = Test.init_test_session(conn, %{pending_oauth_registration: session_data})

      LogCapture.with_capture([logger_level: :info], fn ->
        conn = post(conn, ~p"/auth/complete", %{"terms_accepted" => "on"})

        assert redirected_to(conn) == "/dashboard"
      end)

      assert [event] = social_auth_events()
      assert event.event_type == "social_auth_success"
      assert event.provider == "github"
      assert event.email_masked == "n***@example.com"
    end
  end
end
