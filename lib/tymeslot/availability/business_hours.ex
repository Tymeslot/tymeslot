defmodule Tymeslot.Availability.BusinessHours do
  @moduledoc """
  Pure functions for business hours calculations.
  Handles business hours definitions and timezone conversions.
  Uses the weekly availability of a named availability schedule.
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
        schedule_id,
        owner_timezone,
        user_timezone,
        config \\ %{}
      )

  def get_business_hours_in_timezone(date, nil, owner_timezone, user_timezone, _config) do
    get_business_hours_in_timezone_fallback(date, owner_timezone, user_timezone)
  end

  def get_business_hours_in_timezone(date, schedule_id, owner_timezone, user_timezone, config) do
    override = lookup_override(date, schedule_id, config)

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
        day_availability = lookup_day_availability(day_of_week, schedule_id, config)

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

  @typedoc "A business-hours window for a single day, expressed in the user's timezone."
  @type slot_window :: %{
          required(:start_dt) => DateTime.t(),
          required(:end_dt) => DateTime.t(),
          required(:date) => Date.t()
        }

  @doc """
  Returns the business-hours windows that can produce slots on `target_date`
  in the user's timezone. Adjacent days are considered because business hours
  in the owner's timezone may bleed across midnight in the user's timezone.
  """
  @spec windows_for_target_date(
          Date.t(),
          integer() | nil,
          String.t(),
          String.t(),
          Calculate.availability_config()
        ) :: [slot_window()]
  def windows_for_target_date(target_date, schedule_id, owner_timezone, user_timezone, config) do
    Enum.flat_map([Date.add(target_date, -1), target_date, Date.add(target_date, 1)], fn d ->
      case get_business_hours_in_timezone(d, schedule_id, owner_timezone, user_timezone, config) do
        {:ok, %{start_datetime: %DateTime{} = start_dt, end_datetime: %DateTime{} = end_dt}} ->
          if DateTime.to_date(start_dt) == target_date or
               DateTime.to_date(end_dt) == target_date do
            [%{start_dt: start_dt, end_dt: end_dt, date: d}]
          else
            []
          end

        _other ->
          []
      end
    end)
  end

  @doc """
  Returns the breaks for a date as a list of `{start_time, end_time}` tuples,
  reading from preloaded weekly schedule when available.
  """
  @spec breaks_for_day(Date.t(), integer() | nil, Calculate.availability_config()) ::
          [{Time.t(), Time.t()}]
  def breaks_for_day(date, schedule_id, config) do
    day_of_week = Date.day_of_week(date)

    case lookup_day_availability(day_of_week, schedule_id, config) do
      %{breaks: breaks} when is_list(breaks) ->
        Enum.map(breaks, &{&1.start_time, &1.end_time})

      _other ->
        []
    end
  end

  @doc """
  Fallback for callers with no resolvable availability schedule.
  Uses the hard-coded fallback hours when no schedule is resolvable.
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
  Checks if a given date is a business day within a schedule.

  Accepts preloaded data via `config` to avoid per-date DB queries.
  """
  @spec business_day?(Date.t(), integer() | nil, Calculate.availability_config()) :: boolean()
  def business_day?(date, schedule_id, config \\ %{})

  def business_day?(date, nil, _config) do
    Date.day_of_week(date) in @fallback_working_days
  end

  def business_day?(date, schedule_id, config) do
    override = lookup_override(date, schedule_id, config)

    case override do
      %{override_type: "unavailable"} ->
        false

      %{override_type: type} when type in ["custom_hours", "available"] ->
        true

      _no_override ->
        day_of_week = Date.day_of_week(date)
        day_availability = lookup_day_availability(day_of_week, schedule_id, config)

        match?(%{is_available: true}, day_availability)
    end
  end

  # Data lookup — uses preloaded collections when available, falls back to DB queries

  defp lookup_override(date, schedule_id, %{overrides: overrides}) when is_list(overrides) do
    Enum.find(overrides, &(&1.date == date and &1.schedule_id == schedule_id))
  end

  defp lookup_override(date, schedule_id, _config) do
    AvailabilityOverrideQueries.get_override_by_schedule_and_date(schedule_id, date)
  end

  @doc false
  @spec lookup_day_availability(integer(), integer() | nil, Calculate.availability_config()) ::
          day_availability() | nil
  def lookup_day_availability(_day_of_week, nil, _config), do: nil

  def lookup_day_availability(day_of_week, _schedule_id, %{weekly_schedule: schedule})
      when is_list(schedule) do
    Enum.find(schedule, &(&1.day_of_week == day_of_week))
  end

  def lookup_day_availability(day_of_week, schedule_id, _config) do
    WeeklySchedule.get_day_availability(schedule_id, day_of_week)
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
