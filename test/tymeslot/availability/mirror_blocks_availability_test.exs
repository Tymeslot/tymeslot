defmodule Tymeslot.Availability.MirrorBlocksAvailabilityTest do
  @moduledoc """
  A busy-block mirror in the event cache still removes a slot from availability.

  **This test pins existing behaviour; it does not describe a change.**
  `CalendarEvent.blocking?/1` returns true for any confirmed, opaque event and
  never consults `created_by_tymeslot`, so a mirror blocks with no code written
  for it. That is deliberate: availability is computed across all of an
  organiser's calendars together, and a mirror occupying time on the second
  calendar is a true statement about that calendar. Booking over it would
  double-book the very time the mirror exists to protect.

  The pin is here because the grid hides mirrors, which makes them easy to read
  as "not real events". A later change that carried that intuition into the
  availability path — skipping mirrors alongside hiding them, or filtering them
  in the cache read for speed — would silently reopen every mirrored slot for
  booking, and nothing else in the suite would notice. Deleting or weakening a
  test here is the change; make it deliberately.

  Asserted against `Calculate.available_slots/6` fed from the real cache read
  (`CalendarEventQueries.in_range/2`) rather than a hand-built event list: the
  claim being pinned is that a mirror row written to the cache reaches the slot
  calculation, so the cache read has to be part of the test.
  """
  use Tymeslot.DataCase, async: true

  @moduletag :availability
  @moduletag :calendar

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.CalendarEventQueries

  setup do
    user = insert(:user)
    profile = insert(:profile, user: user, timezone: "Etc/UTC")
    date = next_monday()

    # The buffer lives on the availability schedule, and weekly availability
    # hangs off that schedule rather than the profile — attaching it to the
    # profile would leave no free slot for a mirror to occupy, and the
    # assertions below would pass over an empty list.
    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        buffer_minutes: 0
      )

    insert(:weekly_availability,
      schedule: schedule,
      day_of_week: Date.day_of_week(date),
      is_available: true,
      start_time: ~T[09:00:00],
      end_time: ~T[12:00:00]
    )

    source = insert(:calendar_integration, user: user, is_active: true)
    target = insert(:calendar_integration, user: user, is_active: true)

    link =
      insert(:calendar_sync_link,
        user_id: user.id,
        source_integration_id: source.id,
        target_integration_id: target.id
      )

    {:ok,
     user: user, profile: profile, schedule: schedule, date: date, target: target, link: link}
  end

  defp slots(schedule, date, integration_ids) do
    events =
      CalendarEventQueries.in_range(
        integration_ids,
        {DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
         DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")}
      )

    Calculate.available_slots(date, 30, "Etc/UTC", "Etc/UTC", events, %{
      schedule_id: schedule.id,
      buffer_minutes: schedule.buffer_minutes,
      min_advance_hours: 0,
      max_advance_booking_days: 3650,
      duration_minutes: 30
    })
  end

  describe "a mirror occupying time on a second calendar" do
    test "removes the slot it covers", %{
      schedule: schedule,
      date: date,
      target: target,
      link: link
    } do
      {:ok, before_slots} = slots(schedule, date, [target.id])
      assert "10:00 AM" in before_slots

      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: "mirror-uid",
        summary: "Busy",
        created_by_tymeslot: true,
        start_at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
      )

      mirror_for_link(link, source_uid: "source-uid", target_uid: "mirror-uid")

      {:ok, after_slots} = slots(schedule, date, [target.id])

      refute "10:00 AM" in after_slots
      assert "10:30 AM" in after_slots
      assert before_slots -- after_slots == ["10:00 AM"]
    end

    test "is counted as blocking when read back out of the cache", %{
      date: date,
      target: target,
      link: link
    } do
      # The layer beneath the slot assertion, stated separately so a failure
      # says which half broke: the cache row converts to a CalendarEvent that
      # `blocking?/1` accepts, despite `created_by_tymeslot` being set.
      insert(:provider_calendar_event,
        calendar_integration: target,
        uid: "mirror-uid",
        created_by_tymeslot: true,
        start_at: DateTime.new!(date, ~T[10:00:00], "Etc/UTC"),
        end_at: DateTime.new!(date, ~T[10:30:00], "Etc/UTC")
      )

      mirror_for_link(link, source_uid: "source-uid", target_uid: "mirror-uid")

      [event] =
        CalendarEventQueries.in_range(
          [target.id],
          {DateTime.new!(date, ~T[00:00:00], "Etc/UTC"),
           DateTime.new!(Date.add(date, 1), ~T[00:00:00], "Etc/UTC")}
        )

      assert event.created_by_tymeslot
      assert CalendarEvent.blocking?(event)
    end
  end

  # A fixed weekday keeps the expected slot list deterministic: anchoring on
  # "tomorrow" would silently skip the assertion on a weekend.
  defp next_monday do
    today = Date.utc_today()
    Date.add(today, rem(1 - Date.day_of_week(today) + 7, 7) + 7)
  end
end
