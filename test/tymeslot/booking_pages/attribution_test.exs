defmodule Tymeslot.BookingPages.AttributionTest do
  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias TymeslotWeb.Themes.Shared.PathHandlers

  test "existing_id/1 keeps a live page's id and drops a deleted one's" do
    page = insert(:booking_page)

    assert BookingPages.existing_id(page.id) == page.id
    assert BookingPages.existing_id(nil) == nil

    {:ok, _deleted} = BookingPages.delete(page)
    assert BookingPages.existing_id(page.id) == nil
  end

  test "choosing a new time returns to the page the booking belongs to" do
    profile = insert(:profile, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "einfachiso")

    assert PathHandlers.organizer_scheduling_path(%{organizer_profile: profile}) == "/joern"

    assert PathHandlers.organizer_scheduling_path(%{
             organizer_profile: BookingPages.apply_to_profile(profile, page),
             meeting_uid: "abc"
           }) == "/einfachiso?reschedule_meeting_uid=abc"
  end
end
