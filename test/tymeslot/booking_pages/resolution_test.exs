defmodule Tymeslot.BookingPages.ResolutionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :themes

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Profiles
  alias TymeslotWeb.Themes.Core.Context
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

  test "a page address resolves to its owner, wearing the page", %{profile: profile, page: page} do
    resolved = Profiles.get_profile_by_username("einfachiso")

    assert resolved.id == profile.id
    assert resolved.username == "joern"
    assert resolved.booking_theme == "1"
    assert resolved.booking_heading == "ISO consulting"
    assert resolved.booking_page.id == page.id
    assert BookingPages.public_address(resolved) == "einfachiso"
    assert BookingPages.page_id(resolved) == page.id
  end

  test "a username resolves to the profile as it is" do
    resolved = Profiles.get_profile_by_username("joern")

    assert resolved.booking_theme == "2"
    assert resolved.booking_page == nil
    assert BookingPages.public_address(resolved) == "joern"
    assert BookingPages.page_id(resolved) == nil
  end

  test "a username wins over a page holding the same address" do
    other = insert(:profile, username: "clash")
    # Inserted directly, as a race between the two checks would leave it.
    insert(:booking_page, slug: "clash")

    resolved = Profiles.get_profile_by_username("clash")

    assert resolved.id == other.id
    assert resolved.booking_page == nil
  end

  # Pages are found whatever the case of the address, usernames only as typed
  # (`/Clash` never found the username `clash`): an address in other case than
  # a username must not reach the page either.
  test "a username wins over a page in any case of the address" do
    insert(:profile, username: "clash")
    insert(:booking_page, slug: "clash")

    for address <- ["Clash", "CLASH"] do
      assert Profiles.get_profile_by_username(address) == nil
      assert Profiles.resolve_organizer_context(address) == {:error, :profile_not_found}
    end
  end

  test "a page address resolves in any case", %{page: page} do
    assert Profiles.get_profile_by_username("EinfachISO").booking_page.id == page.id
    assert {:ok, context} = Profiles.resolve_organizer_context("EinfachISO")
    assert context.profile.booking_page.id == page.id
  end

  test "an unknown address resolves to nothing" do
    assert Profiles.get_profile_by_username("nobody-here") == nil
    assert Profiles.resolve_organizer_context("nobody-here") == {:error, :profile_not_found}
  end

  test "the organiser context lists the page's own types", %{profile: profile, page: page} do
    on_page = insert(:meeting_type, user: profile.user, name: "ISO audit")
    insert(:meeting_type, user: profile.user, name: "Automation call")
    :ok = BookingPages.set_meeting_type(page, on_page.id, true)

    assert {:ok, context} = Profiles.resolve_organizer_context("einfachiso")
    assert Enum.map(context.meeting_types, & &1.name) == ["ISO audit"]
    assert context.username == "einfachiso"
    assert context.user_id == profile.user_id
  end

  test "a page with nothing to list offers nothing, not the profile's types", %{profile: profile} do
    insert(:meeting_type, user: profile.user, name: "Automation call")

    assert {:ok, %{meeting_types: []}} = Profiles.resolve_organizer_context("einfachiso")
  end

  test "the start page wears the page's colours", %{profile: profile, page: page} do
    insert(:theme_customization, profile: profile, theme_id: "1", color_scheme: "ocean")

    insert(:theme_customization,
      profile: profile,
      booking_page: page,
      theme_id: "1",
      color_scheme: "rose"
    )

    resolved = Profiles.get_profile_by_username("einfachiso")
    socket = Helpers.assign_theme_customization(%Phoenix.LiveView.Socket{}, resolved, "1")

    assert socket.assigns.theme_customization.color_scheme == "rose"
    assert Context.new("1", resolved).customizations["color_scheme"] == "rose"
    assert Context.new("1", profile).customizations["color_scheme"] == "ocean"
  end
end
