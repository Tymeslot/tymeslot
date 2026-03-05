defmodule TymeslotWeb.E2E.SignupTest do
  use TymeslotWeb.BrowserCase

  alias Tymeslot.Auth
  alias Tymeslot.Auth.Verification
  alias Tymeslot.DatabaseSchemas.UserSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  @moduletag :e2e

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
    Auth.mark_onboarding_complete(user)
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
end
