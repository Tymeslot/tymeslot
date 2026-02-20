defmodule Tymeslot.Timezones.Formatting do
  @moduledoc """
  Display formatting for timezones and UTC offsets.
  """

  alias Tymeslot.Timezones.Data

  @spec format(term()) :: String.t()
  def format(timezone_id) when is_binary(timezone_id) do
    normalized = Data.normalize(timezone_id)
    Data.display_name(normalized)
  end

  def format(_other), do: "Unknown timezone"

  @spec utc_offset(String.t()) :: String.t()
  def utc_offset(timezone_id) do
    now = DateTime.utc_now()

    case DateTime.shift_zone(now, timezone_id) do
      {:ok, shifted} ->
        offset_seconds = shifted.utc_offset + shifted.std_offset
        format_utc_offset(offset_seconds)

      _error ->
        "UTC"
    end
  rescue
    _exception -> "UTC"
  end

  @spec format_utc_offset(integer()) :: String.t()
  def format_utc_offset(0), do: "UTC±0"

  def format_utc_offset(seconds) when seconds > 0 do
    hours = div(seconds, 3600)
    minutes = div(rem(seconds, 3600), 60)

    if minutes == 0 do
      "UTC+#{hours}"
    else
      "UTC+#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end

  def format_utc_offset(seconds) when seconds < 0 do
    hours = div(-seconds, 3600)
    minutes = div(rem(-seconds, 3600), 60)

    if minutes == 0 do
      "UTC-#{hours}"
    else
      "UTC-#{hours}:#{String.pad_leading("#{minutes}", 2, "0")}"
    end
  end
end
