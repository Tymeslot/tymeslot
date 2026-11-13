defmodule TymeslotWeb.Dashboard.LanguagesUntranslatedFormsTest do
  @moduledoc """
  The common case: an organiser with no translation language. Each form
  that edits translatable texts (the profile intro, the booking page text
  card, the venue modal and the meeting type editor) shows no translation
  strip and no field marks, and saves as it always has.
  """
  use TymeslotWeb.LiveCase, async: true

  @moduletag :i18n
  @moduletag :live

  import Tymeslot.DashboardTestHelpers
  import Tymeslot.Factory

  alias Ecto.Changeset
  alias Tymeslot.MeetingTypes
  alias Tymeslot.Repo
  alias Tymeslot.Venues.VenueSchema

  setup :setup_dashboard_user

  setup %{profile: profile} do
    profile =
      profile
      |> Changeset.change(
        username: "no-translations",
        translation_locales: [],
        booking_text_enabled: true,
        booking_heading: "Ready to talk?",
        booking_greeting: "I am Sarah.",
        booking_instruction: "Choose a session."
      )
      |> Repo.update!()

    %{profile: profile}
  end

  test "the profile intro shows no translation status and saves", %{conn: conn, profile: profile} do
    {:ok, view, _html} = live(conn, ~p"/dashboard/settings")

    refute_translation_status(view)

    view
    |> form("#intro-form", profile_intro: %{headline: "Leadership coach", bio: "Hello."})
    |> render_submit()

    assert Repo.reload!(profile).headline == "Leadership coach"
  end

  test "the booking page text card shows no translation status and autosaves", %{
    conn: conn,
    profile: profile
  } do
    {:ok, view, _html} = live(conn, ~p"/dashboard/pages")

    refute_translation_status(view)

    view
    |> form("#booking-text-form-form", profile_schema: %{booking_heading: "Shall we talk?"})
    |> render_change()

    assert Repo.reload!(profile).booking_heading == "Shall we talk?"
  end

  test "the venue modal shows no translation status and saves", %{conn: conn, user: user} do
    venue = insert(:venue, user: user, name: "Studio")
    {:ok, view, _html} = live(conn, ~p"/dashboard/locations")

    view |> element("[phx-click='edit_venue'][phx-value-id='#{venue.id}']") |> render_click()
    refute_translation_status(view)

    view |> form("#venue-form", %{"venue" => %{"name" => "Main studio"}}) |> render_submit()

    assert Repo.get!(VenueSchema, venue.id).name == "Main studio"
    refute has_element?(view, "#venue-form-modal")
  end

  test "the meeting type editor shows no translation status and autosaves", %{
    conn: conn,
    user: user
  } do
    meeting_type = insert(:meeting_type, user: user, name: "Intro call")
    {:ok, view, _html} = live(conn, ~p"/dashboard/meeting-settings")

    view
    |> element("[phx-click='edit_type'][phx-value-id='#{meeting_type.id}']")
    |> render_click()

    refute_translation_status(view)

    view
    |> element(~s|input[name="meeting_type[name]"]|)
    |> render_change(%{"meeting_type" => %{"name" => "First call"}})

    assert MeetingTypes.get_meeting_type(meeting_type.id, user.id).name == "First call"

    view
    |> element("#meeting-type-config-view button[aria-label='Close']")
    |> render_click()

    refute has_element?(view, "#meeting-type-config-view")
  end

  defp refute_translation_status(view) do
    refute has_element?(view, "[data-testid='translation-strip']")
    refute has_element?(view, "[data-testid='translation-mark']")
  end
end
