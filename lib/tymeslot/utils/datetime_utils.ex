defmodule Tymeslot.Utils.DateTimeUtils do
  @moduledoc """
  Utility functions for date and time operations.
  Pure functions for parsing, formatting, and manipulating dates and times.
  """

  require Logger

  alias Tymeslot.Timezones

  @doc """
  Parses a time string in AM/PM format. Supports both string and map input (for demo data).

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.parse_time_string("2:30 PM")
      {:ok, ~T[14:30:00]}

      iex> Tymeslot.Utils.DateTimeUtils.parse_time_string(%{time: "10:30 pm", available: true})
      {:ok, ~T[22:30:00]}

      iex> Tymeslot.Utils.DateTimeUtils.parse_time_string("12:00 AM")
      {:ok, ~T[00:00:00]}
  """
  @spec parse_time_string(String.t() | map()) :: {:ok, Time.t()} | {:error, atom()}
  def parse_time_string(%{time: time_string}) when is_binary(time_string) do
    parse_time_string(time_string)
  end

  def parse_time_string(time_string) when is_binary(time_string) do
    trimmed = String.trim(time_string)

    case String.split(trimmed, " ", parts: 2, trim: true) do
      [time_part, period] ->
        parse_12h_time(time_part, period)

      [time_part] ->
        parse_24h_time(time_part)

      _invalid ->
        {:error, :invalid_time_format}
    end
  rescue
    _exception -> {:error, :invalid_time_format}
  end

  def parse_time_string(_value), do: {:error, :invalid_time_format}

  defp parse_12h_time(time_part, period) do
    with {:ok, hour, minute} <- parse_hour_minute(time_part),
         {:ok, normalized_period} <- normalize_period(period),
         adjusted_hour <- adjust_hour_for_period(hour, normalized_period),
         {:ok, time} <- Time.new(adjusted_hour, minute, 0) do
      {:ok, time}
    else
      _error -> {:error, :invalid_time_format}
    end
  end

  defp parse_24h_time(time_part) do
    normalized =
      case String.split(time_part, ":") do
        [hour, minute] -> "#{hour}:#{minute}:00"
        [hour, minute, second] -> "#{hour}:#{minute}:#{second}"
        _invalid -> nil
      end

    case normalized && Time.from_iso8601(normalized) do
      {:ok, time} -> {:ok, time}
      _error -> {:error, :invalid_time_format}
    end
  end

  defp parse_hour_minute(value) do
    case String.split(value, ":", parts: 2) do
      [hour_str, minute_str] ->
        with {hour, ""} <- Integer.parse(hour_str),
             {minute, ""} <- Integer.parse(minute_str) do
          {:ok, hour, minute}
        else
          _error -> {:error, :invalid_time_format}
        end

      _invalid ->
        {:error, :invalid_time_format}
    end
  end

  defp normalize_period(period) do
    case String.upcase(String.trim(period)) do
      "AM" -> {:ok, :am}
      "PM" -> {:ok, :pm}
      _invalid -> {:error, :invalid_period}
    end
  end

  defp adjust_hour_for_period(12, :am), do: 0
  defp adjust_hour_for_period(hour, :am), do: hour
  defp adjust_hour_for_period(12, :pm), do: 12
  defp adjust_hour_for_period(hour, :pm), do: hour + 12

  @doc """
  Groups time slots by time period (Early Morning, Morning, Afternoon, Evening, Late Night).

  Slots within each period are sorted chronologically by their parsed time value,
  so times like "7:30 AM" correctly appear before "11:30 AM".

  ## Examples
      iex> slots = ["2:00 AM", "9:00 AM", "2:00 PM", "7:00 PM", "11:00 PM"]
      iex> Tymeslot.Utils.DateTimeUtils.group_slots_by_period(slots)
      %{
        "Early Morning" => ["2:00 AM"],
        "Morning" => ["9:00 AM"],
        "Afternoon" => ["2:00 PM"],
        "Evening" => ["7:00 PM"],
        "Late Night" => ["11:00 PM"]
      }
  """
  @spec group_slots_by_period([String.t()]) :: %{optional(String.t()) => [String.t()]}
  def group_slots_by_period(slots) do
    slots
    |> Enum.group_by(&get_time_period/1)
    |> Map.new(fn {period, period_slots} ->
      sorted =
        Enum.sort_by(period_slots, fn slot ->
          case parse_time_string(slot) do
            {:ok, time} -> {time.hour, time.minute, time.second}
            {:error, _reason} -> {99, 99, 99}
          end
        end)

      {period, sorted}
    end)
  end

  @doc """
  Determines the time period for a given time slot.
  """
  @spec get_time_period(String.t()) :: String.t()
  def get_time_period(slot_string) do
    case parse_time_string(slot_string) do
      {:ok, time} ->
        determine_period_from_hour(time.hour)

      {:error, _parse_error} ->
        "Unknown"
    end
  end

  defp determine_period_from_hour(hour) when hour >= 0 and hour < 5, do: "Early Morning"
  defp determine_period_from_hour(hour) when hour >= 5 and hour < 12, do: "Morning"
  defp determine_period_from_hour(hour) when hour >= 12 and hour < 17, do: "Afternoon"
  defp determine_period_from_hour(hour) when hour >= 17 and hour < 21, do: "Evening"
  defp determine_period_from_hour(_hour), do: "Late Night"

  @doc """
  Formats duration for URL parameters.

  ## Examples
      iex> Tymeslot.Utils.DateTimeUtils.format_duration_for_url(15)
      "15min"

      iex> Tymeslot.Utils.DateTimeUtils.format_duration_for_url(30)
      "30min"
  """
  @spec format_duration_for_url(non_neg_integer()) :: String.t()
  def format_duration_for_url(duration_minutes) when is_integer(duration_minutes) do
    "#{duration_minutes}min"
  end

  @doc """
  Coerces a `Date`, `DateTime`, or `nil` into a `DateTime`.

  - `%DateTime{}` values pass through unchanged.
  - `%Date{}` values become midnight UTC on that date.
  - `nil` returns `nil`.

  Useful for normalising calendar events where all-day events use `Date`
  structs while timed events use `DateTime`.
  """
  @spec to_datetime(DateTime.t()) :: DateTime.t()
  @spec to_datetime(Date.t()) :: DateTime.t()
  @spec to_datetime(nil) :: nil
  def to_datetime(%DateTime{} = dt), do: dt
  def to_datetime(%Date{} = date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  def to_datetime(nil), do: nil

  @doc """
  Converts a DateTime to a different timezone safely.
  """
  @spec convert_to_timezone(DateTime.t(), String.t()) :: DateTime.t()
  def convert_to_timezone(datetime, timezone) do
    case DateTime.shift_zone(datetime, timezone) do
      {:ok, shifted} -> shifted
      # Fallback to original if conversion fails
      {:error, _shift_error} -> datetime
    end
  end

  @doc """
  Returns the current DateTime in the given timezone, falling back to UTC.
  """
  @spec now_in_timezone(String.t()) :: DateTime.t()
  def now_in_timezone(timezone) do
    case DateTime.now(timezone) do
      {:ok, dt} -> dt
      _other -> DateTime.utc_now()
    end
  end

  @doc """
  Creates a DateTime safely with timezone fallback and DST gap handling.
  """
  @spec create_datetime_safe(Date.t(), Time.t(), String.t()) :: DateTime.t()
  def create_datetime_safe(date, time, timezone) do
    case DateTime.new(date, time, timezone) do
      {:ok, datetime} ->
        datetime

      {:ambiguous, first, _second} ->
        # In case of ambiguity (e.g. DST fall back), use the first occurrence
        first

      {:gap, _just_before, _just_after} ->
        # Time is in a DST gap (spring forward). Shift forward by 1 hour.
        naive = NaiveDateTime.new!(date, time)
        shifted = NaiveDateTime.add(naive, 3600, :second)

        case DateTime.from_naive(shifted, timezone) do
          {:ok, dt} -> dt
          {:ambiguous, first, _second} -> first
          {:error, _naive_error} -> DateTime.new!(date, time, "Etc/UTC")
        end

      {:error, _new_error} ->
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
    utc_dt = ensure_utc!(dt)

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
    utc_dt = ensure_utc!(dt)

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
  @spec parse_ical_datetime(String.t()) :: {:ok, NaiveDateTime.t() | Date.t()} | {:error, term()}
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
        case Regex.run(~r/(\d{4})(\d{2})(\d{2})/, datetime_str) do
          [_match, year, month, day] ->
            Date.new(
              String.to_integer(year),
              String.to_integer(month),
              String.to_integer(day)
            )

          nil ->
            {:error, "Invalid date format"}
        end

      true ->
        {:error, "Unrecognized datetime format"}
    end
  end

  @doc """
  Parses an iCal datetime with timezone information.
  Supports both DateTime and Date (all-day) formats.
  """
  @spec parse_datetime_with_timezone(
          %{required(:value) => String.t(), optional(:timezone) => String.t() | nil}
          | nil
        ) :: {:ok, DateTime.t() | Date.t()} | {:error, term()}
  def parse_datetime_with_timezone(%{value: datetime_str, timezone: timezone}) do
    case parse_ical_datetime(datetime_str) do
      {:ok, %NaiveDateTime{} = naive_dt} ->
        convert_to_utc(naive_dt, timezone)

      {:ok, %Date{} = date} ->
        {:ok, date}

      {:error, _parse_error} = error ->
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
      {:error, _conversion_error} -> {:error, "Failed to convert to UTC"}
    end
  end

  def convert_to_utc(naive_dt, timezone) when is_binary(timezone) do
    case Timezones.sanitize(timezone) do
      nil ->
        Logger.warning("Timezone string is empty after sanitization; assuming UTC",
          original_timezone: timezone
        )

        convert_to_utc(naive_dt, nil)

      clean ->
        do_convert_to_utc(naive_dt, clean, timezone)
    end
  end

  def convert_to_utc(naive_dt, _other), do: convert_to_utc(naive_dt, nil)

  defp do_convert_to_utc(naive_dt, clean, original) do
    case DateTime.from_naive(naive_dt, clean) do
      {:ok, dt} ->
        shift_to_utc(dt, naive_dt, clean, original)

      {:ambiguous, first, _second} ->
        # DST fall-back: two valid local times exist — resolve to the earlier one (first)
        shift_to_utc(first, naive_dt, clean, original)

      {:gap, _just_before, just_after} ->
        # DST spring-forward: local time does not exist — resolve to just_after
        shift_to_utc(just_after, naive_dt, clean, original)

      {:error, reason} ->
        Logger.warning("Unknown timezone when parsing external datetime; falling back to UTC",
          timezone: clean,
          original_timezone: original,
          reason: inspect(reason)
        )

        convert_to_utc(naive_dt, nil)
    end
  end

  defp shift_to_utc(dt, naive_dt, clean, original) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc_dt} ->
        {:ok, utc_dt}

      {:error, reason} ->
        Logger.warning("Failed to shift DateTime to UTC; falling back to naive UTC",
          timezone: clean,
          original_timezone: original,
          reason: inspect(reason)
        )

        convert_to_utc(naive_dt, nil)
    end
  end

  @doc """
  Ensures a DateTime is in UTC timezone.

  Returns `{:ok, utc_dt}` on success and `{:error, reason}` when
  `DateTime.shift_zone/2` fails — typically because the source DateTime's
  time zone is unknown to the loaded tzdata. Prior versions silently
  returned the original (non-UTC) DateTime on failure, which produced
  downstream iCal/CalDAV strings in the wrong zone. Callers that must
  have a UTC DateTime should use `ensure_utc!/1`.
  """
  @spec ensure_utc(DateTime.t()) :: {:ok, DateTime.t()} | {:error, term()}
  def ensure_utc(%DateTime{time_zone: "Etc/UTC"} = dt), do: {:ok, dt}

  def ensure_utc(%DateTime{} = dt) do
    case DateTime.shift_zone(dt, "Etc/UTC") do
      {:ok, utc_dt} ->
        {:ok, utc_dt}

      {:error, reason} ->
        Logger.error("Failed to shift timezone to UTC",
          reason: reason,
          datetime: inspect(dt)
        )

        {:error, reason}
    end
  end

  @doc """
  Same as `ensure_utc/1` but unwraps `{:ok, utc_dt}` and raises on error.

  Use this in internal callers whose contract is `DateTime.t() -> String.t()`
  (iCal/CalDAV formatters) where falling back to the original non-UTC
  DateTime would silently produce a wrong-zone output string.
  """
  @spec ensure_utc!(DateTime.t()) :: DateTime.t()
  def ensure_utc!(%DateTime{} = dt) do
    case ensure_utc(dt) do
      {:ok, utc_dt} ->
        utc_dt

      {:error, reason} ->
        raise ArgumentError,
              "DateTimeUtils.ensure_utc!/1 failed to shift #{inspect(dt)} to UTC: #{inspect(reason)}"
    end
  end

  @doc """
  Parses an ISO 8601 duration string (simplified).
  Supports both time durations (PT1H) and day durations (P1D).

  ## Examples

      iex> parse_duration("PT1H30M")
      {:ok, 5400}  # 1 hour 30 minutes in seconds

      iex> parse_duration("P1D")
      {:ok, 86400} # 1 day in seconds
  """
  @spec parse_duration(String.t()) :: {:ok, non_neg_integer()} | {:error, String.t()}
  def parse_duration(duration_str) when is_binary(duration_str) do
    cond do
      # Time duration: PT1H30M
      String.starts_with?(duration_str, "PT") ->
        parse_time_duration(duration_str)

      # Day duration: P1D or P1W
      String.starts_with?(duration_str, "P") ->
        parse_day_duration(duration_str)

      true ->
        {:error, "Invalid duration format"}
    end
  end

  defp parse_time_duration(duration_str) do
    case Regex.run(~r/^PT(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?$/, duration_str) do
      [_match | captures] ->
        hours = parse_duration_component(Enum.at(captures, 0), 3600)
        minutes = parse_duration_component(Enum.at(captures, 1), 60)
        seconds = parse_duration_component(Enum.at(captures, 2), 1)

        if hours + minutes + seconds > 0 or duration_str == "PT0S" do
          {:ok, hours + minutes + seconds}
        else
          {:error, "Invalid time duration values"}
        end

      _no_match ->
        {:error, "Invalid time duration format"}
    end
  end

  defp parse_day_duration(duration_str) do
    case Regex.run(~r/^P(?:(\d+)W)?(?:(\d+)D)?$/, duration_str) do
      [_match | captures] ->
        weeks = parse_duration_component(Enum.at(captures, 0), 86_400 * 7)
        days = parse_duration_component(Enum.at(captures, 1), 86_400)
        total = weeks + days

        # Accept zero durations if the format is valid (regex matched)
        # and at least one component is present (not just "P")
        if total > 0 or duration_str != "P" do
          {:ok, total}
        else
          {:error, "Unsupported or invalid duration format"}
        end

      _no_match ->
        {:error, "Invalid day/week duration format or unsupported components"}
    end
  end

  # Private helper functions

  defp parse_basic_datetime(datetime_str) do
    case Regex.run(~r/(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})/, datetime_str) do
      [_match, year, month, day, hour, minute, second] ->
        NaiveDateTime.new(
          String.to_integer(year),
          String.to_integer(month),
          String.to_integer(day),
          String.to_integer(hour),
          String.to_integer(minute),
          String.to_integer(second)
        )

      nil ->
        {:error, "Invalid datetime format"}
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
  Parses an "HH:MM" string into a Time struct.
  """
  @spec parse_hhmm(String.t()) :: {:ok, Time.t()} | {:error, atom()}
  def parse_hhmm(hhmm) when is_binary(hhmm) do
    Time.from_iso8601(hhmm <> ":00")
  end

  # ========== Display Formatting ==========

  @doc """
  Formats duration string or integer for display.
  """
  @spec format_duration(term()) :: String.t()
  def format_duration(duration) when is_integer(duration) do
    format_minutes(duration)
  end

  def format_duration(duration_string) when is_binary(duration_string) do
    case Regex.run(~r/^\s*(\d+)\s*(?:-?\s*min(?:utes?)?)?\s*$/i, duration_string) do
      [_match, minutes_str] ->
        minutes_str |> String.to_integer() |> format_minutes()

      _result ->
        "Unknown duration"
    end
  end

  def format_duration(_value), do: "Unknown duration"

  @doc """
  Formats date string for display.
  """
  @spec format_date_string(term()) :: String.t()
  def format_date_string(date_string) when is_binary(date_string) do
    case Date.from_iso8601(date_string) do
      {:ok, date} -> Calendar.strftime(date, "%B %d, %Y")
      _result -> date_string
    end
  end

  def format_date_string(_value), do: "Invalid date"

  defp format_minutes(1), do: "1 minute"
  defp format_minutes(minutes) when minutes < 60, do: "#{minutes} minutes"
  defp format_minutes(60), do: "1 hour"
  defp format_minutes(90), do: "1.5 hours"
  defp format_minutes(120), do: "2 hours"
  defp format_minutes(minutes) when rem(minutes, 60) == 0, do: "#{div(minutes, 60)} hours"

  defp format_minutes(minutes) do
    hours = div(minutes, 60)
    mins = rem(minutes, 60)
    hour_text = "#{hours} hour#{if hours > 1, do: "s", else: ""}"
    minute_text = "#{mins} minute#{if mins > 1, do: "s", else: ""}"
    "#{hour_text} #{minute_text}"
  end
end
