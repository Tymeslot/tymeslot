defmodule TymeslotWeb.Components.Shared.TimeOptions do
  @moduledoc """
  Shared helpers for time-related UI options used across dashboard components.

  The **value** of an option is always the 24h form the domain parses, so it
  never varies with what the organiser is looking at; only the **label**
  follows their clock preference. An end time on the next day is labelled
  "(+1)" and valued `"HH:MM+1"` (`Tymeslot.Availability.Window.parse_end/1`).
  """

  use Phoenix.Component

  alias Tymeslot.Availability.Window
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat

  @next_day_mark "(+1)"
  @day_seconds 86_400

  @doc """
  Returns 15-minute interval options as `{label, value}` pairs.

  The **value** is always 24h `HH:MM`: it is what the form submits and what
  `Tymeslot.Availability` parses, so it must not vary with what the organiser
  is looking at. Only the **label** follows their clock preference, so a 12-hour
  organiser picks "2:30 PM" from the list and the schedule still stores 14:30.
  """
  @spec time_options(String.t() | nil) :: list({String.t(), String.t()})
  def time_options(time_format), do: Enum.map(quarter_hours(), &option(&1, false, time_format))

  @doc """
  Same as `time_options/1`, narrowed to the slots from `from` to `to` inclusive.
  """
  @spec time_options_between(Time.t(), Time.t(), String.t() | nil) ::
          list({String.t(), String.t()})
  def time_options_between(%Time{} = from, %Time{} = to, time_format) do
    time_format
    |> time_options()
    |> Enum.filter(fn {_label, value} ->
      slot = Time.from_iso8601!(value <> ":00")
      Time.compare(slot, from) != :lt and Time.compare(slot, to) != :gt
    end)
  end

  @doc """
  End-time options for hours opening at `start`: every quarter hour after it
  the same day, then the next day's through `start` itself (a full 24 hours),
  even when `start` is off the quarter-hour grid.
  `current`, the stored end in the editor's format, stays on the list when it
  is off the quarter-hour grid, so opening the editor never changes it.
  """
  @spec end_options(Time.t() | nil, String.t() | nil, String.t() | nil) ::
          list({String.t(), String.t()})
  def end_options(nil, time_format, _current), do: time_options(time_format)

  def end_options(%Time{} = start, time_format, current) do
    {same_day, next_day} =
      quarter_hours()
      |> with_current(current)
      |> Enum.concat([start])
      |> Enum.uniq()
      |> Enum.sort(Time)
      |> Enum.split_with(&(Time.compare(&1, start) == :gt))

    Enum.map(same_day, &option(&1, false, time_format)) ++
      Enum.map(next_day, &option(&1, true, time_format))
  end

  @doc """
  The quarter hours inside a day's hours, in order from the start, for the
  break pickers. In hours that end the next day, times after midnight are
  labelled "(+1)"; their value stays `HH:MM`, because a break's day follows
  from its hours (`Tymeslot.Availability.Window.next_day?/3`).
  """
  @spec window_options(map(), String.t() | nil) :: list({String.t(), String.t()})
  def window_options(
        %{start_time: %Time{} = start, end_time: %Time{}, ends_next_day: true} = window,
        time_format
      ) do
    span = Window.span_seconds(window)

    in_window =
      quarter_hours()
      |> Enum.map(&{Integer.mod(Time.diff(&1, start), @day_seconds), &1})
      |> Enum.filter(fn {offset, _time} -> offset <= span end)
      |> Enum.sort()

    with_end = if span == @day_seconds, do: in_window ++ [{span, start}], else: in_window

    Enum.map(with_end, fn {offset, time} ->
      next_day? = offset == @day_seconds or Time.compare(time, start) == :lt
      {label(time, next_day?, time_format), Calendar.strftime(time, "%H:%M")}
    end)
  end

  def window_options(%{start_time: %Time{} = from, end_time: %Time{} = to}, time_format),
    do: time_options_between(from, to, time_format)

  def window_options(_no_hours, _time_format), do: []

  defp quarter_hours,
    do: for(hour <- 0..23, minute <- [0, 15, 30, 45], do: Time.new!(hour, minute, 0))

  defp with_current(times, current) when is_binary(current) and current != "" do
    case Window.parse_end(current) do
      {:ok, {time, _next_day?}} -> times |> Enum.concat([time]) |> Enum.uniq() |> Enum.sort(Time)
      {:error, _reason} -> times
    end
  end

  defp with_current(times, _current), do: times

  defp option(time, next_day?, time_format),
    do: {label(time, next_day?, time_format), Window.format_end(time, next_day?)}

  defp label(time, next_day?, time_format), do: time_label(time, next_day?, time_format)

  @doc """
  A time as shown to the organiser: in their clock, with "(+1)" after a time
  on the day following the day's own date. The one place such labels are built.
  """
  @spec time_label(Time.t(), boolean(), String.t() | nil) :: String.t()
  def time_label(time, false, time_format), do: TimeFormat.format(time, time_format)

  def time_label(time, true, time_format),
    do: "#{TimeFormat.format(time, time_format)} #{@next_day_mark}"
end
