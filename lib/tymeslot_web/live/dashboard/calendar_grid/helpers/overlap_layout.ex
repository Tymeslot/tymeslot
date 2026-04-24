defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.OverlapLayout do
  @moduledoc "Overlap-aware column layout algorithm for positioning simultaneous timed events within a day column."

  # Cap visible overlap columns — anything beyond this becomes unreadable (< 33% width).
  # Events that would land in column 4+ are returned as overflow and rendered as a "+N" chip.
  @max_visible_cols 3

  @spec positioned_events_for_day(map(), Date.t()) :: list()
  def positioned_events_for_day(assigns, date) do
    {visible, _overflow} = layout_for_day(assigns, date)
    visible
  end

  @spec overflow_events_for_day(map(), Date.t()) :: list()
  def overflow_events_for_day(assigns, date) do
    {_visible, overflow} = layout_for_day(assigns, date)
    overflow
  end

  @spec layout_for_day(map(), Date.t()) :: {list(), list()}
  def layout_for_day(assigns, date) do
    tz = assigns.user_timezone

    events =
      assigns.visible_events
      |> Enum.filter(fn e ->
        not e.all_day and event_spans_day?(e, date, tz)
      end)
      |> Enum.map(&clamp_event_to_day(&1, date, tz))
      |> Enum.sort_by(& &1.start_at)

    overlap_layout(events)
  end

  @doc """
  Assigns each event a column index and total column count for side-by-side rendering.

  Returns `{visible_tuples, overflow_events}` where `visible_tuples` is a list of
  `{event, col_idx, total_cols}` for events fitting within the max visible columns,
  and `overflow_events` are those that would have landed beyond the cap.
  """
  @spec overlap_layout(list()) :: {list(), list()}
  def overlap_layout([]), do: {[], []}

  def overlap_layout(events) do
    # Greedy slot assignment: assign each event to the first available column slot
    # that doesn't overlap with existing events in that slot
    slots =
      Enum.reduce(events, [], fn event, slots ->
        col_idx =
          Enum.find_index(slots, fn col_events ->
            last = List.last(col_events)
            last == nil or DateTime.compare(last.end_at, event.start_at) != :gt
          end)

        if col_idx do
          List.update_at(slots, col_idx, &(&1 ++ [event]))
        else
          slots ++ [[event]]
        end
      end)

    actual_cols = length(slots)
    total_cols = min(actual_cols, @max_visible_cols)
    visible_slots = Enum.take(slots, @max_visible_cols)
    overflow_events = slots |> Enum.drop(@max_visible_cols) |> List.flatten()

    visible_tuples =
      for {col_events, col_idx} <- Enum.with_index(visible_slots),
          event <- col_events do
        {event, col_idx, total_cols}
      end

    {visible_tuples, overflow_events}
  end

  @doc """
  Returns the UTC boundaries `{day_start, day_end}` for a calendar day in the given timezone.
  """
  @spec day_boundary_utc(Date.t(), String.t()) :: {DateTime.t(), DateTime.t()}
  def day_boundary_utc(date, tz) do
    day_start = DateTime.shift_zone!(DateTime.new!(date, ~T[00:00:00], tz), "Etc/UTC")
    day_end = DateTime.shift_zone!(DateTime.new!(Date.add(date, 1), ~T[00:00:00], tz), "Etc/UTC")
    {day_start, day_end}
  end

  # Does this event overlap with the given calendar day (in the user's timezone)?
  defp event_spans_day?(event, date, tz) do
    {day_start, day_end} = day_boundary_utc(date, tz)

    DateTime.compare(event.start_at, day_end) == :lt and
      DateTime.compare(event.end_at, day_start) == :gt
  end

  # Clamp an event's display start/end to the boundaries of a single calendar day.
  # Preserves original times in :display_start_at / :display_end_at for the time label.
  defp clamp_event_to_day(event, date, tz) do
    {day_start, day_end} = day_boundary_utc(date, tz)

    clamped_start =
      if DateTime.compare(event.start_at, day_start) == :lt, do: day_start, else: event.start_at

    clamped_end =
      if DateTime.compare(event.end_at, day_end) == :gt, do: day_end, else: event.end_at

    event
    |> Map.put(:display_start_at, event.start_at)
    |> Map.put(:display_end_at, event.end_at)
    |> Map.put(:start_at, clamped_start)
    |> Map.put(:end_at, clamped_end)
  end
end
