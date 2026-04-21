defmodule Tymeslot.Availability.OverridesBreaksInteractionTest do
  @moduledoc """
  Tests covering the interaction between the three levers that shape a
  day's availability window: the weekly schedule, the per-date override,
  and the per-weekday break list. The levers compose in several
  user-visible ways and no single-module test asserts on the combined
  result, so this file locks in the five canonical scenarios:

    * Scenario A — weekly is available, override narrows the window,
      a break carves a hole inside the narrowed window.
    * Scenario B — override `unavailable` zeros the day; flipping it
      to `available` (same hours as the weekly schedule) restores slots
      and the break is still applied. This pins that breaks survive an
      override state flip, which no other test covers.
    * Scenario C — override `available` promotes a weekly-unavailable
      day, and breaks configured on that weekday still apply.
    * Scenario D — a day-long blocking event removes every slot even
      when an override declares a narrow custom-hours window.
    * Scenario E — an `available` override with nil times falls through
      to the weekly schedule; a weekly-unavailable day still yields no
      slots, pinning the nil-guard in BusinessHours.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  describe "weekly schedule + override + break interactions" do
    test "scenario A: weekly 9-17, override custom 10-14, break 12-13 → slots 10-11:30 and 13-13:30" do
      {profile, target} = insert_profile_with_weekly_and_break()

      insert(:availability_override,
        profile: profile,
        date: target,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 config(profile)
               )

      # Override carves 10:00–14:00. Break 12:00–13:00 removes any slot that
      # would overlap. Duration is 30min so 11:30 (runs 11:30–12:00) is the
      # last morning slot, and 13:00 is the first afternoon slot. 13:30 runs
      # to 14:00 and is still inside the override window.
      refute "9:00 AM" in slots
      refute "9:30 AM" in slots
      assert "10:00 AM" in slots
      assert "11:30 AM" in slots
      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "1:00 PM" in slots
      assert "1:30 PM" in slots
      refute "2:00 PM" in slots
    end

    test "scenario B: unavailable override zeros the day; flipping to available restores slots with break still applied" do
      {profile, target} = insert_profile_with_weekly_and_break()

      unavailable_override =
        insert(:availability_override,
          profile: profile,
          date: target,
          override_type: "unavailable"
        )

      assert {:ok, []} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 config(profile)
               )

      # Flip the override state: delete the unavailable record and insert an
      # available one covering the same hours as the weekly schedule (09:00–17:00).
      # The break record (12:00–13:00) on the weekly row must still be applied,
      # proving that breaks survive an override state change.
      Repo.delete!(unavailable_override)

      insert(:availability_override,
        profile: profile,
        date: target,
        override_type: "available",
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 config(profile)
               )

      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "1:00 PM" in slots
      assert "4:30 PM" in slots
      refute "5:00 PM" in slots
    end

    test "scenario C: weekly unavailable + override available 10-14 still honours weekday breaks" do
      target = future_weekday_with_dow(2)
      target_dow = Date.day_of_week(target)

      profile = insert(:profile, timezone: "Europe/Berlin", buffer_minutes: 0)

      weekly =
        insert(:weekly_availability,
          profile: profile,
          day_of_week: target_dow,
          is_available: false
        )

      insert(:availability_break,
        weekly_availability: weekly,
        start_time: ~T[12:00:00],
        end_time: ~T[13:00:00],
        label: "Lunch"
      )

      insert(:availability_override,
        profile: profile,
        date: target,
        override_type: "available",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 config(profile)
               )

      assert "10:00 AM" in slots
      assert "11:30 AM" in slots
      refute "12:00 PM" in slots
      refute "12:30 PM" in slots
      assert "1:00 PM" in slots
      assert "1:30 PM" in slots
      refute "2:00 PM" in slots
    end

    test "scenario D: an all-day blocking event removes every slot inside a custom-hours override" do
      {profile, target} = insert_profile_with_weekly_and_break()

      insert(:availability_override,
        profile: profile,
        date: target,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[14:00:00]
      )

      all_day_event =
        CalendarEvent.new!(%{
          uid: "all-day-#{System.unique_integer([:positive])}",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "all-day-#{System.unique_integer([:positive])}",
          provider_calendar_id: "primary",
          all_day: true,
          start_date: target,
          end_date: Date.add(target, 1),
          synced_at: DateTime.utc_now()
        })

      assert {:ok, []} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [all_day_event],
                 config(profile)
               )
    end

    test "scenario E: available override with nil times falls through to weekly schedule, unavailable Saturday yields no slots" do
      # BusinessHours.get_business_hours_in_timezone guards on
      # `start_time != nil and end_time != nil` before using override times.
      # A nil-time `available` override therefore falls through to `_no_override`
      # and consults the weekly schedule. When the weekly row marks the day
      # unavailable, the result must be an empty slot list — pinning the nil-guard
      # so a regression (e.g. `or` instead of `and`) is caught immediately.
      {profile, saturday} = insert_profile_with_unavailable_saturday()

      insert(:availability_override,
        profile: profile,
        date: saturday,
        override_type: "available",
        start_time: nil,
        end_time: nil
      )

      assert {:ok, []} =
               Calculate.available_slots(
                 saturday,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 config(profile)
               )
    end
  end

  # --- Helpers ---

  # Inserts a Berlin profile with 9-17 weekly availability on the target weekday
  # (a Tuesday at least one day in the future) and a 12-13 lunch break on that
  # same weekday. Returns `{profile, target_date}`.
  defp insert_profile_with_weekly_and_break do
    target = future_weekday_with_dow(2)
    target_dow = Date.day_of_week(target)

    profile = insert(:profile, timezone: "Europe/Berlin", buffer_minutes: 0)

    weekly =
      insert(:weekly_availability,
        profile: profile,
        day_of_week: target_dow,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

    insert(:availability_break,
      weekly_availability: weekly,
      start_time: ~T[12:00:00],
      end_time: ~T[13:00:00],
      label: "Lunch"
    )

    {profile, target}
  end

  defp future_weekday_with_dow(target_dow) when target_dow in 1..7 do
    today = Date.utc_today()
    current_dow = Date.day_of_week(today)
    days_ahead = rem(target_dow - current_dow + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    Date.add(today, days_ahead)
  end

  # Inserts a Berlin profile with Saturday (dow 6) marked unavailable in the
  # weekly schedule and no hours. Returns `{profile, next_saturday}`.
  defp insert_profile_with_unavailable_saturday do
    today = Date.utc_today()
    current_dow = Date.day_of_week(today)
    days_ahead = rem(6 - current_dow + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    saturday = Date.add(today, days_ahead)

    profile = insert(:profile, timezone: "Europe/Berlin", buffer_minutes: 0)

    insert(:weekly_availability,
      profile: profile,
      day_of_week: 6,
      is_available: false
    )

    {profile, saturday}
  end

  defp config(profile) do
    %{profile_id: profile.id, buffer_minutes: 0, min_advance_hours: 0}
  end
end
