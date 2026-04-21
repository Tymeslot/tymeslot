defmodule Tymeslot.Availability.OverridesBreaksInteractionTest do
  @moduledoc """
  Tests covering the interaction between the three levers that shape a
  day's availability window: the weekly schedule, the per-date override,
  and the per-weekday break list. The levers compose in several
  user-visible ways and no single-module test asserts on the combined
  result, so this file locks in the four canonical scenarios:

    * Scenario A — weekly is available, override narrows the window,
      a break carves a hole inside the narrowed window.
    * Scenario B — override `unavailable` zeros the day even when the
      weekly schedule declares the day as available with breaks.
    * Scenario C — override `available` promotes a weekly-unavailable
      day, and breaks configured on that weekday still apply.
    * Scenario D — a day-long blocking event removes every slot even
      when an override declares a narrow custom-hours window.
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

    test "scenario B: override unavailable zeros the day even when the weekly schedule + breaks are set" do
      {profile, target} = insert_profile_with_weekly_and_break()

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

  defp config(profile) do
    %{profile_id: profile.id, buffer_minutes: 0, min_advance_hours: 0}
  end
end
