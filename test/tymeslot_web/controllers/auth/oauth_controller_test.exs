defmodule TymeslotWeb.OAuthControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :utils

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

    test "registration required: redirects to /auth/complete-registration with params", %{conn: conn} do
      registration_params = %{
        "auth" => "oauth_complete",
        "oauth_provider" => "github",
        "oauth_email" => "user@example.com",
        "oauth_missing" => "name"
      }

      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:registration_required, conn, :github, registration_params}
      end)

      conn = get(conn, ~p"/auth/github/callback", %{"code" => "code", "state" => "state"})

      location = redirected_to(conn)
      assert String.starts_with?(location, "/auth/complete-registration?")
      query = location |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
      assert query["auth"] == "oauth_complete"
      assert query["oauth_provider"] == "github"
    end

    test "registration_path query param is ignored; always redirects to /auth/complete-registration", %{conn: conn} do
      :meck.expect(OAuthHelper, :handle_oauth_callback, fn conn,
                                                           %{code: "code", state: "state", provider: :github} ->
        {:registration_required, conn, :github, %{"auth" => "oauth_complete", "oauth_provider" => "github"}}
      end)

      conn =
        get(conn, ~p"/auth/github/callback", %{
          "code" => "code",
          "state" => "state",
          "registration_path" => "/custom/registration"
        })

      assert String.starts_with?(redirected_to(conn), "/auth/complete-registration")
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
      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "new@example.com",
        "oauth_github_id" => "12345",
        "oauth_name" => "New User",
        "terms_accepted" => "on"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user = Factory.insert(:user, email: "new@example.com", provider: "github")
        {:ok, user}
      end)

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Successfully signed up"
    end

    test "requires terms acceptance when enforced", %{conn: conn} do
      Application.put_env(:tymeslot, :enforce_legal_agreements, true)

      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "new@example.com",
        "oauth_github_id" => "12345"
      }

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "must accept the terms"
    end

    test "fails if email missing", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "github",
        "oauth_github_id" => "12345",
        "terms_accepted" => "on"
      }

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "creates user and requires email verification if needed", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "unverified@example.com",
        "oauth_github_id" => "12345",
        "oauth_verified" => "false",
        "terms_accepted" => "on"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user =
          Factory.insert(:user,
            email: "unverified@example.com",
            provider: "github",
            verified_at: nil
          )

        # Add the virtual field that the controller checks
        user = Map.put(user, :needs_email_verification, true)
        {:ok, user}
      end)

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Please check your email to verify"
    end

    test "handles user creation failure with changeset", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "fail@example.com",
        "oauth_github_id" => "12345",
        "terms_accepted" => "on"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        changeset = Changeset.add_error(%Changeset{}, :email, "can't be blank")
        {:error, changeset}
      end)

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) =~ "/auth/complete-registration"
      assert Flash.get(conn.assigns.flash, :error) =~ "Email address is required"
    end

    test "handles user creation failure with other errors", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "error@example.com",
        "oauth_github_id" => "12345",
        "terms_accepted" => "on"
      }

      :meck.expect(OAuthHelper, :create_oauth_user, fn :github, _data, _profile, _opts ->
        {:error, :user_creation_failed}
      end)

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Failed to create user account"
    end

    test "rejects unsupported oauth_provider", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "totally_new_provider",
        "oauth_email" => "new@example.com"
      }

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Unsupported OAuth provider"
    end

    test "handles rate limited completion", %{conn: conn} do
      :meck.expect(RateLimiter, :check_oauth_completion_rate_limit, fn _ip ->
        {:error, :rate_limited, "Too many attempts"}
      end)

      conn = post(conn, ~p"/auth/complete", %{"oauth_provider" => "github"})
      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :error) =~ "Too many registration attempts"
    end

    test "creates generic oauth user and logs in", %{conn: conn} do
      user_data = %{
        "oauth_provider" => "oauth",
        "oauth_email" => "sso@example.com",
        "oauth_provider_uid" => "sub-12345",
        "oauth_name" => "SSO User",
        "terms_accepted" => "on"
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

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/dashboard"
      assert Flash.get(conn.assigns.flash, :info) =~ "Successfully signed up"
    end

    test "redirects to login with info flash when registration is disabled", %{conn: conn} do
      original_value = Application.get_env(:tymeslot, :registration_enabled, true)
      Application.put_env(:tymeslot, :registration_enabled, false)

      on_exit(fn ->
        Application.put_env(:tymeslot, :registration_enabled, original_value)
      end)

      user_data = %{
        "oauth_provider" => "github",
        "oauth_email" => "new@example.com",
        "oauth_github_id" => "12345",
        "terms_accepted" => "on"
      }

      conn = post(conn, ~p"/auth/complete", user_data)

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end
  end
end
