defmodule Tymeslot.Availability.BookableWindowsTest do
  @moduledoc """
  `Availability.bookable_windows/4` and `Availability.next_bookable/3`: the
  times the organiser's calendar shades as bookable for a meeting type, and
  the first one ahead.

  The property is the contract: over a week, the windows are exactly the
  meetings the booking page offers day by day (`Offer.slots_for_date/3`),
  merged, across the host's timezone, buffers, notice, slot interval, own
  bookings, an unavailable-day override, time off and calendar events. The
  examples pin the shapes a reader relies on and the refusals.

  The property freezes the clock in a January fortnight of next year, when
  none of the zones below changes its clock, so a page label read back on its
  day names exactly one instant.
  """

  use Tymeslot.DataCase, async: false
  use ExUnitProperties

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability
  alias Tymeslot.Availability.Intervals
  alias Tymeslot.Availability.Offer
  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.CalendarMock
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    :ok
  end

  @timezones [
    "Etc/UTC",
    "Europe/Berlin",
    "America/New_York",
    "Asia/Tokyo",
    "Asia/Kolkata",
    "Pacific/Auckland"
  ]

  # Counts the runs that offered anything, so a generator change that emptied
  # every week fails the property instead of passing it vacuously.
  @offering_runs :bookable_windows_property_offering_runs

  property "the windows are exactly the meetings the booking page offers, merged" do
    monday = frozen_monday()
    ClockHelpers.freeze_clock(DateTime.new!(monday, ~T[08:00:00], "Etc/UTC"))
    Process.put(@offering_runs, 0)

    check all(
            timezone <- member_of(@timezones),
            duration <- member_of([15, 30, 60]),
            rules <- rules_generator(),
            offset <- integer(0..3),
            events <- events_generator(Date.add(monday, offset), timezone),
            max_runs: 25
          ) do
      range_start = Date.add(monday, offset)
      range_end = Date.add(range_start, 6)
      host = create_host(timezone, duration, rules, range_start)

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok, events}
      end)

      assert {:ok, windows} =
               Availability.bookable_windows(
                 host.user.id,
                 host.meeting_type.id,
                 range_start,
                 range_end
               )

      expected = page_windows(host, range_start, range_end, duration, timezone)

      assert unix(windows) == unix(expected),
             "windows differ from the page for #{timezone}, #{duration}min under " <>
               "#{inspect(rules)} with #{length(events)} event(s)"

      if windows != [], do: Process.put(@offering_runs, Process.get(@offering_runs) + 1)
    end

    assert Process.get(@offering_runs) > 0,
           "every run offered nothing at all, so no window was ever compared"
  end

  describe "bookable_windows/4" do
    setup do
      %{user: user, profile: profile, schedule: schedule} = create_bookable_profile()

      schedule
      |> Changeset.change(buffer_before_minutes: 0, buffer_after_minutes: 0)
      |> Repo.update!()

      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      %{user: user, profile: profile, meeting_type: meeting_type, date: next_bookable_weekday()}
    end

    test "one window covers a day open from 11:00 to 17:00", ctx do
      assert {:ok, [window]} =
               Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

      assert DateTime.compare(window.start_at, at(ctx.date, ~T[11:00:00])) == :eq
      assert DateTime.compare(window.end_at, at(ctx.date, ~T[17:00:00])) == :eq
      assert window.start_at.time_zone == "Etc/UTC"
    end

    test "a calendar event splits the day in two", ctx do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:ok,
         [
           %{
             uid: "lunch",
             start_time: at(ctx.date, ~T[13:00:00]),
             end_time: at(ctx.date, ~T[14:00:00]),
             status: "confirmed",
             transparency: "opaque"
           }
         ]}
      end)

      assert {:ok, windows} =
               Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)

      assert unix(windows) == [
               {unix_at(ctx.date, ~T[11:00:00]), unix_at(ctx.date, ~T[13:00:00])},
               {unix_at(ctx.date, ~T[14:00:00]), unix_at(ctx.date, ~T[17:00:00])}
             ]
    end

    test "a slot interval longer than the meeting leaves gaps between windows", ctx do
      meeting_type =
        insert(:meeting_type, user: ctx.user, duration_minutes: 30, slot_interval_minutes: 60)

      assert {:ok, windows} =
               Availability.bookable_windows(ctx.user.id, meeting_type.id, ctx.date, ctx.date)

      expected =
        for hour <- 11..16 do
          {unix_at(ctx.date, Time.new!(hour, 0, 0)), unix_at(ctx.date, Time.new!(hour, 30, 0))}
        end

      assert unix(windows) == expected
    end

    test "a day the schedule does not open has no windows", ctx do
      saturday = ctx.date |> Date.beginning_of_week(:monday) |> Date.add(5)

      assert {:ok, []} =
               Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, saturday, saturday)
    end

    # Its planned sessions are joined, never started, so the calendar shades
    # nothing the booking page would not offer.
    test "a fixed-date type has no windows and nothing bookable ahead", ctx do
      fixed =
        insert(:meeting_type,
          user: ctx.user,
          duration_minutes: 30,
          fixed_dates: true,
          max_participants: 5
        )

      assert {:ok, []} = Availability.bookable_windows(ctx.user.id, fixed.id, ctx.date, ctx.date)

      assert {:ok, nil} =
               Availability.next_bookable(ctx.user.id, fixed.id, at(ctx.date, ~T[00:00:00]))
    end

    test "another user's meeting type is not found", ctx do
      other = insert(:meeting_type)

      assert {:error, :not_found} =
               Availability.bookable_windows(ctx.user.id, other.id, ctx.date, ctx.date)
    end

    test "an archived or inactive meeting type is not found", ctx do
      archived = insert(:meeting_type, user: ctx.user, is_archived: true)
      inactive = insert(:meeting_type, user: ctx.user, is_active: false)

      assert {:error, :not_found} =
               Availability.bookable_windows(ctx.user.id, archived.id, ctx.date, ctx.date)

      assert {:error, :not_found} =
               Availability.bookable_windows(ctx.user.id, inactive.id, ctx.date, ctx.date)
    end

    test "refuses a range ending before it starts, and one longer than six weeks", ctx do
      assert {:error, :invalid_range} =
               Availability.bookable_windows(
                 ctx.user.id,
                 ctx.meeting_type.id,
                 ctx.date,
                 Date.add(ctx.date, -1)
               )

      assert {:ok, _windows} =
               Availability.bookable_windows(
                 ctx.user.id,
                 ctx.meeting_type.id,
                 ctx.date,
                 Date.add(ctx.date, 41)
               )

      assert {:error, :range_too_long} =
               Availability.bookable_windows(
                 ctx.user.id,
                 ctx.meeting_type.id,
                 ctx.date,
                 Date.add(ctx.date, 42)
               )
    end

    test "fails when the host's calendar cannot be read", ctx do
      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :timeout}
      end)

      assert {:error, _reason} =
               Availability.bookable_windows(ctx.user.id, ctx.meeting_type.id, ctx.date, ctx.date)
    end
  end

  describe "next_bookable/3" do
    test "finds the first open day ahead" do
      %{user: user} = create_bookable_profile(days: [3])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      monday = Date.utc_today() |> Date.beginning_of_week(:monday) |> Date.add(14)

      assert {:ok, next} =
               Availability.next_bookable(user.id, meeting_type.id, at(monday, ~T[00:00:00]))

      assert DateTime.compare(next, at(Date.add(monday, 2), ~T[11:00:00])) == :eq
      assert next.time_zone == "Etc/UTC"
    end

    test "searches past the first six weeks" do
      %{user: user, schedule: schedule} = create_bookable_profile(days: [])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      far = Date.add(Date.utc_today(), 60)

      insert(:availability_override,
        schedule: schedule,
        date: far,
        override_type: "custom_hours",
        start_time: ~T[11:00:00],
        end_time: ~T[12:00:00]
      )

      assert {:ok, next} =
               Availability.next_bookable(user.id, meeting_type.id, DateTime.utc_now())

      assert DateTime.compare(next, at(far, ~T[11:00:00])) == :eq
    end

    test "stops at the schedule's booking window" do
      %{user: user, schedule: schedule} = create_bookable_profile(days: [])
      schedule |> Changeset.change(advance_booking_days: 30) |> Repo.update!()
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      insert(:availability_override,
        schedule: schedule,
        date: Date.add(Date.utc_today(), 60),
        override_type: "custom_hours",
        start_time: ~T[11:00:00],
        end_time: ~T[12:00:00]
      )

      assert {:ok, nil} = Availability.next_bookable(user.id, meeting_type.id, DateTime.utc_now())
    end

    test "answers nil for a host who is never open" do
      %{user: user} = create_bookable_profile(days: [])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)

      assert {:ok, nil} = Availability.next_bookable(user.id, meeting_type.id, DateTime.utc_now())
    end

    test "skips starts before after_at, on the slot grid" do
      %{user: user} = create_bookable_profile(days: [3])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      monday = Date.utc_today() |> Date.beginning_of_week(:monday) |> Date.add(14)
      wednesday = Date.add(monday, 2)

      assert {:ok, next} =
               Availability.next_bookable(user.id, meeting_type.id, at(wednesday, ~T[13:10:00]))

      assert DateTime.compare(next, at(wednesday, ~T[13:30:00])) == :eq
    end

    test "moves to the next open day when after_at is past the day's last start" do
      %{user: user} = create_bookable_profile(days: [3])
      meeting_type = insert(:meeting_type, user: user, duration_minutes: 30)
      monday = Date.utc_today() |> Date.beginning_of_week(:monday) |> Date.add(14)
      wednesday = Date.add(monday, 2)

      assert {:ok, next} =
               Availability.next_bookable(user.id, meeting_type.id, at(wednesday, ~T[17:00:00]))

      assert DateTime.compare(next, at(Date.add(wednesday, 7), ~T[11:00:00])) == :eq
    end

    test "an archived or inactive meeting type is not found" do
      %{user: user} = create_bookable_profile()
      archived = insert(:meeting_type, user: user, is_archived: true)
      inactive = insert(:meeting_type, user: user, is_active: false)

      assert {:error, :not_found} =
               Availability.next_bookable(user.id, archived.id, DateTime.utc_now())

      assert {:error, :not_found} =
               Availability.next_bookable(user.id, inactive.id, DateTime.utc_now())
    end

    test "another user's meeting type is not found" do
      %{user: user} = create_bookable_profile()

      assert {:error, :not_found} =
               Availability.next_bookable(user.id, insert(:meeting_type).id, DateTime.utc_now())
    end
  end

  defp at(date, time), do: DateTime.new!(date, time, "Etc/UTC")
  defp unix_at(date, time), do: date |> at(time) |> DateTime.to_unix()

  defp unix(windows),
    do: Enum.map(windows, &{DateTime.to_unix(&1.start_at), DateTime.to_unix(&1.end_at)})

  # What the booking page offers on each day of the range, read back into
  # instants on the host's clock and merged as the windows are.
  defp page_windows(host, range_start, range_end, duration, timezone) do
    request = %{profile: host.profile, user_timezone: timezone, meeting_type: host.meeting_type}

    range_start
    |> Date.range(range_end)
    |> Enum.flat_map(fn day ->
      {:ok, labels} = Offer.slots_for_date(request, Date.to_iso8601(day), duration)

      Enum.map(labels, fn label ->
        start =
          day
          |> DateTime.new!(TimeSlots.parse_time_slot(label), timezone)
          |> DateTime.shift_zone!("Etc/UTC")

        {start, DateTime.add(start, duration, :minute)}
      end)
    end)
    |> Intervals.merge()
    |> Enum.map(fn {from, to} -> %{start_at: from, end_at: to} end)
  end

  # The second Monday of January next year: a fortnight clear of every clock
  # change in `@timezones`, inside the default 90-day booking window.
  defp frozen_monday do
    Date.utc_today().year
    |> Kernel.+(1)
    |> Date.new!(1, 4)
    |> Date.beginning_of_week(:monday)
    |> Date.add(7)
  end

  # A host open 11:00-17:00 every day under the generated rules, with its own
  # bookings on the range's second day, an optional unavailable-day override
  # on the third and time off on the fourth.
  defp create_host(timezone, duration, rules, range_start) do
    %{user: user, profile: profile, schedule: schedule} =
      create_bookable_profile(
        timezone: timezone,
        days: Enum.to_list(1..7),
        profile: %{max_bookings_per_day: rules.max_bookings_per_day}
      )

    schedule
    |> Changeset.change(
      buffer_before_minutes: rules.buffer_before_minutes,
      buffer_after_minutes: rules.buffer_after_minutes,
      min_advance_hours: rules.min_advance_hours
    )
    |> Repo.update!()

    day_start = DateTime.new!(Date.add(range_start, 1), ~T[11:00:00], timezone)

    for booking <- 0..(rules.existing_bookings - 1)//1 do
      start_time = DateTime.add(day_start, booking * 30, :minute)

      insert(:meeting,
        organizer_user_id: user.id,
        start_time: start_time,
        end_time: DateTime.add(start_time, 30, :minute)
      )
    end

    if rules.override? do
      insert(:availability_override,
        schedule: schedule,
        date: Date.add(range_start, 2),
        override_type: "unavailable"
      )
    end

    if rules.time_off? do
      insert(:time_off_period,
        profile: profile,
        starts_on: Date.add(range_start, 3),
        ends_on: Date.add(range_start, 3),
        start_time: ~T[12:00:00],
        end_time: ~T[14:00:00]
      )
    end

    meeting_type =
      insert(:meeting_type,
        user: user,
        duration_minutes: duration,
        slot_interval_minutes: rules.slot_interval_minutes
      )

    %{user: user, profile: profile, meeting_type: meeting_type}
  end

  defp rules_generator do
    gen all(
          buffer_before_minutes <- member_of([0, 15, 30]),
          buffer_after_minutes <- member_of([0, 15, 30]),
          min_advance_hours <- member_of([0, 5, 30]),
          slot_interval_minutes <- member_of([nil, 15, 30, 60]),
          {max_bookings_per_day, existing_bookings} <- booking_limit(),
          override? <- boolean(),
          time_off? <- boolean()
        ) do
      %{
        buffer_before_minutes: buffer_before_minutes,
        buffer_after_minutes: buffer_after_minutes,
        min_advance_hours: min_advance_hours,
        slot_interval_minutes: slot_interval_minutes,
        max_bookings_per_day: max_bookings_per_day,
        existing_bookings: existing_bookings,
        override?: override?,
        time_off?: time_off?
      }
    end
  end

  defp booking_limit do
    one_of([
      bind(integer(0..2), fn count -> constant({nil, count}) end),
      bind(integer(1..3), fn cap -> map(integer(0..cap), &{cap, &1}) end)
    ])
  end

  # 0-4 blocking events, each on one of the range's seven days.
  defp events_generator(range_start, timezone) do
    gen all(
          specs <-
            list_of(tuple({integer(0..6), integer(600..1080), integer(20..180)}), max_length: 4)
        ) do
      Enum.map(specs, fn {day, start_min, len} ->
        date = Date.add(range_start, day)
        start_dt = DateTime.new!(date, minutes_to_time(start_min), timezone)
        end_dt = DateTime.new!(date, minutes_to_time(min(start_min + len, 1439)), timezone)

        %{
          uid: "windows-#{System.unique_integer([:positive])}",
          start_time: start_dt,
          end_time: end_dt,
          status: "confirmed",
          transparency: "opaque"
        }
      end)
    end
  end

  defp minutes_to_time(minutes), do: Time.new!(div(minutes, 60), rem(minutes, 60), 0)
end
