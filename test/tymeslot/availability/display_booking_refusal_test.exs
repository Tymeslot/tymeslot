defmodule Tymeslot.Availability.DisplayBookingRefusalTest do
  @moduledoc """
  The converse of `DisplayBookingConsistencyTest`'s invariant: a time the
  booking page's display never offers is refused by `Create.execute/2`, for a
  booker who reaches the submit path without passing through the page.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # The converse of the display ↔ booking invariant, and the reason it is enforced in the
  # domain rather than in the booking page's step machine: `/:username/:slug/book`
  # is directly enterable, so a booker can arrive at the submit path having
  # passed through none of the page's own guards. Only a check on the create
  # path itself can hold for those.
  describe "times the display never offered are refused by the booking API" do
    setup do
      TestMocks.stub_no_calendar_events()
      :ok
    end

    test "a time outside the host's working hours is refused" do
      timezone = "Etc/UTC"
      %{user: user, profile: profile} = create_bookable_profile(timezone: timezone)
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      target_date = next_bookable_weekday()

      slots = offered(profile, target_date, "30min")

      # The helper's window is 11:00–17:00, so 08:00 is a real time on a real
      # working day that the display simply never offers.
      refute "8:00 AM" in slots

      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, meeting_type, target_date, "08:00", "30min", timezone),
                 attendee()
               )
    end

    test "a day the host is not available at all is refused" do
      timezone = "Etc/UTC"

      %{user: user} = create_bookable_profile(timezone: timezone, days: [1, 2, 3])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      # A Thursday: inside the advance window, outside the host's Mon–Wed week.
      target_date = next_weekday_of(4)

      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, meeting_type, target_date, "12:00", "30min", timezone),
                 attendee()
               )
    end

    test "a duration that overruns the host's window is refused" do
      timezone = "Etc/UTC"
      %{user: user} = create_bookable_profile(timezone: timezone)
      # The slot length comes from the type, so the overrun is the type's own.
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 540)
      target_date = next_bookable_weekday()

      # 11:00 starts inside the 11:00–17:00 window; nine hours does not fit in
      # it. Nothing else on the create path bounds the meeting's duration.
      assert {:error, :slot_taken} =
               Create.execute(
                 booking_at(user, meeting_type, target_date, "11:00", "540min", timezone),
                 attendee()
               )
    end

    defp booking_at(user, meeting_type, date, time, duration, timezone) do
      %{
        date: date,
        time: time,
        duration: duration,
        user_timezone: timezone,
        organizer_user_id: user.id,
        meeting_type_id: meeting_type.id
      }
    end

    defp attendee do
      %{
        "name" => "Invariant Attendee",
        "email" => "invariant-attendee@example.com",
        "message" => "Attempting a time the schedule never offered"
      }
    end

    # The next date whose ISO weekday is `day_of_week`, at least ten days out so
    # the advance window never clips it.
    defp next_weekday_of(day_of_week) do
      Date.utc_today()
      |> Date.add(10)
      |> Stream.iterate(&Date.add(&1, 1))
      |> Enum.find(&(Date.day_of_week(&1) == day_of_week))
    end
  end
end
