defmodule Tymeslot.Availability.AvailableSlotsCompositionTest do
  @moduledoc """
  End-to-end composition tests for
  `Tymeslot.Availability.Calculate.available_slots/6`.

  The pipeline — weekly schedule prefetch → overrides prefetch →
  business-hours window in the owner's timezone → blocking-event
  filter with buffer → break-aware slot generation — is never
  asserted as one path in the per-module tests. This file locks in
  the user-observable outcomes:

    * a blocking calendar event removes the slots that overlap it
      (respecting the profile's buffer),
    * a non-working weekday (the weekend in the default setup) yields
      no slots regardless of incoming events,
    * an `unavailable` override zeros the day even when the weekly
      schedule says available,
    * a `custom_hours` override narrows the window without touching
      the weekly schedule.

  The DST section pins behaviour across spring-forward and fall-back
  transitions in the owner's timezone, and across a transition in
  only one of the two timezones when owner and viewer differ.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Integrations.Calendar.CalendarEvent

  describe "available_slots/6 with a blocking calendar event" do
    test "removes slots that overlap a busy event in the owner's timezone" do
      profile = setup_weekday_profile("Europe/Berlin")
      target = next_occurrence_of_weekday(1)

      event_start = local_to_utc(target, ~T[10:00:00], "Europe/Berlin")
      event_end = local_to_utc(target, ~T[11:00:00], "Europe/Berlin")

      events = [blocking_event(event_start, event_end)]

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 events,
                 %{profile_id: profile.id}
               )

      refute slots == []
      # buffer = 15 min → blocked window is [09:45, 11:15]
      refute "9:30 AM" in slots
      refute "10:00 AM" in slots
      refute "10:30 AM" in slots
      refute "11:00 AM" in slots
      assert "9:00 AM" in slots
      assert "11:30 AM" in slots
      assert "2:00 PM" in slots
    end

    test "keeps all slots when the only event is cancelled" do
      profile = setup_weekday_profile("Europe/Berlin")
      target = next_occurrence_of_weekday(1)

      cancelled =
        CalendarEvent.new!(%{
          uid: "cancelled-evt-#{System.unique_integer([:positive])}",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "cancelled-#{System.unique_integer([:positive])}",
          provider_calendar_id: "primary",
          all_day: false,
          start_at: local_to_utc(target, ~T[10:00:00], "Europe/Berlin"),
          end_at: local_to_utc(target, ~T[11:00:00], "Europe/Berlin"),
          status: :cancelled,
          synced_at: DateTime.utc_now()
        })

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [cancelled],
                 %{profile_id: profile.id}
               )

      assert "10:00 AM" in slots
      assert "10:30 AM" in slots
    end

    test "keeps all slots when the only event is transparent (free)" do
      profile = setup_weekday_profile("Europe/Berlin")
      target = next_occurrence_of_weekday(1)

      free =
        CalendarEvent.new!(%{
          uid: "free-evt-#{System.unique_integer([:positive])}",
          calendar_integration_id: 1,
          provider: :google,
          provider_event_id: "free-#{System.unique_integer([:positive])}",
          provider_calendar_id: "primary",
          all_day: false,
          start_at: local_to_utc(target, ~T[10:00:00], "Europe/Berlin"),
          end_at: local_to_utc(target, ~T[11:00:00], "Europe/Berlin"),
          transparency: :transparent,
          synced_at: DateTime.utc_now()
        })

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [free],
                 %{profile_id: profile.id}
               )

      assert "10:00 AM" in slots
      assert "10:30 AM" in slots
    end
  end

  describe "available_slots/6 on a non-working day" do
    test "returns an empty list on a day the weekly schedule marks unavailable" do
      profile = setup_weekday_profile("Europe/Berlin")
      # 7 = Sunday, which is marked unavailable by the setup helper.
      sunday = next_occurrence_of_weekday(7)

      assert {:ok, slots} =
               Calculate.available_slots(
                 sunday,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 %{profile_id: profile.id}
               )

      assert slots == []
    end

    test "returns an empty list on Saturday (dow=6) which is also marked unavailable" do
      profile = setup_weekday_profile("Europe/Berlin")
      # 6 = Saturday, which is marked unavailable by the setup helper.
      saturday = next_occurrence_of_weekday(6)

      assert {:ok, slots} =
               Calculate.available_slots(
                 saturday,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 %{profile_id: profile.id}
               )

      assert slots == []
    end
  end

  describe "available_slots/6 with overrides" do
    test "an 'unavailable' override zeros a day the weekly schedule marks available" do
      profile = setup_weekday_profile("Europe/Berlin")
      target = next_occurrence_of_weekday(1)

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
                 %{profile_id: profile.id}
               )
    end

    test "a 'custom_hours' override narrows the window without touching the weekly schedule" do
      profile = setup_weekday_profile("Europe/Berlin")
      target = next_occurrence_of_weekday(1)

      insert(:availability_override,
        profile: profile,
        date: target,
        override_type: "custom_hours",
        start_time: ~T[10:00:00],
        end_time: ~T[12:00:00]
      )

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 %{profile_id: profile.id}
               )

      refute "9:00 AM" in slots
      refute "12:00 PM" in slots
      refute "2:00 PM" in slots
      assert "10:00 AM" in slots
      assert "11:00 AM" in slots
      assert "11:30 AM" in slots
    end
  end

  describe "available_slots/6 DST transitions" do
    # The booking-window cap and minimum-advance-notice defaults (90 days and
    # 3 hours) would filter every slot on these far-future dates; loosen both
    # for the DST suite so we are asserting on the DST behaviour in isolation.
    @dst_config %{max_advance_booking_days: 2000, min_advance_hours: 0, buffer_minutes: 0}

    test "spring-forward Sunday (Europe/Berlin) does not affect normal business hours" do
      profile = insert_always_on_profile("Europe/Berlin")

      # The spring-forward date for Europe/Berlin (CET → CEST, clock jumps
      # 02:00 → 03:00). Business hours start at 09:00 local — well clear of the
      # gap — so the 8-hour window must still yield 16 half-hour slots and each
      # slot must be a valid local wall time. This pins that normal hours are
      # unaffected by the transition.
      target = next_spring_forward_sunday("Europe/Berlin")

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 Map.put(@dst_config, :profile_id, profile.id)
               )

      assert length(slots) == 16
      assert Enum.uniq(slots) == slots
      assert "9:00 AM" in slots
      assert "4:30 PM" in slots
    end

    test "spring-forward transition window (Europe/Berlin): only pre- and post-gap slots emitted" do
      # Hours 01:00–04:00 local straddle the spring-forward gap (02:00 → 03:00).
      # The gap hour is physically absent, so a correct 30-min slot generator
      # must emit exactly 4 slots: 1:00 AM, 1:30 AM, 3:00 AM, 3:30 AM.
      profile = insert_profile_with_sunday_hours(~T[01:00:00], ~T[04:00:00], "Europe/Berlin")
      target = next_spring_forward_sunday("Europe/Berlin")

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [],
                 Map.put(@dst_config, :profile_id, profile.id)
               )

      assert length(slots) == 4
      assert "1:00 AM" in slots
      assert "1:30 AM" in slots
      refute "2:00 AM" in slots
      refute "2:30 AM" in slots
      assert "3:00 AM" in slots
      assert "3:30 AM" in slots
    end

    test "fall-back Sunday (America/New_York) does not duplicate slots when business hours clear the repeated window" do
      profile = insert_always_on_profile("America/New_York")

      # The fall-back date for America/New_York (EDT → EST, 01:00–02:00 repeats).
      # Business hours run 09:00–17:00 — entirely outside the repeated window.
      # This pins that normal hours are unaffected by the transition.
      target = next_fall_back_sunday("America/New_York")

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "America/New_York",
                 "America/New_York",
                 [],
                 Map.put(@dst_config, :profile_id, profile.id)
               )

      assert length(slots) == 16
      assert Enum.uniq(slots) == slots
      assert "9:00 AM" in slots
      assert "4:30 PM" in slots
    end

    test "fall-back transition window (America/New_York): repeated hour collapses to one label per wall-clock time" do
      # Hours 00:30–02:30 local straddle the fall-back repeated hour
      # (02:00 EDT → 01:00 EST). Six real 30-minute intervals elapse across the
      # 180 UTC-minute window, but only four wall-clock labels exist
      # (12:30 AM, 1:00 AM, 1:30 AM, 2:00 AM). Users can't disambiguate
      # "1:00 AM EDT" from "1:00 AM EST" when booking, so the generator must
      # collapse duplicates to one label each, keeping the earlier occurrence.
      profile =
        insert_profile_with_sunday_hours(~T[00:30:00], ~T[02:30:00], "America/New_York")

      target = next_fall_back_sunday("America/New_York")

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "America/New_York",
                 "America/New_York",
                 [],
                 Map.put(@dst_config, :profile_id, profile.id)
               )

      assert slots == ["12:30 AM", "1:00 AM", "1:30 AM", "2:00 AM"]
      assert Enum.uniq(slots) == slots
    end

    test "cross-timezone DST: owner in Berlin on spring-forward day, viewer in New York" do
      profile = insert_always_on_profile("Europe/Berlin")

      # On the Berlin spring-forward Sunday, Berlin has switched to CEST (UTC+2)
      # and New York is already on EDT (UTC-4) — a six-hour gap between zones.
      # Owner hours 09:00–17:00 CEST therefore map to 03:00–11:00 in New York
      # on that date. The viewer should see those times in their own wall clock
      # with no duplicates, and the last 30-minute slot must start at 10:30 AM
      # (a slot starting at 11:00 AM would run past the owner's 17:00 close).
      target = next_spring_forward_sunday("Europe/Berlin")

      assert {:ok, slots} =
               Calculate.available_slots(
                 target,
                 30,
                 "America/New_York",
                 "Europe/Berlin",
                 [],
                 Map.put(@dst_config, :profile_id, profile.id)
               )

      assert length(slots) == 16
      assert Enum.uniq(slots) == slots
      assert "3:00 AM" in slots
      assert "10:30 AM" in slots
      refute "11:00 AM" in slots
    end
  end

  # --- Helpers ---

  defp insert_always_on_profile(timezone) do
    profile = insert(:profile, timezone: timezone, buffer_minutes: 0)

    for dow <- 1..7 do
      insert(:weekly_availability,
        profile: profile,
        day_of_week: dow,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    profile
  end

  defp setup_weekday_profile(timezone) do
    profile = insert(:profile, timezone: timezone, buffer_minutes: 15)

    for dow <- 1..5 do
      insert(:weekly_availability,
        profile: profile,
        day_of_week: dow,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )
    end

    for dow <- 6..7 do
      insert(:weekly_availability,
        profile: profile,
        day_of_week: dow,
        is_available: false
      )
    end

    profile
  end

  defp next_occurrence_of_weekday(target_dow) when target_dow in 1..7 do
    today = Date.utc_today()
    current_dow = Date.day_of_week(today)
    days_ahead = rem(target_dow - current_dow + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    Date.add(today, days_ahead)
  end

  defp local_to_utc(date, time, timezone) do
    date
    |> DateTime.new!(time, timezone)
    |> DateTime.shift_zone!("Etc/UTC")
  end

  defp blocking_event(start_at, end_at) do
    CalendarEvent.new!(%{
      uid: "blocking-evt-#{System.unique_integer([:positive])}",
      calendar_integration_id: 1,
      provider: :google,
      provider_event_id: "blocking-#{System.unique_integer([:positive])}",
      provider_calendar_id: "primary",
      all_day: false,
      start_at: start_at,
      end_at: end_at,
      synced_at: DateTime.utc_now()
    })
  end

  # Inserts a profile available only on Sunday (dow 7) with the given local
  # start/end times. All other days are marked unavailable. Useful for
  # targeting a specific DST transition Sunday without noise from other days.
  defp insert_profile_with_sunday_hours(start_time, end_time, timezone) do
    profile = insert(:profile, timezone: timezone, buffer_minutes: 0)

    for dow <- 1..6 do
      insert(:weekly_availability,
        profile: profile,
        day_of_week: dow,
        is_available: false
      )
    end

    insert(:weekly_availability,
      profile: profile,
      day_of_week: 7,
      is_available: true,
      start_time: start_time,
      end_time: end_time
    )

    profile
  end

  # Returns the next Sunday on or after `from` in `timezone` where the clock
  # jumps forward (DST "spring-forward"). Scans up to 53 Sundays ahead.
  # Uses DateTime.new/3 which returns {:gap, _, _} for gap times; 02:30 local
  # is chosen as the probe because it is within the standard transition hour.
  defp next_spring_forward_sunday(timezone, from \\ Date.utc_today()) do
    first_sunday = first_sunday_on_or_after(from)

    result =
      Enum.find(0..52, fn i ->
        candidate = Date.add(first_sunday, i * 7)
        match?({:gap, _, _}, DateTime.new(candidate, ~T[02:30:00], timezone))
      end)

    if is_nil(result) do
      raise "No spring-forward Sunday found within 53 weeks of #{from} in #{timezone}"
    end

    Date.add(first_sunday, result * 7)
  end

  # Returns the next Sunday on or after `from` in `timezone` where the clock
  # falls back (DST "fall-back"). Scans up to 53 Sundays ahead.
  # Uses DateTime.new/3 which returns {:ambiguous, _, _} for repeated times;
  # 01:30 local is chosen as the probe because it is within the standard
  # repeated hour.
  defp next_fall_back_sunday(timezone, from \\ Date.utc_today()) do
    first_sunday = first_sunday_on_or_after(from)

    result =
      Enum.find(0..52, fn i ->
        candidate = Date.add(first_sunday, i * 7)
        match?({:ambiguous, _, _}, DateTime.new(candidate, ~T[01:30:00], timezone))
      end)

    if is_nil(result) do
      raise "No fall-back Sunday found within 53 weeks of #{from} in #{timezone}"
    end

    Date.add(first_sunday, result * 7)
  end

  defp first_sunday_on_or_after(date) do
    dow = Date.day_of_week(date)
    days_ahead = rem(7 - dow, 7)
    Date.add(date, days_ahead)
  end
end
