defmodule TymeslotWeb.Live.Scheduling.CalendarNavigation do
  @moduledoc """
  Calendar navigation boundary helpers for the scheduling flow.
  Pure functions for determining month and week navigation limits.
  """

  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Checks if previous month navigation should be disabled.
  """
  @spec prev_month_disabled?(integer(), integer(), String.t()) :: boolean()
  def prev_month_disabled?(current_year, current_month, user_timezone) do
    today = today_in_timezone(user_timezone)
    current_year < today.year || (current_year == today.year && current_month <= today.month)
  end

  @doc """
  Checks if next month navigation should be disabled.
  """
  @spec next_month_disabled?(integer(), integer(), String.t(), integer()) :: boolean()
  def next_month_disabled?(current_year, current_month, user_timezone, advance_booking_days) do
    today = today_in_timezone(user_timezone)
    max_booking_date = Date.add(today, advance_booking_days)

    next_month_first_day =
      if current_month == 12 do
        Date.new!(current_year + 1, 1, 1)
      else
        Date.new!(current_year, current_month + 1, 1)
      end

    Date.compare(next_month_first_day, max_booking_date) != :lt
  end

  @doc """
  Checks if previous week navigation should be disabled.
  Disabled when the previous week would end entirely before today.
  """
  @spec prev_week_disabled?(Date.t(), String.t()) :: boolean()
  def prev_week_disabled?(current_week_start, user_timezone) do
    today = today_in_timezone(user_timezone)
    prev_week_end = Date.add(current_week_start, -1)
    Date.compare(prev_week_end, today) == :lt
  end

  @doc """
  Checks if next week navigation should be disabled.
  Disabled when the next week would start entirely past the max booking date.
  """
  @spec next_week_disabled?(Date.t(), String.t(), integer()) :: boolean()
  def next_week_disabled?(current_week_start, user_timezone, advance_booking_days) do
    today = today_in_timezone(user_timezone)
    max_booking_date = Date.add(today, advance_booking_days)
    next_week_start = Date.add(current_week_start, 7)
    Date.compare(next_week_start, max_booking_date) == :gt
  end

  defp today_in_timezone(user_timezone) do
    user_timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()
  end
end
