defmodule TymeslotWeb.Dashboard.Calendar.Transfer do
  @moduledoc """
  Moving an event to another calendar from the side panel.

  No provider moves an event between calendars, so a move is a create on the
  destination and then a delete of the original (`Changes.move_event/3`),
  run in a supervised task whose answer reaches `DashboardLive` as
  `{:event_move_result, result}`, the message the calendar and the write
  guardian read. `CalendarEventHandlers.handle_event_move_result/2` routes
  it here as `:event_moved`, `:series_moved`, `:series_move_failed` or a
  `:revert_event` with no write named.

  A single event shows on its new calendar at once. Once moved, its cached
  row has a new identity, so the panel follows it there, and the toast
  offers Undo, which moves it back the same way, unless the original could
  not be removed cleanly. A member of a repeating series moves the whole
  series, so the organiser confirms it first (`SeriesMoveModal`); nothing
  shows on the grid until it has moved, the series' other writes are held
  meanwhile (`Writes.series_moving/2`), and it cannot be undone here.

  One move at a time: `transfer` holds the one in flight, so the toast can
  name its calendar, and panel edits of its event wait for it.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.CalendarDirectory
  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.CalendarGrid.WriteTask
  alias Tymeslot.Integrations.Calendar.Selection
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The calendar `event` sits on, as the panel's select names it
  (`"<integration_id>:<calendar_id>"`), or `nil` when its calendar is not one
  of its account's synced calendars.
  """
  @spec calendar_key(map(), [map()]) :: String.t() | nil
  def calendar_key(%{calendar_integration_id: id} = event, integrations) do
    with %{} = integration <- Enum.find(integrations, &(&1.id == id)),
         %{id: calendar_id} <-
           Selection.calendar_for_event(event, CalendarDirectory.synced_entries(integration)) do
      CalendarDirectory.key(id, calendar_id)
    else
      _none -> nil
    end
  end

  def calendar_key(_booking, _integrations), do: nil

  @doc """
  The organiser chose the calendar `key` for the event the panel shows. A
  key the panel never offered (another account, a read-only calendar) is
  ignored; anything refused says why and leaves the event where it is.
  """
  @spec request(socket(), String.t()) :: socket()
  def request(socket, key) when is_binary(key) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with %{mode: :edit, event_id: id} <- socket.assigns.panel,
         {:ok, event} <- lookup(socket, id),
         {:ok, destination} <- destination(socket.assigns, key),
         false <- calendar_key(event, integrations) == key,
         :ok <- idle(socket, event),
         :ok <- EditGuard.transfer_gates(user.id, integrations, event) do
      begin(socket, event, destination)
    else
      {:error, _reason} = refusal ->
        refused(socket, refusal)

      {:error, :rate_limited, _message} = refusal ->
        refused(socket, refusal)

      _ignored ->
        socket
    end
  end

  defp begin(socket, event, destination) do
    case Changes.ensure_movable(event) do
      :ok -> single(socket, event, destination)
      {:ok, :series} -> prompt_series(socket, event, destination)
      {:error, reason} -> refuse(socket, CalendarEditMessages.series_move_failed_message(reason))
    end
  end

  defp refused(socket, {:error, :rate_limited, _message}),
    do: refuse(socket, CalendarEditMessages.move_rate_limited_message())

  defp refused(socket, {:error, :saving}), do: refuse(socket, still_saving_message())

  defp refused(socket, {:error, :busy}),
    do: refuse(socket, CalendarEditMessages.another_moving_message())

  defp refused(socket, refusal) do
    socket
    |> redraw_select()
    |> flash(CalendarEditMessages.refusal(refusal))
    |> SurfaceData.push_events(false)
  end

  # One move takes one rate-limit token, taken here for a single event and
  # at the confirmation for a series.
  defp single(socket, event, destination) do
    case EditGuard.move_rate_limit(socket.assigns.current_user.id) do
      :ok -> start(socket, event, destination, nil)
      {:error, :rate_limited, _message} = refusal -> refused(socket, refusal)
    end
  end

  @doc "Moves the series the open prompt is for, once nothing of it is saving."
  @spec confirm_series(socket()) :: socket()
  def confirm_series(%{assigns: %{series_move_prompt: %{} = prompt}} = socket) do
    socket = assign(socket, :series_move_prompt, nil)

    cond do
      not is_nil(socket.assigns.transfer) ->
        refuse(socket, CalendarEditMessages.another_moving_message())

      Writes.series_busy?(socket, prompt.event) ->
        refuse(socket, still_saving_message())

      EditGuard.move_rate_limit(socket.assigns.current_user.id) != :ok ->
        refuse(socket, CalendarEditMessages.move_rate_limited_message())

      true ->
        socket
        |> Writes.series_moving(prompt.event)
        |> start(prompt.event, prompt.destination, prompt.destination.name)
        |> Toast.show(
          dgettext("dashboard_calendar_editing", "Moving the series to %{calendar}…",
            calendar: prompt.destination.name
          )
        )
    end
  end

  def confirm_series(socket), do: socket

  @doc "Closes the series prompt; nothing has changed."
  @spec cancel_series(socket()) :: socket()
  def cancel_series(socket),
    do: socket |> assign(:series_move_prompt, nil) |> redraw_select()

  @doc """
  A single event's move has landed (`:event_moved`): the window reloads, the
  panel follows the event to its new identity, and the toast names the
  result, with Undo when the original was removed cleanly.
  """
  @spec moved(socket(), map()) :: socket()
  def moved(socket, %{new_event_uid: uid, new_event_integration_id: integration_id} = moved) do
    transfer = socket.assigns.transfer
    socket = socket |> assign(:transfer, nil) |> SurfaceData.reload(:events)
    found = find(socket, integration_id, uid)

    socket
    |> follow(Map.get(moved, :original_event), found)
    |> rebase_undo(Map.get(moved, :original_event), found)
    |> PanelEdits.put_status(:saved)
    |> moved_toast(transfer, Map.get(moved, :original_event), found, Map.get(moved, :source))
  end

  @doc "A single event's move failed: it goes back to the calendar it was on."
  @spec failed(socket(), map()) :: socket()
  def failed(socket, original) do
    socket
    |> assign(:transfer, nil)
    |> redraw_select()
    |> SurfaceData.show_event(original)
    |> PanelEdits.put_status(:idle)
    |> SurfaceData.push_events(false)
  end

  @doc """
  A whole series has moved: what was held for it is dropped, the window
  reloads, and the panel closes, since the series' rows are gone until the
  destination's next sync. The toast names the result; there is no Undo.
  """
  @spec series_moved(socket(), map(), atom() | nil) :: socket()
  def series_moved(socket, event, source) do
    calendar = get_in(socket.assigns, [:transfer, :calendar_name])
    socket = socket |> assign(:transfer, nil) |> Writes.series_moved(event)

    socket
    |> SurfaceData.reload(:events)
    |> PanelState.close_on(EventPayload.id(event))
    |> series_toast(calendar, source)
  end

  @doc "A whole series' move failed: the writes held for it are made now."
  @spec series_failed(socket(), map()) :: socket()
  def series_failed(socket, event) do
    socket
    |> assign(:transfer, nil)
    |> Writes.series_move_failed(event)
    |> PanelEdits.put_status(:idle)
    |> Toast.dismiss()
  end

  @doc """
  Undoes a single event's move: moves it back to the calendar it came from,
  while it is still where the move put it. The move back is not itself
  undoable.
  """
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :transfer} = entry) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with {:ok, event} <- lookup(socket, entry.id),
         :ok <- idle(socket, event),
         {:ok, destination} <- destination(socket.assigns, entry.back_to),
         :ok <- EditGuard.check_transfer(user.id, integrations, event) do
      start(socket, event, destination, nil, undo: true)
    else
      {:error, :rate_limited, _message} ->
        socket
        |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
        |> refuse(CalendarEditMessages.move_rate_limited_message())

      {:error, :saving} ->
        socket
        |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
        |> refuse(still_saving_message())

      {:error, :busy} ->
        socket
        |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
        |> refuse(CalendarEditMessages.another_moving_message())

      {:error, _reason} = refusal ->
        flash(socket, CalendarEditMessages.refusal(refusal))

      _gone ->
        Toast.show(
          socket,
          dgettext("dashboard_calendar_editing", "That change can't be undone any more.")
        )
    end
  end

  @doc """
  Whether a move of the event `id` names is in flight. The id is the grid's
  (`EventPayload.id/1`), which the optimistic swap to the destination keeps,
  where the write key (the integration and uid) changes with it.
  """
  @spec moving?(socket(), String.t()) :: boolean()
  def moving?(%{assigns: %{transfer: %{id: id}}}, id), do: true
  def moving?(_socket, _key), do: false

  # The calendar `key` names, when it is one the select offers: a writable
  # calendar of one of the organiser's writable accounts.
  defp destination(assigns, key) do
    with {:ok, id, calendar_id} <- CalendarDirectory.parse_key(key),
         %{read_only: false} = account <- Enum.find(assigns.accounts, &(&1.id == id)),
         %{read_only: false, name: name} <-
           Enum.find(account.calendars, &(&1.id == calendar_id)),
         %{} = integration <- Enum.find(assigns.integrations, &(&1.id == id)) do
      {:ok, %{integration: integration, calendar_id: calendar_id, name: name, key: key}}
    else
      _not_offered -> :error
    end
  end

  # One move at a time, and never over a write still saving: the move copies
  # the event as the provider holds it now.
  defp idle(%{assigns: %{transfer: %{}}}, _event), do: {:error, :busy}

  defp idle(socket, event),
    do: if(Writes.saving?(socket, event), do: {:error, :saving}, else: :ok)

  defp prompt_series(socket, event, destination) do
    case Changes.series_move_notes(event, destination.integration) do
      {:ok, notes} ->
        socket
        |> assign(:series_move_prompt, %{
          event: event,
          destination: destination,
          notes: notes,
          title: EventPayload.title(event)
        })
        |> SurfaceData.push_events(false)

      {:error, reason} ->
        refuse(socket, CalendarEditMessages.series_move_failed_message(reason))
    end
  end

  defp start(socket, event, destination, series_to, opts \\ []) do
    user_id = socket.assigns.current_user.id
    target = Map.take(destination, [:integration, :calendar_id])

    :ok =
      WriteTask.start(
        :event_move_result,
        fn -> Changes.move_event_reported(user_id, event, target, series_to) end,
        Changes.move_crash_report(event, series_to),
        report_to_guardian: not is_nil(series_to)
      )

    socket
    |> assign(:transfer, %{
      id: EventPayload.id(event),
      calendar_name: destination.name,
      series: not is_nil(series_to),
      undo: Keyword.get(opts, :undo, false)
    })
    |> show_moving(event, destination, series_to)
    |> PanelEdits.put_status(:saving)
  end

  # A single event shows on its new calendar at once; a series stays put
  # until it has moved.
  defp show_moving(socket, _event, _destination, series_to) when is_binary(series_to),
    do: socket

  defp show_moving(socket, event, destination, nil) do
    optimistic = %{
      event
      | calendar_integration_id: destination.integration.id,
        provider_calendar_id: destination.calendar_id
    }

    socket |> SurfaceData.show_event(optimistic) |> SurfaceData.push_events(false)
  end

  defp find(socket, integration_id, uid) do
    Enum.find(
      socket.assigns.window_events,
      &(Map.get(&1, :calendar_integration_id) == integration_id and Map.get(&1, :uid) == uid)
    )
  end

  # The panel on the moved event follows it to the row the move cached.
  defp follow(
         %{assigns: %{panel: %{mode: :edit, event_id: id} = panel}} = socket,
         original,
         found
       )
       when is_map(original) and is_map(found) do
    if id == EventPayload.id(original),
      do: assign(socket, :panel, %{panel | event_id: EventPayload.id(found), event: found}),
      else: socket
  end

  defp follow(socket, _original, _found), do: socket

  # The changes made to the event before it moved (and held while it moved)
  # follow it to its new identity, so they can still be undone there.
  defp rebase_undo(socket, original, found) when is_map(original) and is_map(found) do
    {from, to, key} = {EventPayload.id(original), EventPayload.id(found), WriteQueue.key(found)}

    stack =
      UndoStack.map(socket.assigns.undo, fn
        %{id: ^from} = entry -> %{entry | id: to, key: key}
        entry -> entry
      end)

    assign(socket, :undo, stack)
  end

  defp rebase_undo(socket, _original, _found), do: socket

  defp moved_toast(socket, %{undo: true, calendar_name: name}, _original, _found, nil),
    do:
      Toast.show(
        socket,
        dgettext("dashboard_calendar_editing", "Moved back to %{calendar}", calendar: name)
      )

  defp moved_toast(socket, %{calendar_name: name}, original, %{} = found, nil)
       when is_map(original) do
    entry = %{
      kind: :transfer,
      key: WriteQueue.key(found),
      id: EventPayload.id(found),
      back_to: calendar_key(original, socket.assigns.integrations),
      title: EventPayload.title(found)
    }

    socket
    |> assign(:undo, UndoStack.push(socket.assigns.undo, entry))
    |> Toast.show(dgettext("dashboard_calendar_editing", "Moved to %{calendar}", calendar: name),
      undo: not is_nil(entry.back_to),
      key: entry.key
    )
  end

  # A move that left the original behind, or that the surface lost track of
  # (it was mounted again meanwhile), is named without Undo: moving it back
  # would leave two copies on the original calendar.
  defp moved_toast(socket, _transfer, _original, _found, source) do
    {_level, message} = CalendarEditMessages.moved_message(source)
    Toast.show(socket, message)
  end

  defp series_toast(socket, nil, _source), do: Toast.dismiss(socket)

  defp series_toast(socket, calendar, source) do
    {_level, message} = CalendarEditMessages.series_moved_message(source, calendar)

    Toast.show(
      socket,
      message <>
        " " <> dgettext("dashboard_calendar_editing", "Moving a series can't be undone here.")
    )
  end

  defp still_saving_message,
    do:
      dgettext(
        "dashboard_calendar_editing",
        "A change to this event is still saving. Please choose the calendar once it has saved."
      )

  defp refuse(socket, message), do: socket |> redraw_select() |> flash({:warning, message})

  # The select shows what the organiser picked; a new id for its wrapper
  # draws it again with the event's own calendar (as the Repeat select does).
  defp redraw_select(socket) do
    PanelState.update(
      socket,
      &Map.update(&1, :calendar_version, 1, fn version -> version + 1 end)
    )
  end

  # The event as the surface holds it: a visible one first, then the panel's
  # own (`PanelState.fetch_event/2`), then one loaded but filtered out (a move
  # to a hidden calendar lands there).
  defp lookup(socket, id) do
    case PanelState.fetch_event(socket.assigns, id) do
      {:ok, _event} = found ->
        found

      :error ->
        case Enum.find(socket.assigns.window_events, &(EventPayload.id(&1) == id)) do
          nil -> :error
          event -> {:ok, event}
        end
    end
  end

  defp flash(socket, flash) do
    send(self(), {:flash, flash})
    socket
  end
end
