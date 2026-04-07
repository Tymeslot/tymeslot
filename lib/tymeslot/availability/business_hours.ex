defmodule Tymeslot.Availability.BusinessHours do
  @moduledoc """
  Pure functions for business hours calculations.
  Handles business hours definitions and timezone conversions.
  Uses dynamic weekly availability from user profiles.
  """

  alias Tymeslot.Availability.AvailabilityOverrideQueries
  alias Tymeslot.Availability.Calculate
  alias Tymeslot.Availability.WeeklySchedule
  alias Tymeslot.Utils.DateTimeUtils

  # Fallback business hours configuration (for backwards compatibility)
  @fallback_start_time ~T[11:00:00]
  @fallback_end_time ~T[19:30:00]
  # Monday to Friday
  @fallback_working_days 1..5

  @typedoc "Availability for a single day of the week from a weekly schedule entry."
  @type day_availability :: %{
          required(:is_available) => boolean(),
          required(:day_of_week) => non_neg_integer(),
          optional(:start_time) => Time.t() | nil,
          optional(:end_time) => Time.t() | nil,
          optional(:breaks) => list(term())
        }

  @typedoc "Business hours window for a specific date, with datetimes in the attendee's timezone."
  @type business_hours_result :: %{
          required(:start_datetime) => DateTime.t() | nil,
          required(:end_datetime) => DateTime.t() | nil,
          required(:selected_date) => Date.t()
        }

  @doc """
  Gets the business hours for a date in the user's timezone.

  When `config` contains `:weekly_schedule` and/or `:overrides`, those
  preloaded collections are used instead of issuing per-date DB queries.

  Returns a map with start_datetime, end_datetime, and selected_date.
  For unavailable days, returns nil for start and end datetimes.
  """
  @spec get_business_hours_in_timezone(
          Date.t(),
          integer() | nil,
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: {:ok, business_hours_result()} | {:error, String.t()}
  def get_business_hours_in_timezone(
        date,
        profile_id,
        owner_timezone,
        user_timezone,
        config \\ %{}
      )

  def get_business_hours_in_timezone(date, nil, owner_timezone, user_timezone, _config) do
    get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone)
  end

  def get_business_hours_in_timezone(date, profile_id, owner_timezone, user_timezone, config) do
    override = lookup_override(date, profile_id, config)

    case override do
      %{override_type: "unavailable"} ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}

      %{override_type: type, start_time: start_time, end_time: end_time}
      when type in ["custom_hours", "available"] and start_time != nil and end_time != nil ->
        convert_business_hours_to_user_timezone(
          date,
          start_time,
          end_time,
          owner_timezone,
          user_timezone
        )

      _no_override ->
        day_of_week = Date.day_of_week(date)
        day_availability = lookup_day_availability(day_of_week, profile_id, config)

        case day_availability do
          %{is_available: true, start_time: start_time, end_time: end_time}
          when start_time != nil and end_time != nil ->
            convert_business_hours_to_user_timezone(
              date,
              start_time,
              end_time,
              owner_timezone,
              user_timezone
            )

          _other ->
            {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
        end
    end
  end

  @doc """
  Fallback for profiles without explicit business hours configuration.
  Uses default hardcoded hours when profile_id is not provided.
  """
  @spec get_business_hours_in_timezone_fallback(Date.t(), String.t(), String.t()) ::
          {:ok, business_hours_result()}
  def get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone) do
    case Date.day_of_week(date) do
      day when day in @fallback_working_days ->
        convert_business_hours_to_user_timezone(
          date,
          @fallback_start_time,
          @fallback_end_time,
          owner_timezone,
          user_timezone
        )

      _other ->
        {:ok, %{start_datetime: nil, end_datetime: nil, selected_date: date}}
    end
  end

  @doc """
  Checks if a given date is a business day for a profile.

  Accepts preloaded data via `config` to avoid per-date DB queries.
  """
  @spec business_day?(Date.t(), integer() | nil, Calculate.availability_config()) :: boolean()
  def business_day?(date, profile_id, config \\ %{})

  def business_day?(date, nil, _config) do
    Date.day_of_week(date) in @fallback_working_days
  end

  def business_day?(date, profile_id, config) do
    override = lookup_override(date, profile_id, config)

    case override do
      %{override_type: "unavailable"} ->
        false

      %{override_type: type} when type in ["custom_hours", "available"] ->
        true

      _no_override ->
        day_of_week = Date.day_of_week(date)
        day_availability = lookup_day_availability(day_of_week, profile_id, config)

        match?(%{is_available: true}, day_availability)
    end
  end

  @doc """
  Returns the business hours range for a specific day of week.

  Accepts preloaded data via `config` to avoid per-date DB queries.
  """
  @spec business_hours_range(integer() | nil, integer(), Calculate.availability_config()) ::
          {Time.t() | nil, Time.t() | nil}
  def business_hours_range(profile_id, day_of_week, config \\ %{})

  def business_hours_range(nil, _day_of_week, _config) do
    {@fallback_start_time, @fallback_end_time}
  end

  def business_hours_range(profile_id, day_of_week, config) do
    day_availability = lookup_day_availability(day_of_week, profile_id, config)

    case day_availability do
      %{is_available: true, start_time: start_time, end_time: end_time} ->
        {start_time, end_time}

      _other ->
        {nil, nil}
    end
  end

  @doc """
  Returns default business hours when no profile-specific settings are configured.
  """
  @spec fallback_business_hours_range() :: {Time.t(), Time.t()}
  def fallback_business_hours_range do
    {@fallback_start_time, @fallback_end_time}
  end

  @doc """
  Determines if month navigation should be disabled.
  """
  @spec month_navigation_disabled?(
          atom(),
          integer(),
          integer(),
          String.t(),
          Calculate.availability_config()
        ) :: boolean()
  def month_navigation_disabled?(type, year, month, timezone, config \\ %{}) do
    current_date = timezone |> DateTimeUtils.now_in_timezone() |> DateTime.to_date()
    max_advance_booking_days = Map.get(config, :max_advance_booking_days, 90)

    case type do
      :prev ->
        target_date = Date.new!(year, month, 1)
        Date.compare(target_date, current_date) != :gt

      :next ->
        last_day = year |> Date.new!(month, 1) |> Date.end_of_month()
        max_booking_date = Date.add(current_date, max_advance_booking_days)
        Date.compare(last_day, max_booking_date) != :lt
    end
  end

  # Data lookup — uses preloaded collections when available, falls back to DB queries

  defp lookup_override(date, profile_id, %{overrides: overrides}) when is_list(overrides) do
    Enum.find(overrides, &(&1.date == date and &1.profile_id == profile_id))
  end

  defp lookup_override(date, profile_id, _config) do
    AvailabilityOverrideQueries.get_override_by_profile_and_date(profile_id, date)
  end

  @doc false
  @spec lookup_day_availability(integer(), integer() | nil, Calculate.availability_config()) ::
          day_availability() | nil
  def lookup_day_availability(_day_of_week, nil, _config), do: nil

  def lookup_day_availability(day_of_week, _profile_id, %{weekly_schedule: schedule})
      when is_list(schedule) do
    Enum.find(schedule, &(&1.day_of_week == day_of_week))
  end

  def lookup_day_availability(day_of_week, profile_id, _config) do
    WeeklySchedule.get_day_availability(profile_id, day_of_week)
  end

  # Private functions

  defp convert_business_hours_to_user_timezone(
         date,
         start_time,
         end_time,
         owner_timezone,
         user_timezone
       ) do
    owner_start = DateTimeUtils.create_datetime_safe(date, start_time, owner_timezone)
    owner_end = DateTimeUtils.create_datetime_safe(date, end_time, owner_timezone)

    with {:ok, user_start} <- DateTime.shift_zone(owner_start, user_timezone),
         {:ok, user_end} <- DateTime.shift_zone(owner_end, user_timezone) do
      {:ok, %{start_datetime: user_start, end_datetime: user_end, selected_date: date}}
    else
      _other -> {:error, "Failed to convert business hours to user timezone"}
    end
  end
end
