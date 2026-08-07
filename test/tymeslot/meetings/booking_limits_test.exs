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

    test "weeks start on Monday" do
      # 2026-07-19 is a Sunday; its week began Monday 2026-07-13
      assert BookingLimits.week_key(~U[2026-07-19 10:00:00Z], "Etc/UTC") == ~D[2026-07-13]
      # A Monday is its own week key
      assert BookingLimits.week_key(~U[2026-07-13 10:00:00Z], "Etc/UTC") == ~D[2026-07-13]
    end

    test "month key is the first of the host-timezone month" do
      # 23:30 UTC on 31 July is already 1 August in Berlin (UTC+2 in summer)
      assert BookingLimits.month_key(~U[2026-07-31 23:30:00Z], "Europe/Berlin") == ~D[2026-08-01]
      assert BookingLimits.month_key(~U[2026-07-31 23:30:00Z], "Etc/UTC") == ~D[2026-07-01]
    end
  end

  describe "expanded_query_window/3" do
    test "covers the full enclosing months and weeks of the padded range" do
      {from_utc, to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-10], ~D[2026-07-20], "Etc/UTC")

      # Padded range is 09..21 July; enclosing month spans the whole of July.
      assert from_utc == ~U[2026-07-01 00:00:00Z]
      assert to_utc == ~U[2026-08-01 00:00:00Z]
    end

    test "the one-day pad pulls in the neighbouring week and month" do
      # Padding 01 July back to 30 June pulls in June's month span and the
      # Monday (29 June) starting that week.
      {from_utc, to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-01], ~D[2026-07-31], "Etc/UTC")

      assert from_utc == ~U[2026-06-01 00:00:00Z]
      # 01 August (padded end) sits in the week ending Sunday 02 August and
      # the month ending 31 August; the month wins.
      assert to_utc == ~U[2026-09-01 00:00:00Z]
    end

    test "bounds are host-timezone midnights expressed in UTC" do
      {from_utc, _to_utc} =
        BookingLimits.expanded_query_window(~D[2026-07-10], ~D[2026-07-10], @host_plus12)

      # July 2026: padded range 09..11 July, enclosing month = July, whose
      # host midnight (01 July 00:00 at UTC+12) is 30 June 12:00 UTC.
      assert from_utc == ~U[2026-06-30 12:00:00Z]
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
