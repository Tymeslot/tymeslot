defmodule TymeslotWeb.E2E.SignupTest do
  use TymeslotWeb.BrowserCase

  alias Tymeslot.Auth.Verification
  alias Tymeslot.Repo
  alias Tymeslot.DatabaseSchemas.UserSchema

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

    # Should land on verify-email page
    session = assert_has(session, css("a[href='/auth/login']"))

    # Verify programmatically (simulating clicking the email link)
    user = Repo.get_by!(UserSchema, email: email)
    {:ok, _user} = Verification.verify_user(user.id)

    # Mark onboarding complete so we can reach dashboard
    Tymeslot.Auth.mark_onboarding_complete(user)
    Tymeslot.Profiles.get_or_create_profile(user.id)

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
