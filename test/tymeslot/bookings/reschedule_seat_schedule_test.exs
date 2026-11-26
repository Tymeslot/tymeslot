defmodule Tymeslot.Bookings.RescheduleSeatScheduleTest do
  @moduledoc """
  Move-my-seat against the organiser's own schedule: a seat moved to a
  time the organiser never offered is refused, and the seat stays where it
  was. The move itself is covered by
  `Tymeslot.Bookings.RescheduleSeatIntegrationTest`.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :bookings

  import Mox

  import Tymeslot.AvailabilityTestHelpers,
    only: [create_bookable_profile: 1, next_bookable_weekday: 0]

  import Tymeslot.Factory

  alias Tymeslot.Bookings.{Create, RescheduleSeat}
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Meetings.ParticipantQueries
  alias Tymeslot.Repo
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_calendar_mocks()

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, []}
    end)

    :ok
  end

  # Submitted from the seat's own organiser's booking page, as the seat
  # reschedule link sends it.
  defp move(participant, params) do
    organizer_user_id = Repo.get!(MeetingSchema, participant.meeting_id).organizer_user_id
    RescheduleSeat.execute(participant.management_token, params, organizer_user_id)
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
