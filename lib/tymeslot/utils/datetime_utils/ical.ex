defmodule Tymeslot.Utils.DateTimeUtils.ICal do
  @moduledoc "iCal/CalDAV datetime formatting and parsing."

  alias Tymeslot.Utils.DateTimeUtils

  @doc """
  Formats a DateTime to iCal format (YYYYMMDDTHHMMSSZ).
  Ensures the datetime is in UTC before formatting.
  """
  @spec format_ical_datetime(DateTime.t()) :: String.t()
  def format_ical_datetime(%DateTime{} = dt) do
    utc_dt = DateTimeUtils.ensure_utc!(dt)

    # Format without microseconds for iCalendar compatibility
    utc_dt
    |> DateTime.truncate(:second)
    |> DateTime.to_iso8601(:basic)
    |> String.replace(~r/[-:]/, "")
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
        DateTimeUtils.convert_to_utc(naive_dt, timezone)

      {:ok, %Date{} = date} ->
        {:ok, date}

      {:error, _parse_error} = error ->
        error
    end
  end

  def parse_datetime_with_timezone(nil), do: {:error, "No datetime provided"}

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
end
