defmodule Tymeslot.Polls.SlotHealth do
  @moduledoc """
  Advisory conflict check for a poll's candidate slots against the host's calendar.

  Powers the host's results view: each candidate slot is flagged `:ok` or
  `:conflict` depending on whether it overlaps a blocking event on the host's
  calendar. This is a hint only, **not** an authoritative gate. The binding
  conflict check happens at confirmation time in
  `Tymeslot.Meetings.Scheduling.create_meeting_with_conflict_check/1`.

  Because it is advisory, it degrades gracefully: any failure fetching the
  host's calendar events returns every slot as `:ok` and never blocks anything.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Utils.TimeRange

  require Logger

  @type slot_status :: :ok | :conflict

  @doc """
  Returns a `%{slot_id => :ok | :conflict}` map for every slot in the poll.

  The poll's `time_slots` association must be loaded. A poll with no slots
  returns an empty map.
  """
  @spec check(map()) :: %{binary() => slot_status()}
  def check(%{time_slots: []}), do: %{}

  def check(%{time_slots: slots} = poll) when is_list(slots) do
    {range_start, range_end} = slot_range(slots)

    case fetch_events(poll.user_id, range_start, range_end) do
      {:ok, events} ->
        blocking_events = Enum.filter(events, &CalendarEvent.blocking?/1)
        Map.new(slots, &{&1.id, slot_status(&1, blocking_events)})

      {:error, reason} ->
        Logger.warning("Poll slot-health calendar fetch failed; treating all slots as available",
          poll_id: poll.id,
          reason: inspect(reason)
        )

        Map.new(slots, &{&1.id, :ok})
    end
  end

  @spec fetch_events(integer(), DateTime.t(), DateTime.t()) :: {:ok, list()} | {:error, term()}
  defp fetch_events(user_id, range_start, range_end) do
    CalendarEvents.get_events_for_range_fresh(
      user_id,
      DateTime.to_date(range_start),
      DateTime.to_date(range_end)
    )
  end

  @spec slot_range([map()]) :: {DateTime.t(), DateTime.t()}
  defp slot_range(slots) do
    {
      slots |> Enum.map(& &1.start_time) |> Enum.min(DateTime),
      slots |> Enum.map(& &1.end_time) |> Enum.max(DateTime)
    }
  end

  @spec slot_status(map(), [map()]) :: slot_status()
  defp slot_status(slot, blocking_events) do
    if TimeRange.has_conflict_with_events?(slot.start_time, slot.end_time, blocking_events) do
      :conflict
    else
      :ok
    end
  end
end
