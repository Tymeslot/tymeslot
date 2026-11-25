defmodule Tymeslot.Bookings.RescheduleSeatChecksIntegrationTest do
  @moduledoc """
  Move-my-seat checks the new time as a booking of it would be checked: the
  booking page it came from, the seat's own length, the organiser's calendar
  and schedule. The move itself is covered by
  `Tymeslot.Bookings.RescheduleSeatIntegrationTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  use Oban.Testing, repo: Tymeslot.Repo

  import Mox

  import Tymeslot.AvailabilityTestHelpers,
    only: [create_bookable_profile: 1, next_bookable_weekday: 0]

  import Tymeslot.Factory
  import Tymeslot.SeatMoveTestHelpers

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo

  setup :verify_on_exit!

  setup :seat_move_context

  describe "the move is checked like a booking of the new time" do
    test "a move submitted from another organiser's booking page is refused",
         %{old_meeting: old_meeting, mover: mover} do
      other_organizer = insert(:user)

      assert {:error, :meeting_not_found} =
               RescheduleSeat.execute(
                 mover.management_token,
                 new_slot_params(),
                 other_organizer.id
               )

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      assert id == mover.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "the seat keeps the old meeting's length whatever duration the request carries",
         %{old_meeting: old_meeting, mover: mover} do
      assert {:ok, %{meeting: new_meeting, created_meeting?: true}} =
               move(mover, %{new_slot_params() | duration: "120min"})

      assert new_meeting.duration == old_meeting.duration
      assert DateTime.diff(new_meeting.end_time, new_meeting.start_time, :minute) == 30
    end

    test "a time the organiser's calendar has since blocked is refused",
         %{old_meeting: old_meeting, mover: mover} do
      stub_calendar_events([busy_event("someone-elses-event", new_slot_start())])

      assert {:error, :slot_taken} = move(mover, new_slot_params())

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      assert id == mover.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    # The organiser's calendars could not all be read, so the new time can be
    # neither confirmed nor refused: the mover is told that, not that the
    # time is taken, and keeps their seat.
    test "a time that cannot be checked against the organiser's calendar is refused as such",
         %{old_meeting: old_meeting, mover: mover} do
      stub_calendar_result({:error, :some_calendars_unavailable})

      assert {:error, :availability_unverifiable} = move(mover, new_slot_params())

      assert [%{id: id}] = ParticipantQueries.list_live_for_meeting(old_meeting.id)
      assert id == mover.id
      assert Repo.aggregate(MeetingSchema, :count) == 1
    end

    test "joining a live slot is not refused by that slot's own calendar event",
         %{base_params: base_params, old_meeting: old_meeting, mover: mover} do
      target_params =
        Map.merge(base_params, %{date: Date.add(Date.utc_today(), 3), time: "10:00"})

      {:ok, target} = Create.execute(target_params, %{"name" => "T", "email" => "t@example.com"})

      stub_calendar_events([busy_event(target.calendar_uid, target.start_time)])

      assert {:ok, %{meeting: joined, created_meeting?: false}} =
               move(mover, new_slot_params())

      assert joined.id == target.id
      assert ParticipantQueries.list_live_for_meeting(old_meeting.id) == []
    end
  end

  # `Validation.prepare_new_times/2` never ran `ScheduleCheck`, so a seat
  # move could land outside the organiser's own working hours — an
  # unauthenticated seat-token holder could confirm a meeting the organiser
  # never offered.
  describe "schedule enforcement" do
    setup do
      %{user: user} =
        create_bookable_profile(
          hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
        )

      meeting_type =
        insert(:meeting_type,
          user: user,
          duration_minutes: 30,
          is_active: true,
          max_participants: 2
        )

      date = next_bookable_weekday()

      old_params = %{
        date: date,
        time: "10:00",
        duration: "30min",
        user_timezone: "Etc/UTC",
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }

      {:ok, old_meeting} =
        Create.execute(old_params, %{"name" => "Mover", "email" => "mover-hours@example.com"})

      mover =
        old_meeting.id
        |> ParticipantQueries.list_live_for_meeting()
        |> Enum.find(&(&1.email == "mover-hours@example.com"))

      %{old_meeting: old_meeting, mover: mover, date: date}
    end

    test "a seat move to a time outside the organiser's schedule is refused",
         %{old_meeting: old_meeting, mover: mover, date: date} do
      outside_hours_params = %{
        date: Date.to_iso8601(date),
        time: "22:00",
        duration: "30min",
        user_timezone: "Etc/UTC"
      }

      assert {:error, :slot_taken} =
               move(mover, outside_hours_params)

      # Atomicity: the old seat still stands
      assert [%{email: "mover-hours@example.com"}] =
               ParticipantQueries.list_live_for_meeting(old_meeting.id)
    end
  end
end
