defmodule Tymeslot.CalendarGrid.EventEditTransparencyAvailabilityTest do
  @moduledoc """
  Free/busy decides whether an event blocks bookings: setting an event free
  from the calendar makes its hour bookable at once, and setting it busy
  again blocks it, though availability is memoised per organiser.

  The provider is an Agent behind the suite-wide `:calendar_module` seam:
  the edit's write changes what the provider holds, and the booking page
  reads it back, as it would read the real calendar.
  """

  use Tymeslot.DataCase, async: false

  @moduletag :calendar
  @moduletag :availability
  @moduletag :integration

  import Mox

  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.Infrastructure.AvailabilityCache
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup tags do
    Mox.set_mox_from_context(tags)
    AvailabilityCache.clear_all()
    TestMocks.setup_all_mocks()

    user = insert(:user)
    profile = insert(:profile, user: user, username: "freebusy", timezone: "Etc/UTC")

    schedule =
      insert(:availability_schedule,
        profile: profile,
        is_default: true,
        advance_booking_days: 90,
        min_advance_hours: 0,
        buffer_before_minutes: 0,
        buffer_after_minutes: 0
      )

    # One bookable hour a day, so one event decides the whole day's answer.
    Enum.each(1..7, fn day_of_week ->
      insert(:weekly_availability,
        schedule: schedule,
        day_of_week: day_of_week,
        is_available: true,
        start_time: ~T[09:00:00],
        end_time: ~T[10:00:00]
      )
    end)

    date = Date.add(Date.utc_today(), 10)
    integration = insert(:calendar_integration, user: user, provider: "google", is_active: true)

    event =
      insert(:provider_calendar_event,
        calendar_integration: integration,
        uid: "focus-#{System.unique_integer([:positive])}",
        summary: "Focus time",
        provider: "google",
        provider_calendar_id: "primary",
        provider_event_id: "focus-time",
        all_day: false,
        start_at: DateTime.new!(date, ~T[09:00:00.000000], "Etc/UTC"),
        end_at: DateTime.new!(date, ~T[10:00:00.000000], "Etc/UTC"),
        transparency: "opaque",
        sync_state: "synced"
      )

    # What the provider holds: the event, with the free/busy the last write gave it.
    provider = start_supervised!({Agent, fn -> "opaque" end})

    stub(Tymeslot.CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok,
       [
         %{
           uid: event.uid,
           summary: event.summary,
           start_time: event.start_at,
           end_time: event.end_at,
           status: "confirmed",
           transparency: Agent.get(provider, & &1)
         }
       ]}
    end)

    stub(Tymeslot.CalendarMock, :update_event, fn _uid, payload, _context ->
      Agent.update(provider, fn _old -> payload.transparency end)
      :ok
    end)

    %{user: user, profile: profile, date: date, event: event}
  end

  test "an event set free stops blocking its hour, and set busy blocks it again", %{
    user: user,
    profile: profile,
    date: date,
    event: event
  } do
    refute offered?(profile, date), "a busy event should block its hour"

    assert {:ok, free} = Changes.update_event(user.id, event, %{transparency: "transparent"})
    assert offered?(profile, date), "the hour of an event set free is still not offered"

    assert {:ok, _busy} = Changes.update_event(user.id, free, %{transparency: "opaque"})
    refute offered?(profile, date), "the hour of an event set busy again is still offered"
  end

  # The day-level answer the booking page's month grid renders, which is the
  # surface `AvailabilityCache` memoises.
  defp offered?(profile, date) do
    request = %{profile: profile, user_timezone: "Etc/UTC", meeting_type: nil}

    assert {:ok, days} = Offer.days_in_range(request, date, date, 60)
    Map.fetch!(days, Date.to_iso8601(date))
  end
end
