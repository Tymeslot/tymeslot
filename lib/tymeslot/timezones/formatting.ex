defmodule Tymeslot.Timezones.Formatting do
  @moduledoc """
  Display formatting for timezones and UTC offsets.
  """

  use Gettext, backend: TymeslotWeb.Gettext

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
  The zone named as a time rather than a place, for showing beside times:
  "Berlin time (UTC+1)". A bare "Berlin, Germany" next to a meeting reads as
  where it happens. The offset is the one in force at `at` (now, by default),
  so a label for a given day reads it on that day. A zone named after no
  place is its offset alone.
  """
  @spec time_label(String.t(), DateTime.t()) :: String.t()
  def time_label(timezone_id, at \\ Clock.utc_now()) when is_binary(timezone_id) do
    normalized = Data.normalize(timezone_id)

    case {Data.city(normalized), utc_offset(normalized, at)} do
      {nil, "UTC±0"} ->
        "UTC"

      {nil, offset} ->
        offset

      {city, offset} ->
        dgettext("datetime", "%{city} time (%{offset})", city: city, offset: offset)
    end
  end

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
