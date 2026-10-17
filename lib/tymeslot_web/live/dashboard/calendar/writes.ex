defmodule TymeslotWeb.Dashboard.Calendar.Writes do
  @moduledoc """
  Drives the calendar surface's writes to existing events through
  `Tymeslot.CalendarGrid.WriteQueue`, the order the old grid writes in, so
  quick successive changes reach the provider in the order they were made
  and a late failure can never put an older version back over a newer one.

  The queue lives in the `:event_writes` assign and is handed to the
  LiveView's `Tymeslot.CalendarGrid.WriteGuardian` after every change,
  before any write it releases starts, so writes still queued when the
  organiser leaves the page are finished anyway. A surface mounted again
  takes the queue back (`adopt/1`).

  `update/5`, `settle/3` and `resume/3` push the loaded window to the hook
  whenever the queue has something to show, so the grid settles on what the
  server holds: the change shown at once, or the original back after a
  failure. An answer that changes nothing (a stale result) pushes nothing,
  and a series-wide write, which leaves the series' cached rows stale, pushes
  with a cache reset. On success the optimistic event stays on the grid until
  the next window load. `adopt/1`, `series_busy?/2` and `saving?/2` do not
  push.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.QueuedWrite
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.CalendarGrid.WriteTask
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  Shows `optimistic` at once and writes `changes` to `event` through
  `Tymeslot.CalendarGrid.update_event/4`, now or once its earlier writes
  have answered. `opts` go to the write (`recurrence_scope:`; a `:notify`
  key is dropped, see below). The answer
  arrives as `{:event_update_result, ...}` at `DashboardLive`, which hands
  it to `settle/3` through `CalendarRouting`.
  """
  @spec update(socket(), map(), map(), map(), keyword()) :: socket()
  def update(socket, event, optimistic, changes, opts) do
    opts = Keyword.delete(opts, :notify)

    socket
    |> SurfaceData.show_event(optimistic)
    |> drive(&WriteQueue.update(&1, event, changes, opts, nil))
    |> push()
  end

  @doc "Records how the write `ref` answered and starts the next one for its event."
  @spec settle(socket(), WriteQueue.ref(), WriteQueue.outcome()) :: socket()
  def settle(socket, ref, outcome),
    do: socket |> drive(&WriteQueue.settle(&1, ref, outcome)) |> push_if_changed()

  @doc "Starts the writes kept for an event another LiveView has finished writing."
  @spec resume(socket(), WriteQueue.release()) :: socket()
  def resume(socket, release),
    do: socket |> drive(&WriteQueue.resume(&1, release)) |> push_if_changed()

  @doc """
  The queue the surface starts from: this LiveView's own, taken back from
  its guardian, and waiting for whatever any other guardian of the
  organiser is still writing (see `WriteGuardian.adopt/2`). Records the
  count of departures it was taken at, so `SurfaceData` can tell a revived
  surface (one that missed a departure) from one updated in the ordinary way.
  """
  @spec adopt(socket()) :: socket()
  def adopt(socket) do
    user_id = socket.assigns.current_user.id

    {socket, _effects} = drive(socket, &{WriteGuardian.adopt(&1, user_id), []})

    assign(socket, :writes_adopted_after, socket.assigns[:calendar_left])
  end

  @doc """
  Whether another event of `event`'s series is still being written, or the
  series is held: a write to the whole series is not made meanwhile.
  """
  @spec series_busy?(socket(), map()) :: boolean()
  def series_busy?(socket, event),
    do: CalendarGrid.series_busy?(socket.assigns.event_writes, event)

  @doc "Whether `event` has a write running or waiting."
  @spec saving?(socket(), map()) :: boolean()
  def saving?(socket, event),
    do: WriteQueue.key(event) in WriteQueue.pending_keys(socket.assigns.event_writes)

  # Runs what the queue releases; answers the socket and the effects, which
  # say whether the grid must be told.
  defp drive(socket, fun) do
    {queue, effects} = fun.(socket.assigns.event_writes)
    :ok = WriteGuardian.mirror(queue, socket.assigns.current_user.id)
    socket = Enum.reduce(effects, assign(socket, :event_writes, queue), &run_effect/2)

    {socket, effects}
  end

  defp push({socket, effects}), do: push(socket, effects)

  defp push_if_changed({socket, []}), do: socket
  defp push_if_changed({socket, effects}), do: push(socket, effects)

  # A series-wide write leaves the hook's cached occurrences outside the
  # window stale, so it pushes with a reset.
  defp push(socket, effects) do
    if :reload in effects,
      do: SurfaceData.reload(socket, :events),
      else: SurfaceData.push_events(socket, false)
  end

  defp run_effect({:start, write, event}, socket) do
    user_id = socket.assigns.current_user.id

    :ok =
      WriteTask.start(
        QueuedWrite.result_tag(write),
        fn -> QueuedWrite.perform(user_id, write, event) end,
        QueuedWrite.crash_result(write, event),
        report_to_guardian: true
      )

    socket
  end

  defp run_effect({:show, event}, socket), do: SurfaceData.show_event(socket, event)

  # Reloaded by `push/2`, which pushes the window with a cache reset.
  defp run_effect(:reload, socket), do: socket

  # The surface never queues a write with a notification (updates always queue with `notify: nil`).
  defp run_effect({:notify, _notify, _updated, _scope}, socket), do: socket

  defp run_effect({:dropped, reason, count}, socket) do
    send(self(), {:flash, {:warning, CalendarEditMessages.dropped_message(reason, count)}})
    socket
  end
end
