defmodule Tymeslot.Meetings.SeatViewTest do
  use Tymeslot.DataCase, async: true

  @moduletag :meetings

  import Tymeslot.Factory

  alias Ecto.UUID
  alias Tymeslot.Meetings.GuestQueries
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.SeatView

  setup do
    meeting = insert(:group_meeting, capacity: 4)
    seat = insert(:participant, meeting: meeting, name: "Ada", email: "ada@example.com")
    other = insert(:participant, meeting: meeting, name: "Bob", email: "bob@example.com")
    %{meeting: meeting, seat: seat, other: other}
  end

  defp with_guests(meeting), do: Repo.preload(meeting, :guests)

  defp add_guest(meeting, participant, email) do
    {:ok, _guest} =
      GuestQueries.insert_guest(%{
        meeting_id: meeting.id,
        email: email,
        participant_id: participant.id
      })
  end

  describe "at_event/4" do
    test "is the seat's booking: its participant, its seat, the seats taken now",
         %{meeting: meeting, seat: seat} do
      view = SeatView.at_event(meeting, seat)

      assert %MeetingSchema{attendee_name: "Ada", attendee_email: "ada@example.com"} = view

      assert view.seat == %{
               participant_id: seat.id,
               seats_taken: 2,
               previous: nil,
               series_id: nil,
               series_position: nil
             }

      assert SeatView.participant_id(view) == seat.id
      assert SeatView.seats_taken(view) == 2
    end

    test "narrows loaded guests to the seat's own", %{meeting: meeting, seat: seat, other: other} do
      add_guest(meeting, seat, "mine@example.com")
      add_guest(meeting, other, "theirs@example.com")

      view = SeatView.at_event(with_guests(meeting), seat)

      assert Enum.map(view.guests, & &1.email) == ["mine@example.com"]
    end

    test "a seat given up on a meeting still on reads as cancelled when it was given up",
         %{meeting: meeting} do
      cancelled_at = ~U[2026-01-02 03:04:05Z]
      gone = insert(:participant, meeting: meeting, cancelled_at: cancelled_at)

      view = SeatView.at_event(meeting, gone)

      assert view.status == :cancelled
      assert view.cancelled_at == cancelled_at
    end
  end

  describe "load/4" do
    test "rebuilds the view with the seat count the event fired with",
         %{meeting: meeting, seat: seat} do
      assert {:ok, view} = SeatView.load(meeting, seat.id, 7)
      assert view.attendee_email == "ada@example.com"

      assert view.seat == %{
               participant_id: seat.id,
               seats_taken: 7,
               previous: nil,
               series_id: nil,
               series_position: nil
             }
    end

    test "carries the seat a move replaced, as the event recorded it",
         %{meeting: meeting, seat: seat} do
      previous = %{
        seat_id: UUID.generate(),
        meeting_id: UUID.generate(),
        start_time: ~U[2026-10-05 14:00:00Z]
      }

      assert {:ok, view} = SeatView.load(meeting, seat.id, 7, previous)
      assert SeatView.previous_seat(view) == previous
    end

    test "counts the seats now when the event carried no count", %{meeting: meeting, seat: seat} do
      assert {:ok, view} = SeatView.load(meeting, seat.id, nil)
      assert view.seat.seats_taken == 2
    end

    test "refuses a participant of another meeting, or none", %{meeting: meeting} do
      elsewhere = insert(:participant, meeting: insert(:group_meeting))

      assert {:error, :not_found} = SeatView.load(meeting, elsewhere.id, nil)
      assert {:error, :not_found} = SeatView.load(meeting, UUID.generate(), nil)
    end
  end

  describe "for_participant/1" do
    test "is the seat on whichever meeting it sits", %{seat: seat} do
      elsewhere = insert(:group_meeting, capacity: 4)
      moved = insert(:participant, meeting: elsewhere, name: "Cy", email: "cy@example.com")

      assert {:ok, %MeetingSchema{id: meeting_id, attendee_email: "cy@example.com"} = view} =
               SeatView.for_participant(moved.id)

      assert meeting_id == elsewhere.id
      assert view.seat.participant_id == moved.id
      assert view.seat.seats_taken == 1
      assert {:ok, %{attendee_email: "ada@example.com"}} = SeatView.for_participant(seat.id)
    end

    test "refuses a participant that does not exist" do
      assert {:error, :not_found} = SeatView.for_participant(UUID.generate())
    end
  end

  test "a meeting that is not a seat view has no seat" do
    meeting = build(:meeting)

    assert SeatView.participant_id(meeting) == nil
    assert SeatView.seats_taken(meeting) == nil
  end
end
