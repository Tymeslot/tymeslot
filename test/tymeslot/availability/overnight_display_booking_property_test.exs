defmodule Tymeslot.Availability.OvernightDisplayBookingPropertyTest do
  @moduledoc """
  Any slot the booking page offers can be booked, for hosts whose hours run
  past midnight and bookers far from them, on both the date a window opens
  and the date after. Complements
  `Tymeslot.Availability.DisplayBookingConsistencyPropertyTest`, whose hosts
  keep 11:00 to 17:00 so their windows never meet a day boundary.

  The booked meeting must also land on the instant offered: the date the
  slot was listed under plus its label, resolved in the booker's zone.

  Hosts and bookers include Pacific/Pago_Pago (UTC-11) and Pacific/Kiritimati
  (UTC+14), 25 hours apart, so a booker's date can reach host dates two days
  away; most hosts carry a daily booking cap and already hold one booking
  near the date, so the page's limit counts are checked against the submit's
  across that gap too: every slot offered must pass the submit's own limit
  check, not just the one booked. Half the runs place that pair on the one
  date where a booker's day reaches a host date two days away, with the
  host's booking on that far date. The dates run from Saturday 30 January to Tuesday
  02 February 2027, across a Sunday that ends both a week and a month, with
  the clock frozen ten days before, so the counts cannot borrow the host's
  date from an enclosing week or month they read anyway.
  """

  use Tymeslot.DataCase, async: false
  use ExUnitProperties

  @moduletag :availability
  @moduletag :integration

  import Mox
  import Tymeslot.AvailabilityTestHelpers
  import Tymeslot.Test.ClockHelpers

  alias Tymeslot.Bookings.Create
  alias Tymeslot.CalendarMock
  alias Tymeslot.Meetings.BookingLimits.Checker
  alias Tymeslot.Meetings.MeetingSchema
  alias Tymeslot.Profiles
  alias Tymeslot.TestMocks
  alias Tymeslot.Utils.DateTimeUtils

  setup :verify_on_exit!

  setup do
    TestMocks.setup_all_mocks()
    stub(CalendarMock, :get_events_for_range_fresh, fn _user_id, _start, _end -> {:ok, []} end)
    freeze_clock(~U[2027-01-20 12:00:00Z])
    :ok
  end

  @host_zones [
    "Europe/London",
    "America/New_York",
    "Asia/Kolkata",
    "Australia/Sydney",
    "Pacific/Pago_Pago",
    "Pacific/Kiritimati"
  ]
  @booker_zones [
    "Europe/London",
    "America/Los_Angeles",
    "Asia/Tokyo",
    "Pacific/Auckland",
    "America/Santiago",
    "Pacific/Kiritimati",
    "Pacific/Pago_Pago"
  ]

  @hours [
    %{start_time: ~T[22:00:00], end_time: ~T[02:00:00], ends_next_day: true},
    %{start_time: ~T[18:00:00], end_time: ~T[06:00:00], ends_next_day: true},
    %{start_time: ~T[00:00:00], end_time: ~T[00:00:00], ends_next_day: true},
    %{start_time: ~T[09:00:00], end_time: ~T[17:00:00], ends_next_day: false}
  ]

  @far_pairs [
    {"Pacific/Pago_Pago", "Pacific/Kiritimati"},
    {"Pacific/Kiritimati", "Pacific/Pago_Pago"}
  ]

  @dates Enum.to_list(Date.range(~D[2027-01-30], ~D[2027-02-02]))

  @offering_runs :overnight_property_offering_runs
  @capped_offering_runs :overnight_property_capped_offering_runs
  @far_capped_offering_runs :overnight_property_far_capped_offering_runs

  property "any slot offered across midnight can be booked, at the instant offered" do
    Process.put(@offering_runs, 0)
    Process.put(@capped_offering_runs, 0)
    Process.put(@far_capped_offering_runs, 0)

    check all(
            {host_tz, booker_tz, date, booked_day} <- scenario(),
            hours <- member_of(@hours),
            duration <- member_of([30, 60, 240, 1440]),
            picker <- integer(0..9_999),
            daily_cap <- member_of([nil, 1, 1, 2]),
            booked_hour <- integer(0..23),
            max_runs: 50
          ) do
      host =
        create_bookable_profile(
          timezone: host_tz,
          days: Enum.to_list(1..7),
          hours: Map.put(hours, :is_available, true),
          profile: %{max_bookings_per_day: daily_cap}
        )

      insert_booking(
        host,
        DateTime.new!(Date.add(date, booked_day), Time.new!(booked_hour, 0, 0), host_tz)
      )

      slots = offered(host.profile, date, duration, timezone: booker_tz)

      if slots != [] do
        count_offering_run(daily_cap, {host_tz, booker_tz})
        assert_limits_agree(host, slots, date, booker_tz)

        chosen = Enum.at(slots, rem(picker, length(slots)))

        result =
          Create.execute(
            %{
              date: date,
              time: chosen,
              duration: "#{duration}min",
              user_timezone: booker_tz,
              organizer_user_id: host.user.id,
              meeting_type_id: nil
            },
            %{
              "name" => "Property",
              "email" => "p-#{System.unique_integer([:positive])}@example.com",
              "message" => ""
            }
          )

        assert {:ok, %MeetingSchema{} = meeting} = result,
               "offered #{chosen} on #{date} to #{booker_tz} for a #{host_tz} host with #{inspect(hours)}, " <>
                 "#{duration} min, daily cap #{inspect(daily_cap)}, but booking failed: #{inspect(result)}"

        {:ok, time} = DateTimeUtils.parse_time_string(chosen)
        {:ok, expected} = DateTimeUtils.resolve_local(date, time, booker_tz)
        assert DateTime.compare(meeting.start_time, expected) == :eq
      end
    end

    assert Process.get(@offering_runs) > 10, "too few runs offered anything"
    assert Process.get(@capped_offering_runs) > 5, "too few capped runs offered anything"

    assert Process.get(@far_capped_offering_runs) > 3,
           "too few capped runs 25 hours apart offered anything"
  end

  # `{host_tz, booker_tz, date, booked_day}`: the host's existing booking
  # falls on the host date `booked_day` days from `date`. Half the runs pair
  # the two zones 25 hours apart, in either direction, on the date whose
  # booker day reaches a host date two days away outside every week and
  # month the page reads anyway (Tuesday 02 February from Kiritimati reaches
  # Sunday 31 January in Pago Pago; Saturday 30 January from Pago Pago
  # reaches Monday 01 February in Kiritimati), with the booking on that date.
  defp scenario do
    one_of([
      tuple(
        {member_of(@host_zones), member_of(@booker_zones), member_of(@dates), integer(-2..2)}
      ),
      member_of([
        {"Pacific/Pago_Pago", "Pacific/Kiritimati", ~D[2027-02-02], -2},
        {"Pacific/Kiritimati", "Pacific/Pago_Pago", ~D[2027-01-30], 2}
      ])
    ])
  end

  defp count_offering_run(nil, _zones), do: bump(@offering_runs)

  defp count_offering_run(_daily_cap, zones) do
    bump(@offering_runs)
    bump(@capped_offering_runs)

    if zones in @far_pairs, do: bump(@far_capped_offering_runs)
  end

  defp bump(key), do: Process.put(key, Process.get(key) + 1)

  # The submit's own limit check, as `Tymeslot.Bookings.Create` runs it,
  # passes every slot the page offers.
  defp assert_limits_agree(host, slots, date, booker_tz) do
    settings = Profiles.get_profile_settings(host.user.id)

    refused =
      Enum.reject(slots, fn slot ->
        {:ok, time} = DateTimeUtils.parse_time_string(slot)
        {:ok, instant} = DateTimeUtils.resolve_local(date, time, booker_tz)
        Checker.check_booking_allowed(host.user.id, settings, nil, instant) == :ok
      end)

    assert refused == [],
           "offered #{inspect(refused)} on #{date} to #{booker_tz} for a #{host.profile.timezone} " <>
             "host, but the submit refuses them for the booking limits"
  end

  # One booking the host already holds, half an hour long.
  defp insert_booking(host, start_time) do
    insert(:meeting,
      organizer_user_id: host.user.id,
      start_time: start_time,
      end_time: DateTime.add(start_time, 30, :minute),
      duration: 30,
      status: "confirmed"
    )
  end
end
