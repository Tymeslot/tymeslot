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
             ThemeFlow.reschedule_location_choice(meeting.uid, user.id)

    assert venue_id == venue.id
  end

  test "is nil for a meeting that is not the organiser's" do
    meeting = insert(:meeting, organizer_user_id: insert(:user).id)

    assert ThemeFlow.reschedule_location_choice(meeting.uid, insert(:user).id) == nil
  end
end
