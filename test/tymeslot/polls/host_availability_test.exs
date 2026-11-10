defmodule Tymeslot.Polls.HostAvailabilityTest do
  use Tymeslot.DataCase, async: true

  @moduletag :polls

  import Tymeslot.Factory

  alias Tymeslot.Polls.HostAvailability

  # The week from Monday 3 June 2030, read in Berlin (UTC+2 in summer).
  @window {~U[2030-06-02 22:00:00Z], ~U[2030-06-09 22:00:00Z]}

  setup do
    profile = insert(:profile, timezone: "Europe/Berlin")
    %{profile: profile, user_id: profile.user_id}
  end

  defp for_window(user_id) do
    {from, to} = @window
    HostAvailability.for_window(user_id, from, to)
  end

  defp default_schedule(profile, hours) do
    schedule = insert(:availability_schedule, profile: profile, is_default: true)

    for {day, {start_time, end_time}} <- hours do
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day,
        is_available: true,
        start_time: start_time,
        end_time: end_time
      )
    end
  end

  describe "for_window/3" do
    test "reads calendar events and time off as busy", %{profile: profile, user_id: user_id} do
      insert(:provider_calendar_event,
        calendar_integration: insert(:calendar_integration, user: profile.user),
        start_at: ~U[2030-06-03 08:00:00Z],
        end_at: ~U[2030-06-03 09:00:00Z]
      )

      insert(:time_off_period,
        profile: profile,
        starts_on: ~D[2030-06-05],
        ends_on: ~D[2030-06-05],
        start_time: nil,
        end_time: nil
      )

      assert %{busy: busy} = for_window(user_id)

      assert busy == [
               {~U[2030-06-03 08:00:00Z], ~U[2030-06-03 09:00:00Z]},
               {~U[2030-06-04 22:00:00Z], ~U[2030-06-05 22:00:00Z]}
             ]
    end

    test "reads the default schedule's hours on the owner's clock, breaks taken out",
         %{profile: profile, user_id: user_id} do
      [row] = default_schedule(profile, [{1, {~T[09:00:00], ~T[17:00:00]}}])
      insert(:availability_break, weekly_availability: row)

      assert %{hours: hours} = for_window(user_id)

      # 09:00–12:00 and 13:00–17:00 Berlin, the lunch break between.
      assert hours == [
               {~U[2030-06-03 07:00:00Z], ~U[2030-06-03 10:00:00Z]},
               {~U[2030-06-03 11:00:00Z], ~U[2030-06-03 15:00:00Z]}
             ]
    end

    test "gives no hours to a host without a default schedule", %{user_id: user_id} do
      assert for_window(user_id) == %{busy: [], hours: nil}
    end

    test "treats a user without a profile as free throughout" do
      user = insert(:user)
      assert for_window(user.id) == %{busy: [], hours: nil}
    end
  end

  describe "status/3" do
    setup do
      availability = %{
        busy: [{~U[2030-06-03 10:00:00Z], ~U[2030-06-03 11:00:00Z]}],
        hours: [{~U[2030-06-03 07:00:00Z], ~U[2030-06-03 15:00:00Z]}]
      }

      %{availability: availability}
    end

    test "is busy when the meeting runs into busy time, though it starts clear",
         %{availability: availability} do
      assert HostAvailability.status(availability, ~U[2030-06-03 09:30:00Z], 60) == :busy
      assert HostAvailability.status(availability, ~U[2030-06-03 09:30:00Z], 30) == :free
    end

    test "is free when the meeting starts as busy time ends", %{availability: availability} do
      assert HostAvailability.status(availability, ~U[2030-06-03 11:00:00Z], 30) == :free
    end

    test "is outside hours when the meeting runs past them", %{availability: availability} do
      assert HostAvailability.status(availability, ~U[2030-06-03 14:30:00Z], 60) ==
               :outside_hours

      assert HostAvailability.status(availability, ~U[2030-06-03 06:00:00Z], 30) ==
               :outside_hours
    end

    test "has no hours to be outside of without a schedule" do
      assert HostAvailability.status(%{busy: [], hours: nil}, ~U[2030-06-03 03:00:00Z], 30) ==
               :free
    end
  end
end
