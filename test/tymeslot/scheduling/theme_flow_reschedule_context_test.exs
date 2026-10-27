defmodule Tymeslot.Scheduling.ThemeFlowRescheduleContextTest do
  @moduledoc """
  The booking a reschedule page is moving, loaded once with what the page
  starts from: the type it is pinned to, the form's starting values and the
  location the picker opens on. Only a movable booking of the page's own
  organiser yields one.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :scheduling

  alias Ecto.Changeset
  alias Tymeslot.Scheduling.RescheduleContext
  alias Tymeslot.Scheduling.ThemeFlow

  setup do
    user = insert(:user)
    meeting_type = insert(:meeting_type, user: user, name: "Strategy call")

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        organizer_email: user.email,
        meeting_type_id: meeting_type.id,
        attendee_name: "Ada Lovelace",
        attendee_email: "ada@example.com",
        attendee_message: nil,
        location_option_id: "loc-video"
      )

    %{user: user, meeting_type: meeting_type, meeting: meeting}
  end

  test "loads the booking with the type it is committed to and its attendee's details", %{
    user: user,
    meeting_type: meeting_type,
    meeting: meeting
  } do
    assert {:ok, %RescheduleContext{} = context} =
             ThemeFlow.reschedule_context(meeting.uid, user.id)

    assert context.uid == meeting.uid
    assert context.meeting.id == meeting.id
    assert context.meeting_type.id == meeting_type.id
    assert context.location_choice.option_id == "loc-video"

    assert context.form_data == %{
             "name" => "Ada Lovelace",
             "email" => "ada@example.com",
             "message" => ""
           }
  end

  # Deleting a type clears it off its bookings, which leaves them where a
  # booking made before meeting types existed is.
  test "has no type for a booking whose type has since been deleted", %{
    user: user,
    meeting_type: meeting_type,
    meeting: meeting
  } do
    Repo.delete!(meeting_type)

    assert {:ok, %RescheduleContext{meeting_type: nil}} =
             ThemeFlow.reschedule_context(meeting.uid, user.id)
  end

  test "is not found for a booking of another organiser", %{meeting: meeting} do
    assert ThemeFlow.reschedule_context(meeting.uid, insert(:user).id) ==
             {:error, :meeting_not_found}
  end

  test "is refused, with the reason, for a booking the rules no longer let move", %{
    user: user,
    meeting: meeting
  } do
    meeting |> Changeset.change(%{status: "cancelled"}) |> Repo.update!()

    assert ThemeFlow.reschedule_context(meeting.uid, user.id) ==
             {:error, {:not_reschedulable, :cancelled}}
  end
end
