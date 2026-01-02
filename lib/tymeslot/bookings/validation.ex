defmodule Tymeslot.Bookings.Validation do
  @moduledoc """
  Pure validation functions for booking-related data.

  This module contains only pure functions with no side effects or database calls.
  All validation is based on the data passed in as parameters.
  """

  alias Tymeslot.Availability.TimeSlots
  alias Tymeslot.Utils.TimeRange

  @doc """
  Validates buffer minutes are within acceptable range.

  ## Examples

      iex> Validation.valid_buffer_minutes?(15)
      true

      iex> Validation.valid_buffer_minutes?(150)
      false
  """
  @spec valid_buffer_minutes?(any()) :: boolean()
  def valid_buffer_minutes?(minutes) when is_integer(minutes) do
    minutes >= 0 and minutes <= 120
  end

  def valid_buffer_minutes?(_), do: false

  @doc """
  Validates booking window days are within acceptable range.

  ## Examples

      iex> Validation.valid_booking_window?(30)
      true

      iex> Validation.valid_booking_window?(400)
      false
  """
  @spec valid_booking_window?(any()) :: boolean()
  def valid_booking_window?(days) when is_integer(days) do
    days >= 1 and days <= 365
  end

  def valid_booking_window?(_), do: false

  @doc """
  Validates minimum notice hours are within acceptable range.

  ## Examples

      iex> Validation.valid_minimum_notice?(2)
      true

      iex> Validation.valid_minimum_notice?(200)
      false
  """
  @spec valid_minimum_notice?(any()) :: boolean()
  def valid_minimum_notice?(hours) when is_number(hours) do
    hours >= 0 and hours <= 168
  end

  def valid_minimum_notice?(_), do: false

  @doc """
  Validates meeting duration is reasonable.

  ## Examples

      iex> Validation.valid_meeting_duration?(30)
      true

      iex> Validation.valid_meeting_duration?(500)
      false
  """
  @spec valid_meeting_duration?(any()) :: boolean()
  def valid_meeting_duration?(minutes) when is_integer(minutes) do
    # 15 minutes to 8 hours
    minutes >= 15 and minutes <= 480
  end

  def valid_meeting_duration?(_), do: false

  @doc """
  Parses and validates meeting time strings into DateTime objects.

  ## Examples

      iex> Validation.parse_meeting_times("2024-01-01", "10:00 AM", 30, "America/New_York")
      {:ok, {start_datetime, end_datetime}}

      iex> Validation.parse_meeting_times("invalid", "10:00 AM", 30, "America/New_York")
      {:error, "Invalid date or time format"}
  """
  @spec parse_meeting_times(String.t(), String.t(), integer() | String.t(), String.t()) ::
          {:ok, {DateTime.t(), DateTime.t()}} | {:error, String.t()}
  def parse_meeting_times(date_string, time_string, duration, timezone) do
    with {:ok, date} <- parse_date(date_string),
         {:ok, time} <- safe_parse_time_slot(time_string),
         {:ok, duration_minutes} <- parse_duration(duration),
         {:ok, start_datetime} <- DateTime.new(date, time, timezone),
         end_datetime <- DateTime.add(start_datetime, duration_minutes, :minute) do
      {:ok, {start_datetime, end_datetime}}
    else
      _ -> {:error, "Invalid date or time format"}
    end
  end

  @doc """
  Validates that a booking time meets all constraints.

  Pure validation based on time calculations only.
  """
  @spec validate_booking_time(DateTime.t(), String.t() | DateTime.t(), map()) ::
          :ok | {:error, String.t()}
  def validate_booking_time(start_datetime, timezone_or_end, config \\ %{})

  # Handle the 2-parameter case: (start_time, timezone)
  def validate_booking_time(start_datetime, timezone, config) when is_binary(timezone) do
    overrides = %{
      max_advance_booking_days: 90,
      notice_error_message: fn hours -> "Booking requires at least #{hours} hours in advance" end,
      window_error_message: fn days -> "Cannot book more than #{days} days in advance" end
    }

    validate_booking_time_with_defaults(start_datetime, config, overrides)
  end

  # Handle the 3-parameter case: (start_datetime, end_datetime, config)
  def validate_booking_time(start_datetime, _end_datetime, config) do
    overrides = %{
      notice_error_message: fn hours ->
        "Booking requires at least #{hours} hours advance notice"
      end,
      window_error_message: fn days -> "Booking cannot be more than #{days} days in advance" end
    }

    validate_booking_time_with_defaults(start_datetime, config, overrides)
  end

  @doc """
  Checks if a time slot has conflicts with existing events.

  This is a pure function that takes events as a parameter rather than
  fetching them from the database.
  """
  @spec check_slot_availability(DateTime.t(), DateTime.t(), [map()], non_neg_integer()) ::
          :ok | {:error, :slot_unavailable}
  def check_slot_availability(start_datetime, end_datetime, events, buffer_minutes \\ 0) do
    # Normalize events to ensure they have end times
    normalized_events =
      Enum.map(events, fn event ->
        %{event | end_time: event.end_time || DateTime.add(event.start_time, 30, :minute)}
      end)

    if TimeRange.has_conflict_with_events?(
         start_datetime,
         end_datetime,
         normalized_events,
         buffer_minutes
       ) do
      {:error, :slot_unavailable}
    else
      :ok
    end
  end

  @doc """
  Validates booking form data structure.

  Pure validation of required fields and formats.
  """
  @spec validate_booking_form_structure(map()) :: {:ok, map()} | {:error, String.t()}
  def validate_booking_form_structure(params) do
    required_fields = ["name", "email", "date", "time"]

    missing_fields = required_fields -- Map.keys(params)

    if Enum.empty?(missing_fields) do
      {:ok, params}
    else
      {:error, "Missing required fields: #{Enum.join(missing_fields, ", ")}"}
    end
  end

  @doc """
  Validates email format using a simple regex.

  ## Examples

      iex> Validation.valid_email_format?("test@example.com")
      true

      iex> Validation.valid_email_format?("invalid")
      false
  """
  @spec valid_email_format?(any()) :: boolean()
  def valid_email_format?(email) when is_binary(email) do
    email =~ ~r/^[^\s]+@[^\s]+\.[^\s]+$/
  end

  def valid_email_format?(_), do: false

  @doc """
  Validates booking time from string inputs.

  Parses date and time strings, validates the resulting datetime.
  """
  @spec validate_booking_time_from_strings(String.t(), String.t(), String.t()) ::
          :ok | {:error, String.t()}
  def validate_booking_time_from_strings(date_str, time_str, timezone) do
    case parse_meeting_times(date_str, time_str, 30, timezone) do
      {:ok, {start_datetime, end_datetime}} ->
        validate_booking_time(start_datetime, end_datetime)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Validates that a time slot has no conflicts with existing events.

  Takes calendar events and checks for overlaps.
  """
  @spec validate_no_conflicts(DateTime.t(), DateTime.t(), [map()], map()) ::
          :ok | {:error, :slot_unavailable}
  def validate_no_conflicts(start_datetime, end_datetime, events, config \\ %{}) do
    buffer_minutes = Map.get(config, :buffer_minutes, 15)
    check_slot_availability(start_datetime, end_datetime, events, buffer_minutes)
  end

  @doc """
  Gets a meeting for rescheduling by UID.

  This function delegates to the appropriate database query module.
  """
  @spec get_meeting_for_reschedule(String.t()) ::
          {:ok, Ecto.Schema.t()} | {:error, :not_found | String.t()}
  def get_meeting_for_reschedule(meeting_uid) do
    alias Tymeslot.DatabaseQueries.MeetingQueries

    case MeetingQueries.get_meeting_by_uid(meeting_uid) do
      {:error, :not_found} -> {:error, :not_found}
      {:ok, meeting} -> validate_meeting_for_reschedule(meeting)
    end
  end

  # Private functions

  defp parse_date(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> {:ok, date}
      {:error, _} -> {:error, :invalid_date}
    end
  end

  defp parse_date(_), do: {:error, :invalid_date}

  defp safe_parse_time_slot(time_string) do
    time = TimeSlots.parse_time_slot(time_string)
    {:ok, time}
  rescue
    _ -> {:error, :invalid_time}
  end

  defp parse_duration(duration) when is_integer(duration), do: {:ok, duration}

  defp parse_duration(duration) when is_binary(duration) do
    # TimeSlots.parse_duration returns an integer directly
    minutes = TimeSlots.parse_duration(duration)
    {:ok, minutes}
  end

  defp parse_duration(_), do: {:error, :invalid_duration}

  defp validate_meeting_for_reschedule(meeting) do
    cond do
      meeting.status == "cancelled" -> {:error, "Cannot reschedule a cancelled meeting"}
      meeting.status == "completed" -> {:error, "Cannot reschedule a completed meeting"}
      true -> {:ok, meeting}
    end
  end

  defp validate_booking_time_with_defaults(start_datetime, config, overrides) do
    defaults = %{
      current_time: DateTime.utc_now(),
      min_advance_hours: 3,
      max_advance_booking_days: 365
    }

    merged =
      defaults
      |> Map.merge(overrides)
      |> Map.merge(config)

    current_time = Map.get(merged, :current_time)
    min_notice_hours = Map.get(merged, :min_advance_hours)
    max_booking_days = Map.get(merged, :max_advance_booking_days)
    min_notice_minutes = min_notice_hours * 60

    past_error = Map.get(merged, :past_error_message, "Booking time must be in the future")

    notice_error =
      format_window_message(
        Map.get(merged, :notice_error_message),
        min_notice_hours,
        fn hours -> "Booking requires at least #{hours} hours advance notice" end
      )

    window_error =
      format_window_message(
        Map.get(merged, :window_error_message),
        max_booking_days,
        fn days -> "Booking cannot be more than #{days} days in advance" end
      )

    cond do
      DateTime.compare(start_datetime, current_time) != :gt ->
        {:error, past_error}

      not TimeRange.meets_minimum_notice?(start_datetime, current_time, min_notice_minutes) ->
        {:error, notice_error}

      not TimeRange.within_booking_window?(start_datetime, current_time, max_booking_days) ->
        {:error, window_error}

      true ->
        :ok
    end
  end

  defp format_window_message(message, value, _default_fun)
       when is_function(message, 1),
       do: message.(value)

  defp format_window_message(message, _value, _default_fun) when is_binary(message), do: message

  defp format_window_message(_message, value, default_fun), do: default_fun.(value)
end
