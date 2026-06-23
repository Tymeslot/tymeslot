defmodule TymeslotWeb.E2E.OnboardingTest do
  use TymeslotWeb.BrowserCase, async: false

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

    # Step 1: Welcome — click "Let's go"
    session =
      session
      |> assert_has(css("button[phx-click='next_step']"))
      |> click(css("button[phx-click='next_step']"))

    # Step 2: Profile — fill name and username, then continue
    session =
      session
      |> assert_has(css("#full_name"))
      |> fill_in(css("#full_name"), with: "E2E Test User")
      |> fill_in(css("#username"), with: "e2e-user-#{System.unique_integer([:positive])}")
      |> click(css("button[phx-click='next_step']"))

    # Step 3: Connect Calendar — select "Not right now", then Continue
    session =
      session
      |> assert_has(css(~s{button[phx-value-option="skip"]}))
      |> click(css(~s{button[phx-value-option="skip"]}))
      |> click(css("button[phx-click='next_step']"))

    # Step 4: Buffer Time — use defaults, continue
    session =
      session
      |> assert_has(css("button[phx-click='next_step']"))
      |> click(css("button[phx-click='next_step']"))

    # Step 5: Booking Window — use defaults, continue
    session =
      session
      |> assert_has(css("button[phx-click='next_step']"))
      |> click(css("button[phx-click='next_step']"))

    # Step 6: Minimum Notice — use defaults, continue
    session =
      session
      |> assert_has(css("button[phx-click='next_step']"))
      |> click(css("button[phx-click='next_step']"))

    # Step 7: Ready — click "Go to dashboard" to finish onboarding
    session
    |> assert_has(css("button[phx-click='next_step']"))
    |> click(css("button[phx-click='next_step']"))
    |> wait_for_dashboard()
    |> assert_has(css("#dashboard-root"))
  end
end
