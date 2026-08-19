defmodule TymeslotWeb.Themes.Shared.SlotGrouping do
  @moduledoc """
  Decides how a day's slots are presented, and groups them accordingly.

  A meeting type may offer starts on a grid finer than its own duration, which
  turns a working day into around a hundred slots. Both themes already group
  slots into parts of the day; at that density the grouping stops helping, so
  the slots are nested one level deeper, under the hour they fall in, and the
  booker opens one hour at a time.

  The decision is made here rather than in either theme so the two cannot
  disagree, and so a theme renders whichever shape it is handed without
  knowing why.
  """

  alias Tymeslot.Availability.TimeSlots
  alias TymeslotWeb.Themes.Shared.LocalizationHelpers

  @typedoc "Slots grouped by part of the day, as the themes have always rendered them."
  @type flat :: {:flat, [{String.t(), [String.t()]}]}

  @typedoc "Slots grouped by part of the day, then by the hour they start in."
  @type hours :: {:hours, [{String.t(), [{0..23, [String.t()]}]}]}

  @type grouping :: flat() | hours()

  @doc """
  Whether the two-tier hour picker applies.

  Only a grid finer than the meeting itself produces enough slots to need it.
  An interval longer than the duration produces *fewer* slots than the default
  and is left on the flat grid.
  """
  @spec two_tier?(pos_integer() | nil, pos_integer() | nil) :: boolean()
  def two_tier?(interval, duration) when is_integer(interval) and is_integer(duration),
    do: interval < duration

  def two_tier?(_interval, _duration), do: false

  @doc """
  Groups `slots` for display.
  """
  @spec group([String.t()], pos_integer() | nil, pos_integer() | nil) :: grouping()
  def group(slots, interval_minutes, duration_minutes) do
    periods = LocalizationHelpers.group_slots_by_period(slots)

    if two_tier?(interval_minutes, duration_minutes) do
      {:hours,
       Enum.map(periods, fn {period, period_slots} -> {period, by_hour(period_slots)} end)}
    else
      {:flat, periods}
    end
  end

  @doc """
  Resolves the hour actually shown expanded.

  `nil` means the booker has not chosen, so the earliest hour holding slots
  opens: someone who just wants the next opening sees real times without
  clicking. `:none` means they collapsed it deliberately, which must not
  spring back open on the next render.
  """
  @spec effective_expanded_hour(0..23 | :none | nil, grouping()) :: 0..23 | nil
  def effective_expanded_hour(:none, _grouping), do: nil
  def effective_expanded_hour(hour, _grouping) when is_integer(hour), do: hour

  def effective_expanded_hour(nil, {:hours, periods}) do
    periods
    |> Enum.flat_map(fn {_period, hours} -> Enum.map(hours, fn {hour, _slots} -> hour end) end)
    |> Enum.sort()
    |> List.first()
  end

  def effective_expanded_hour(nil, {:flat, _periods}), do: nil

  # `group_slots_by_period/1` has already sorted within each period, and
  # `Enum.group_by/2` preserves that order, so only the hour keys need sorting.
  defp by_hour(slots) do
    slots
    |> Enum.group_by(&hour_of/1)
    |> Enum.sort_by(fn {hour, _slots} -> hour end)
  end

  defp hour_of(slot), do: TimeSlots.parse_time_slot(slot).hour
end
