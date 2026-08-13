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
    assigns |> timed_events_for_day(date) |> overlap_layout()
  end

  @doc """
  Ids of the events in one day column that clash with an event on a different
  calendar integration.

  Computed from the day's clamped events, the same list the column layout is
  built from, so the marker and the columns can never disagree about which
  events share a day. Clamping matters: an event running past midnight competes
  with the next morning only for the part of it that lands in that column, and
  the untrimmed times would report a clash in a column where nothing is drawn
  overlapping.
  """
  @spec cross_integration_overlap_ids_for_day(map(), Date.t()) :: MapSet.t()
  def cross_integration_overlap_ids_for_day(assigns, date) do
    assigns |> timed_events_for_day(date) |> cross_integration_overlap_ids()
  end

  # The timed events landing in one day column, clamped to it and sorted by
  # start time — the shared input of the column layout and the clash marker.
  defp timed_events_for_day(assigns, date) do
    tz = assigns.user_timezone

    assigns.visible_events
    |> Enum.filter(fn e ->
      not e.all_day and event_spans_day?(e, date, tz)
    end)
    |> Enum.map(&clamp_event_to_day(&1, date, tz))
    |> Enum.sort_by(& &1.start_at)
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
  Returns the ids of events that overlap an event from a *different* calendar
  integration.

  This is not the same question as the column layout above answers. A
  `total_cols` greater than 1 says an event shares a cluster with something, but
  a cluster is transitive: A overlaps B and B overlaps C puts all three in one
  cluster and gives all three the same column count, even when A and C never
  touch. Marking on the column count would flag an event whose only real
  neighbour sits on its own calendar. The pairing therefore has to be decided
  pairwise, which is what this does.

  The sweep relies on the caller's list being sorted by `start_at`, which
  `layout_for_day/2` already does. For each event it walks forward only while
  the next event begins before this one ends, so a day of back-to-back
  appointments costs one comparison each and only a genuine pile-up costs more.

  A shared boundary is not an overlap: an event ending exactly when the next
  begins does not compete for the organiser's time, and the column layout above
  already reuses the column in that case. The two must agree, or an organiser
  whose calendar is merely full would see every consecutive pair flagged.
  """
  @spec cross_integration_overlap_ids(list()) :: MapSet.t()
  def cross_integration_overlap_ids(events) do
    events
    |> pairs_overlapping_in_time()
    |> Enum.reduce(MapSet.new(), fn {a, b}, marked ->
      if a.calendar_integration_id == b.calendar_integration_id do
        marked
      else
        marked |> MapSet.put(a.id) |> MapSet.put(b.id)
      end
    end)
  end

  # Every pair of events whose times genuinely intersect, from a list already
  # sorted by `start_at`. `Enum.take_while/2` stops at the first event starting
  # at or after `a`'s end; because the list is sorted, nothing after it can
  # overlap `a` either.
  defp pairs_overlapping_in_time(events) do
    events
    |> Stream.unfold(fn
      [] -> nil
      [event | rest] -> {{event, rest}, rest}
    end)
    |> Enum.flat_map(fn {event, later} ->
      later
      |> Enum.take_while(&(DateTime.compare(&1.start_at, event.end_at) == :lt))
      |> Enum.map(&{event, &1})
    end)
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
