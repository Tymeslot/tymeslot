defmodule Tymeslot.Availability.OfferRangeTest do
  @moduledoc """
  `Offer.slots_for_range/4`: the free times on every day of a range, for a
  week view.

  The property is the whole contract: each day of the range is exactly what
  `Offer.slots_for_date/3` offers for that day, across the host's rules
  (the buffers before and after, notice, slot interval, a daily booking cap
  with bookings counting against it, an unavailable-day override, a stretch of
  time off), the booker's timezone, the host's calendar and a reschedule. The
  range reads the host's calendar once where the per-day path reads it once a
  day, so the examples below pin that and the refusals.

  The clock is frozen for every test: today is in every range, and a slot
  starting between the two computations would otherwise pass its notice
  cut-off in one and not the other.
  """

  use Tymeslot.DataCase, async: false
  use ExUnitProperties

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers

  alias Ecto.Changeset
  alias Tymeslot.Availability.Offer
  alias Tymeslot.CalendarMock
  alias Tymeslot.Clock
  alias Tymeslot.Test.ClockHelpers
  alias Tymeslot.TestMocks

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    TestMocks.stub_no_calendar_events()
    ClockHelpers.freeze_clock(DateTime.utc_now(:second))
    :ok
  end

  # The host's and the booker's zones are drawn independently from these:
  # positive, negative, half-hour and no offset, and both hemispheres' DST.
  @timezones [
    "Etc/UTC",
    "Europe/Berlin",
    "America/New_York",
    "Asia/Tokyo",
    "Asia/Kolkata",
    "Pacific/Auckland"
  ]

  # Counts the runs whose range offered anything, so a generator change that
  # emptied every day fails the property instead of passing it vacuously.
  @offering_runs :offer_range_property_offering_runs

  property "each day of the range is exactly what slots_for_date/3 offers for it" do
    today = Clock.utc_today()
    Process.put(@offering_runs, 0)

    check all(
            host_timezone <- member_of(@timezones),
            booker_timezone <- member_of(@timezones),
            duration <- member_of([15, 30, 60]),
            rules <- rules_generator(),
            offset <- integer(0..3),
            events <- events_generator(Date.add(today, offset), host_timezone),
            max_runs: 25
          ) do
      assert_range_matches_days(
        Date.add(today, offset),
        host_timezone,
        booker_timezone,
        duration,
        rules,
        events
      )
    end

    assert Process.get(@offering_runs) > 0,
           "every run offered nothing at all, so no day was ever compared"
  end

  # The plain property starts within three days of today, which almost never
  # meets a clock change. Here the clock is frozen three days before the last
  # Sunday of March or October of next year, so a range starting 0-3 days on
  # always spans that Sunday: European hosts change zone mid-range, and a
  # booker elsewhere sees the shift as a 23 or 25 hour day.
  property "the equivalence holds across a DST transition" do
    year = Clock.utc_today().year + 1
    Process.put(@offering_runs, 0)

    check all(
            sunday <- member_of([last_sunday(year, 3), last_sunday(year, 10)]),
            host_timezone <- member_of(["Europe/Berlin", "Europe/London"]),
            booker_timezone <- member_of(@timezones),
            duration <- member_of([15, 30, 60]),
            rules <- rules_generator(),
            offset <- integer(0..3),
            events <- events_generator(Date.add(sunday, offset - 3), host_timezone),
            max_runs: 25
          ) do
      frozen_today = Date.add(sunday, -3)
      ClockHelpers.freeze_clock(DateTime.new!(frozen_today, ~T[08:00:00], "Etc/UTC"))
      range_start = Date.add(frozen_today, offset)

      assert_range_matches_days(
        range_start,
        host_timezone,
        booker_timezone,
        duration,
        rules,
        events
      )
    end

    assert Process.get(@offering_runs) > 0,
           "every run offered nothing at all, so no day was ever compared"
  end

  describe "slots_for_range/4" do
    test "maps every day of the range, a day with nothing free to []" do
      %{profile: profile} = create_bookable_profile(days: [1, 2, 3, 4, 5])
      start_date = next_monday()

      assert {:ok, range} =
               Offer.slots_for_range(
                 %{profile: profile, user_timezone: "Etc/UTC"},
                 start_date,
                 Date.add(start_date, 6),
                 30
               )

      assert map_size(range) == 7
      assert "11:00 AM" in range[Date.to_iso8601(start_date)]
      assert range[start_date |> Date.add(5) |> Date.to_iso8601()] == []
      assert range[start_date |> Date.add(6) |> Date.to_iso8601()] == []
    end

    test "reads the host's calendar once for the whole range" do
      %{profile: profile} = create_bookable_profile()
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        send(test_pid, :calendar_read)
        {:ok, []}
      end)

      start_date = next_monday()

      assert {:ok, _range} =
               Offer.slots_for_range(
                 %{profile: profile, user_timezone: "Etc/UTC"},
                 start_date,
                 Date.add(start_date, 6),
                 30
               )

      assert_received :calendar_read
      refute_received :calendar_read
    end

    test "fails as slots_for_date/3 does when the calendar cannot be read" do
      %{profile: profile} = create_bookable_profile()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        {:error, :timeout}
      end)

      request = %{profile: profile, user_timezone: "Etc/UTC"}
      start_date = next_monday()

      range_result = Offer.slots_for_range(request, start_date, Date.add(start_date, 6), 30)

      assert {:error, _reason} = range_result
      assert range_result == Offer.slots_for_date(request, Date.to_iso8601(start_date), 30)
    end

    test "refuses a range that ends before it starts" do
      %{profile: profile} = create_bookable_profile()
      start_date = next_monday()

      assert {:error, :invalid_range} =
               Offer.slots_for_range(
                 %{profile: profile, user_timezone: "Etc/UTC"},
                 start_date,
                 Date.add(start_date, -1),
                 30
               )
    end

    test "refuses a range longer than six weeks, and answers one of exactly six" do
      %{profile: profile} = create_bookable_profile()
      request = %{profile: profile, user_timezone: "Etc/UTC"}
      start_date = next_monday()

      assert {:ok, range} =
               Offer.slots_for_range(request, start_date, Date.add(start_date, 41), 30)

      assert map_size(range) == 42

      assert {:error, :range_too_long} =
               Offer.slots_for_range(request, start_date, Date.add(start_date, 42), 30)
    end
  end

  describe "slots_for_range/4 on a demo page" do
    defmodule DemoProvider do
      @moduledoc false
      # Only what `Offer` asks of a demo provider: whether the profile is a
      # demo one, and a day's slots. Each day's answer names the day, so a
      # range that answered every day from one call would show it.
      @spec demo_profile?(map() | nil) :: boolean()
      def demo_profile?(_profile), do: false

      @spec get_available_slots(String.t(), term(), String.t(), integer(), map(), map()) ::
              {:ok, [map()]}
      def get_available_slots(date_string, _duration, _timezone, _user_id, _profile, _context),
        do: {:ok, [%{time: "9:00 AM", available: true, date: date_string}]}
    end

    setup do
      previous = Application.get_env(:tymeslot, :demo_provider)
      Application.put_env(:tymeslot, :demo_provider, DemoProvider)

      on_exit(fn ->
        if previous,
          do: Application.put_env(:tymeslot, :demo_provider, previous),
          else: Application.delete_env(:tymeslot, :demo_provider)
      end)

      :ok
    end

    test "answers every day from the demo provider, as slots_for_date/3 does" do
      %{profile: profile} = create_bookable_profile()
      test_pid = self()

      stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
        send(test_pid, :calendar_read)
        {:ok, []}
      end)

      request = %{profile: profile, user_timezone: "Etc/UTC", demo_mode?: true}
      start_date = next_monday()

      assert {:ok, range} =
               Offer.slots_for_range(request, start_date, Date.add(start_date, 2), 30)

      for day <- Enum.map(Date.range(start_date, Date.add(start_date, 2)), &Date.to_iso8601/1) do
        assert range[day] == [%{time: "9:00 AM", available: true, date: day}]
        assert {:ok, range[day]} == Offer.slots_for_date(request, day, 30)
      end

      refute_received :calendar_read
    end
  end

  defp assert_range_matches_days(
         range_start,
         host_timezone,
         booker_timezone,
         duration,
         rules,
         events
       ) do
    range_end = Date.add(range_start, 6)
    host = create_host(host_timezone, duration, rules, range_start)

    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end ->
      {:ok, events}
    end)

    request = %{
      profile: host.profile,
      user_timezone: booker_timezone,
      meeting_type: host.meeting_type,
      reschedule_uid: host.moving_uid
    }

    assert {:ok, range} = Offer.slots_for_range(request, range_start, range_end, duration)

    days = Enum.map(Date.range(range_start, range_end), &Date.to_iso8601/1)
    assert range |> Map.keys() |> Enum.sort() == days

    for day <- days do
      assert {:ok, Map.fetch!(range, day)} == Offer.slots_for_date(request, day, duration),
             "#{day} differs for host #{host_timezone}, booker #{booker_timezone}, " <>
               "#{duration}min under #{inspect(rules)} with #{length(events)} event(s)"
    end

    if Enum.any?(range, fn {_day, slots} -> slots != [] end) do
      Process.put(@offering_runs, Process.get(@offering_runs) + 1)
    end
  end

  defp last_sunday(year, month) do
    last = Date.end_of_month(Date.new!(year, month, 1))
    Date.add(last, -rem(Date.day_of_week(last), 7))
  end

  # The Monday after next: a whole bookable week clear of today and inside
  # the default 90-day booking window.
  defp next_monday do
    today = Clock.utc_today()
    today |> Date.beginning_of_week(:monday) |> Date.add(14)
  end

  # A weekday 11:00-17:00 host carrying the generated rules, with bookings
  # counting against the daily cap on the range's second day, an optional
  # unavailable-day override and stretch of time off, and an optional meeting
  # being rescheduled, which must stay free on its own day.
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

    busy_day = Date.add(range_start, 1)
    day_start = DateTime.new!(busy_day, ~T[08:00:00], timezone)

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

    meeting_type = meeting_type(user, duration, rules)

    moving_uid =
      if rules.reschedule? do
        start_time = DateTime.new!(Date.add(range_start, 4), ~T[12:00:00], timezone)

        meeting =
          insert(:meeting,
            organizer_user_id: user.id,
            meeting_type_id: meeting_type && meeting_type.id,
            start_time: start_time,
            end_time: DateTime.add(start_time, duration, :minute),
            duration: duration,
            status: "confirmed"
          )

        meeting.uid
      end

    %{profile: profile, meeting_type: meeting_type, moving_uid: moving_uid}
  end

  defp meeting_type(_user, _duration, %{slot_interval_minutes: :no_meeting_type}), do: nil

  defp meeting_type(user, duration, %{slot_interval_minutes: interval}) do
    insert(:meeting_type,
      user: user,
      duration_minutes: duration,
      slot_interval_minutes: interval
    )
  end

  defp rules_generator do
    gen all(
          buffer_before_minutes <- member_of([0, 15, 30]),
          buffer_after_minutes <- member_of([0, 15, 30]),
          min_advance_hours <- member_of([0, 5, 30, 480]),
          slot_interval_minutes <- member_of([:no_meeting_type, nil, 15, 30]),
          {max_bookings_per_day, existing_bookings} <- booking_limit(),
          override? <- boolean(),
          time_off? <- boolean(),
          reschedule? <- boolean()
        ) do
      %{
        buffer_before_minutes: buffer_before_minutes,
        buffer_after_minutes: buffer_after_minutes,
        min_advance_hours: min_advance_hours,
        slot_interval_minutes: slot_interval_minutes,
        max_bookings_per_day: max_bookings_per_day,
        existing_bookings: existing_bookings,
        override?: override?,
        time_off?: time_off?,
        reschedule?: reschedule?
      }
    end
  end

  defp booking_limit do
    one_of([
      constant({nil, 0}),
      bind(integer(1..3), fn cap -> map(integer(0..cap), &{cap, &1}) end)
    ])
  end

  # 0-4 blocking events, each on one of the range's seven days, covering a
  # random stretch of it. A start or end in a DST gap is dropped.
  defp events_generator(range_start, timezone) do
    gen all(
          specs <-
            list_of(tuple({integer(0..6), integer(540..1080), integer(20..180)}), max_length: 4)
        ) do
      specs
      |> Enum.map(fn {day, start_min, len} ->
        build_event(Date.add(range_start, day), timezone, start_min, len)
      end)
      |> Enum.reject(&is_nil/1)
    end
  end

  defp build_event(date, timezone, start_min, len) do
    with {:ok, start_dt} <- DateTime.new(date, minutes_to_time(start_min), timezone),
         {:ok, end_dt} <-
           DateTime.new(date, minutes_to_time(min(start_min + len, 1439)), timezone) do
      %{
        uid: "range-#{System.unique_integer([:positive])}",
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
