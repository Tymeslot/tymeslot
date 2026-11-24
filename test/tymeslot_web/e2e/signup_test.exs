defmodule TymeslotWeb.E2E.SignupTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.Verification
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @moduletag :e2e
  @moduletag :auth

  test "user can sign up, verify email, and reach dashboard", %{session: session} do
    email = "e2e-signup-#{System.unique_integer([:positive])}@example.com"

    # Sign up
    session =
      session
      |> visit("/auth/signup")
      |> fill(by_css("input[name='user[email]']"), email)
      |> fill(by_css("#password-input"), default_password())
      |> click(by_css("button[type='submit']"))

    # Should land on verify-email page — wait for the "Back to Login" button
    # (unique to the verify-email page; the signup page also has a login button but
    # with text "Log in", not "Back to Login")
    session = assert_has(session, filter(by_css("button"), has_text: "Back to Login"))

    # Verify programmatically with a freshly issued link token (simulating
    # clicking the email link)
    user = Repo.get_by!(UserSchema, email: email)
    {:ok, _user, token} = Verification.issue_verification_token(user.id)
    {:ok, _user} = Verification.verify_user(token)

    # Mark onboarding complete so we can reach dashboard
    Onboarding.mark_onboarding_complete(user)
    Profiles.get_or_create_profile(user.id)

    # Log in with the new account
    session
    |> visit("/auth/login")
    |> fill(by_label("Email Address"), email)
    |> fill(by_css("#password-input"), default_password())
    |> click(by_css("button[type='submit']"))
    |> wait_for_dashboard()
    |> assert_has(by_css("#dashboard-root"))
  end

  test "signup page fits the narrowest supported viewport", %{session: session} do
    session
    |> resize_to_mobile()
    |> visit("/auth/signup")
    |> assert_has(by_css("input[name='user[email]']"))
    |> assert_no_horizontal_overflow("signup page at 320px")
  end
end
