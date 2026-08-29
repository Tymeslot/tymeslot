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

  # A stored hour can outlive the grouping that produced it: a refetch that
  # keeps the same date (a timezone change, a lost-slot retry) can leave the
  # booker's chosen hour holding no slots at all. Treat that hour as unchosen
  # rather than rendering an expanded, empty section.
  def effective_expanded_hour(hour, {:hours, _periods} = grouping) when is_integer(hour) do
    if hour in hour_keys(grouping), do: hour, else: earliest_hour(grouping)
  end

  def effective_expanded_hour(hour, {:flat, _periods}) when is_integer(hour), do: hour

  def effective_expanded_hour(nil, {:hours, _periods} = grouping), do: earliest_hour(grouping)

  def effective_expanded_hour(nil, {:flat, _periods}), do: nil

  defp earliest_hour(grouping), do: grouping |> hour_keys() |> Enum.sort() |> List.first()

  defp hour_keys({:hours, periods}) do
    Enum.flat_map(periods, fn {_period, hours} ->
      Enum.map(hours, fn {hour, _slots} -> hour end)
    end)
  end

  @doc """
  Which hour holds `selected_time`, if any.

  Lets a theme mark the hour button that contains the pending selection even
  while collapsed, so picking a slot and then browsing a different hour
  doesn't make the selection disappear from the screen.
  """
  @spec selected_hour(grouping(), String.t() | nil) :: 0..23 | nil
  def selected_hour(_grouping, nil), do: nil
  def selected_hour({:flat, _periods}, _selected_time), do: nil

  def selected_hour({:hours, periods}, selected_time) do
    Enum.find_value(periods, fn {_period, hours} ->
      Enum.find_value(hours, fn {hour, slots} -> selected_time in slots && hour end)
    end)
  end

  @doc """
  Formats an hour as a label.

  Follows the same 12/24-hour convention as the slots themselves (via
  `LocalizationHelpers.format_time_by_locale/1`), so an hour and the times
  nested inside it can't disagree about how they read.
  """
  @spec hour_label(0..23) :: String.t()
  def hour_label(hour), do: LocalizationHelpers.format_time_by_locale(Time.new!(hour, 0, 0))

  # `group_slots_by_period/1` has already sorted within each period, and
  # `Enum.group_by/2` preserves that order, so only the hour keys need sorting.
  defp by_hour(slots) do
    slots
    |> Enum.group_by(&hour_of/1)
    |> Enum.sort_by(fn {hour, _slots} -> hour end)
  end

  defp hour_of(slot), do: TimeSlots.parse_time_slot(slot).hour
end
