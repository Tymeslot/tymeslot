defmodule TymeslotWeb.Live.Scheduling.CalendarNavigationTest do
  use ExUnit.Case, async: true
  @moduletag :scheduling

  alias TymeslotWeb.Live.Scheduling.CalendarNavigation

  describe "next_month_disabled?/4" do
    test "allows navigation within advance booking window" do
      today = Date.utc_today()

      refute CalendarNavigation.next_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC",
               90
             )
    end

    # Both sides of the boundary, derived from today rather than assumed, so
    # these hold on the last day of a month as well as the middle of one. The
    # old version passed 1 day and asserted "disabled", which is only true when
    # tomorrow is still in this month.
    test "allows navigation when the next month's first day is the last bookable day" do
      today = Date.utc_today()
      reaches_first = today |> Date.end_of_month() |> Date.add(1) |> Date.diff(today)

      refute CalendarNavigation.next_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC",
               reaches_first
             )
    end

    test "disables navigation when the window stops one day short of the next month" do
      today = Date.utc_today()
      stops_short = (today |> Date.end_of_month() |> Date.add(1) |> Date.diff(today)) - 1

      assert CalendarNavigation.next_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC",
               stops_short
             )
    end

    test "works with advance_booking_days greater than 90" do
      today = Date.utc_today()
      # With 365 days advance booking, months well into the future should be reachable
      far_future = Date.add(today, 180)

      refute CalendarNavigation.next_month_disabled?(
               far_future.year,
               far_future.month,
               "Etc/UTC",
               365
             )
    end

    test "handles December to January boundary" do
      # December should allow navigating to January of next year if within window
      refute CalendarNavigation.next_month_disabled?(
               Date.utc_today().year,
               12,
               "Etc/UTC",
               365
             )
    end
  end

  describe "next_week_disabled?/3" do
    test "allows navigation within advance booking window" do
      today = Date.utc_today()
      refute CalendarNavigation.next_week_disabled?(today, "Etc/UTC", 90)
    end

    test "disables navigation beyond advance booking window" do
      today = Date.utc_today()
      far_future = Date.add(today, 100)
      assert CalendarNavigation.next_week_disabled?(far_future, "Etc/UTC", 90)
    end

    test "works with advance_booking_days greater than 90" do
      today = Date.utc_today()
      far_future = Date.add(today, 180)

      refute CalendarNavigation.next_week_disabled?(far_future, "Etc/UTC", 365)
    end
  end

  describe "prev_month_disabled?/3" do
    test "disables navigation to months before current" do
      today = Date.utc_today()

      assert CalendarNavigation.prev_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC"
             )
    end

    test "allows navigation when viewing future month" do
      today = Date.utc_today()
      future = Date.add(today, 60)

      refute CalendarNavigation.prev_month_disabled?(
               future.year,
               future.month,
               "Etc/UTC"
             )
    end
  end

  describe "prev_week_disabled?/2" do
    test "disables navigation when previous week ends before today" do
      today = Date.utc_today()
      assert CalendarNavigation.prev_week_disabled?(today, "Etc/UTC")
    end

    test "allows navigation when previous week overlaps today" do
      future = Date.add(Date.utc_today(), 14)
      refute CalendarNavigation.prev_week_disabled?(future, "Etc/UTC")
    end
  end
end
