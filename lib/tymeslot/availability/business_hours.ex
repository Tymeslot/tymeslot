defmodule Tymeslot.Availability.BusinessHours do
  @moduledoc """
  Pure functions for business hours calculations.
  Handles business hours definitions and timezone conversions.
  Now uses dynamic weekly availability from user profiles.
  """

  alias Tymeslot.Availability.WeeklySchedule

  # Fallback business hours configuration (for backwards compatibility)
  @fallback_start_time ~T[11:00:00]
  @fallback_end_time ~T[19:30:00]
  # Monday to Friday
  @fallback_working_days 1..5

  @doc """
  Gets the business hours for a date in the user's timezone.
  Now supports dynamic availability from user profiles.

  Returns a map with start_datetime, end_datetime, and selected_date.
  For unavailable days, returns nil for start and end datetimes.
  """
  @spec get_business_hours_in_timezone(Date.t(), integer(), String.t(), String.t()) ::
          {:ok, map()} | {:error, String.t()}
  def get_business_hours_in_timezone(date, profile_id, owner_timezone, user_timezone) do
    day_of_week = Date.day_of_week(date)

    case WeeklySchedule.get_day_availability(profile_id, day_of_week) do
      %{is_available: true, start_time: start_time, end_time: end_time}
      when start_time != nil and end_time != nil ->
        convert_business_hours_to_user_timezone(
          date,
          start_time,
          end_time,
          owner_timezone,
          user_timezone
        )

      _ ->
        # Day not available - return empty availability window
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end

  @doc """
  Fallback function for profiles without explicit business hours configuration.
  Uses default hardcoded hours when profile_id is not provided.
  """
  @spec get_business_hours_in_timezone(Date.t(), String.t(), String.t()) :: {:ok, map()}
  def get_business_hours_in_timezone(date, owner_timezone, user_timezone) do
    case Date.day_of_week(date) do
      day when day in @fallback_working_days ->
        convert_business_hours_to_user_timezone(
          date,
          @fallback_start_time,
          @fallback_end_time,
          owner_timezone,
          user_timezone
        )

      _ ->
        # Weekend - return empty availability window
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end

  @doc """
  Checks if a given date is a business day for a profile.
  """
  @spec business_day?(Date.t(), integer()) :: boolean()
  def business_day?(date, profile_id) do
    day_of_week = Date.day_of_week(date)

    case WeeklySchedule.get_day_availability(profile_id, day_of_week) do
      %{is_available: true} -> true
      _ -> false
    end
  end

  @doc """
  Checks if a date is a business day using default rules when no profile settings exist.
  """
  @spec business_day?(Date.t()) :: boolean()
  def business_day?(date) do
    Date.day_of_week(date) in @fallback_working_days
  end

  @doc """
  Returns the business hours for a specific day of week for a profile.
  """
  @spec business_hours_range(integer(), integer()) :: {Time.t() | nil, Time.t() | nil}
  def business_hours_range(profile_id, day_of_week) do
    case WeeklySchedule.get_day_availability(profile_id, day_of_week) do
      %{is_available: true, start_time: start_time, end_time: end_time} ->
        {start_time, end_time}

      _ ->
        {nil, nil}
    end
  end

  @doc """
  Returns default business hours when no profile-specific settings are configured.
  """
  @spec business_hours_range() :: {Time.t(), Time.t()}
  def business_hours_range do
    {@fallback_start_time, @fallback_end_time}
  end

  @doc """
  Determines if month navigation should be disabled.
  """
  @spec month_navigation_disabled?(atom(), integer(), integer(), String.t(), map()) :: boolean()
  def month_navigation_disabled?(type, year, month, timezone, config \\ %{}) do
    current_date =
      case DateTime.now(timezone) do
        {:ok, dt} -> DateTime.to_date(dt)
        _ -> Date.utc_today()
      end

    target_date = Date.new!(year, month, 1)
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    case type do
      :prev ->
        # Disable if target month is current month or earlier
        Date.compare(target_date, current_date) != :gt

      :next ->
        # Disable if target month exceeds max advance booking
        months_ahead = (year - current_date.year) * 12 + (month - current_date.month)
        # Rough approximation
        max_months_ahead = div(max_advance_booking_days, 30)
        months_ahead >= max_months_ahead
    end
  end

  # Private functions

  @spec create_datetime_safe(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def create_datetime_safe(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} ->
        datetime

      {:error, _reason} ->
        # Fallback to UTC if timezone is invalid
        DateTime.new!(date, time, "Etc/UTC")
    end
  end

  defp convert_business_hours_to_user_timezone(
         date,
         start_time,
         end_time,
         owner_timezone,
         user_timezone
       ) do
    # Create datetime range in owner's timezone
    owner_start = create_datetime_safe(date, start_time, owner_timezone)
    owner_end = create_datetime_safe(date, end_time, owner_timezone)

    # Convert to user's timezone
    with {:ok, user_start} <- DateTime.shift_zone(owner_start, user_timezone),
         {:ok, user_end} <- DateTime.shift_zone(owner_end, user_timezone) do
      {:ok, %{start_datetime: user_start, end_datetime: user_end, selected_date: date}}
    else
      _ -> {:error, "Failed to convert business hours to user timezone"}
    end
  end
end
