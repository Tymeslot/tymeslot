defmodule TymeslotWeb.E2E.EmbedConfirmationLayoutTest do
  @moduledoc """
  Guards the embedded Rhythm confirmation ticket, whose entries share flex
  lines and wrap as the card narrows.

  An in-person type with no venue shows the "address arranged after booking"
  note in the location entry. That entry used to stay beside Date, Time and
  Host however little width was left, and the ticket body, which clips its
  overflow, cut off its label.

  The page is marked embedded with `BookerSteps.mark_embedded/1`, as
  `EmbedSizesMatrixTest` does for the other steps.
  """
  use TymeslotWeb.BrowserCase, async: false

  import TymeslotWeb.E2E.BookerLayoutAssertions
  import TymeslotWeb.E2E.BookerSteps

  alias Tymeslot.MeetingTypes.Slugs
  alias Tymeslot.Profiles

  @moduletag :e2e
  @moduletag :scheduling

  @height 800

  feature "embedded rhythm confirmation keeps an arranged location entry unclipped",
          %{session: session} do
    {profile, slug} = create_user_with_arranged_location()

    session =
      session
      |> resize_window(1000, @height)
      |> visit("/#{profile.username}/#{slug}?theme=2")
      |> wait_for_live()
      |> pick_first_slot()
      |> submit_booking_form()
      |> assert_has(css("[data-testid='location-arranged-note']"))
      |> mark_embedded()

    for width <- [640, 800, 1000], reduce: session do
      acc ->
        acc
        |> resize_window(width, @height)
        |> assert_location_entry_unclipped("rhythm embedded confirmation width=#{width}px")
    end
  end

  defp create_user_with_arranged_location do
    user = create_onboarded_user()
    profile = Profiles.get_profile(user.id)
    insert(:calendar_integration, user_id: user.id, user: user)

    meeting_type =
      insert(:meeting_type,
        user: user,
        name: "Embedded Confirmation Visit",
        duration_minutes: 30,
        is_active: true,
        locations: [in_person_location()]
      )

    {profile, Slugs.to_slug(meeting_type)}
  end
end
