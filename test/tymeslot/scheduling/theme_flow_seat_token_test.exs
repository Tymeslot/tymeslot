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

  alias Ecto.Changeset
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.Scheduling.SeatMoveContext
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

    %{user: user, meeting_type: meeting_type, meeting: meeting, participant: participant}
  end

  describe "seat_move_context/2" do
    test "loads a seat still held, with its start, its type and the participant's details",
         %{user: user, meeting_type: meeting_type, meeting: meeting, participant: participant} do
      token = participant.management_token

      assert {:ok, %SeatMoveContext{} = context} = ThemeFlow.seat_move_context(token, user.id)

      assert context.token == token
      assert context.seat.participant.id == participant.id
      assert context.start == meeting.start_time
      assert context.meeting_type.id == meeting_type.id
      assert %{"name" => "Mover", "email" => "mover@example.com"} = context.form_data
    end

    test "has no type for a seat on another organiser's meeting", %{participant: participant} do
      assert {:ok, %SeatMoveContext{meeting_type: nil}} =
               ThemeFlow.seat_move_context(participant.management_token, insert(:user).id)
    end

    test "is spent once the seat has been given up", %{user: user, participant: participant} do
      {:ok, _cancelled} = ParticipantQueries.cancel(participant)

      assert ThemeFlow.seat_move_context(participant.management_token, user.id) ==
               {:error, :already_cancelled}
    end

    test "cannot move a seat whose type has since been deleted",
         %{user: user, meeting_type: meeting_type, participant: participant} do
      Repo.delete!(meeting_type)

      assert ThemeFlow.seat_move_context(participant.management_token, user.id) ==
               {:error, :seat_not_movable}
    end

    test "cannot move a seat whose type no longer takes group bookings",
         %{user: user, meeting_type: meeting_type, participant: participant} do
      meeting_type |> Changeset.change(%{max_participants: 1}) |> Repo.update!()

      assert ThemeFlow.seat_move_context(participant.management_token, user.id) ==
               {:error, :seat_not_movable}
    end

    test "is not found for an unknown or missing token", %{user: user} do
      assert ThemeFlow.seat_move_context("not-a-token", user.id) == {:error, :not_found}
      assert ThemeFlow.seat_move_context(nil, user.id) == {:error, :not_found}
    end
  end

  describe "build_booking_form_data/2 for a seat move" do
    test "pre-fills the participant's own details, never the link's prefill",
         %{user: user, participant: participant} do
      {:ok, context} = ThemeFlow.seat_move_context(participant.management_token, user.id)

      assert %{"name" => "Mover", "email" => "mover@example.com"} =
               ThemeFlow.build_booking_form_data(context, %{"name" => "Someone Else"})
    end
  end
end
