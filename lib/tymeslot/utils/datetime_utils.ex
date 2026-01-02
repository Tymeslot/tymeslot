defmodule Tymeslot.Utils.DateTimeUtils do
  @moduledoc """
  Utility functions for date and time operations.
  Pure functions for parsing, formatting, and manipulating dates and times.
  """

  require Logger

  @doc """
  Parses a time string in AM/PM format.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.parse_time_string("2:30 PM")
      {:ok, ~T[14:30:00]}

      iex> Tymeslot.Utils.DateTimeUtils.parse_time_string("12:00 AM")
      {:ok, ~T[00:00:00]}
  """
  @spec parse_time_string(String.t()) :: {:ok, Time.t()} | {:error, atom()}
  def parse_time_string(time_string) when is_binary(time_string) do
    trimmed = String.trim(time_string)

    case String.split(trimmed, " ", parts: 2, trim: true) do
      [time_part, period] ->
        parse_12h_time(time_part, period)

      [time_part] ->
        parse_24h_time(time_part)

      _ ->
        {:error, :invalid_time_format}
    end
  rescue
    _ -> {:error, :invalid_time_format}
  end

  defp parse_12h_time(time_part, period) do
    with {:ok, hour, minute} <- parse_hour_minute(time_part),
         {:ok, normalized_period} <- normalize_period(period),
         adjusted_hour <- adjust_hour_for_period(hour, normalized_period),
         {:ok, time} <- Time.new(adjusted_hour, minute, 0) do
      {:ok, time}
    else
      _ -> {:error, :invalid_time_format}
    end
  end

  defp parse_24h_time(time_part) do
    normalized =
      case String.split(time_part, ":") do
        [hour, minute] -> "#{hour}:#{minute}:00"
        [hour, minute, second] -> "#{hour}:#{minute}:#{second}"
        _ -> nil
      end

    case normalized && Time.from_iso8601(normalized) do
      {:ok, time} -> {:ok, time}
      _ -> {:error, :invalid_time_format}
    end
  end

  defp parse_hour_minute(value) do
    case String.split(value, ":", parts: 2) do
      [hour_str, minute_str] ->
        with {hour, ""} <- Integer.parse(hour_str),
             {minute, ""} <- Integer.parse(minute_str) do
          {:ok, hour, minute}
        else
          _ -> {:error, :invalid_time_format}
        end

      _ ->
        {:error, :invalid_time_format}
    end
  end

  defp normalize_period(period) do
    case String.upcase(String.trim(period)) do
      "AM" -> {:ok, :am}
      "PM" -> {:ok, :pm}
      _ -> {:error, :invalid_period}
    end
  end

  defp adjust_hour_for_period(12, :am), do: 0
  defp adjust_hour_for_period(hour, :am), do: hour
  defp adjust_hour_for_period(12, :pm), do: 12
  defp adjust_hour_for_period(hour, :pm), do: hour + 12

  @doc """
  Parses a slot time string and returns a Time struct.

  Used for parsing time slots from the scheduling interface.
  """
  @spec parse_slot_time(String.t()) :: {:ok, Time.t()} | {:error, atom()}
  def parse_slot_time(slot_string) do
    parse_time_string(slot_string)
  end

  @doc """
  Groups time slots by time period (Morning, Afternoon, Evening, Night).

  ## Examples
      iex> slots = ["9:00 AM", "2:00 PM", "7:00 PM", "11:00 PM"]
      iex> Tymeslot.Utils.DateTimeUtils.group_slots_by_period(slots)
      %{
        "Morning" => ["9:00 AM"],
        "Afternoon" => ["2:00 PM"],
        "Evening" => ["7:00 PM"],
        "Night" => ["11:00 PM"]
      }
  """
  @spec group_slots_by_period([String.t()]) :: %{optional(String.t()) => [String.t()]}
  def group_slots_by_period(slots) do
    slots
    |> Enum.group_by(&get_time_period/1)
    |> Enum.into(%{})
  end

  @doc """
  Determines the time period for a given time slot.
  """
  @spec get_time_period(String.t()) :: String.t()
  def get_time_period(slot_string) do
    case parse_time_string(slot_string) do
      {:ok, time} ->
        determine_period_from_hour(time.hour)

      {:error, _} ->
        "Unknown"
    end
  end

  defp determine_period_from_hour(hour) when hour >= 5 and hour < 12, do: "Morning"
  defp determine_period_from_hour(hour) when hour >= 12 and hour < 17, do: "Afternoon"
  defp determine_period_from_hour(hour) when hour >= 17 and hour < 21, do: "Evening"
  defp determine_period_from_hour(_hour), do: "Night"

  @doc """
  Formats duration for URL parameters.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.format_duration_for_url(15)
      "15min"

      iex> Tymeslot.Utils.DateTimeUtils.format_duration_for_url(30)
      "30min"
  """
  @spec format_duration_for_url(non_neg_integer() | String.t()) :: String.t()
  def format_duration_for_url(duration_minutes) when is_integer(duration_minutes) do
    "#{duration_minutes}min"
  end

  def format_duration_for_url(duration_string) when is_binary(duration_string) do
    case duration_string do
      "15min" -> "15min"
      "30min" -> "30min"
      # Default fallback
      _ -> "30min"
    end
  end

  @doc """
  Parses duration from URL format to minutes.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.parse_duration_from_url("15min")
      15

      iex> Tymeslot.Utils.DateTimeUtils.parse_duration_from_url("30min")
      30
  """
  @spec parse_duration_from_url(String.t()) :: non_neg_integer()
  def parse_duration_from_url(duration_string) do
    case duration_string do
      "15min" -> 15
      "30min" -> 30
      # Default fallback
      _ -> 30
    end
  end

  @doc """
  Converts a DateTime to a different timezone safely.
  """
  @spec convert_to_timezone(DateTime.t(), String.t()) :: DateTime.t()
  def convert_to_timezone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      # Fallback to original if conversion fails
      {:error, _} -> datetime
    end
  end

  @doc """
  Creates a DateTime safely with timezone fallback.
  """
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

  # ========== iCal/CalDAV Functions (migrated from old DateTimeUtils) ==========

  @doc """
  Formats a DateTime to iCal format (YYYYMMDDTHHMMSSZ).
  Ensures the datetime is in UTC before formatting.
  """
  @spec format_ical_datetime(DateTime.t()) :: String.t()
  def format_ical_datetime(%DateTime{} = dt) do
    utc_dt = ensure_utc(dt)

    # Format without microseconds for iCalendar compatibility
    utc_dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[-:]/, "")
    |> String.replace("+00:00", "Z")
  end

  @doc """
  Formats a DateTime for CalDAV time-range queries.
  Similar to iCal format but removes milliseconds.
  """
  @spec format_caldav_datetime(DateTime.t()) :: String.t()
  def format_caldav_datetime(%DateTime{} = dt) do
    utc_dt = ensure_utc(dt)

    utc_dt
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[-:]/, "")
    # Remove milliseconds
    |> String.replace(~r/\.\d+/, "")
    |> String.replace("+00:00", "Z")
  end

  @doc """
  Parses an iCal datetime string (various formats supported).

  Formats:
  - UTC time: 20240726T163000Z
  - Local time: 20240726T163000
  - Date only: 20240726
  """
  @spec parse_ical_datetime(String.t()) :: {:ok, NaiveDateTime.t()} | {:error, term()}
  def parse_ical_datetime(datetime_str) when is_binary(datetime_str) do
    cond do
      # UTC time: 20240726T163000Z
      String.ends_with?(datetime_str, "Z") ->
        datetime_str
        |> String.trim_trailing("Z")
        |> parse_basic_datetime()

      # Local time: 20240726T163000
      String.contains?(datetime_str, "T") ->
        parse_basic_datetime(datetime_str)

      # Date only: 20240726
      String.match?(datetime_str, ~r/^\d{8}$/) ->
        parse_date_only(datetime_str)

      true ->
        {:error, "Unrecognized datetime format"}
    end
  end

  @doc """
  Parses an iCal datetime with timezone information.

  ## Examples

      iex> parse_datetime_with_timezone(%{value: "20240726T163000Z", timezone: nil})
      {:ok, #DateTime<...>}

      iex> parse_datetime_with_timezone(%{value: "20240726T163000", timezone: "Europe/Berlin"})
      {:ok, #DateTime<...>}
  """
  @spec parse_datetime_with_timezone(
          %{required(:value) => String.t(), optional(:timezone) => String.t() | nil}
          | nil
        ) :: {:ok, DateTime.t()} | {:error, term()}
  def parse_datetime_with_timezone(%{value: datetime_str, timezone: timezone}) do
    case parse_ical_datetime(datetime_str) do
      {:ok, naive_dt} ->
        convert_to_utc(naive_dt, timezone)

      {:error, _} = error ->
        error
    end
  end

  def parse_datetime_with_timezone(nil), do: {:error, "No datetime provided"}

  @doc """
  Converts a NaiveDateTime to UTC DateTime, handling timezone if provided.
  """
  @spec convert_to_utc(NaiveDateTime.t(), String.t() | nil) ::
          {:ok, DateTime.t()} | {:error, term()}
  def convert_to_utc(naive_dt, nil) do
    # No timezone specified, assume UTC
    case DateTime.from_naive(naive_dt, "Etc/UTC") do
      {:ok, dt} -> {:ok, dt}
      _ -> {:error, "Failed to convert to UTC"}
    end
  end

  def convert_to_utc(naive_dt, timezone) do
    case DateTime.from_naive(naive_dt, timezone) do
      {:ok, dt} ->
        case DateTime.shift_zone(dt, "Etc/UTC") do
          {:ok, utc_dt} -> {:ok, utc_dt}
          # Fallback to UTC
          _ -> convert_to_utc(naive_dt, nil)
        end

      _ ->
        # Fallback to UTC
        convert_to_utc(naive_dt, nil)
    end
  end

  @doc """
  Ensures a DateTime is in UTC timezone.
  """
  @spec ensure_utc(DateTime.t()) :: DateTime.t()
  def ensure_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: dt

  def ensure_utc(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc_dt} ->
        utc_dt

      {:error, reason} ->
        Logger.error("Failed to shift timezone to UTC",
          reason: reason,
          datetime: inspect(dt)
        )

        dt
    end
  end

  @doc """
  Parses an ISO 8601 duration string (simplified).

  ## Examples

      iex> parse_duration("PT1H30M")
      {:ok, 5400}  # 1 hour 30 minutes in seconds

      iex> parse_duration("PT45M")
      {:ok, 2700}  # 45 minutes in seconds
  """
  @spec parse_duration(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_duration(duration_str) when is_binary(duration_str) do
    case Regex.run(~r/PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?/, duration_str) do
      [_ | captures] ->
        hours = parse_duration_component(Enum.at(captures, 0), 3600)
        minutes = parse_duration_component(Enum.at(captures, 1), 60)
        seconds = parse_duration_component(Enum.at(captures, 2), 1)

        {:ok, hours + minutes + seconds}

      _ ->
        {:error, "Invalid duration format"}
    end
  end

  # Private helper functions

  defp parse_basic_datetime(datetime_str) do
    case Regex.run(~r/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})/, datetime_str) do
      [_, year, month, day, hour, minute, second] ->
        NaiveDateTime.new(
          String.to_integer(year),
          String.to_integer(month),
          String.to_integer(day),
          String.to_integer(hour),
          String.to_integer(minute),
          String.to_integer(second)
        )

      _ ->
        {:error, "Invalid datetime format"}
    end
  end

  defp parse_date_only(date_str) do
    case Regex.run(~r/(\d{4})(\d{2})(\d{2})/, date_str) do
      [_, year, month, day] ->
        NaiveDateTime.new(
          String.to_integer(year),
          String.to_integer(month),
          String.to_integer(day),
          0,
          0,
          0
        )

      _ ->
        {:error, "Invalid date format"}
    end
  end

  defp parse_duration_component(nil, _multiplier), do: 0
  defp parse_duration_component("", _multiplier), do: 0

  defp parse_duration_component(value, multiplier) do
    String.to_integer(value) * multiplier
  end

  @doc """
  Formats a time for display in the UI.
  """
  @spec format_time_for_display(Time.t()) :: String.t()
  def format_time_for_display(time) do
    hour =
      if time.hour == 0, do: 12, else: if(time.hour > 12, do: time.hour - 12, else: time.hour)

    period = if time.hour < 12, do: "AM", else: "PM"
    minute = String.pad_leading(Integer.to_string(time.minute), 2, "0")

    "#{hour}:#{minute} #{period}"
  end

  @doc """
  Checks if a date is within the allowed booking window.
  """
  @spec date_in_booking_window?(Date.t(), String.t(), map()) :: boolean()
  def date_in_booking_window?(date, timezone, config \\ %{}) do
    current_date =
      DateTime.utc_now()
      |> DateTime.shift_zone!(timezone)
      |> DateTime.to_date()

    max_advance_days = Map.get(config, :max_advance_booking_days, 90)
    max_date = Date.add(current_date, max_advance_days)

    Date.compare(date, current_date) != :lt and Date.compare(date, max_date) != :gt
  end
end
