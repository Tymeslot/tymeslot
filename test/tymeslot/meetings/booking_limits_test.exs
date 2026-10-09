defmodule Tymeslot.Meetings.BookingLimitsTest do
  @moduledoc false

  use ExUnit.Case, async: true

  @moduletag :meetings
  @moduletag :unit

  alias Tymeslot.Meetings.BookingLimits

  # Fixed-offset zone (UTC+12, no DST) keeps host-day expectations stable
  # year-round; Pacific/Auckland covers the real-tzdata path elsewhere.
  @host_plus12 "Etc/GMT-12"

  describe "period keys resolve in the host timezone" do
    test "an instant late in the UTC day belongs to the next host day" do
      # 12:30 UTC is 00:30 the next day at UTC+12
      assert BookingLimits.day_key(~U[2026-07-18 12:30:00Z], @host_plus12) == ~D[2026-07-19]
      assert BookingLimits.day_key(~U[2026-07-18 11:30:00Z], @host_plus12) == ~D[2026-07-18]
    end
  end

  describe "expanded_query_window/3" do
    test "covers the full enclosing months and weeks of the range" do
      {from_utc, to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-10], ~D[2026-07-20], "Etc/UTC")

      assert from_utc == ~U[2026-07-01 00:00:00Z]
      assert to_utc == ~U[2026-08-01 00:00:00Z]
    end

    test "a week straddling a month edge pulls in the neighbouring month's days" do
      # 01 July 2026 is a Wednesday, so its week starts on Monday 29 June;
      # 31 July is a Friday, so its week ends on Sunday 02 August.
      {from_utc, to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-01], ~D[2026-07-31], "Etc/UTC")

      assert from_utc == ~U[2026-06-29 00:00:00Z]
      assert to_utc == ~U[2026-08-03 00:00:00Z]
    end

    test "bounds are host-timezone midnights expressed in UTC" do
      {from_utc, _to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-10], ~D[2026-07-10], @host_plus12)

      # The enclosing month is July, whose host midnight (01 July 00:00 at
      # UTC+12) is 30 June 12:00 UTC.
      assert from_utc == ~U[2026-06-30 12:00:00Z]
    end
  end

  describe "host_dates/4" do
    test "a booker 25 hours ahead of the host reaches back two host dates" do
      # Tuesday 02 February 00:00 in Kiritimati (UTC+14) is Sunday 31 January
      # 23:00 in Pago Pago (UTC-11).
      assert BookingLimits.host_dates(
               ~D[2027-02-02],
               ~D[2027-02-02],
               "Pacific/Kiritimati",
               "Pacific/Pago_Pago"
             ) == {~D[2027-01-31], ~D[2027-02-01]}
    end

    test "a booker 25 hours behind the host reaches forward two host dates" do
      # Saturday 30 January 23:59:59 in Pago Pago is Monday 01 February
      # 00:59:59 in Kiritimati.
      assert BookingLimits.host_dates(
               ~D[2027-01-30],
               ~D[2027-01-30],
               "Pacific/Pago_Pago",
               "Pacific/Kiritimati"
             ) == {~D[2027-01-31], ~D[2027-02-01]}
    end

    test "a booker in the host's zone keeps their dates" do
      assert BookingLimits.host_dates(~D[2026-07-10], ~D[2026-07-12], "Etc/UTC", "Etc/UTC") ==
               {~D[2026-07-10], ~D[2026-07-12]}
    end
  end

  describe "limits_for/2 and enabled?/1" do
    test "no caps configured means disabled" do
      limits = BookingLimits.limits_for(%{max_bookings_per_day: nil}, nil)
      refute BookingLimits.enabled?(limits)
    end

    test "any single cap enables enforcement" do
      assert BookingLimits.enabled?(BookingLimits.limits_for(%{max_bookings_per_week: 5}, nil))

      assert BookingLimits.enabled?(
               BookingLimits.limits_for(%{}, %{id: 1, max_bookings_per_month: 10})
             )
    end
  end

  describe "slot_blocked?/2" do
    defp context(profile_caps, type_caps, rows) do
      meeting_type = type_caps && Map.put(type_caps, :id, 7)
      limits = BookingLimits.limits_for(profile_caps, meeting_type)
      BookingLimits.build_context(limits, "Etc/UTC", rows)
    end

    defp row(dt, type_id \\ 7), do: %{start_time: dt, meeting_type_id: type_id}

    test "account-wide daily cap counts bookings of every type" do
      ctx =
        context(%{max_bookings_per_day: 2}, nil, [
          row(~U[2026-07-20 09:00:00Z], 7),
          row(~U[2026-07-20 10:00:00Z], 99)
        ])

      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 15:00:00Z])
      refute BookingLimits.slot_blocked?(ctx, ~U[2026-07-21 15:00:00Z])
    end

    test "per-type daily cap ignores other types" do
      ctx =
        context(%{}, %{max_bookings_per_day: 1}, [
          row(~U[2026-07-20 09:00:00Z], 99)
        ])

      refute BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 15:00:00Z])

      ctx =
        context(%{}, %{max_bookings_per_day: 1}, [
          row(~U[2026-07-20 09:00:00Z], 7)
        ])

      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 15:00:00Z])
    end

    test "weekly cap blocks the whole Monday-to-Sunday week" do
      # 2026-07-20 is a Monday
      ctx = context(%{max_bookings_per_week: 1}, nil, [row(~U[2026-07-22 09:00:00Z])])

      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 15:00:00Z])
      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-26 15:00:00Z])
      refute BookingLimits.slot_blocked?(ctx, ~U[2026-07-27 09:00:00Z])
    end

    test "monthly cap counts bookings anywhere in the host month" do
      ctx = context(%{max_bookings_per_month: 1}, nil, [row(~U[2026-07-02 09:00:00Z])])

      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-30 15:00:00Z])
      refute BookingLimits.slot_blocked?(ctx, ~U[2026-08-01 15:00:00Z])
    end

    test "bookings bucket by host day, not booker day" do
      limits = BookingLimits.limits_for(%{max_bookings_per_day: 1}, nil)

      # 11:00 UTC is host day 20 July at UTC+12; 13:00 UTC is host day 21 July.
      ctx =
        BookingLimits.build_context(limits, @host_plus12, [row(~U[2026-07-20 11:00:00Z], nil)])

      assert BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 10:00:00Z])
      refute BookingLimits.slot_blocked?(ctx, ~U[2026-07-20 13:00:00Z])
    end

    test "check_booking_allowed/2 mirrors slot_blocked?/2" do
      ctx = context(%{max_bookings_per_day: 1}, nil, [row(~U[2026-07-20 09:00:00Z])])

      assert BookingLimits.check_booking_allowed(ctx, ~U[2026-07-20 15:00:00Z]) ==
               {:error, :booking_limit_reached}

      assert BookingLimits.check_booking_allowed(ctx, ~U[2026-07-21 15:00:00Z]) == :ok
    end
  end
end
