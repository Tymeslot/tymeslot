defmodule Tymeslot.CalendarGrid.WriteQueue.SeriesActivity do
  @moduledoc """
  Whether a `Tymeslot.CalendarGrid.WriteQueue` is still writing to a
  recurring series, which decides whether the grid may write the whole of
  it: a write to the whole series made while one of its occurrences is
  still being written, here or by another driver, could be undone by that
  occurrence's write landing after it (see "Events another driver is
  writing" in `WriteQueue`).
  """

  alias Tymeslot.CalendarGrid.WriteQueue

  @doc """
  Whether a write to an event of the series `event` belongs to is still
  running or waiting, or the series is moving.
  """
  @spec saving?(WriteQueue.t(), map()) :: boolean()
  def saving?(queue, event) do
    case writers(queue, event) do
      nil -> false
      %{held_by: held_by, writing: writing} -> held_by != :none or writing != []
    end
  end

  @doc """
  Whether a write to another event of the series `event` belongs to is still
  running or waiting, or the series is moving. Writes to `event` itself are
  not counted, since a write to the whole series made from it waits behind
  them.
  """
  @spec busy?(WriteQueue.t(), map()) :: boolean()
  def busy?(queue, event) do
    case writers(queue, event) do
      nil ->
        false

      %{held_by: held_by, writing: writing} ->
        own = WriteQueue.key(event)
        held_by not in [:none, event.uid] or Enum.any?(writing, &(&1 != own))
    end
  end

  defp writers(queue, event) do
    case WriteQueue.series_key(event) do
      nil -> nil
      series -> WriteQueue.series_writers(queue, series)
    end
  end
end
