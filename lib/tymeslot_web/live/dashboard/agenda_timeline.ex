defmodule TymeslotWeb.Dashboard.AgendaTimeline do
  @moduledoc """
  Turns a day's timed entries into an ordered *spine* for the dashboard agenda —
  the vertical time-rail that replaces the old flat list.

  A spine is a list of rows the component renders top to bottom:

    * `{:event, entry, meta}` — an appointment block. `meta` carries
      `next?` (the hero the cockpit zooms into) and `in_progress?` (started but
      not yet ended).
    * `{:gap, minutes}` — a labelled free stretch between two consecutive
      appointments. Dead time is compressed to a connector and *named* rather
      than drawn to scale, so a short meeting never vanishes and an empty morning
      never dominates the rail.
    * `:now` — the live now-line, placed once at its true position in the
      sequence: after anything in progress, before the next thing to start.

  This module is pure: entries in, rows out. All time reasoning is anchored to a
  `now` passed by the caller, so it is trivially testable and never reads the
  clock itself.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.Agenda.Entry

  # Free stretches shorter than this are noise, not breathing room — no connector.
  @gap_threshold_min 30

  @type meta :: [next?: boolean(), in_progress?: boolean()]
  @type row :: {:event, Entry.t(), meta()} | {:gap, non_neg_integer()} | :now

  @doc """
  Builds the spine for `entries` (a single day's timed appointments) anchored at
  `now`. `next_id` marks which entry the cockpit is featuring so the rail can
  ring it. Entries are sorted internally; all-day entries must be filtered out by
  the caller (they are not points in time).
  """
  @spec spine([Entry.t()], DateTime.t(), String.t() | nil) :: [row()]
  def spine(entries, now, next_id \\ nil)

  # An empty day carries no now-line — a lone marker under a "Today" heading reads
  # as noise, not information.
  def spine([], _now, _next_id), do: []

  def spine(entries, now, next_id) do
    {in_progress, upcoming} =
      entries
      |> Enum.sort_by(& &1.start_at, DateTime)
      |> Enum.split_with(&started?(&1, now))

    in_progress_rows =
      Enum.map(in_progress, &{:event, &1, meta(&1, next_id, in_progress?(&1, now))})

    in_progress_rows ++ [:now] ++ upcoming_rows(upcoming, now, in_progress == [], next_id)
  end

  @doc """
  Formats a gap of `minutes` as a human connector label, e.g. `"2h 15m free"`.
  """
  @spec format_gap(non_neg_integer()) :: String.t()
  def format_gap(minutes) when minutes < 60,
    do: dgettext("dashboard_home", "%{minutes}m free", minutes: minutes)

  def format_gap(minutes) do
    case {div(minutes, 60), rem(minutes, 60)} do
      {hours, 0} ->
        dgettext("dashboard_home", "%{hours}h free", hours: hours)

      {hours, mins} ->
        dgettext("dashboard_home", "%{hours}h %{mins}m free", hours: hours, mins: mins)
    end
  end

  # --- Spine assembly --------------------------------------------------------

  # Leads with the runway from `now` to the first upcoming entry (only when the
  # rail isn't already occupied by something in progress), then interleaves the
  # upcoming entries with the gaps between them.
  defp upcoming_rows([], _now, _idle?, _next_id), do: []

  defp upcoming_rows([first | _rest] = upcoming, now, idle?, next_id) do
    leading = if idle?, do: maybe_gap(minutes_between(now, first.start_at)), else: []
    leading ++ interleave(upcoming, next_id)
  end

  defp interleave([entry], next_id), do: [{:event, entry, meta(entry, next_id, false)}]

  defp interleave([earlier, later | rest], next_id) do
    [{:event, earlier, meta(earlier, next_id, false)}] ++
      maybe_gap(minutes_between(earlier.end_at, later.start_at)) ++
      interleave([later | rest], next_id)
  end

  defp maybe_gap(minutes) when minutes >= @gap_threshold_min, do: [{:gap, minutes}]
  defp maybe_gap(_minutes), do: []

  # --- Helpers ---------------------------------------------------------------

  defp meta(%Entry{id: id}, next_id, in_progress?),
    do: [next?: id == next_id, in_progress?: in_progress?]

  defp started?(%Entry{start_at: start_at}, now), do: DateTime.compare(start_at, now) != :gt

  # "In progress" per the moduledoc contract: started, and not yet ended. A stale
  # entry that has already ended (e.g. a `Day` that hasn't ticked yet) must not
  # keep rendering the pulsing "Now" node/badge.
  defp in_progress?(entry, now), do: started?(entry, now) and not_ended?(entry, now)

  defp not_ended?(%Entry{end_at: end_at}, now), do: DateTime.compare(end_at, now) == :gt

  # Never negative: overlapping or back-to-back entries yield no gap.
  defp minutes_between(earlier, later), do: max(DateTime.diff(later, earlier, :minute), 0)
end
