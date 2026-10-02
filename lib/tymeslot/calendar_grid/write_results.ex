defmodule Tymeslot.CalendarGrid.WriteResults do
  @moduledoc """
  The result messages a `Tymeslot.CalendarGrid.WriteQueue` waits for, read
  by a driver with no screen (`Tymeslot.CalendarGrid.WriteGuardian`): which
  of them the queue still waits for, what each does to it, exactly as the
  grid's own handlers would apply it, and how those that drained an event
  left it, for a driver it was lent to.
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

  @doc """
  How the queue's writes left the event `key`, or the series of a
  `{:series, series}` key, once it has none left for it: worked out from the queue as it was before, and the result `messages`
  that drained it.

  A write held while its series was written or moved, and dropped once the
  series changed, leaves the event `:series_changed`, as the series write
  does, and so does the change for the series itself. With no message in
  hand, a held write may simply be unsaved, so the event is left
  `:unknown`.
  """
  @spec left_by(WriteQueue.t(), WriteQueue.lent(), [{atom(), tuple()}]) :: WriteQueue.left()
  def left_by(queue, {:series, series} = lent, messages) do
    if Enum.any?(messages, &changes_series?(queue, series, &1)),
      do: :series_changed,
      else: drained_left(queue, lent, messages)
  end

  def left_by(queue, key, messages) do
    if held_through_series_change?(queue, key, messages),
      do: :series_changed,
      else: drained_left(queue, key, messages)
  end

  defp settling({tag, _result} = message, ref)
       when tag in [:event_update_result, :event_video_result] do
    case QueuedWrite.outcome(message) do
      {^ref, outcome} -> outcome
      _other -> nil
    end
  end

  defp settling(_message, _ref), do: nil

  defp drained_left(queue, key, messages) do
    case queue do
      %{chains: %{^key => chain}} ->
        ref = chain.in_flight.ref
        chain_left(chain, Enum.find_value(messages, &settling(&1, ref)))

      %{elsewhere: %{^key => waiting}} ->
        for {:event_writes_released, {_driver, ^key, left}} <- messages,
            reduce: waiting.left,
            do: (acc -> WriteQueue.latest(acc, left))

      _not_pending ->
        :unknown
    end
  end

  # See "After a write to a whole series" in `WriteQueue`: a write held
  # while its series was written or moved is dropped once the series
  # changed, and the event it was made on is no longer what the provider
  # holds.
  defp held_through_series_change?(queue, key, messages) do
    Enum.any?(WriteQueue.series_holds(queue), fn {series, held} ->
      Enum.any?(held, fn {event, _write} -> WriteQueue.key(event) == key end) and
        Enum.any?(messages, &changes_series?(queue, series, &1))
    end)
  end

  defp changes_series?(_queue, series, {:event_move_result, {:ok, payload}}),
    do: WriteQueue.series_key(payload[:original_event]) == series

  defp changes_series?(queue, series, {tag, _result} = message)
       when tag in [:event_update_result, :event_video_result] do
    {{key, _seq} = ref, outcome} = QueuedWrite.outcome(message)

    case queue.chains do
      %{^key => chain} ->
        Enum.any?(
          [chain.in_flight | :queue.to_list(chain.waiting)],
          &(match?(%{ref: ^ref, series: ^series}, &1) and
              QueuedWrite.series_wide_success?(&1, outcome))
        )

      _not_writing ->
        false
    end
  end

  defp changes_series?(_queue, series, {:event_writes_released, {_driver, lent, left}}),
    do: lent == {:series, series} and left == :series_changed

  defp changes_series?(_queue, _series, _message), do: false

  defp chain_left(chain, nil), do: {:ok, chain.confirmed}

  defp chain_left(chain, outcome) do
    if QueuedWrite.series_wide_success?(chain.in_flight, outcome),
      do: :series_changed,
      else: {:ok, QueuedWrite.confirmed_after(chain.confirmed, chain.in_flight, outcome)}
  end
end
