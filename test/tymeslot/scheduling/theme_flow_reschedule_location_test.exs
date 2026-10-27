defmodule Tymeslot.Scheduling.ThemeFlowRescheduleLocationTest do
  @moduledoc """
  The location choice a reschedule's picker opens on: the one the meeting
  being moved was booked at.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :scheduling

  alias Tymeslot.Scheduling.ThemeFlow

  test "opens on the meeting's option and the saved venue it is at" do
    user = insert(:user)
    venue = insert(:venue, user: user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        location_kind: "in_person",
        location_option_id: "loc-offices",
        venue_id: venue.id
      )

    assert %{option_id: "loc-offices", venue_id: venue_id} =
             meeting.uid |> context!(user.id) |> ThemeFlow.reschedule_location_choice()

    assert venue_id == venue.id
  end

  test "carries the location the meeting stores, which a time-only reschedule keeps" do
    user = insert(:user)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        location: "Our offices",
        location_kind: "in_person",
        location_option_id: "loc-offices",
        address_to_arrange: true
      )

    assert %{location: "Our offices", address_to_arrange: true, venue_id: nil} =
             meeting.uid |> context!(user.id) |> ThemeFlow.reschedule_location_choice()
  end

  test "is nil when the page is not moving a booking" do
    assert ThemeFlow.reschedule_location_choice(nil) == nil
  end

  defp context!(uid, user_id) do
    {:ok, context} = ThemeFlow.reschedule_context(uid, user_id)
    context
  end
end
