defmodule TymeslotWeb.E2E.PublicBookingTest do
  use TymeslotWeb.BrowserCase

  alias Tymeslot.MeetingTypes

  @moduletag :e2e

  feature "visitor books a meeting through the public page", %{session: session} do
    user = create_onboarded_user()
    profile = Tymeslot.Profiles.get_profile(user.id)

    # Create a meeting type for the user
    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(user.id, %{
        name: "Discovery Call",
        duration_minutes: 30,
        is_active: true
      })

    slug = MeetingTypes.to_slug(meeting_type.name)

    # Visit the public booking page
    session =
      session
      |> visit("/#{profile.username}/#{slug}")
      |> wait_for_live()

    # Select a calendar day (pick the first available day)
    session =
      session
      |> click(css("[data-testid='calendar-day']:not([disabled])"))

    # Select a time slot (pick the first available)
    session =
      session
      |> assert_has(css("[data-testid='time-slot']"))
      |> click(css("[data-testid='time-slot']"))

    # Click next to go to booking form
    session =
      session
      |> click(css("[data-testid='next-step']"))

    # Fill in the booking form
    session =
      session
      |> assert_has(css("[data-testid='booking-form']"))
      |> fill_in(text_field("name"), with: "Jane Doe")
      |> fill_in(css("input[type='email']"), with: "jane@example.com")
      |> click(css("[data-testid='submit-booking']"))

    # Should see confirmation
    assert_has(session, css("[data-testid='confirmation-heading']"))
  end
end
