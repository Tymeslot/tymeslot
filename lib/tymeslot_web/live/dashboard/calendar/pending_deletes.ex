defmodule TymeslotWeb.Dashboard.Calendar.PendingDeletes do
  @moduledoc """
  The deletes the surface is hiding until they have run, keyed by the token
  of the job that will run them (see `Deletion`).

  An entry is `%{event: event, scope: scope, title: title, confirmed: boolean,
  notify: boolean, series: key | nil}`, `notify` when the delete is meant to
  tell the attendees. `event` carries what addresses the event (a loaded
  event, or the address a scheduled delete was stored with), so the same entry
  hides the event whichever week is loaded, and again after a reload, a
  remount or in a second tab: an `:occurrence` delete hides the event with that
  integration and uid, a `:series` delete every event of the same series
  (`WriteQueue.series_key/1`), loaded now or later.
  """

  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.Occurrence
  alias Tymeslot.CalendarGrid.WriteQueue

  @type t :: %{optional(pos_integer()) => map()}

  @doc """
  The entry for deleting `event` in `scope`; `confirmed?` when it cannot be
  undone, `notify?` when it tells the attendees.
  """
  @spec entry(map(), :occurrence | :series, boolean(), boolean()) :: map()
  def entry(event, scope, confirmed?, notify? \\ false) do
    %{
      event: event,
      scope: scope,
      title: EventPayload.title(event),
      confirmed: confirmed?,
      notify: notify?,
      series: if(scope == :series, do: WriteQueue.series_key(event))
    }
  end

  @doc """
  The entries for `jobs`, as `Changes.pending_deletes/1` lists them. A
  delete that is already running cannot be undone, so it counts as confirmed.
  The title is the cached row's, which exists until the delete has run: one
  cached-row query per pending job, and an organiser has a handful at most.
  """
  @spec from_jobs([map()]) :: t()
  def from_jobs(jobs) do
    Map.new(jobs, fn job ->
      titled = Occurrence.cached_row(job)
      {job.token, entry(titled, job.scope, not job.undoable?, job.notify_attendees?)}
    end)
  end

  @doc """
  The entry for a delete another tab scheduled, from the address it was
  scheduled with and whether it tells the attendees (`notify_attendees`). It
  is confirmed here (this tab offers no Undo for it) and marked
  `origin: :elsewhere`, so this tab does not announce that it was deleted.
  """
  @spec foreign(map(), :occurrence | :series) :: map()
  def foreign(address, scope) do
    address
    |> Occurrence.cached_row()
    |> entry(scope, true, Map.get(address, :notify_attendees) == true)
    |> Map.put(:origin, :elsewhere)
  end

  @doc """
  The undoable entry whose delete the browser tab `tab` scheduled last, with
  its token. None without a tab (`nil`), so a job stored without one is
  never offered.
  """
  @spec latest_undoable(t(), [map()], String.t() | nil) :: {pos_integer(), map()} | nil
  def latest_undoable(_pending, _jobs, nil), do: nil

  def latest_undoable(pending, jobs, tab) do
    latest =
      jobs
      |> Enum.filter(&(&1.undoable? and &1.tab == tab and Map.has_key?(pending, &1.token)))
      |> Enum.max_by(& &1.token, fn -> nil end)

    if latest, do: {latest.token, Map.fetch!(pending, latest.token)}
  end

  @doc "`events` without those a pending delete hides."
  @spec reject([map()], t()) :: [map()]
  def reject(events, pending) when map_size(pending) == 0, do: events

  def reject(events, pending) do
    entries = Map.values(pending)
    uids = MapSet.new(entries, &uid_key(&1.event))
    series = entries |> Enum.map(& &1.series) |> Enum.reject(&is_nil/1) |> MapSet.new()

    Enum.reject(events, fn event ->
      MapSet.member?(uids, uid_key(event)) or
        (MapSet.size(series) > 0 and MapSet.member?(series, WriteQueue.series_key(event)))
    end)
  end

  defp uid_key(event), do: {Map.get(event, :calendar_integration_id), Map.get(event, :uid)}
end
