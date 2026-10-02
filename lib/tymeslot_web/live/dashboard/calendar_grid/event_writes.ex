defmodule TymeslotWeb.Dashboard.CalendarGrid.EventWrites do
  @moduledoc """
  Serialises the calendar grid's writes to one event, so that quick
  successive edits reach the provider in the order they were made.

  Every edit of an existing event (a drag, a resize, an inline field, the
  recurrence prompt, a video change) is shown on the grid at once and written
  in the background. Two of them running side by side for one event would
  race: they could land at the provider out of order, and a late failure of
  the first would put its original back over the second on screen.

  The order itself, what each write carries, what a failure takes back, and
  how writes to a recurring series are held while the whole series is
  written or moved, is `Tymeslot.CalendarGrid.WriteQueue`, kept in the
  `:event_writes` assign. This module drives it for the grid: it starts the
  writes the queue releases, shows what it asks to be shown, reloads the
  grid after a write to a whole series, and warns the organiser about
  changes that were dropped.

  ## Telling the attendees

  A write made with `:notify` (a change of an event's timing, see
  `EditWorkflow.apply_event_change/6`) asks whether to tell the event's
  attendees only once the provider has accepted it, in the scope it was
  written in. Nobody is asked about a change that failed, and the
  notification of a write to a whole series is sent from the event the
  write answered with, not read back from the series' cached rows, which
  the write dropped. Only a grid on screen asks: with the LiveView gone,
  the guardian finishes the write and asks nobody.

  ## Surviving the LiveView

  A write waiting in the queue lives only in this process. So the queue is
  also handed to a `Tymeslot.CalendarGrid.WriteGuardian` after every
  change, and each write's result is sent to it as well; should the
  LiveView go, or the grid be taken off the page, before the queue drains,
  the guardian finishes it. A grid mounted again in this LiveView takes the
  queue back from it. One mounted in another LiveView, after the
  connection came back or in another tab, takes nothing: it waits for the
  events the other LiveView's guardian is still writing, and starts its own
  edits of them once that guardian has released them (`adopt/1`).

  ## Results

  Every write carries a reference, `{key, seq}`. The async result names it,
  and a result that does not name the write in flight for its event is
  dropped. Results arrive as plain messages to the LiveView (see
  `EditWorkflow.run_async/5`), one per task, so two writes can never share a
  task name and silently drop each other's answer.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.QueuedWrite
  alias Tymeslot.CalendarGrid.WriteGuardian
  alias Tymeslot.CalendarGrid.WriteQueue
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @doc """
  Writes `changes` to `event` through `Tymeslot.CalendarGrid.update_event/4`,
  now or once the event's earlier writes have answered.

  Reports back with `{:event_update_result, {:ok, write: ref, updated_event:
  event}}` or `{:event_update_result, {:error, write: ref, original_event:
  event, reason: reason, retry: retry}}`, where `retry` is `:queued` when the
  edit is saved locally and will sync, `:not_queued` otherwise.
  """
  @spec update(Phoenix.LiveView.Socket.t(), map(), map(), keyword()) ::
          Phoenix.LiveView.Socket.t()
  def update(socket, event, changes, opts) do
    {notify, opts} = Keyword.pop(opts, :notify)
    drive(socket, &WriteQueue.update(&1, event, changes, opts, notify))
  end

  @doc """
  Changes the video of `event` through
  `Tymeslot.CalendarGrid.change_event_video/3`, now or once the event's
  earlier writes have answered.

  Reports back with `{:event_video_result, {:ok, write: ref, original_event:
  event, updated_event: event}}`, `{:event_video_result, {:unchanged, write:
  ref}}` for a choice that changed nothing, or `{:event_video_result,
  {:error, write: ref, original_event: event, reason: reason}}`.
  """
  @spec change_video(Phoenix.LiveView.Socket.t(), map(), pos_integer() | nil) ::
          Phoenix.LiveView.Socket.t()
  def change_video(socket, event, video_integration_id),
    do: drive(socket, &WriteQueue.change_video(&1, event, video_integration_id))

  @doc """
  Records how the write `ref` answered and starts the next write waiting for
  the same event, taking a failed write's change back off the grid. A result
  for a write that is not in flight is ignored.
  """
  @spec settle(Phoenix.LiveView.Socket.t(), WriteQueue.ref(), WriteQueue.outcome()) ::
          Phoenix.LiveView.Socket.t()
  def settle(socket, ref, outcome), do: drive(socket, &WriteQueue.settle(&1, ref, outcome))

  @doc """
  Starts the edits kept for an event another LiveView was still writing,
  once it has finished with it, applied to the event as its writes left it
  (see `Tymeslot.CalendarGrid.WriteQueue.resume/2`).
  """
  @spec resume(Phoenix.LiveView.Socket.t(), WriteQueue.release()) :: Phoenix.LiveView.Socket.t()
  def resume(socket, release), do: drive(socket, &WriteQueue.resume(&1, release))

  @doc """
  Holds every write to an event of the series `event` belongs to while
  the series moves to another calendar, until `series_moved/2` or
  `series_move_failed/2`. The move is only started once nothing is saving
  for the series (`series_saving?/2`).
  """
  @spec series_moving(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_moving(socket, event),
    do: drive(socket, &{WriteQueue.series_moving(&1, event), []})

  @doc """
  Reloads the grid once the series `event` belongs to has moved to another
  calendar, dropping every write held while it moved.
  """
  @spec series_moved(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_moved(socket, event), do: drive(socket, &WriteQueue.series_moved(&1, event))

  @doc """
  Starts the writes held while the series `event` belongs to was moving,
  once the move has failed and left the series where it was.
  """
  @spec series_move_failed(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_move_failed(socket, event),
    do: drive(socket, &WriteQueue.series_move_failed(&1, event))

  @doc """
  Whether a write to an event of the series `event` belongs to is still
  running or waiting, or the series is moving. A series is not moved while
  one is: the write would land on the original after the move had copied it.
  """
  @spec series_saving?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def series_saving?(socket, event),
    do: WriteQueue.series_saving?(socket.assigns.event_writes, event)

  @doc """
  Whether a write to another event of the series `event` belongs to is
  still running or waiting, or the series is moving. A write to the whole
  series is not made from `event` while one is: the two would race at the
  provider. Writes to `event` itself are not counted, since a write to the
  whole series made from it waits behind them.
  """
  @spec series_busy?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def series_busy?(socket, event),
    do: WriteQueue.series_busy?(socket.assigns.event_writes, event)

  @doc """
  The queue the grid starts from when it mounts, so that a new edit of an
  event still being written waits behind it (see
  `Tymeslot.CalendarGrid.WriteGuardian.adopt/2`): this LiveView's own,
  taken back from its guardian after the organiser left the calendar for
  another dashboard page, waiting for the events and series every other
  guardian of the organiser is still writing, after the connection dropped
  and came back, or in another tab. Those are written by the guardian
  writing them, and this grid's edits of them start once it has released
  them. The queue is handed straight to this LiveView's guardian.
  """
  @spec adopt(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def adopt(socket) do
    user_id = socket.assigns.current_user.id

    socket
    |> drive(&{WriteGuardian.adopt(&1, user_id), []})
    |> assign(:writes_adopted_after, socket.assigns[:calendar_left])
  end

  @doc """
  Shows `event` in place of the grid's row with the same id, and in the
  detail panel when that row is the one open.
  """
  @spec show(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def show(socket, event) do
    events = Enum.map(socket.assigns.events, &if(&1.id == event.id, do: event, else: &1))
    selected = socket.assigns.selected_event

    socket
    |> assign(:events, events)
    |> assign(:selected_event, if(selected && selected.id == event.id, do: event, else: selected))
    |> Helpers.precompute_derived()
  end

  # Changes the queue, hands the new queue to the guardian before any write
  # it releases starts, then does what the queue asks, in order.
  defp drive(socket, fun) do
    {queue, effects} = fun.(socket.assigns.event_writes)
    :ok = WriteGuardian.mirror(queue, socket.assigns.current_user.id)
    socket = assign(socket, :event_writes, queue)
    Enum.reduce(effects, socket, &run_effect/2)
  end

  defp run_effect({:start, write, event}, socket) do
    user_id = socket.assigns.current_user.id

    EditWorkflow.run_async(
      socket,
      QueuedWrite.result_tag(write),
      fn -> QueuedWrite.perform(user_id, write, event) end,
      QueuedWrite.crash_result(write, event),
      report_to_guardian: true
    )
  end

  defp run_effect({:show, event}, socket), do: show(socket, event)

  defp run_effect(:reload, socket), do: reload(socket)

  # See "Telling the attendees" in the moduledoc.
  defp run_effect({:notify, notify, updated, scope}, socket) do
    EditWorkflow.apply_notify_result(
      socket,
      notify.original,
      updated,
      notify.saved_message,
      scope
    )
  end

  defp run_effect({:dropped, reason, count}, socket) do
    send(self(), {:flash, {:warning, dropped_message(reason, count)}})
    socket
  end

  # Reloads the grid's events, closing the detail panel when its event is
  # gone from them.
  defp reload(socket) do
    socket = Helpers.load_events(socket)
    selected = socket.assigns.selected_event

    if selected && not Enum.any?(socket.assigns.events, &(&1.id == selected.id)),
      do: assign(socket, :selected_event, nil),
      else: socket
  end

  defp dropped_message(:series_move, count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was moved, but a change you made while it was moving was not applied. Please make it again.",
      "The series was moved, but %{count} changes you made while it was moving were not applied. Please make them again.",
      count
    )
  end

  defp dropped_message(:series_write, count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was updated, but a change you made while it was saving was not applied. Please make it again.",
      "The series was updated, but %{count} changes you made while it was saving were not applied. Please make them again.",
      count
    )
  end
end
