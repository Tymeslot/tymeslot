defmodule TymeslotWeb.E2E.OnboardingTest do
  use TymeslotWeb.BrowserCase

  alias Tymeslot.Auth.Verification

  @moduletag :e2e

  feature "new user completes onboarding wizard", %{session: session} do
    # Create a verified user who hasn't completed onboarding
    user =
      insert(:user, %{
        onboarding_completed_at: nil,
        email: "e2e-onboard-#{System.unique_integer([:positive])}@example.com"
      })

    {:ok, _user} = Verification.verify_user(user.id)

    # Log in — should redirect to onboarding since not completed
    session =
      session
      |> visit("/auth/login")
      |> wait_for_live()
      |> fill_in(text_field("email"), with: user.email)
      |> fill_in(css("#password-input"), with: default_password())
      |> click(css("button[type='submit']"))

    # Should be on onboarding page (welcome step)
    session = assert_has(session, css("button[phx-click='next_step']"))

    # Step 1: Welcome — click Next
    session =
      session
      |> click(css("button[phx-click='next_step']"))

    # Step 2: Basic Settings — fill name and username
    session =
      session
      |> assert_has(css("#full_name"))
      |> fill_in(css("#full_name"), with: "E2E Test User")
      |> fill_in(css("#username"), with: "e2e-user-#{System.unique_integer([:positive])}")
      |> click(css("button[phx-click='next_step']"))

    # Step 3: Scheduling Preferences — use defaults, advance to complete step
    session =
      session
      |> assert_has(css("button[phx-click='next_step']"))
      |> click(css("button[phx-click='next_step']"))

    # Step 4: Complete — click "Get Started" to finish onboarding and go to dashboard
    session
    |> assert_has(css("button[phx-click='next_step']"))
    |> click(css("button[phx-click='next_step']"))
    |> wait_for_dashboard()
    |> assert_has(css("#dashboard-root"))
  end
end
