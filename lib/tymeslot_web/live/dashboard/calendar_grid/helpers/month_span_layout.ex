defmodule TymeslotWeb.Dashboard.CalendarGrid.Helpers.MonthSpanLayout do
  @moduledoc """
  Lays out multi-day and all-day events as horizontal bars across a week row of
  the month grid, the way Google/Outlook month views do.

  A month cell can show two kinds of event:

    * **bars** — all-day events (any duration) and *timed* events that cover more
      than one calendar day. These render as a continuous horizontal bar across
      every day they touch, packed into stable lanes so they never overlap and
      sit at the same vertical position in every cell they span.
    * **chips** — single-day timed events. These render as ordinary chips inside
      their own cell (handled by the view, not here).

  Every visible event is exactly one of the two, so bars and chips never
  double-count an event.

  Lane packing is greedy interval colouring: within a week, segments are sorted
  by start column then longest-span-first, and each is placed in the first lane
  whose previously-placed segment has already ended. This is the same shape as
  `OverlapLayout` but over *date* columns within a week rather than time within
  a day.
  """

  alias Tymeslot.Integrations.Calendar.CalendarEvent

  @type segment :: %{
          event: CalendarEvent.t(),
          start_col: non_neg_integer(),
          end_col: non_neg_integer(),
          continues_left: boolean(),
          continues_right: boolean(),
          lane: non_neg_integer()
        }

  @doc """
  Computes the bar layout for a single week (a list of seven consecutive `Date`s).

  Returns `%{segments: [segment], lane_count: non_neg_integer}` where each
  segment carries its inclusive `start_col`/`end_col` (0–6 within the week), the
  `continues_left?`/`continues_right?` flags for rendering open-ended bars at week
  boundaries, and its assigned `lane`. `lane_count` is the number of lanes the
  week needs (used to reserve vertical space above the single-day chips).
  """
  @spec week_layout(map(), [Date.t()]) :: %{segments: [segment()], lane_count: non_neg_integer()}
  def week_layout(assigns, [week_first | _rest] = week_days) do
    tz = assigns.user_timezone
    week_last = List.last(week_days)

    segments =
      assigns.visible_events
      |> Enum.filter(&bar_event?(&1, tz))
      |> Enum.map(&segment_for_week(&1, week_first, week_last, tz))
      |> Enum.reject(&is_nil/1)
      |> Enum.sort_by(fn seg -> {seg.start_col, seg.start_col - seg.end_col} end)
      |> assign_lanes()

    %{segments: segments, lane_count: lane_count(segments)}
  end

  @doc """
  Returns the single-day *timed* events that should render as chips in `date`'s
  cell — i.e. everything that is not a bar.
  """
  @spec chip_events(map(), Date.t()) :: [CalendarEvent.t()]
  def chip_events(assigns, date) do
    tz = assigns.user_timezone

    Enum.filter(assigns.visible_events, fn event ->
      not bar_event?(event, tz) and single_day_on?(event, date, tz)
    end)
  end

  # --- Classification ---

  # All-day events are always bars. A timed event is a bar only when it covers
  # more than one local calendar day; otherwise it is a single-day chip.
  defp bar_event?(%{all_day: true}, _tz), do: true

  defp bar_event?(%{start_at: %DateTime{}} = event, tz) do
    {start_date, end_date} = local_span(event, tz)
    Date.compare(start_date, end_date) != :eq
  end

  defp bar_event?(_event, _tz), do: false

  defp single_day_on?(%{start_at: %DateTime{}} = event, date, tz) do
    {start_date, end_date} = local_span(event, tz)
    Date.compare(start_date, end_date) == :eq and Date.compare(start_date, date) == :eq
  end

  defp single_day_on?(_event, _date, _tz), do: false

  # --- Geometry ---

  defp segment_for_week(event, week_first, week_last, tz) do
    {start_date, end_date} = local_span(event, tz)

    cond do
      Date.compare(end_date, week_first) == :lt -> nil
      Date.compare(start_date, week_last) == :gt -> nil
      true -> build_segment(event, start_date, end_date, week_first, week_last)
    end
  end

  defp build_segment(event, start_date, end_date, week_first, week_last) do
    seg_start = max_date(start_date, week_first)
    seg_end = min_date(end_date, week_last)

    %{
      event: event,
      start_col: Date.diff(seg_start, week_first),
      end_col: Date.diff(seg_end, week_first),
      continues_left: Date.compare(start_date, week_first) == :lt,
      continues_right: Date.compare(end_date, week_last) == :gt
    }
  end

  # Returns `{start_date, inclusive_end_date}` in the user's timezone. For all-day
  # events the stored `end_date` is exclusive (iCal DTEND), so the inclusive last
  # day is one earlier. For timed events the end instant is shifted into the
  # user's zone; an end that lands exactly on local midnight belongs to the
  # previous day, so we step back one second before taking the date.
  defp local_span(%{all_day: true} = event, _tz) do
    {event.start_date, Date.add(event.end_date, -1)}
  end

  defp local_span(%{start_at: %DateTime{} = start_at, end_at: %DateTime{} = end_at}, tz) do
    start_date = start_at |> DateTime.shift_zone!(tz) |> DateTime.to_date()

    end_date =
      end_at
      |> DateTime.shift_zone!(tz)
      |> DateTime.add(-1, :second)
      |> DateTime.to_date()

    {start_date, max_date(start_date, end_date)}
  end

  defp max_date(a, b), do: if(Date.compare(a, b) == :gt, do: a, else: b)
  defp min_date(a, b), do: if(Date.compare(a, b) == :lt, do: a, else: b)

  # --- Lane packing ---

  defp assign_lanes(segments) do
    {placed, _lane_ends} =
      Enum.map_reduce(segments, %{}, fn seg, lane_ends ->
        lane = first_free_lane(lane_ends, seg.start_col)
        {Map.put(seg, :lane, lane), Map.put(lane_ends, lane, seg.end_col)}
      end)

    placed
  end

  # The first lane whose last-placed segment ends before this segment starts (or
  # an unused lane). Lanes are dense from 0, so iterating upward terminates.
  defp first_free_lane(lane_ends, start_col) do
    Enum.find(Stream.iterate(0, &(&1 + 1)), fn lane ->
      case Map.get(lane_ends, lane) do
        nil -> true
        end_col -> end_col < start_col
      end
    end)
  end

  defp lane_count([]), do: 0
  defp lane_count(segments), do: (segments |> Enum.map(& &1.lane) |> Enum.max()) + 1
end
