defmodule Tymeslot.Bookings.ScheduleCheckValidationAgreementTest do
  @moduledoc """
  `Bookings.Create` runs `Validation.validate_booking_time/3` and
  `ScheduleCheck.validate_slot_on_schedule/5` against the very same
  `scheduling_config`, expecting both to agree on whether "now" makes a
  candidate slot too soon or too far out.

  `Validation` reads "now" through `Tymeslot.Clock`. `ScheduleCheck` (via
  `Calculate.offers_slot/6` -> `Conflicts.filter_available_slots/6`) used to
  re-derive "now" from `Tymeslot.Utils.DateTimeUtils.now_in_timezone/1`
  reading the raw wall clock, so a frozen clock made the two checks disagree:
  `Validation` would allow a slot relative to the frozen instant while
  `ScheduleCheck` refused it relative to the real one (or the reverse).
  """

  use Tymeslot.DataCase, async: true

  @moduletag :bookings

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Bookings.{Policy, ScheduleCheck, Validation}
  alias Tymeslot.Test.ClockHelpers

  import Tymeslot.AvailabilityTestHelpers

  describe "min-notice and advance-window enforcement" do
    test "Validation and ScheduleCheck agree on a slot that is only valid relative to a frozen clock" do
      %{user: user} = create_always_bookable_profile(timezone: "Etc/UTC")

      # Frozen instant far from the real wall clock: any check that
      # accidentally reads the real clock instead of this one is guaranteed
      # to disagree with a check that reads it correctly.
      frozen_now = ~U[2024-06-10 08:00:00Z]
      date = ~D[2024-06-10]
      start_datetime = ~U[2024-06-10 12:00:00Z]
      duration_minutes = 60

      config =
        user.id
        |> Policy.scheduling_config(nil)
        |> Map.put(:min_advance_hours, 3)
        |> Map.put(:max_advance_booking_days, 365)

      ClockHelpers.with_frozen_clock(frozen_now, fn ->
        validation_result = Validation.validate_booking_time(start_datetime, "Etc/UTC", config)

        schedule_check_result =
          ScheduleCheck.validate_slot_on_schedule(
            date,
            start_datetime,
            duration_minutes,
            "Etc/UTC",
            config
          )

        assert validation_result == :ok
        assert schedule_check_result == :ok
      end)

      # Sanity check that the frozen instant is genuinely far from the real
      # clock, so the assertion above could not have passed by coincidence.
      assert DateTime.diff(DateTime.utc_now(), frozen_now, :day) > 30
    end

    test "Validation and ScheduleCheck agree in refusing a slot inside the frozen minimum notice window" do
      %{user: user} = create_always_bookable_profile(timezone: "Etc/UTC")

      frozen_now = ~U[2024-06-10 08:00:00Z]
      date = ~D[2024-06-10]
      # One hour out, under the 3-hour minimum notice measured from the
      # frozen clock.
      start_datetime = ~U[2024-06-10 09:00:00Z]
      duration_minutes = 60

      config =
        user.id
        |> Policy.scheduling_config(nil)
        |> Map.put(:min_advance_hours, 3)
        |> Map.put(:max_advance_booking_days, 365)

      ClockHelpers.with_frozen_clock(frozen_now, fn ->
        assert {:error, _reason} =
                 Validation.validate_booking_time(start_datetime, "Etc/UTC", config)

        assert {:error, :slot_not_offered} =
                 ScheduleCheck.validate_slot_on_schedule(
                   date,
                   start_datetime,
                   duration_minutes,
                   "Etc/UTC",
                   config
                 )
      end)
    end
  end

  describe "Calculate.offers_slot/6 reads the frozen clock directly" do
    test "matches Conflicts' own min-notice check under a frozen clock" do
      %{schedule_id: schedule_id} = create_always_bookable_profile(timezone: "Etc/UTC")

      frozen_now = ~U[2024-06-10 08:00:00Z]
      date = ~D[2024-06-10]

      config = %{
        owner_timezone: "Etc/UTC",
        schedule_id: schedule_id,
        min_advance_hours: 3,
        max_advance_booking_days: 365
      }

      ClockHelpers.with_frozen_clock(frozen_now, fn ->
        assert {:ok, true} =
                 Calculate.offers_slot(
                   date,
                   ~U[2024-06-10 12:00:00Z],
                   60,
                   "Etc/UTC",
                   "Etc/UTC",
                   config
                 )

        assert {:ok, false} =
                 Calculate.offers_slot(
                   date,
                   ~U[2024-06-10 09:00:00Z],
                   60,
                   "Etc/UTC",
                   "Etc/UTC",
                   config
                 )
      end)
    end
  end
end
