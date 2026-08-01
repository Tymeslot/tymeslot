defmodule Tymeslot.Utils.DateTimeUtils do
  @moduledoc """
  Timezone coercion and basic time parsing.

  Specialised helpers live in dedicated submodules:

    * `Tymeslot.Utils.DateTimeUtils.ICal` — iCal/CalDAV formatters and parsers.
    * `Tymeslot.Utils.DateTimeUtils.Duration` — ISO 8601 duration parsing and
      human-readable duration formatting.
    * `Tymeslot.Utils.DateTimeUtils.Display` — UI-facing date/time formatting
      and time-period grouping for booking slots.
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
    exception ->
      # The `case` above already covers every shape we expect to fail, so
      # reaching here means something genuinely unexpected about the input.
      Logger.warning("Unexpected failure parsing a time string",
        error: Exception.message(exception)
      )

      {:error, :invalid_time_format}
  end

  def parse_time_string(_value), do: {:error, :invalid_time_format}

  @doc """
  Parses an "HH:MM" string into a Time struct.
  """
  @spec parse_hhmm(String.t()) :: {:ok, Time.t()} | {:error, atom()}
  def parse_hhmm(hhmm) when is_binary(hhmm) do
    Time.from_iso8601(hhmm <> ":00")
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
end
