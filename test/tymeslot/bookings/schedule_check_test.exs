defmodule Tymeslot.Bookings.ScheduleCheckTest do
  @moduledoc """
  Coverage for the booking schedule gate under a meeting type's slot interval.

  `ScheduleCheck.validate_slot_on_schedule/5` re-derives the organiser's slot
  list from the config and asks whether the submitted start is in it, so a
  booking can never drift from the list the booking page rendered. That makes
  the config the gate's single source of truth: if `Policy.scheduling_config/2`
  failed to carry `slot_interval_minutes`, the gate would regenerate a
  duration-locked grid and refuse *every* booking on an interval-based meeting
  type, while the rest of the bookings suite — which sets no interval — stayed
  green.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings
  @moduletag :integration

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.ScheduleCheck

  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Factory

  describe "validate_slot_on_schedule/5 under a slot interval" do
    test "accepts a start the interval offers but the duration grid would not" do
      %{user: user, meeting_type: meeting_type} = interval_meeting_type(duration: 30, interval: 5)
      config = Policy.scheduling_config(user.id, meeting_type)

      date = next_bookable_weekday(10)
      {:ok, start_dt} = DateTime.new(date, ~T[09:05:00], "Europe/London")

      assert :ok =
               ScheduleCheck.validate_slot_on_schedule(
                 date,
                 start_dt,
                 30,
                 "Europe/London",
                 config
               )
    end

    test "still refuses a start no window offers" do
      %{user: user, meeting_type: meeting_type} = interval_meeting_type(duration: 30, interval: 5)
      config = Policy.scheduling_config(user.id, meeting_type)

      date = next_bookable_weekday(10)
      {:ok, start_dt} = DateTime.new(date, ~T[09:02:00], "Europe/London")

      assert {:error, :slot_not_offered} =
               ScheduleCheck.validate_slot_on_schedule(
                 date,
                 start_dt,
                 30,
                 "Europe/London",
                 config
               )
    end
  end

  # A user whose default schedule offers 09:00-17:00 Monday to Friday in
  # Europe/London, plus a meeting type booked against that schedule carrying
  # the given duration and slot interval.
  defp interval_meeting_type(opts) do
    %{user: user, schedule: schedule} =
      create_bookable_profile(
        timezone: "Europe/London",
        days: [1, 2, 3, 4, 5],
        hours: %{is_available: true, start_time: ~T[09:00:00], end_time: ~T[17:00:00]}
      )

    meeting_type =
      insert(:meeting_type,
        user: user,
        availability_schedule_id: schedule.id,
        duration_minutes: Keyword.fetch!(opts, :duration),
        slot_interval_minutes: Keyword.fetch!(opts, :interval)
      )

    %{user: user, meeting_type: meeting_type}
  end
end
