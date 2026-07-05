defmodule Tymeslot.Availability.DisplayBookingConsistencyPropertyTest do
  @moduledoc """
  Property-based hardening of the display ↔ booking invariant pinned by
  `Tymeslot.Availability.DisplayBookingConsistencyTest`.

  The example-based test covers two fixed scenarios (no events, all-day block).
  This one fuzzes the space the two example scenarios leave open — timezones
  with varied UTC offsets (DST-observing zones on either hemisphere and a
  half-hour offset), sub-hour and multi-hour durations, and blocking-event
  layouts with partial overlaps and multiple events — and asserts the
  safety-critical direction of the invariant: **any slot the display offers must
  be bookable via the booking API.** A violation means a user sees a slot,
  clicks it, and gets "no longer available" — or worse, a slot is offered that
  booking would have to reject.

  Scope note: the target date is a single near-future weekday (booking-window
  validation runs against the real clock, so it must be), so a given run
  exercises whichever UTC offset each zone is in that day, not the DST
  *transition* day itself. Transition-day gap/overlap handling is guarded
  defensively in `build_event/4` but is not the focus of this property.
  """

  use Tymeslot.DataCase, async: false
  use ExUnitProperties

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    :ok
  end

  # A spread that exercises the tricky conversions: UTC, DST-observing zones in
  # both hemispheres, and a half-hour offset (Asia/Kolkata, +05:30).
  @timezones ["Etc/UTC", "America/New_York", "Europe/Berlin", "Australia/Sydney", "Asia/Kolkata"]

  property "any slot the display offers can be booked" do
    # Same target date across runs: a weekday far enough out that the profile's
    # min-advance window never clips the offered slots.
    target_date = next_bookable_weekday()

    check all(
            timezone <- member_of(@timezones),
            duration <- member_of([15, 30, 60]),
            events <- events_generator(target_date, timezone),
            picker <- integer(0..9_999),
            max_runs: 30
          ) do
      %{user: user, profile_id: profile_id} = create_bookable_profile(timezone: timezone)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, events}
      end)

      {:ok, slots} =
        Calculate.available_slots(
          target_date,
          duration,
          timezone,
          timezone,
          events,
          %{profile_id: profile_id}
        )

      # When the generated events wipe out the whole day the invariant holds
      # vacuously — there is nothing the display offered to book.
      if slots != [] do
        chosen = Enum.at(slots, rem(picker, length(slots)))

        result =
          Create.execute(
            %{
              date: target_date,
              time: chosen,
              duration: duration,
              user_timezone: timezone,
              organizer_user_id: user.id
            },
            %{
              "name" => "Property Attendee",
              "email" => "prop-#{System.unique_integer([:positive])}@example.com",
              "message" => "Booking a slot the display offered"
            }
          )

        assert {:ok, %MeetingSchema{status: "confirmed"}} = result,
               "display offered #{chosen} for #{timezone}/#{duration}min with " <>
                 "#{length(events)} event(s), but booking failed: #{inspect(result)}"
      end
    end
  end

  # 0–3 blocking events, each covering a random sub-window of the day. On the
  # rare transition day, a start/end that lands in a DST gap/overlap for the
  # timezone is dropped rather than forced (defensive; see the scope note above).
  defp events_generator(date, timezone) do
    gen all(specs <- list_of(event_spec(), max_length: 3)) do
      specs
      |> Enum.map(fn {start_min, len} -> build_event(date, timezone, start_min, len) end)
      |> Enum.reject(&is_nil/1)
    end
  end

  # Start anywhere from 09:00 to 18:00; length 20 min (sub-hour) to 3 hours.
  defp event_spec do
    gen all(start_min <- integer(540..1080), len <- integer(20..180)) do
      {start_min, len}
    end
  end

  defp build_event(date, timezone, start_min, len) do
    start_time = minutes_to_time(start_min)
    end_time = minutes_to_time(min(start_min + len, 1439))

    with {:ok, start_dt} <- DateTime.new(date, start_time, timezone),
         {:ok, end_dt} <- DateTime.new(date, end_time, timezone) do
      %{
        uid: "prop-#{System.unique_integer([:positive])}",
        start_time: start_dt,
        end_time: end_dt,
        status: "confirmed",
        transparency: "opaque",
        summary: "Generated block"
      }
    else
      _gap_or_ambiguous -> nil
    end
  end

  defp minutes_to_time(minutes), do: Time.new!(div(minutes, 60), rem(minutes, 60), 0)
end
