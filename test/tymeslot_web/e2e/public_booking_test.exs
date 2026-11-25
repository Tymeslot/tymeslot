defmodule TymeslotWeb.E2E.PublicBookingTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias TymeslotWeb.E2E.BookerSteps

  @moduletag :e2e
  @moduletag :bookings

  feature "visitor books a meeting through the public page", %{session: session} do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)

    # A calendar integration is required for the public booking page to be active
    insert(:calendar_integration, user_id: user.id, user: user)

    # Create a meeting type for the user
    {:ok, meeting_type} =
      MeetingTypes.create_meeting_type(%{
        user_id: user.id,
        name: "Discovery Call",
        duration_minutes: 30,
        is_active: true
      })

    slug = Slugs.to_slug(meeting_type)

    # Visit the public booking page
    session =
      session
      |> visit("/#{profile.username}/#{slug}")
      |> wait_for_live()

    # Pick the first available day, then its first time. Each waits for its
    # buttons first: the days and the times render after the LiveView
    # connects and loads them, so a bare `find` could see none yet.
    session =
      session
      |> BookerSteps.pick_first("[data-testid='calendar-day']:not([disabled])")
      |> BookerSteps.pick_first("[data-testid='time-slot']")

    # Click next to go to booking form
    session = click(session, css("[data-testid='next-step']"))

    # Fill in the booking form and submit straight from the email field. The
    # fields reach the server only on blur, so a click while the email field
    # still has focus must land on an enabled button and book first time.
    session =
      session
      |> assert_has(css("[data-testid='booking-form']"))
      |> fill_in(css("input[name='booking[name]']"), with: "Jane Doe")
      |> fill_in(css("input[name='booking[email]']"), with: "jane@example.com")

    session = click(session, css("[data-testid='submit-booking']"))

    # Should see confirmation
    assert_has(session, css("[data-testid='confirmation-heading']"))
  end
end
