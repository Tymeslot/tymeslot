defmodule Tymeslot.Availability.DisplayBookingConsistencyPropertyTest do
  @moduledoc """
  Property-based hardening of the display ↔ booking invariant pinned by
  `Tymeslot.Availability.DisplayBookingConsistencyTest`.

  The display side is `Offer.slots_for_date/3`, the booking page's own
  pipeline, for the reason its moduledoc gives: a config assembled by hand
  here would be a copy of that pipeline, and a rule the copy carries but the
  page does not is exactly the disagreement these tests exist to catch.

  The example-based test covers fixed scenarios. This one fuzzes the space
  they leave open, across two axes at once:

    * the booker's view - timezones with varied UTC offsets (DST-observing
      zones on either hemisphere and a half-hour offset), sub-hour and
      multi-hour durations, and blocking-event layouts with partial overlaps
      and multiple events;
    * the host's rules - a buffer, a minimum notice, a meeting type with and
      without its own slot interval, and a daily booking limit with bookings
      already counting against it.

  It asserts the safety-critical direction of the invariant: **any slot the
  display offers must be bookable via the booking API.** A violation means a
  user sees a slot, clicks it, and gets "no longer available" - or worse, a
  slot is offered that booking would have to reject.

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

  alias Ecto.Changeset
  alias Tymeslot.Availability.Offer
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

  # Generated events can wipe out a whole day, and the invariant then holds
  # vacuously, so every run's assertion sits behind a guard. This counts the
  # runs that reached it: `check all` runs its body in the test process, so a
  # tally in the process dictionary survives all of them, and a generator
  # change that started emptying every day would fail the property rather than
  # quietly pass it.
  @offering_runs :display_booking_property_offering_runs

  property "any slot the display offers can be booked" do
    # Same target date across runs: a weekday ten days out, so only a generated
    # notice longer than that clips the offered slots.
    target_date = next_bookable_weekday()
    Process.put(@offering_runs, 0)

    check all(
            timezone <- member_of(@timezones),
            duration <- member_of([15, 30, 60]),
            rules <- rules_generator(),
            events <- events_generator(target_date, timezone),
            picker <- integer(0..9_999),
            max_runs: 30
          ) do
      host = create_host(timezone, duration, rules, target_date)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, events}
      end)

      {:ok, slots} =
        Offer.slots_for_date(
          %{
            profile: host.profile,
            user_timezone: timezone,
            meeting_type: host.meeting_type
          },
          Date.to_iso8601(target_date),
          "#{duration}min"
        )

      if slots != [] do
        Process.put(@offering_runs, Process.get(@offering_runs, 0) + 1)

        chosen = Enum.at(slots, rem(picker, length(slots)))

        result =
          Create.execute(
            %{
              date: target_date,
              time: chosen,
              duration: "#{duration}min",
              user_timezone: timezone,
              organizer_user_id: host.user.id,
              meeting_type_id: host.meeting_type && host.meeting_type.id
            },
            %{
              "name" => "Property Attendee",
              "email" => "prop-#{System.unique_integer([:positive])}@example.com",
              "message" => "Booking a slot the display offered"
            }
          )

        assert {:ok, %MeetingSchema{status: "confirmed"}} = result,
               "display offered #{chosen} for #{timezone}/#{duration}min under " <>
                 "#{inspect(rules)} with #{length(events)} event(s), " <>
                 "but booking failed: #{inspect(result)}"
      end
    end

    assert Process.get(@offering_runs) > 0,
           "every run was vacuous: the display offered nothing at all, so the " <>
             "invariant was never exercised"
  end

  # The host the booking page reads: a weekday schedule carrying the generated
  # buffer and notice, an optional meeting type with its own slot interval, and
  # a daily booking limit with bookings already counting against it.
  defp create_host(timezone, duration, rules, target_date) do
    %{user: user, profile: profile, schedule: schedule} =
      create_bookable_profile(
        timezone: timezone,
        profile: %{max_bookings_per_day: rules.max_bookings_per_day}
      )

    schedule
    |> Changeset.change(
      buffer_minutes: rules.buffer_minutes,
      min_advance_hours: rules.min_advance_hours
    )
    |> Repo.update!()

    # Outside the schedule's 11:00-17:00 window and staggered, so they count
    # against the day's limit without hiding a slot or colliding with one
    # another on the organiser's unique-start-time index.
    day_start = DateTime.new!(target_date, ~T[08:00:00], timezone)

    for booking <- 0..(rules.existing_bookings - 1)//1 do
      start_time = DateTime.add(day_start, booking * 30, :minute)

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )
    end

    %{user: user, profile: profile, meeting_type: meeting_type(user, duration, rules)}
  end

  defp meeting_type(_user, _duration, %{slot_interval_minutes: :no_meeting_type}), do: nil

  defp meeting_type(user, duration, %{slot_interval_minutes: interval}) do
    insert(:meeting_type,
      user: user,
      duration_minutes: duration,
      slot_interval_minutes: interval
    )
  end

  # Every scheduling rule the page's config carries beyond the schedule itself.
  # `:no_meeting_type` covers the ad-hoc booking, where there is no type to
  # resolve a duration or an interval from. The 480-hour notice is longer than
  # the distance to the target date, so it empties the day: like a day at its
  # booking cap, that is what makes the rule load-bearing rather than merely
  # present.
  defp rules_generator do
    gen all(
          buffer_minutes <- member_of([0, 15, 30]),
          min_advance_hours <- member_of([0, 24, 48, 480]),
          slot_interval_minutes <- member_of([:no_meeting_type, nil, 15, 30]),
          {max_bookings_per_day, existing_bookings} <- booking_limit()
        ) do
      %{
        buffer_minutes: buffer_minutes,
        min_advance_hours: min_advance_hours,
        slot_interval_minutes: slot_interval_minutes,
        max_bookings_per_day: max_bookings_per_day,
        existing_bookings: existing_bookings
      }
    end
  end

  # A daily cap and the bookings already counting against it, from an empty day
  # up to one at its cap. The full days are what makes the cap load-bearing: a
  # display that dropped the limit check would offer times there that the
  # booking API has to refuse.
  defp booking_limit do
    one_of([
      constant({nil, 0}),
      bind(integer(1..3), fn cap -> map(integer(0..cap), &{cap, &1}) end)
    ])
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
