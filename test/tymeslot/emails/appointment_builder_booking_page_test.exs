defmodule Tymeslot.Emails.AppointmentBuilderBookingPageTest do
  use Tymeslot.DataCase, async: true

  @moduletag :emails

  import Tymeslot.Factory

  alias Tymeslot.BookingPages
  alias Tymeslot.Emails.AppointmentBuilder
  alias Tymeslot.Repo

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, username: "joern")
    page = insert(:booking_page, profile: profile, slug: "einfachiso")
    listed = insert(:meeting_type, user: user, name: "ISO audit")
    :ok = BookingPages.set_meeting_type(page, listed.id, true)
    %{user: user, page: page, listed: listed}
  end

  defp meeting(user, attrs) do
    insert(
      :meeting,
      Keyword.merge(
        [
          organizer_user_id: user.id,
          start_time: ~U[2027-03-17 14:00:00Z],
          end_time: ~U[2027-03-17 15:00:00Z]
        ],
        attrs
      )
    )
  end

  test "\"book another time\" leads to the page the booking came through", %{
    user: user,
    page: page
  } do
    result = AppointmentBuilder.from_meeting(meeting(user, booking_page_id: page.id))

    assert URI.parse(result.booking_url).path == "/joern/einfachiso"
  end

  # A draft page is not there for the attendee to go back to.
  test "it leads to the username while the page lists nothing", %{
    user: user,
    page: page,
    listed: listed
  } do
    :ok = BookingPages.set_meeting_type(page, listed.id, false)

    result = AppointmentBuilder.from_meeting(meeting(user, booking_page_id: page.id))

    assert URI.parse(result.booking_url).path == "/joern"
  end

  test "it leads to the username once the page is gone", %{user: user, page: page} do
    booked = meeting(user, booking_page_id: page.id)
    {:ok, _deleted} = BookingPages.delete(page)

    assert Repo.reload!(booked).booking_page_id == nil
    assert BookingPages.address_for_meeting(booked, "joern") == "joern"

    result = AppointmentBuilder.from_meeting(Repo.reload!(booked))

    assert URI.parse(result.booking_url).path == "/joern"
  end
end
