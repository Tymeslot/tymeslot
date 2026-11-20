defmodule TymeslotWeb.E2E.PublicBookingTest do
  use TymeslotWeb.BrowserCase, async: false

  alias Tymeslot.MeetingTypes
  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles
  alias Wallaby.Element

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

    # Select a calendar day (pick the first available day).
    # Multiple enabled days match the selector — grab the first and click it directly.
    session
    |> find(css("[data-testid='calendar-day']:not([disabled])", count: :any))
    |> List.first()
    |> Element.click()

    # Select a time slot (pick the first available).
    # Multiple slots may be visible — wait for at least one then click the first.
    session = assert_has(session, css("[data-testid='time-slot']", minimum: 1))

    session
    |> find(css("[data-testid='time-slot']", count: :any))
    |> List.first()
    |> Element.click()

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
