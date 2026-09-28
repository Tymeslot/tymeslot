defmodule TymeslotWeb.Dashboard.CalendarGrid.EventWrites do
  @moduledoc """
  Serialises the calendar grid's writes to one event, so that quick
  successive edits reach the provider in the order they were made.

  Every edit of an existing event (a drag, a resize, an inline field, the
  recurrence prompt, a video change) is shown on the grid at once and written
  in the background. Two of them running side by side for one event would
  race: they could land at the provider out of order, and a late failure of
  the first would put its original back over the second on screen.

  So each event, known by its integration and uid, has at most one write in
  flight. A write made while another is running waits in a queue in the
  socket, and starts once the running one has answered, whether it succeeded
  or failed. Writes to different events still run side by side.

  ## What each write carries

  Each write carries only its own change, and is applied to the event as the
  provider last accepted it (the chain's `confirmed` event), not to the grid's
  copy at the moment it was made. The grid's copy already shows every earlier
  write's change, and every provider write sends the whole event, so a write
  built from it would quietly carry an earlier write's change even after that
  write had failed, and would send the event without what an earlier success
  added on the provider's side (a video room's join line in the description).

  ## When a write fails

  Only the failed write's change is taken back. When writes are still waiting
  behind it, they still run, and the grid shows the confirmed event with the
  waiting writes' changes on top of it. When nothing is waiting, the grid goes
  back to the confirmed event. So once an event's queue drains, the grid
  shows what the provider holds.

  An edit that could not reach the provider but was saved to sync later
  (`retry: :queued`) counts as accepted: the next write starts from it, as
  the queued replay will.

  ## After a write to a whole series

  A write of this and following events, or of all events, of a recurring
  series (`:recurrence_scope` `:following` or `:all`) can move every
  occurrence, and the grid's cached rows of the series are dropped until a
  sync brings them back (see `Tymeslot.CalendarGrid.SeriesEdit`). When one
  succeeds, the grid reloads its events, so the series shows what the cache
  now holds and the sync's rows appear as it lands; the detail panel closes
  if its event is gone.

  The writes still waiting behind it for the same event are dropped, not
  run. They were made against the occurrence as it was, whose row, and for
  a split its uid, may no longer exist, and the chain's `confirmed` event
  is no longer what the provider holds; running them could write a stale
  copy of the event over the series-wide change, or to an occurrence the
  series has left. The organiser is told how many changes were not applied,
  and can make them again on the reloaded grid.

  A series moved to another calendar is not one of these writes, but it
  ends the same way (`series_moved/2`): every write held while it was
  moving is dropped and counted, and the grid reloads.

  ## While a whole series is written or moved

  Queueing by event alone would let an edit of another occurrence of the
  series run alongside a write to the whole of it, or its move, and land
  on the series as it was: on Google across accounts and on Outlook, on
  the original the move deletes; on CalDAV, turning the move into a copy
  with the original left behind, or writing an occurrence the series no
  longer has.

  So while such a write or move is running, the series is held, known by
  its integration and address (`Tymeslot.CalendarGrid.Occurrence.series_address/1`)
  as read when it started. A write to any other event of the series waits
  in the hold, not started, until the series write or move answers.
  Writes to the event the series write was made from queue behind it as
  before. When the series was changed, the held writes are dropped with
  the ones queued behind it, and counted in the same warning; when it was
  not, they start in the order they were made.

  Neither starts while the series is busy: a move while any write to the
  series is saving (`series_saving?/2`), a write to the whole series while
  a write to another of its events is saving, or it is moving
  (`series_busy?/2`). The organiser is asked to wait instead. Events
  outside a series, and other series, are never held.

  ## Telling the attendees

  A write made with `:notify` (a change of an event's timing, see
  `EditWorkflow.apply_event_change/6`) asks whether to tell the event's
  attendees only once the provider has accepted it, in the scope it was
  written in. Nobody is asked about a change that failed, and the
  notification of a write to a whole series is sent from the event the
  write answered with, not read back from the series' cached rows, which
  the write dropped.

  ## Results

  Every write carries a reference, `{key, seq}`, where `seq` rises with every
  write the grid makes. The async result names it, and a result that does not
  name the write in flight for its event is dropped, so a stale failure can
  never revert a later edit. Results arrive as plain messages to the
  LiveView (see `EditWorkflow.run_async/4`), one per task, so two writes can
  never share a task name and silently drop each other's answer.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.Occurrence
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @typedoc "Identifies the event a chain of writes belongs to."
  @type key :: {integer() | nil, String.t()}

  @typedoc "Identifies one write: its event and its place in the grid's writes."
  @type ref :: {key(), pos_integer()}

  @typedoc "How a write answered, as the component hears it."
  @type outcome :: {:ok, map()} | :unchanged | :queued | :failed

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
    submit(socket, event, %{kind: :update, changes: changes, opts: opts, notify: notify})
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
    do: submit(socket, event, %{kind: :video, video_integration_id: video_integration_id})

  @doc """
  Records how the write `ref` answered and starts the next write waiting for
  the same event, taking a failed write's change back off the grid. A result
  for a write that is not in flight is ignored.
  """
  @spec settle(Phoenix.LiveView.Socket.t(), ref(), outcome()) :: Phoenix.LiveView.Socket.t()
  def settle(socket, {key, _seq} = ref, outcome) do
    case socket.assigns.event_writes do
      %{^key => %{in_flight: %{ref: ^ref} = write} = chain} ->
        socket
        |> advance(key, chain, outcome)
        |> notify_attendees(write, outcome)

      _stale ->
        socket
    end
  end

  # See "Telling the attendees" in the moduledoc.
  defp notify_attendees(socket, %{notify: %{} = notify, opts: opts}, {:ok, updated}) do
    EditWorkflow.apply_notify_result(
      socket,
      notify.original,
      updated,
      notify.saved_message,
      Keyword.get(opts, :recurrence_scope, :this_only)
    )
  end

  defp notify_attendees(socket, _write, _outcome), do: socket

  @doc """
  Holds every write to an event of the series `event` belongs to while
  the series moves to another calendar, until `series_moved/2` or
  `series_move_failed/2`. The move is only started once nothing is saving
  for the series (`series_saving?/2`).
  """
  @spec series_moving(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_moving(socket, event) do
    case series_key(event) do
      nil -> socket
      series -> put_hold(socket, series, %{uid: nil, held: []})
    end
  end

  @doc """
  Reloads the grid once the series `event` belongs to has moved to another
  calendar, dropping every write held while it moved (see "While a whole
  series is written or moved" in the moduledoc).
  """
  @spec series_moved(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_moved(socket, event) do
    {held, socket} = take_hold(socket, series_key(event))
    report_dropped(length(held), &dropped_by_move_message/1)
    reload(socket)
  end

  @doc """
  Starts the writes held while the series `event` belongs to was moving,
  once the move has failed and left the series where it was.
  """
  @spec series_move_failed(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def series_move_failed(socket, event), do: release(socket, series_key(event))

  @doc """
  Whether a write to an event of the series `event` belongs to is still
  running or waiting, or the series is moving. A series is not moved while
  one is: the write would land on the original after the move had copied it.
  """
  @spec series_saving?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def series_saving?(socket, event) do
    case series_key(event) do
      nil ->
        false

      series ->
        Map.has_key?(socket.assigns.series_holds, series) or
          Enum.any?(socket.assigns.event_writes, fn {_key, chain} -> chain.series == series end)
    end
  end

  @doc """
  Whether a write to another event of the series `event` belongs to is
  still running or waiting, or the series is moving. A write to the whole
  series is not made from `event` while one is: the two would race at the
  provider. Writes to `event` itself are not counted, since a write to the
  whole series made from it waits behind them.
  """
  @spec series_busy?(Phoenix.LiveView.Socket.t(), map()) :: boolean()
  def series_busy?(socket, event) do
    case series_key(event) do
      nil ->
        false

      series ->
        uid = event.uid

        match?(%{^series => %{uid: holder}} when holder != uid, socket.assigns.series_holds) or
          Enum.any?(socket.assigns.event_writes, fn {{_integration_id, chain_uid}, chain} ->
            chain.series == series and chain_uid != uid
          end)
    end
  end

  # The series an event belongs to, as the grid holds its writes: its
  # integration and its address there, read once, when a write is made.
  defp series_key(%{calendar_integration_id: integration_id} = event) do
    case Occurrence.series_address(event) do
      {:ok, address} -> {integration_id, address}
      {:error, _unaddressable} -> nil
    end
  end

  defp series_key(_event), do: nil

  defp dropped_by_move_message(count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was moved, but a change you made while it was moving was not applied. Please make it again.",
      "The series was moved, but %{count} changes you made while it was moving were not applied. Please make them again.",
      count
    )
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

  defp submit(socket, event, write) do
    key = {event.calendar_integration_id, event.uid}
    series = series_key(event)
    seq = socket.assigns.event_write_seq + 1
    write = write |> Map.put(:ref, {key, seq}) |> tag_series_wide(series)
    socket = assign(socket, :event_write_seq, seq)

    case socket.assigns.series_holds do
      # See "While a whole series is written or moved" in the moduledoc.
      %{^series => %{uid: holder} = hold} when holder != event.uid ->
        put_hold(socket, series, %{hold | held: [{event, write} | hold.held]})

      _free ->
        socket
        |> hold_for(write, event)
        |> enqueue(key, series, event, write)
    end
  end

  defp enqueue(socket, key, series, event, write) do
    case socket.assigns.event_writes do
      %{^key => chain} ->
        put_chain(socket, key, %{chain | waiting: :queue.in(write, chain.waiting)})

      _idle ->
        socket
        |> put_chain(key, %{
          confirmed: event,
          series: series,
          in_flight: write,
          waiting: :queue.new()
        })
        |> start(write, event)
    end
  end

  # A write to the whole of an addressable series carries the series, so
  # the hold it puts on it can be lifted when it answers.
  defp tag_series_wide(write, nil), do: write

  defp tag_series_wide(%{kind: :update, opts: opts} = write, series) do
    if Keyword.get(opts, :recurrence_scope) in [:following, :all],
      do: Map.put(write, :series, series),
      else: write
  end

  defp tag_series_wide(write, _series), do: write

  defp hold_for(socket, %{series: series}, event) do
    if Map.has_key?(socket.assigns.series_holds, series),
      do: socket,
      else: put_hold(socket, series, %{uid: event.uid, held: []})
  end

  defp hold_for(socket, _write, _event), do: socket

  defp put_hold(socket, series, hold),
    do: assign(socket, :series_holds, Map.put(socket.assigns.series_holds, series, hold))

  # Lifts the hold on `series`, answering with the writes it held, oldest
  # first.
  defp take_hold(socket, series) do
    case Map.pop(socket.assigns.series_holds, series) do
      {nil, _holds} -> {[], socket}
      {hold, holds} -> {Enum.reverse(hold.held), assign(socket, :series_holds, holds)}
    end
  end

  # Lifts the hold on `series` and makes the writes it held, in order, as
  # if they had just been made.
  defp release(socket, series) do
    {held, socket} = take_hold(socket, series)
    Enum.reduce(held, socket, fn {event, write}, socket -> submit(socket, event, write) end)
  end

  defp advance(socket, key, chain, outcome) do
    cond do
      series_wide_success?(chain.in_flight, outcome) ->
        after_series_write(socket, key, chain)

      Map.has_key?(chain.in_flight, :series) ->
        socket
        |> advance_chain(key, chain, outcome)
        |> release_unless_pending(key, chain.in_flight.series)

      true ->
        advance_chain(socket, key, chain, outcome)
    end
  end

  defp advance_chain(socket, key, chain, outcome) do
    confirmed = confirmed_after(chain, outcome)

    case :queue.out(chain.waiting) do
      {:empty, _none} ->
        socket = assign(socket, :event_writes, Map.delete(socket.assigns.event_writes, key))
        if outcome == :failed, do: show(socket, confirmed), else: socket

      {{:value, next}, rest} ->
        socket
        |> put_chain(key, %{chain | confirmed: confirmed, in_flight: next, waiting: rest})
        |> show_waiting(outcome, confirmed, [next | :queue.to_list(rest)])
        |> start(next, confirmed)
    end
  end

  # A write to the whole series that did not change it lifts its hold,
  # unless another one made from the same event is still to run.
  defp release_unless_pending(socket, key, series) do
    pending =
      case socket.assigns.event_writes do
        %{^key => chain} -> [chain.in_flight | :queue.to_list(chain.waiting)]
        _drained -> []
      end

    if Enum.any?(pending, &(Map.get(&1, :series) == series)),
      do: socket,
      else: release(socket, series)
  end

  defp series_wide_success?(%{kind: :update, opts: opts}, {:ok, _updated}),
    do: Keyword.get(opts, :recurrence_scope) in [:following, :all]

  defp series_wide_success?(_write, _outcome), do: false

  # See "After a write to a whole series" in the moduledoc.
  defp after_series_write(socket, key, chain) do
    {held, socket} = take_hold(socket, Map.get(chain.in_flight, :series))
    report_dropped(:queue.len(chain.waiting) + length(held), &dropped_writes_message/1)

    socket
    |> assign(:event_writes, Map.delete(socket.assigns.event_writes, key))
    |> reload()
  end

  defp report_dropped(0, _message), do: :ok
  defp report_dropped(count, message), do: send(self(), {:flash, {:warning, message.(count)}})

  # Reloads the grid's events, closing the detail panel when its event is
  # gone from them.
  defp reload(socket) do
    socket = Helpers.load_events(socket)
    selected = socket.assigns.selected_event

    if selected && not Enum.any?(socket.assigns.events, &(&1.id == selected.id)),
      do: assign(socket, :selected_event, nil),
      else: socket
  end

  defp dropped_writes_message(count) do
    dngettext(
      "dashboard_calendar_events",
      "The series was updated, but a change you made while it was saving was not applied. Please make it again.",
      "The series was updated, but %{count} changes you made while it was saving were not applied. Please make them again.",
      count
    )
  end

  defp confirmed_after(_chain, {:ok, updated}), do: updated
  defp confirmed_after(chain, :queued), do: with_change(chain.confirmed, chain.in_flight)
  defp confirmed_after(chain, _unchanged_or_failed), do: chain.confirmed

  # A failure takes only its own change back: the writes still waiting keep
  # theirs on screen, since they are about to be written.
  defp show_waiting(socket, :failed, confirmed, waiting),
    do: show(socket, Enum.reduce(waiting, confirmed, &with_change(&2, &1)))

  defp show_waiting(socket, _accepted, _confirmed, _waiting), do: socket

  defp with_change(event, %{kind: :update, changes: changes}), do: Map.merge(event, changes)

  defp with_change(event, %{kind: :video, video_integration_id: id}),
    do: Map.put(event, :video_integration_id, id)

  defp put_chain(socket, key, chain),
    do: assign(socket, :event_writes, Map.put(socket.assigns.event_writes, key, chain))

  defp start(socket, %{kind: :update, ref: ref} = write, event) do
    user_id = socket.assigns.current_user.id

    EditWorkflow.run_async(
      socket,
      :event_update_result,
      fn ->
        case CalendarGrid.update_event(user_id, event, write.changes, write.opts) do
          {:ok, updated} -> {:ok, write: ref, updated_event: updated}
          {:error, %{reason: reason, retry: retry}} -> update_failure(ref, event, reason, retry)
        end
      end,
      update_failure(ref, event, :crashed, :not_queued)
    )
  end

  defp start(socket, %{kind: :video, ref: ref, video_integration_id: video_id}, event) do
    user_id = socket.assigns.current_user.id

    EditWorkflow.run_async(
      socket,
      :event_video_result,
      fn ->
        case CalendarGrid.change_event_video(user_id, event, video_id) do
          {:ok, :unchanged} ->
            {:unchanged, write: ref}

          # The event as the change wrote it, so the grid shows what the
          # calendar has and the notification diff sees exactly what the
          # attendees' invitation will carry.
          {:ok, url} ->
            {:ok,
             write: ref,
             original_event: event,
             updated_event: CalendarGrid.changed_event(user_id, event, video_id, url)}

          {:error, reason} ->
            video_failure(ref, event, reason)
        end
      end,
      video_failure(ref, event, :crashed)
    )
  end

  defp update_failure(ref, event, reason, retry),
    do: {:error, write: ref, original_event: event, reason: reason, retry: retry}

  defp video_failure(ref, event, reason),
    do: {:error, write: ref, original_event: event, reason: reason}
end
