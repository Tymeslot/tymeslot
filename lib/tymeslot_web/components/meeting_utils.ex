defmodule TymeslotWeb.Components.MeetingUtils do
  @moduledoc """
  Data utility functions for meeting scheduling — slot normalization and time parsing.
  """
  alias Tymeslot.Utils.DateTimeUtils.Display

  # ========== CALENDAR & TIME ==========

  @spec normalize_slot_time(term()) :: {:ok, String.t()} | :error
  def normalize_slot_time(slot) do
    normalize_slot_value(slot)
  end

  @typedoc "Normalised slot: time plus group-seat data (nil seat fields for solo types)."
  @type slot :: %{
          time: String.t(),
          seats_left: non_neg_integer() | nil,
          capacity: pos_integer() | nil
        }

  @spec normalize_slot_list(term()) :: [slot()]
  def normalize_slot_list(slots) when is_list(slots) do
    Enum.flat_map(slots, fn slot ->
      case normalize_slot_time(slot) do
        {:ok, time} ->
          [
            %{
              time: time,
              seats_left: seat_field(slot, :seats_left),
              capacity: seat_field(slot, :capacity)
            }
          ]

        :error ->
          []
      end
    end)
  end

  def normalize_slot_list(_other), do: []

  defp seat_field(%{} = slot, key) do
    case Map.get(slot, key) do
      count when is_integer(count) -> count
      _other -> nil
    end
  end

  defp seat_field(_slot, _key), do: nil

  @spec normalize_slot_value(term()) :: {:ok, String.t()} | :error
  defp normalize_slot_value(slot) when is_binary(slot) do
    {:ok, slot}
  end

  defp normalize_slot_value(%Time{} = slot) do
    {:ok, Display.format_time_for_display(slot)}
  end

  defp normalize_slot_value(%NaiveDateTime{} = slot) do
    {:ok, slot |> NaiveDateTime.to_time() |> Display.format_time_for_display()}
  end

  defp normalize_slot_value(%DateTime{} = slot) do
    {:ok, slot |> DateTime.to_time() |> Display.format_time_for_display()}
  end

  defp normalize_slot_value(%{} = slot) do
    value =
      Map.get(slot, :time) ||
        Map.get(slot, "time") ||
        Map.get(slot, :start_time) ||
        Map.get(slot, "start_time")

    normalize_slot_value(value)
  end

  defp normalize_slot_value(_other), do: :error
end
