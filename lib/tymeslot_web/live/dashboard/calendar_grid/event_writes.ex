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

  ## Results

  Every write carries a reference, `{key, seq}`, where `seq` rises with every
  write the grid makes. The async result names it, and a result that does not
  name the write in flight for its event is dropped, so a stale failure can
  never revert a later edit. Results arrive as plain messages to the
  LiveView (see `EditWorkflow.run_async/4`), one per task, so two writes can
  never share a task name and silently drop each other's answer.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
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
  def update(socket, event, changes, opts),
    do: submit(socket, event, %{kind: :update, changes: changes, opts: opts})

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
      %{^key => %{in_flight: %{ref: ^ref}} = chain} -> advance(socket, key, chain, outcome)
      _stale -> socket
    end
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
    seq = socket.assigns.event_write_seq + 1
    write = Map.put(write, :ref, {key, seq})
    socket = assign(socket, :event_write_seq, seq)

    case socket.assigns.event_writes do
      %{^key => chain} ->
        put_chain(socket, key, %{chain | waiting: :queue.in(write, chain.waiting)})

      _idle ->
        socket
        |> put_chain(key, %{confirmed: event, in_flight: write, waiting: :queue.new()})
        |> start(write, event)
    end
  end

  defp advance(socket, key, chain, outcome) do
    confirmed = confirmed_after(chain, outcome)

    case :queue.out(chain.waiting) do
      {:empty, _none} ->
        socket = assign(socket, :event_writes, Map.delete(socket.assigns.event_writes, key))
        if outcome == :failed, do: show(socket, confirmed), else: socket

      {{:value, next}, rest} ->
        socket
        |> put_chain(key, %{confirmed: confirmed, in_flight: next, waiting: rest})
        |> show_waiting(outcome, confirmed, [next | :queue.to_list(rest)])
        |> start(next, confirmed)
    end
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
