defmodule Tymeslot.BookingPages.AttributionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias TymeslotWeb.Themes.Shared.PathHandlers

  test "existing_id/2 keeps a live page's id and drops a deleted one's" do
    page = insert(:booking_page)
    user_id = page.profile.user_id

    assert BookingPages.existing_id(page.id, user_id) == page.id
    assert BookingPages.existing_id(nil, user_id) == nil

    {:ok, _deleted} = BookingPages.delete(page)
    assert BookingPages.existing_id(page.id, user_id) == nil
  end

  test "existing_id/2 drops a page that is not the organiser's" do
    page = insert(:booking_page)
    other = insert(:profile)

    assert BookingPages.existing_id(page.id, other.user_id) == nil
    assert BookingPages.existing_id(page.id, nil) == nil
  end

  test "choosing a new time returns to the page the booking belongs to" do
    profile = insert(:profile, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "einfachiso")

    assert PathHandlers.organizer_scheduling_path(%{organizer_profile: profile}) == "/joern"

    assert PathHandlers.organizer_scheduling_path(%{
             organizer_profile: BookingPages.apply_to_profile(profile, page),
             meeting_uid: "abc"
           }) == "/joern/einfachiso?reschedule_meeting_uid=abc"
  end
end
