defmodule TymeslotWeb.E2E.SignupTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.Auth.UserSchema
  alias Tymeslot.Auth.Verification
  alias Tymeslot.Onboarding
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @moduletag :e2e
  @moduletag :auth

  feature "user can sign up, verify email, and reach dashboard", %{session: session} do
    email = "e2e-signup-#{System.unique_integer([:positive])}@example.com"

    # Sign up
    session =
      session
      |> visit("/auth/signup")
      |> wait_for_live()
      |> fill_in(css("input[name='user[email]']"), with: email)
      |> fill_in(css("#password-input"), with: default_password())
      |> click(css("button[type='submit']"))

    # Should land on verify-email page — wait for the "Back to Login" button
    # (unique to the verify-email page; the signup page also has a login button but
    # with text "Log in", not "Back to Login")
    session = assert_has(session, css("button", text: "Back to Login"))

    # Verify programmatically (simulating clicking the email link)
    user = Repo.get_by!(UserSchema, email: email)
    {:ok, _user} = Verification.verify_user(user.id)

    # Mark onboarding complete so we can reach dashboard
    Onboarding.mark_onboarding_complete(user)
    Profiles.get_or_create_profile(user.id)

    # Log in with the new account
    session
    |> visit("/auth/login")
    |> wait_for_live()
    |> fill_in(text_field("email"), with: email)
    |> fill_in(css("#password-input"), with: default_password())
    |> click(css("button[type='submit']"))
    |> wait_for_dashboard()
    |> assert_has(css("#dashboard-root"))
  end

  feature "signup page fits the narrowest supported viewport", %{session: session} do
    session
    |> resize_to_mobile()
    |> visit("/auth/signup")
    |> wait_for_live()
    |> assert_has(css("input[name='user[email]']"))
    |> assert_no_horizontal_overflow("signup page at 320px")
  end
end
