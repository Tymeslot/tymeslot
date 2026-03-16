defmodule TymeslotWeb.OAuthCompletionControllerTest do
  use TymeslotWeb.ConnCase, async: false
  @moduletag :auth

  alias Ecto.Changeset
  alias Phoenix.Flash
  alias Plug.Test
  alias Tymeslot.Auth.OAuth.UserRegistration
  alias Tymeslot.Factory
  alias Tymeslot.Security.RateLimiter

  setup do
    try do
      :meck.unload(UserRegistration)
    rescue
      _other -> :ok
    end

    try do
      :meck.unload(RateLimiter)
    rescue
      _other -> :ok
    end

    :meck.new(UserRegistration, [:passthrough])
    :meck.new(RateLimiter, [:passthrough])

    on_exit(fn ->
      try do
        :meck.unload(UserRegistration)
      rescue
        _other -> :ok
      end

      try do
        :meck.unload(RateLimiter)
      rescue
        _other -> :ok
      end
    end)

    :ok
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user = Factory.insert(:user, email: "new@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github, _data, _profile, _opts ->
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{
          "auth" => %{"email" => "unverified@example.com"},
          "terms_accepted" => "on"
        })

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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github, _data, _profile, _opts ->
        changeset = Changeset.add_error(%Changeset{}, :email, "can't be blank")
        {:error, changeset}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github, _data, _profile, _opts ->
        {:error, :user_creation_failed}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :oauth, _data, _profile, _opts ->
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github, _data, _profile, _opts ->
        user = Factory.insert(:user, email: "cleanup@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :github,
                                                            oauth_data,
                                                            _profile,
                                                            _opts ->
        # Verify the provider from session is used, not any form-submitted value
        assert oauth_data.provider == "github"
        assert oauth_data.email == "session@example.com"
        user = Factory.insert(:user, email: "session@example.com", provider: "github")
        {:ok, user}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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

      :meck.expect(UserRegistration, :create_oauth_user, fn :oauth, oauth_data, _profile, _opts ->
        assert oauth_data.email == "user-provided@example.com"
        assert oauth_data.email_from_provider == false
        user = Factory.insert(:user, email: "user-provided@example.com", provider: "oauth")
        {:ok, user}
      end)

      conn =
        conn
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
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
        |> Test.init_test_session(%{pending_oauth_registration: session_data})
        |> post(~p"/auth/complete", %{"terms_accepted" => "on"})

      assert redirected_to(conn) == "/auth/login"
      assert Flash.get(conn.assigns.flash, :info) =~ "Registration is currently disabled"
    end
  end
end
