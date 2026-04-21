defmodule TymeslotWeb.AuthLiveTest do
  use TymeslotWeb.LiveCase, async: false
  @moduletag :auth

  alias Phoenix.Flash
  alias Tymeslot.Auth
  alias Tymeslot.Auth.AuthActions
  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.UserTokenQueries
  alias Tymeslot.Repo
  alias Tymeslot.Security.{Password, RateLimiter, Token}
  import Ecto.Query, only: [from: 2]
  import Tymeslot.Factory

  describe "Registration disabled" do
    setup do
      original = Application.get_env(:tymeslot, :registration_enabled)
      Application.put_env(:tymeslot, :registration_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :registration_enabled, original) end)
      :ok
    end

    test "redirects /auth/signup to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/signup")

      assert flash["info"] =~ AuthActions.registration_disabled_message()
    end

    test "redirects /auth/complete-registration to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/complete-registration")

      assert flash["info"] =~ AuthActions.registration_disabled_message()
    end

    test "hides sign up link on login page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/login")
      refute html =~ "Sign up"
    end

    test "blocks navigate_to signup event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "signup"})

      assert has_element?(view, "#login-form")
    end
  end

  describe "Password auth disabled" do
    setup do
      original = Application.get_env(:tymeslot, :password_auth_enabled)
      Application.put_env(:tymeslot, :password_auth_enabled, false)
      on_exit(fn -> Application.put_env(:tymeslot, :password_auth_enabled, original) end)
      :ok
    end

    test "redirects /auth/signup to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/signup")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/reset-password")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password?token=... (reset form) to login with flash", %{
      conn: conn
    } do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, "/auth/reset-password?token=sometoken")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "redirects /auth/reset-password-sent to login with flash", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/auth/login", flash: flash}}} =
               live(conn, ~p"/auth/reset-password-sent")

      assert flash["info"] =~ AuthActions.password_auth_disabled_message()
    end

    test "login page shows no password form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      refute has_element?(view, "#login-form")
      refute render(view) =~ "Forgot password?"
    end

    test "login page hides sign up footer link", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/login")

      refute html =~ "Sign up"
    end

    test "blocks navigate_to signup event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "signup"})

      refute has_element?(view, "#signup-form")
    end

    test "blocks navigate_to reset_password event", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      render_hook(view, "navigate_to", %{"state" => "reset_password"})

      refute has_element?(view, "#reset-password-form")
    end

    test "/auth/complete-registration still works", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth@example.com",
            name: nil,
            is_verified: true,
            email_from_provider: true,
            provider_uid: "12345",
            github_user_id: "12345",
            google_user_id: nil
          }
        })

      {:ok, view, _html} = live(conn, ~p"/auth/complete-registration")

      assert has_element?(view, "#complete-registration-form")
    end
  end

  describe "Login" do
    test "renders login page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")
      assert has_element?(view, "#login-form")
    end

    test "successful login with valid credentials", %{conn: conn} do
      password = "ValidPassword123!"
      user = insert(:user, password_hash: Password.hash_password(password))

      {:ok, view, _html} = live(conn, ~p"/auth/login")

      form =
        form(view, "#login-form", %{
          "email" => user.email,
          "password" => password
        })

      conn = submit_form(form, conn)
      assert redirected_to(conn) == "/dashboard"
    end

    test "fails login with invalid password", %{conn: conn} do
      user = insert(:user, password_hash: Password.hash_password("ValidPassword123!"))

      conn =
        post(conn, ~p"/auth/session", %{
          "email" => user.email,
          "password" => "WrongPassword"
        })

      assert Flash.get(conn.assigns.flash, :error) != nil
      assert redirected_to(conn) == ~p"/auth/login"
    end
  end

  describe "Registration" do
    test "renders signup page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/signup")
      assert has_element?(view, "#signup-form")
    end

    test "successful registration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/signup")

      email = "newuser@example.com"

      view
      |> form("#signup-form", %{
        "user" => %{
          "email" => email,
          "password" => "ValidPassword123!",
          "terms_accepted" => "true",
          # honeypot
          "website" => ""
        }
      })
      |> render_submit()

      assert render(view) =~ "Account created successfully"

      assert Auth.get_user_by_email(email)
    end

    test "validation errors on registration", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/signup")

      # Try to submit with invalid data to see errors
      result =
        view
        |> form("#signup-form", %{
          "user" => %{
            "email" => "invalid-email",
            "password" => "short"
          }
        })
        |> render_submit()

      assert result =~ "is invalid"
      assert result =~ "must be at least 8 characters"

      # Now test terms error with otherwise valid data
      result =
        view
        |> form("#signup-form", %{
          "user" => %{
            "email" => "valid@example.com",
            "password" => "ValidPassword123!"
          }
        })
        |> render_submit()

      assert result =~ "must be accepted"
    end
  end

  describe "Password Reset" do
    test "initiates password reset", %{conn: conn} do
      user = insert(:user)
      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      view
      |> form("#reset-password-form", %{"email" => user.email})
      |> render_submit()

      assert render(view) =~ "Check Your Email"
    end

    test "empty email shows an error rather than the success confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      view
      |> form("#reset-password-form", %{"email" => ""})
      |> render_submit()

      refute render(view) =~ "Check Your Email"
      assert has_element?(view, "#reset-password-form")
    end

    test "navigation between states", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      # Go to signup
      view
      |> element("button", "Sign up")
      |> render_click()

      assert has_element?(view, "#signup-form")

      # Go back to login
      view
      |> element("button", "Log in")
      |> render_click()

      assert has_element?(view, "#login-form")
    end
  end

  describe "Page titles and meta descriptions" do
    setup :setup_password_reset_token

    test "login page has a custom title and meta description", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/auth/login")
      assert page_title(view) != "Schedule a Meeting · Tymeslot"
      assert html =~ ~s(<meta name="description")
    end

    test "signup page has a custom title and meta description", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/auth/signup")
      assert page_title(view) != "Schedule a Meeting · Tymeslot"
      assert html =~ ~s(<meta name="description")
    end

    test "reset password page has a custom title and meta description", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/auth/reset-password")
      assert page_title(view) != "Schedule a Meeting · Tymeslot"
      assert html =~ ~s(<meta name="description")
    end

    test "reset password form page has a custom title and meta description", %{
      conn: conn,
      token: token
    } do
      {:ok, view, html} = live(conn, ~p"/auth/reset-password/#{token}")
      assert page_title(view) != "Schedule a Meeting · Tymeslot"
      assert html =~ ~s(<meta name="description")
    end

    test "oauth and transient pages do not set a custom title or meta description", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth@example.com",
            name: nil,
            is_verified: true,
            email_from_provider: true,
            provider_uid: "12345",
            github_user_id: nil,
            google_user_id: nil
          }
        })

      {:ok, view, html} = live(conn, ~p"/auth/complete-registration")
      assert page_title(view) == "Schedule a Meeting · Tymeslot"
      refute html =~ ~s(<meta name="description")
    end
  end

  describe "Password Reset Form" do
    setup :setup_password_reset_token

    test "valid token renders new password form", %{conn: conn, token: token} do
      {:ok, _view, html} = live(conn, ~p"/auth/reset-password/#{token}")

      assert html =~ "new-password-form"
    end

    test "invalid token renders invalid_token state", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/reset-password/nonexistent-token-abc")

      assert html =~ "Link Expired or Invalid"
    end

    test "expired token renders invalid_token state", %{conn: conn, user: user, token: token} do
      expired_time = DateTime.add(DateTime.utc_now(), -3 * 3600, :second)

      Repo.update_all(
        from(u in UserSchema, where: u.id == ^user.id),
        set: [reset_sent_at: expired_time]
      )

      {:ok, _view, html} = live(conn, ~p"/auth/reset-password/#{token}")

      assert html =~ "Link Expired or Invalid"
    end

    test "valid submission transitions to success state", %{conn: conn, token: token} do
      {:ok, view, _html} = live(conn, ~p"/auth/reset-password/#{token}")

      view
      |> form("#new-password-form", %{
        "password" => "NewSecurePass123!",
        "password_confirmation" => "NewSecurePass123!"
      })
      |> render_submit()

      assert render(view) =~ "Password Reset Successfully"
    end

    test "submit_password_reset with nil reset_token surfaces 'Invalid reset token'", %{
      conn: conn
    } do
      # The submit_password_reset handler has a two-step `with`: CSRF valid,
      # then `true <- not is_nil(token)`. A stale reconnect or a direct
      # invocation on the reset-request page hits the nil-guard — test that
      # path by passing a real CSRF token from a page where reset_token was
      # never assigned.
      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      csrf_html = view |> element("input[name=_csrf_token]") |> render()
      [_match, csrf_token] = Regex.run(~r/value="([^"]+)"/, csrf_html)

      result =
        render_hook(view, "submit_password_reset", %{
          "password" => "NewSecurePass123!",
          "password_confirmation" => "NewSecurePass123!",
          "_csrf_token" => csrf_token
        })

      assert result =~ "Invalid reset token"
    end
  end

  describe "CSRF validation failure" do
    test "submit_signup with invalid CSRF token shows security error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/signup")

      result =
        render_hook(view, "submit_signup", %{
          "user" => %{
            "email" => "test@example.com",
            "password" => "ValidPassword123!",
            "terms_accepted" => "true",
            "website" => ""
          },
          "_csrf_token" => "invalid_token"
        })

      assert result =~ "Security validation failed"
    end

    test "submit_reset_request with invalid CSRF token shows security error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      result =
        render_hook(view, "submit_reset_request", %{
          "email" => "test@example.com",
          "_csrf_token" => "invalid_token"
        })

      assert result =~ "Security validation failed"
    end
  end

  describe "rate limiting — password reset" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)
      :ok
    end

    test "submit_reset_request is blocked after exhausting the per-email rate limit", %{
      conn: conn
    } do
      email = "rl-reset-#{System.unique_integer([:positive])}@example.com"

      # Exhaust the 1-hour per-email bucket (limit: 5)
      for _i <- 1..5 do
        RateLimiter.check_password_reset_rate_limit(email, "test-rate-limit-ip")
      end

      {:ok, view, _html} = live(conn, ~p"/auth/reset-password")

      result =
        view
        |> form("#reset-password-form", %{"email" => email})
        |> render_submit()

      assert result =~ "Too many"
    end
  end

  describe "rate limiting — verification resend" do
    setup do
      on_exit(fn -> RateLimiter.clear_all() end)
      :ok
    end

    test "resend_verification is blocked after exhausting the per-user rate limit", %{conn: conn} do
      user = insert(:unverified_user)

      # Exhaust the 1-hour per-user bucket (limit: 5)
      for _i <- 1..5 do
        RateLimiter.check_verification_rate_limit(user.id, "test-rate-limit-ip")
      end

      conn =
        init_test_session(conn, %{
          "unverified_user_id" => user.id,
          "unverified_user_email" => user.email,
          "unverified_session_timestamp" => DateTime.to_unix(DateTime.utc_now())
        })

      {:ok, view, _html} = live(conn, ~p"/auth/verify-email")

      render_hook(view, "resend_verification", %{})

      assert render(view) =~ "limit" or render(view) =~ "Too many"
    end
  end

  defp setup_password_reset_token(_context) do
    user = insert(:user)
    {token, _value} = Token.generate_password_reset_token()
    {:ok, _result} = UserTokenQueries.set_reset_token(user, token)
    %{user: user, token: token}
  end

  describe "OAuth Completion" do
    test "renders complete registration form with session data", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth@example.com",
            name: nil,
            is_verified: true,
            email_from_provider: true,
            provider_uid: "12345",
            github_user_id: "12345",
            google_user_id: nil
          }
        })

      {:ok, view, html} = live(conn, ~p"/auth/complete-registration")

      assert has_element?(view, "#complete-registration-form")
      assert html =~ "oauth@example.com"
    end

    test "successful OAuth completion", %{conn: conn} do
      conn =
        init_test_session(conn, %{
          "pending_oauth_registration" => %{
            provider: "github",
            email: "oauth_new@example.com",
            name: nil,
            is_verified: true,
            email_from_provider: true,
            provider_uid: "gh_new_123",
            github_user_id: "gh_new_123",
            google_user_id: nil
          }
        })

      {:ok, view, _html} = live(conn, ~p"/auth/complete-registration")

      form =
        form(view, "#complete-registration-form", %{
          "profile" => %{"full_name" => "OAuth New User"},
          "auth" => %{"terms_accepted" => "true"}
        })

      conn = submit_form(form, conn)
      assert redirected_to(conn) == "/dashboard"

      # Verify user was created
      user = Auth.get_user_by_email("oauth_new@example.com")
      assert user
      assert user.github_user_id == "gh_new_123"
    end
  end
end
