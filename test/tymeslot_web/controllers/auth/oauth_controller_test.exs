defmodule TymeslotWeb.OAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :auth

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Tymeslot.Auth.OAuth.Helper, as: OAuthHelper
  alias Tymeslot.Factory
  alias Tymeslot.Infrastructure.DashboardCache
  alias Tymeslot.Security.RateLimiter

  setup do
    original_social_auth = Application.get_env(:tymeslot, :social_auth)

    try do
      :meck.unload(OAuthHelper)
    rescue
      _other -> :ok
    end

    try do
      :meck.unload(RateLimiter)
    rescue
      _other -> :ok
    end

    :meck.new(OAuthHelper, [:passthrough])
    :meck.new(RateLimiter, [:passthrough])

    # Ensure dashboard cache is running for invalidate_integration_status
    case Process.whereis(DashboardCache) do
      nil -> DashboardCache.start_link([])
      _pid -> :ok
    end

    on_exit(fn ->
      try do
        :meck.unload(OAuthHelper)
      rescue
        _other -> :ok
      end

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
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:ok, conn, :github}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with GitHub."
      # Redirect goes to configured success path; verify it's a valid internal path.
      assert String.starts_with?(redirected_to(conn), "/")
    end

    test "registration required: stores data in session and redirects to /auth/complete-registration", %{conn: conn} do
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

      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:registration_required, conn, :github, registration_data}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/auth/complete-registration"
      assert session_data = get_session(conn, :pending_oauth_registration)
      assert session_data.provider == "github"
      assert session_data.email == "user@example.com"
      assert session_data.github_user_id == 123
    end

    test "registration_path query param is ignored; always redirects to /auth/complete-registration", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:error, :invalid_state, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) == "Security validation failed. Please try again."
    end

    test "OAuth error: puts provider error flash and redirects to login", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :google} ->
        {:error, :oauth_error, :google, conn}
      end)

      conn = get(conn, ~p"/auth/google/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) == "Failed to authenticate with Google."
    end

    test "general error: puts provider error flash and redirects to login", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:error, :general_error, :github, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :error) =~ "An error occurred during GitHub authentication."
    end

    test "session failed: puts session failure flash and redirects to login", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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

    test "redirects to login with info flash when registration is disabled for new user", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:error, :registration_disabled, :github, conn}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      assert redirected_to(conn) == "/?auth=login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end

    test "successful generic oauth callback redirects to dashboard", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :oauth} ->
        {:ok, conn, :oauth}
      end)

      conn = get(conn, ~p"/auth/oauth/callback", %{"code" => "code", "state" => "state"})

      assert Flash.get(conn.assigns.flash, :info) == "Successfully signed in with SSO."
      assert String.starts_with?(redirected_to(conn), "/")
    end

    test "respects valid internal success_path", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
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

  describe "POST /auth/complete" do
    setup do
      original_value = Application.get_env(:tymeslot, :enforce_legal_agreements, false)
      Application.put_env(:tymeslot, :enforce_legal_agreements, false)
      :meck.expect(RateLimiter, :check_oauth_completion_rate_limit, fn _ip -> :ok end)

      on_exit(fn ->
        Application.put_env(:tymeslot, :enforce_legal_agreements, original_value)
      end)

      :ok
    end

    test "creates user and logs in", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "new@example.com",
        name: "New User",
        is_verified: true,
        email_from_provider: true,
        provider_uid: "",
        github_user_id: 12_345,
        google_user_id: nil
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user = Factory.insert(:user, email: "new@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Successfully signed up"
    end

    test "requires terms acceptance when enforced", %{conn: conn} do
      Application.put_env(:tymeslot, :enforce_legal_agreements, true)

      session_data = %{
        provider: "github",
        email: "new@example.com",
        is_verified: true,
        email_from_provider: true,
        github_user_id: 12_345
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "must accept the terms"
    end

    test "fails if email missing", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: nil,
        is_verified: false,
        email_from_provider: false,
        github_user_id: 12_345
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "creates user and requires email verification if needed", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "unverified@example.com",
        is_verified: false,
        email_from_provider: false,
        github_user_id: 12_345
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user =
          Factory.insert(:user,
            email: "unverified@example.com",
            provider: "github",
            verified_at: nil
          )

        user = Map.put(user, :needs_email_verification, true)
        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"auth" => %{"email" => "unverified@example.com"}, "terms_accepted" => "on"})

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Please check your email to verify"
    end

    test "handles user creation failure with changeset", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "fail@example.com",
        is_verified: true,
        email_from_provider: true,
        github_user_id: 12_345
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        changeset = Changeset.add_error(%Changeset{}, :email, "can't be blank")
        {:error, changeset}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "handles user creation failure with other errors", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "error@example.com",
        is_verified: true,
        email_from_provider: true,
        github_user_id: 12_345
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        {:error, :user_creation_failed}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to create user account"
    end

    test "redirects to login when no session data present", %{conn: conn} do
      conn = post(conn, ~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Missing OAuth provider information"
    end

    test "handles rate limited completion", %{conn: conn} do
      :meck.expect(RateLimiter, :check_oauth_completion_rate_limit, fn _ip ->
        {:error, :rate_limited, "Too many attempts"}
      end)

      conn = post(conn, ~p"/auth/complete", %{})
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many registration attempts"
    end

    test "creates generic oauth user and logs in", %{conn: conn} do
      session_data = %{
        provider: "oauth",
        email: "sso@example.com",
        name: "SSO User",
        is_verified: true,
        email_from_provider: true,
        provider_uid: "sub-12345"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :oauth, _data, _profile, _opts ->
        user =
          Factory.insert(:user,
            email: "sso@example.com",
            provider: "oauth",
            provider_uid: "sub-12345"
          )

        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Successfully signed up"
    end

    test "clears session data after successful completion", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "cleanup@example.com",
        name: "Cleanup User",
        is_verified: true,
        email_from_provider: true,
        provider_uid: "",
        github_user_id: 99_999,
        google_user_id: nil
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user = Factory.insert(:user, email: "cleanup@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/dashboard"
      assert get_session(conn, :pending_oauth_registration) == nil
    end

    test "clears session on unsupported provider", %{conn: conn} do
      session_data = %{
        provider: "totally_unsupported",
        email: "bad@example.com",
        is_verified: true,
        email_from_provider: true
      }

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Unsupported OAuth provider"
      assert get_session(conn, :pending_oauth_registration) == nil
    end

    test "session data takes precedence over form-submitted provider", %{conn: conn} do
      session_data = %{
        provider: "github",
        email: "session@example.com",
        name: "Session User",
        is_verified: true,
        email_from_provider: true,
        provider_uid: "",
        github_user_id: 99_999,
        google_user_id: nil
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, oauth_data, _profile, _opts ->
        # Verify the provider from session is used, not any form-submitted value
        assert oauth_data.provider == "github"
        assert oauth_data.email == "session@example.com"
        user = Factory.insert(:user, email: "session@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{
          "auth" => %{
            "provider" => "google",
            "email" => "attacker@evil.com"
          },
          "terms_accepted" => "on"
        })

      assert redirected_to(conn) == "/dashboard"
    end

    test "uses user-provided email when email_from_provider is false", %{conn: conn} do
      session_data = %{
        provider: "oauth",
        email: nil,
        name: "SSO User",
        is_verified: false,
        email_from_provider: false,
        provider_uid: "sub-123"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :oauth, oauth_data, _profile, _opts ->
        assert oauth_data.email == "user-provided@example.com"
        assert oauth_data.email_from_provider == false
        user = Factory.insert(:user, email: "user-provided@example.com", provider: "oauth")
        {:ok, user}
      end)

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{
          "auth" => %{"email" => "user-provided@example.com"},
          "terms_accepted" => "on"
        })

      assert redirected_to(conn) == "/dashboard"
    end

    test "redirects to login with info flash when registration is disabled", %{conn: conn} do
      original_value = Application.get_env(:tymeslot, :registration_enabled, true)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        Application.put_env(:tymeslot, :registration_enabled, original_value)
      end)

      session_data = %{provider: "github", email: "new@example.com", github_user_id: 12_345}

      conn =
        conn
        |> Plug.Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end
  end
end
