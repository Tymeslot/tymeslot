defmodule Tymeslot.Scheduling.ThemeFlowSeatTokenTest do
  @moduledoc """
  Coverage for the seat-token checks the booking picker relies on.

  The token rides in the picker URL as `reschedule_seat_token`, which browser
  history keeps long after the seat has been moved or given up. Treating a
  spent token as live routed every later submission through the seat-move
  path, where it could only fail.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :scheduling

  import Tymeslot.Factory

  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Scheduling.ThemeFlow

  setup do
    user = insert(:user)
    _profile = insert(:profile, user: user)
    meeting_type = insert(:meeting_type, user: user, max_participants: 4)

    meeting =
      insert(:meeting,
        organizer_user_id: user.id,
        meeting_type_ref: meeting_type,
        attendee_name: nil,
        attendee_email: nil
      )

    participant =
      insert(:participant, meeting: meeting, name: "Mover", email: "mover@example.com")

    %{participant: participant}
  end

  describe "live_seat_token?/1" do
    test "true for a seat still held", %{participant: participant} do
      assert ThemeFlow.live_seat_token?(participant.management_token)
    end

    test "false once the seat has been given up", %{participant: participant} do
      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      refute ThemeFlow.live_seat_token?(participant.management_token)
    end

    test "false for an unknown or missing token" do
      refute ThemeFlow.live_seat_token?("not-a-token")
      refute ThemeFlow.live_seat_token?(nil)
    end
  end

  describe "build_seat_booking_form_data/1" do
    test "pre-fills the participant's own details", %{participant: participant} do
      assert %{"name" => "Mover", "email" => "mover@example.com"} =
               ThemeFlow.build_seat_booking_form_data(participant.management_token)
    end

    test "gives a blank form for a spent token", %{participant: participant} do
      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      assert %{"name" => "", "email" => ""} =
               ThemeFlow.build_seat_booking_form_data(participant.management_token)
    end
  end
end
