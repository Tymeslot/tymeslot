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

    test "disables navigation beyond advance booking window" do
      today = Date.utc_today()
      # With only 1 day advance booking, next month should be disabled
      assert CalendarNavigation.next_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC",
               1
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

    test "disables navigation when max booking date equals first of next month" do
      today = Date.utc_today()
      # Calculate days until the first of next month
      next_month_first =
        if today.month == 12,
          do: Date.new!(today.year + 1, 1, 1),
          else: Date.new!(today.year, today.month + 1, 1)

      days_until = Date.diff(next_month_first, today)

      assert CalendarNavigation.next_month_disabled?(
               today.year,
               today.month,
               "Etc/UTC",
               days_until
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
