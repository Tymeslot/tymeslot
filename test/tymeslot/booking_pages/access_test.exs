defmodule Tymeslot.BookingPages.AccessTest do
  @moduledoc """
  Booking pages without the `:booking_pages_allowed` feature: existing pages
  stay published and may be deleted, every other page write is refused, and
  the profile's own page is never gated.
  """
  # The checker is configured globally.
  use Tymeslot.DataCase, async: false

  @moduletag :profiles

  import Tymeslot.ConfigTestHelpers
  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.BookingPages.Access
  alias Tymeslot.Repo
  alias Tymeslot.Test.BookingPagesDeniedChecker
  alias Tymeslot.ThemeCustomizations

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern", booking_theme: "1")
    type = insert(:meeting_type, user: user, name: "Audit", is_private: true)
    page = insert(:booking_page, profile: profile, slug: "audits", name: "Audits")
    insert(:booking_page_meeting_type, booking_page: page, meeting_type: type)

    %{user: user, profile: profile, page: page, type: type}
  end

  test "Core's default checker allows booking pages", %{user: user, page: page} do
    assert Access.allowed?(user.id)
    assert {:ok, %{name: "Renamed"}} = BookingPages.update_details(page, %{"name" => "Renamed"})
  end

  describe "without the feature" do
    setup do
      setup_config(:tymeslot, :feature_access_checker, BookingPagesDeniedChecker)
    end

    test "no page is created", %{user: user, profile: profile} do
      refute BookingPages.editable?(user.id)

      assert {:error, :upgrade_required} =
               BookingPages.create(profile, %{"name" => "Second", "slug" => "second"})

      assert length(BookingPages.list(profile.id)) == 1
    end

    test "a page's details, theme and texts are refused", %{page: page} do
      assert {:error, :upgrade_required} =
               BookingPages.update_details(page, %{"name" => "Renamed", "slug" => "renamed"})

      assert {:error, :upgrade_required} = BookingPages.update_theme(page, "2")

      assert {:error, :upgrade_required} =
               BookingPages.update_booking_text(page, %{"booking_text_enabled" => "true"})

      assert %{name: "Audits", slug: "audits", booking_theme: "1", booking_text_enabled: false} =
               Repo.reload!(page)
    end

    test "its meeting types can be neither listed nor taken off", %{
      user: user,
      profile: profile,
      page: page,
      type: type
    } do
      other = insert(:meeting_type, user: user, name: "Intro")

      assert {:error, :upgrade_required} = BookingPages.set_meeting_type(page, other.id, true)
      assert {:error, :upgrade_required} = BookingPages.set_meeting_type(page, type.id, false)
      assert BookingPages.memberships(profile.id) == %{type.id => MapSet.new([page.id])}
    end

    test "its colours are refused, the main page's are not", %{profile: profile, page: page} do
      assert {:error, :upgrade_required} =
               ThemeCustomizations.upsert_theme_customization(
                 {profile.id, page.id},
                 "1",
                 %{"color_scheme" => "ocean"}
               )

      assert ThemeCustomizations.get_by_profile_and_theme({profile.id, page.id}, "1") == nil

      assert {:ok, _saved} =
               ThemeCustomizations.upsert_theme_customization(profile.id, "1", %{
                 "color_scheme" => "ocean"
               })
    end

    test "an upload for it is refused before anything is stored", %{
      profile: profile,
      page: page
    } do
      assert {:error, message} =
               ThemeCustomizations.attach_asset(
                 {profile.id, page.id},
                 "2",
                 :background_image_path,
                 %{path: "/nonexistent", filename: "bg.png"}
               )

      assert message == BookingPages.locked_message()
    end

    test "the page stays published and can still be deleted", %{profile: profile, page: page} do
      assert BookingPages.published?(page)
      assert {:ok, _deleted} = BookingPages.delete(page)
      assert BookingPages.list(profile.id) == []
    end
  end
end
