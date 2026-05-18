defmodule Tymeslot.Utils.DateTimeUtils.Display do
  @moduledoc "User-facing date and time formatting and time-period grouping."

  alias Tymeslot.Utils.DateTimeUtils

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

  @doc """
  Groups time slots by time period (Early Morning, Morning, Afternoon, Evening, Late Night).

  Slots within each period are sorted chronologically by their parsed time value,
  so times like "7:30 AM" correctly appear before "11:30 AM".

  ## Examples
      iex> slots = ["2:00 AM", "9:00 AM", "2:00 PM", "7:00 PM", "11:00 PM"]
      iex> Tymeslot.Utils.DateTimeUtils.Display.group_slots_by_period(slots)
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
          case DateTimeUtils.parse_time_string(slot) do
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
    case DateTimeUtils.parse_time_string(slot_string) do
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
end
