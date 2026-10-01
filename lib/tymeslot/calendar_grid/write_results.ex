defmodule Tymeslot.CalendarGrid.WriteResults do
  @moduledoc """
  The result messages a `Tymeslot.CalendarGrid.WriteQueue` waits for, read
  by a driver with no screen (`Tymeslot.CalendarGrid.WriteGuardian`): which
  of them the queue still waits for, and what each does to it, exactly as
  the grid's own handlers would apply it.
  """

  alias Tymeslot.CalendarGrid.QueuedWrite
  alias Tymeslot.CalendarGrid.WriteQueue

  @doc """
  Whether the queue still waits for the write result `{tag, result}`, for
  the answer of a whole-series move, `{:event_move_result, result}`, or for
  another driver to release an event, `{:event_writes_released, release}`.
  """
  @spec awaits?(WriteQueue.t(), {atom(), tuple()}) :: boolean()
  def awaits?(queue, {:event_move_result, {_status, payload}}) do
    if payload[:series_to],
      do: WriteQueue.series_held?(queue, payload[:original_event]),
      else: false
  end

  def awaits?(queue, {tag, _result} = message)
      when tag in [:event_update_result, :event_video_result] do
    {ref, _outcome} = QueuedWrite.outcome(message)
    Enum.any?(queue.chains, fn {_key, chain} -> match?(%{in_flight: %{ref: ^ref}}, chain) end)
  end

  def awaits?(queue, {:event_writes_released, {driver, key, _left}}) do
    case queue.elsewhere do
      %{^key => %{from: from}} -> MapSet.member?(from, driver)
      _not_waiting -> false
    end
  end

  def awaits?(_queue, _message), do: false

  @doc """
  Feeds a result message into the queue as the grid's handlers would: a
  write's answer settles it, a whole-series move's answer lifts its hold,
  and another driver's release resumes the writes kept for its event. Any
  other message changes nothing.
  """
  @spec apply_result(WriteQueue.t(), {atom(), tuple()}) :: {WriteQueue.t(), [WriteQueue.effect()]}
  def apply_result(queue, {:event_move_result, {status, payload}} = message) do
    cond do
      not awaits?(queue, message) -> {queue, []}
      status == :ok -> WriteQueue.series_moved(queue, payload[:original_event])
      true -> WriteQueue.series_move_failed(queue, payload[:original_event])
    end
  end

  def apply_result(queue, {tag, _result} = message)
      when tag in [:event_update_result, :event_video_result] do
    {ref, outcome} = QueuedWrite.outcome(message)
    WriteQueue.settle(queue, ref, outcome)
  end

  def apply_result(queue, {:event_writes_released, release}),
    do: WriteQueue.resume(queue, release)

  def apply_result(queue, _message), do: {queue, []}
end
