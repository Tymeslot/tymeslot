defmodule TymeslotWeb.AuthLiveTest do
  @moduletag :utils
  use TymeslotWeb.LiveCase, async: true

  alias Phoenix.Flash
  alias Tymeslot.Auth
  alias Tymeslot.Security.Password
  import Tymeslot.Factory

  describe "Login" do
  @moduletag :utils
    test "renders login page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/login")
      assert html =~ "Welcome Back!"
      assert html =~ "Log in to Tymeslot"
      assert html =~ "Email Address"
      assert html =~ "Password"
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

      assert Flash.get(conn.assigns.flash, :error) == "Invalid email or password."
      assert redirected_to(conn) == ~p"/auth/login"
    end
  end

  describe "Registration" do
    test "renders signup page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/auth/signup")
      assert html =~ "Join Tymeslot"
      assert html =~ "Email Address"
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
      assert render(view) =~ "check your email"

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
      assert render(view) =~ "sent password reset instructions"
    end

    test "navigation between states", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/auth/login")

      # Go to signup
      view
      |> element("button", "Sign up")
      |> render_click()

      assert render(view) =~ "Join Tymeslot"

      # Go back to login
      view
      |> element("button", "Log in")
      |> render_click()

      assert render(view) =~ "Welcome Back!"
    end
  end

  describe "OAuth Completion" do
    test "renders complete registration form with data from params", %{conn: conn} do
      params = %{
        "oauth_provider" => "github",
        "oauth_email" => "oauth@example.com",
        "oauth_verified" => "true",
        "oauth_github_id" => "12345",
        "oauth_email_from_provider" => "true"
      }

      {:ok, _view, html} = live(conn, ~p"/auth/complete-registration?#{params}")

      assert html =~ "Complete Your Registration"
      assert html =~ "oauth@example.com"
    end

    test "successful OAuth completion", %{conn: conn} do
      params = %{
        "oauth_provider" => "github",
        "oauth_email" => "oauth_new@example.com",
        "oauth_verified" => "true",
        "oauth_github_id" => "gh_new_123",
        "oauth_email_from_provider" => "true"
      }

      {:ok, view, _html} = live(conn, ~p"/auth/complete-registration?#{params}")

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
