defmodule Tymeslot.Timezones.Formatting do
  @moduledoc """
  Display formatting for timezones and UTC offsets.
  """

  require Logger

  alias Tymeslot.Clock
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Timezones.Data

  @spec format(term()) :: String.t()
  def format(timezone_id) when is_binary(timezone_id) do
    normalized = Data.normalize(timezone_id)
    Data.display_name(normalized)
  end

  def format(_other), do: "Unknown timezone"

  @doc """
  The zone's UTC offset in force at `at` (now, by default), as `"UTC+2"`.
  A zone's offset changes across the year, so a label for a given day reads
  it on that day.
  """
  @spec utc_offset(String.t(), DateTime.t()) :: String.t()
  def utc_offset(timezone_id, at \\ Clock.utc_now()) do
    case DateTime.shift_zone(at, timezone_id) do
      {:ok, shifted} ->
        offset_seconds = shifted.utc_offset + shifted.std_offset
        format_utc_offset(offset_seconds)

      _error ->
        "UTC"
    end
  rescue
    exception ->
      Logger.warning("Could not determine UTC offset, falling back to UTC",
        timezone_id: LogFormat.reason(timezone_id),
        error: Exception.message(exception)
      )

      "UTC"
  end

  @spec format_utc_offset(integer()) :: String.t()
  defp format_utc_offset(0), do: "UTC±0"

  defp format_utc_offset(seconds) when seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if minutes == 0 do
      "UTC+#{hours}"
    else
      "UTC+#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end

  defp format_utc_offset(seconds) when seconds < 0 do
    hours = div(-seconds, 3600)
    minutes = div(rem(-seconds, 3600), 60)

    if minutes == 0 do
      "UTC-#{hours}"
    else
      "UTC-#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end
end
