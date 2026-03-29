defmodule TymeslotWeb.OAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :auth

  import Mox

  alias Phoenix.Flash
  alias Tymeslot.Auth.OAuth.HelperMock
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Security.RateLimiter

  setup :verify_on_exit!

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
    test "successful login: puts success flash and redirects", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:ok, conn, :github}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with GitHub."
      # Redirect goes to configured success path; verify it's a valid internal path.
      assert String.starts_with?(redirected_to(conn), "/")
    end

    test "registration required: stores data in session and redirects to /auth/complete-registration",
         %{conn: conn} do
      registration_data = %{
        provider: "github",
        email: "user@example.com",
        name: "Test User",
        is_verified: true,
        email_from_provider: true,
        provider_uid: "",
        github_user_id: 123,
        google_user_id: nil
      }

      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:registration_required, conn, :github, registration_data}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/auth/complete-registration"
      assert session_data = get_session(conn, :pending_oauth_registration)
      assert session_data.provider == "github"
      assert session_data.email == "user@example.com"
      assert session_data.github_user_id == 123
    end

    test "registration_path query param is ignored; always redirects to /auth/complete-registration",
         %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:registration_required, conn, :github, %{provider: "github", email: "u@e.com"}}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "registration_path" => "/custom/registration"
        })

      assert redirected_to(conn) == "/auth/complete-registration"
    end

    test "invalid state: puts security error flash and redirects to login", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:error, :invalid_state, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) ==
               "Security validation failed. Please try again."
    end

    test "OAuth error: puts provider error flash and redirects to login", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :google
                                                      } ->
        {:error, :oauth_error, :google, conn}
      end)

      conn = get(conn, ~p"/auth/google/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with Google."
    end

    test "general error: puts provider error flash and redirects to login", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:error, :general_error, :github, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"

      assert Flash.get(conn.assigns.flash, :error) =~
               "An error occurred during GitHub authentication."
    end

    test "session failed: puts session failure flash and redirects to login", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:error, :session_failed, :github, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "session creation failed"
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
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:error, :registration_disabled, :github, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end

    test "successful generic oauth callback redirects to dashboard", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :oauth
                                                      } ->
        {:ok, conn, :oauth}
      end)

      conn = get(conn, ~p"/auth/oauth/callback", %{"code" => "code", "state" => "state"})

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with SSO."
      assert String.starts_with?(redirected_to(conn), "/")
    end

    test "respects valid internal success_path", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:ok, conn, :github}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "success_path" => "/settings"
        })

      assert redirected_to(conn) == "/settings"
    end

    test "rejects URL-encoded open redirect via success_path", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:ok, conn, :github}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "success_path" => "/%2f%2fevil.com"
        })

      redirect = redirected_to(conn)
      refute redirect =~ "evil.com"
    end

    test "rejects open redirect via success_path parameter", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:ok, conn, :github}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "success_path" => "https://evil.com/steal"
        })

      # Should redirect to default success path, NOT to the evil URL
      redirect = redirected_to(conn)
      refute redirect =~ "evil.com"
      assert String.starts_with?(redirect, "/")
    end

    test "rejects protocol-relative redirect via success_path", %{conn: conn} do
      Mox.stub(HelperMock, :handle_oauth_callback, fn conn,
                                                      %{
                                                        code: "code",
                                                        state: "state",
                                                        provider: :github
                                                      } ->
        {:ok, conn, :github}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "success_path" => "//evil.com/steal"
        })

      redirect = redirected_to(conn)
      refute redirect =~ "evil.com"
      assert String.starts_with?(redirect, "/")
    end

    test "generic oauth callback without code redirects with error", %{conn: conn} do
      conn = get(conn, ~p"/auth/oauth/callback", %{"state" => "some_state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "SSO authentication failed"
    end
  end
end
