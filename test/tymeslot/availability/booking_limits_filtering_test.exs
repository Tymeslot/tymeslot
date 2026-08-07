defmodule Tymeslot.Availability.BookingLimitsFilteringTest do
  @moduledoc """
  Availability rendering under booking limits: days and slots whose
  daily/weekly/monthly cap is already reached must not be offered, judged
  per slot in the host's timezone, with weekly/monthly caps counting
  bookings outside the displayed range.

  Uses the fallback business hours (Mon-Fri 11:00-19:30 in the owner's
  timezone), so assertions stick to weekdays.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Meetings.BookingLimits.Checker

  import Tymeslot.MeetingTestHelpers

  # A weekday at least 5 days out (min notice etc. are then irrelevant).
  defp future_weekday do
    date = Date.add(Date.utc_today(), 5)

    case Date.day_of_week(date) do
      dow when dow >= 5 -> Date.add(date, 8 - dow)
      _weekday -> date
    end
  end

  defp booking_on(user, %Date{} = date, time, attrs \\ %{}) do
    start_time = DateTime.new!(date, time, "Etc/UTC")

    insert(
      :meeting,
      Map.merge(
        %{
          organizer_user_id: user.id,
          start_time: start_time,
          end_time: DateTime.add(start_time, 30, :minute)
        },
        attrs
      )
    )
  end

  defp config_with_checker(user, profile, from, to) do
    %{
      profile_id: nil,
      min_advance_hours: 0,
      max_advance_booking_days: 365,
      buffer_minutes: 0,
      duration_minutes: 30,
      limit_checker: Checker.build_slot_checker(user.id, profile, nil, from, to)
    }
  end

  describe "available_slots/6" do
    test "a day at its daily cap has no slots" do
      %{user: user, profile: profile} =
        create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})

      date = future_weekday()
      booking_on(user, date, ~T[09:00:00])

      config = config_with_checker(user, profile, date, date)

      assert {:ok, []} = Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", [], config)
    end

    test "no checker (no caps configured) leaves slots untouched" do
      %{user: user, profile: profile} = create_user_with_profile(%{timezone: "Etc/UTC"})

      date = future_weekday()
      booking_on(user, date, ~T[09:00:00])

      config = config_with_checker(user, profile, date, date)
      assert config.limit_checker == nil

      assert {:ok, slots} = Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", [], config)
      assert slots != []
    end

    test "a booker-timezone day straddling two host days stays partially available" do
      # Host at UTC+12: UTC slots up to 11:59 belong to host day D, slots
      # from 12:00 to host day D+1. Filling host day D must only remove the
      # earliest UTC slots.
      %{user: user, profile: profile} =
        create_user_with_profile(%{timezone: "Etc/GMT-12", max_bookings_per_day: 1})

      date = future_weekday()
      # 08:00 UTC is 20:00 host time on day D — occupies host day D.
      booking_on(user, date, ~T[08:00:00])

      config = config_with_checker(user, profile, date, date)

      assert {:ok, slots} = Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", [], config)

      refute "11:00 AM" in slots
      refute "11:30 AM" in slots
      assert "12:00 PM" in slots
    end
  end

  describe "range_availability/6" do
    test "marks only the capped day unavailable" do
      %{user: user, profile: profile} =
        create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_day: 1})

      date = future_weekday()
      next_day = Date.add(date, 1)
      booking_on(user, date, ~T[12:00:00])

      config = config_with_checker(user, profile, date, next_day)

      assert {:ok, map} =
               Calculate.range_availability(date, next_day, "Etc/UTC", "Etc/UTC", [], config)

      refute map[Date.to_string(date)]

      # Only assert the neighbour when it's a weekday (fallback hours).
      if Date.day_of_week(next_day) <= 5 do
        assert map[Date.to_string(next_day)]
      end
    end

    test "a weekly cap greys out the whole Monday-week but not the next" do
      %{user: user, profile: profile} =
        create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_week: 1})

      monday = future_weekday() |> Date.beginning_of_week(:monday) |> Date.add(7)
      booking_on(user, Date.add(monday, 1), ~T[12:00:00])

      range_start = monday
      range_end = Date.add(monday, 9)
      config = config_with_checker(user, profile, range_start, range_end)

      assert {:ok, map} =
               Calculate.range_availability(
                 range_start,
                 range_end,
                 "Etc/UTC",
                 "Etc/UTC",
                 [],
                 config
               )

      refute map[Date.to_string(Date.add(monday, 2))]
      refute map[Date.to_string(Date.add(monday, 3))]
      assert map[Date.to_string(Date.add(monday, 7))]
    end

    test "a monthly cap counts bookings outside the displayed range" do
      %{user: user, profile: profile} =
        create_user_with_profile(%{timezone: "Etc/UTC", max_bookings_per_month: 1})

      next_month_first = Date.utc_today() |> Date.end_of_month() |> Date.add(1)
      booking_on(user, Date.add(next_month_first, 1), ~T[12:00:00])

      # Display only a later window of that month — the booking on the 2nd
      # is outside it but must still exhaust the monthly cap.
      range_start = Date.add(next_month_first, 14)
      range_end = Date.add(next_month_first, 18)
      config = config_with_checker(user, profile, range_start, range_end)

      assert {:ok, map} =
               Calculate.range_availability(
                 range_start,
                 range_end,
                 "Etc/UTC",
                 "Etc/UTC",
                 [],
                 config
               )

      for {_date, available?} <- map do
        refute available?
      end
    end
  end
end
