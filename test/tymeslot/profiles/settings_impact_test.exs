defmodule Tymeslot.Profiles.SettingsImpactTest do
  @moduledoc """
  Composition tests for the invariants that link profile settings to
  downstream booking behaviour. Two facets today:

    * **Timezone change is display-only** — `Meeting.start_time` and
      `Meeting.end_time` are `:utc_datetime`, so shifting the organiser's
      timezone must not mutate existing meeting rows. If the schema ever
      drifts to a naive type, every persisted booking would suddenly
      render an hour off — this test pins the UTC storage.
    * **Buffer change flows through to conflict detection** — the booking
      availability calculation reads `buffer_minutes` from the passed
      config (sourced from the profile). A slot that sits just after a
      calendar event must flip from available → blocked when the buffer
      widens, otherwise the setting is decorative.
  """

  use Tymeslot.DataCase, async: true

  @moduletag :profiles
  @moduletag :integration

  import Tymeslot.Factory

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.Repo

  describe "timezone change preserves UTC meeting storage" do
    test "updating profile.timezone does not mutate existing meeting start/end" do
      user = insert(:user)
      profile = insert(:profile, user: user, timezone: "America/New_York")

      # A confirmed meeting whose times are anchored in UTC. The absolute
      # moment must be identical before and after the timezone change —
      # only the organiser's display offset should differ.
      start_utc = ~U[2026-05-01 14:00:00Z]
      end_utc = ~U[2026-05-01 15:00:00Z]

      meeting =
        insert(:meeting,
          organizer_user: user,
          start_time: start_utc,
          end_time: end_utc
        )

      assert {:ok, _updated} = Profiles.update_timezone(profile, "Europe/London")

      reloaded = Repo.get!(MeetingSchema, meeting.id)
      assert DateTime.compare(reloaded.start_time, start_utc) == :eq
      assert DateTime.compare(reloaded.end_time, end_utc) == :eq
    end
  end

  describe "buffer_minutes change flips conflict detection" do
    test "a slot adjacent to a calendar event becomes blocked when buffer widens" do
      # Use a weekday Tuesday at least a day in the future so the
      # `min_advance_hours` check inside Conflicts can never cull slots
      # first for being too soon.
      target = future_tuesday()

      profile =
        insert(:profile,
          timezone: "Europe/Berlin",
          buffer_minutes: 0,
          min_advance_hours: 0
        )

      insert(:weekly_availability,
        profile: profile,
        day_of_week: 2,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[17:00:00]
      )

      # Event 10:00–11:00 Europe/Berlin.
      event_start = DateTime.new!(target, ~T[10:00:00], "Europe/Berlin")
      event_end = DateTime.new!(target, ~T[11:00:00], "Europe/Berlin")

      event =
        CalendarEvent.new!(%{
          uid: "setting-impact-#{System.unique_integer([:positive])}",
          calendar_integration_id: 1,
          provider: :google,
          provider_calendar_id: "primary",
          provider_event_id: "setting-impact-#{System.unique_integer([:positive])}",
          all_day: false,
          start_at: event_start,
          end_at: event_end,
          transparency: :opaque,
          status: :confirmed,
          synced_at: DateTime.utc_now()
        })

      # buffer = 0: the slot butting up against the event is available.
      assert {:ok, slots_no_buffer} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [event],
                 %{profile_id: profile.id, buffer_minutes: 0, min_advance_hours: 0}
               )

      assert "11:00 AM" in slots_no_buffer

      # Widen the buffer. The setting write is the user-facing action;
      # conflict detection must observe the change on the next query.
      assert {:ok, updated} =
               Profiles.update_profile(profile, %{buffer_minutes: 60})

      assert updated.buffer_minutes == 60

      assert {:ok, slots_with_buffer} =
               Calculate.available_slots(
                 target,
                 30,
                 "Europe/Berlin",
                 "Europe/Berlin",
                 [event],
                 %{
                   profile_id: updated.id,
                   buffer_minutes: updated.buffer_minutes,
                   min_advance_hours: 0
                 }
               )

      # The event ends at 11:00, the 60-minute buffer extends the
      # blocked zone to 12:00, so 11:00 and 11:30 must both drop out.
      refute "11:00 AM" in slots_with_buffer
      refute "11:30 AM" in slots_with_buffer
      # 12:00 lands exactly at the buffer boundary and must remain available.
      assert "12:00 PM" in slots_with_buffer
    end
  end

  # --- Helpers ---

  defp future_tuesday do
    today = Date.utc_today()
    current_dow = Date.day_of_week(today)
    days_ahead = rem(2 - current_dow + 7, 7)
    days_ahead = if days_ahead == 0, do: 7, else: days_ahead
    Date.add(today, days_ahead)
  end
end
