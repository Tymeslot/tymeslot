defmodule Tymeslot.BookingPages.ResolutionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias Tymeslot.ThemeCustomizations.Presets
  alias TymeslotWeb.Themes.Shared.Customization.Helpers

  setup do
    profile = insert(:profile, username: "joern", booking_theme: "2")

    page =
      insert(:booking_page,
        profile: profile,
        slug: "einfachiso",
        booking_theme: "1",
        booking_text_enabled: true,
        booking_heading: "ISO consulting",
        booking_greeting: "Hello",
        booking_instruction: "Pick"
      )

    %{profile: profile, page: page}
  end

  test "a page's address resolves to its owner, wearing the page", %{profile: profile, page: page} do
    assert {:ok, context} = Profiles.resolve_organizer_context("joern/einfachiso")
    resolved = context.profile

    assert resolved.id == profile.id
    assert resolved.username == "joern"
    assert resolved.booking_theme == "1"
    assert resolved.booking_heading == "ISO consulting"
    assert resolved.booking_page.id == page.id
    assert BookingPages.public_address(resolved) == "joern/einfachiso"
    assert BookingPages.page_id(resolved) == page.id
  end

  test "a username resolves to the profile as it is" do
    assert {:ok, %{profile: resolved}} = Profiles.resolve_organizer_context("joern")

    assert resolved.booking_theme == "2"
    assert resolved.booking_page == nil
    assert BookingPages.public_address(resolved) == "joern"
    assert BookingPages.page_id(resolved) == nil
  end

  # Pages left the username namespace: a page's slug alone is no address.
  test "a page's slug on its own is no username", %{page: page} do
    assert Profiles.get_profile_by_username(page.slug) == nil
    assert Profiles.resolve_organizer_context(page.slug) == {:error, :profile_not_found}
  end

  test "a page's slug resolves only under its own username", %{page: page} do
    insert(:profile, username: "someone-else")

    assert Profiles.resolve_organizer_context("someone-else/#{page.slug}") ==
             {:error, :profile_not_found}

    assert Profiles.resolve_organizer_context("joern/nothing-here") ==
             {:error, :profile_not_found}
  end

  test "an unknown address resolves to nothing" do
    assert Profiles.get_profile_by_username("nobody-here") == nil
    assert Profiles.resolve_organizer_context("nobody-here") == {:error, :profile_not_found}
  end

  test "the organiser context lists the page's own types", %{profile: profile, page: page} do
    on_page = insert(:meeting_type, user: profile.user, name: "ISO audit")
    insert(:meeting_type, user: profile.user, name: "Automation call")
    :ok = BookingPages.set_meeting_type(page, on_page.id, true)

    assert {:ok, context} = Profiles.resolve_organizer_context("joern/einfachiso")
    assert Enum.map(context.meeting_types, & &1.name) == ["ISO audit"]
    assert context.username == "joern/einfachiso"
    assert context.user_id == profile.user_id
  end

  describe "the organiser context of a profile already found" do
    test "comes with its user, and nil for a username nobody holds", %{profile: profile} do
      organiser = Profiles.get_organizer_by_username("joern")

      assert organiser.id == profile.id
      assert organiser.user.id == profile.user_id
      assert Profiles.get_organizer_by_username("nobody-here") == nil
    end

    test "wearing a page, is the context of the page's address", %{profile: profile, page: page} do
      on_page = insert(:meeting_type, user: profile.user, name: "ISO audit")
      insert(:meeting_type, user: profile.user, name: "Automation call")
      :ok = BookingPages.set_meeting_type(page, on_page.id, true)

      organiser =
        "joern" |> Profiles.get_organizer_by_username() |> BookingPages.apply_to_profile(page)

      {:ok, by_address} = Profiles.resolve_organizer_context("joern/einfachiso")
      context = Profiles.organizer_context(organiser)

      assert context.username == "joern/einfachiso"
      assert Enum.map(context.meeting_types, & &1.name) == ["ISO audit"]
      assert context.profile.booking_theme == "1"
      assert context.page_title == by_address.page_title
      assert context.user_id == by_address.user_id
    end

    test "bare, is the context of the username's own page", %{profile: profile} do
      insert(:meeting_type, user: profile.user, name: "Automation call")

      context = "joern" |> Profiles.get_organizer_by_username() |> Profiles.organizer_context()
      {:ok, by_address} = Profiles.resolve_organizer_context("joern")

      assert context.username == "joern"
      assert Enum.map(context.meeting_types, & &1.name) == ["Automation call"]
      assert context.profile.booking_page == nil
      assert context.page_title == by_address.page_title
    end
  end

  test "a page with nothing to list offers nothing, not the profile's types", %{profile: profile} do
    insert(:meeting_type, user: profile.user, name: "Automation call")

    assert {:ok, %{meeting_types: []}} = Profiles.resolve_organizer_context("joern/einfachiso")
  end

  test "the start page wears the page's colours", %{profile: profile, page: page} do
    insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "ocean")

    insert(:theme_customization,
      profile: profile,
      booking_page: page,
      theme_id: "1",
      color_scheme: "rose"
    )

    resolved = BookingPages.apply_to_profile(profile, page)

    assert primary_colour(resolved) == Presets.get_color_schemes()["rose"].colors.primary
    assert primary_colour(profile) == Presets.get_color_schemes()["ocean"].colors.primary
  end

  defp primary_colour(profile) do
    socket = Helpers.assign_theme_customization(%Phoenix.LiveView.Socket{}, profile, "1")
    socket.assigns.theme_tokens.vars["--theme-primary"]
  end
end
