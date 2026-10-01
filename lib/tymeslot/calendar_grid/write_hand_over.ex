defmodule Tymeslot.CalendarGrid.WriteHandOver do
  @moduledoc """
  Saves for a later sync what can be of a calendar grid's write queue
  (`Tymeslot.CalendarGrid.WriteQueue`) that will never be driven to its
  end, because the node is stopping or the provider never answered, and
  logs, at error level, how many writes it could not.
  """

  require Logger

  alias Tymeslot.CalendarGrid.EventEdit
  alias Tymeslot.CalendarGrid.QueuedWrite
  alias Tymeslot.CalendarGrid.WriteQueue

  @doc """
  Saves what it can of `queue` for `user_id` through
  `Tymeslot.CalendarGrid.EventEdit.queue_for_retry/4`, and logs how many
  writes it could not.
  """
  @spec save(WriteQueue.t(), pos_integer()) :: :ok
  def save(queue, user_id) do
    {plans, lost} = plans(queue)
    unsaved = lost + Enum.sum(Enum.map(plans, &save_plan(&1, user_id)))

    if unsaved > 0 do
      Logger.error("Calendar grid writes lost: the grid's queue could not be finished",
        user_id: user_id,
        lost_writes: unsaved
      )
    end

    :ok
  end

  @doc """
  What of `queue` can still be saved: for each event, the event the writes
  not yet made would be made onto, with those of them that can be made from
  it, oldest first; and how many writes cannot be.

  A waiting edit of the event's fields can: it is applied to the confirmed
  event with the running write's change taken as made, as an edit saved to
  sync later would be. A video change cannot, nor anything behind it, since
  what it writes is only known once the video provider has answered; nor a
  write to a whole series, or anything waiting behind one or held by one,
  since whether it may still be made depends on how the series write ends,
  nor anything kept for a series another driver was writing.
  Edits kept for an event another driver was writing are made onto the
  event the first of them was made against.
  """
  @spec plans(WriteQueue.t()) :: {[{map(), [WriteQueue.write()]}], non_neg_integer()}
  def plans(%WriteQueue{chains: chains, holds: holds, elsewhere: elsewhere}) do
    {lent_series, elsewhere} = Map.split_with(elsewhere, &match?({{:series, _series}, _w}, &1))
    held = count_held(Map.values(holds) ++ Map.values(lent_series))

    kept =
      for {_key, %{held: [_newest | _older] = held}} <- elsewhere,
          do: kept_plan(Enum.reverse(held))

    waiting = for {_key, chain} <- chains, do: waiting_plan(chain)

    Enum.reduce(kept ++ waiting, {[], held}, fn {event, writes}, {plans, lost} ->
      {ready, rest} =
        if event, do: Enum.split_while(writes, &QueuedWrite.plain_edit?/1), else: {[], writes}

      {if(ready == [], do: plans, else: [{event, ready} | plans]), lost + length(rest)}
    end)
  end

  defp count_held(holds), do: Enum.reduce(holds, 0, &(&2 + length(&1.held)))

  # Each event's writes not yet made, after the event they would be made
  # onto, or `nil` when none of them can be.
  defp kept_plan([{event, _write} | _rest] = held), do: {event, Enum.map(held, &elem(&1, 1))}

  defp waiting_plan(chain) do
    if QueuedWrite.plain_edit?(chain.in_flight),
      do: {QueuedWrite.applied(chain.confirmed, chain.in_flight), :queue.to_list(chain.waiting)},
      else: {nil, :queue.to_list(chain.waiting)}
  end

  # Saves each write in turn onto the event as the one before left it, the
  # last carrying all of them; answers how many could not be saved.
  defp save_plan({event, writes}, user_id) do
    writes
    |> Enum.reduce_while({event, length(writes)}, fn write, {event, unsaved} ->
      case EventEdit.queue_for_retry(user_id, event, write.changes, write.opts) do
        {:ok, updated} -> {:cont, {updated, unsaved - 1}}
        {:error, :not_queued} -> {:halt, {event, unsaved}}
      end
    end)
    |> elem(1)
  rescue
    error ->
      Logger.error("Calendar grid writes could not be saved for a later sync",
        user_id: user_id,
        error: Exception.message(error)
      )

      length(writes)
  end
end
