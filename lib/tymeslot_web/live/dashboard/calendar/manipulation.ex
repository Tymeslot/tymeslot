defmodule TymeslotWeb.Dashboard.Calendar.Manipulation do
  @moduledoc """
  Moving and resizing events on the calendar surface, the "this / following
  / all" choice for a member of a repeating series, and undo.

  The hook sends the wall-clock start and end it drew (`calendar:move`).
  The domain's timing rules turn them into instants (`Changes.resolve_timing/4`,
  see `Tymeslot.CalendarGrid.Moves`), and the change is checked
  (`EditGuard.check_timing/3`), shown at once and written
  through `Writes`; the hook is sent the window again whatever happens, so a
  refused move snaps back to what the server holds. A change the organiser
  can take back goes on the undo stack and the toast names the result.
  Undo writes the previous timing the same way, and is not itself undoable;
  an undo whose write fails puts its change back on the stack.

  A move never tells the event's guests; the toast says so when it has any.
  The event as it was before its first untold move is remembered
  (`untold_moves`, by event id), so the side panel opened on it later still
  offers to tell them (`PanelState`). A move of several events of a series
  is not remembered: the panel tells one event's guests.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.RecurrenceScope
  alias Tymeslot.CalendarGrid.WriteQueue
  alias Tymeslot.Utils.DateTimeUtils.TimeFormat
  alias TymeslotWeb.Dashboard.Calendar.BlockTime
  alias TymeslotWeb.Dashboard.Calendar.Creation
  alias TymeslotWeb.Dashboard.Calendar.Deletion
  alias TymeslotWeb.Dashboard.Calendar.OpenBooking
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages
  alias TymeslotWeb.Helpers.LocaleFormat

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "Applies a move or resize the hook drew, or snaps the grid back."
  @spec move(socket(), map()) :: socket()
  def move(socket, %{"id" => id, "start" => start, "end" => finish}) when is_binary(id) do
    socket = drop_open_choice(socket)

    case validate(socket, id, start, finish) do
      {:ok, event, changes} ->
        apply_timing(socket, event, changes)

      :ignore ->
        SurfaceData.push_events(socket, false)

      refusal ->
        socket |> refuse(refusal) |> SurfaceData.push_events(false)
    end
  end

  def move(socket, _params), do: SurfaceData.push_events(socket, false)

  # A series choice still open when another change arrives is given up: the
  # event it was for goes back to what the server holds.
  defp drop_open_choice(%{assigns: %{series_prompt: %{kind: :timing}}} = socket),
    do: cancel_scope(socket)

  defp drop_open_choice(socket), do: socket

  # The event and the timing it is to take, or why not: a refusal the edit
  # guard made, or `:ignore` for a change that is invalid or no change.
  defp validate(socket, id, start, finish) do
    %{timezone: timezone, current_user: user, integrations: integrations} = socket.assigns

    with {:ok, event} <- timed_event(socket, id),
         false <- Transfer.moving?(socket, id),
         {:ok, changes} <- Changes.resolve_timing(event, start, finish, timezone),
         true <- changed?(event, changes.start_at, changes.end_at),
         :ok <- EditGuard.check_timing(user.id, integrations, event) do
      {:ok, event, changes}
    else
      true -> {:error, :moving}
      {:error, reason} when reason in [:invalid_time, :out_of_range] -> :ignore
      refusal when is_tuple(refusal) and elem(refusal, 0) == :error -> refusal
      _unchanged_or_invalid -> :ignore
    end
  end

  @doc "Writes the change waiting on the series choice in the scope chosen."
  @spec choose_scope(socket(), String.t()) :: socket()
  def choose_scope(%{assigns: %{series_prompt: %{kind: :timing} = prompt}} = socket, scope) do
    case RecurrenceScope.parse(scope) do
      {:ok, scope} when scope in [:following, :all] ->
        if Writes.series_busy?(socket, prompt.event) do
          send(self(), {:flash, {:warning, CalendarEditMessages.series_saving_message()}})
          cancel_scope(socket)
        else
          socket
          |> assign(:series_prompt, nil)
          |> write_timing(prompt.event, prompt.changes, scope)
        end

      {:ok, :this_only} ->
        socket
        |> assign(:series_prompt, nil)
        |> write_timing(prompt.event, prompt.changes, :this_only)

      :error ->
        cancel_scope(socket)
    end
  end

  def choose_scope(socket, _scope), do: socket

  @doc "Closes the series choice; a change waiting on it goes back off the grid."
  @spec cancel_scope(socket()) :: socket()
  def cancel_scope(%{assigns: %{series_prompt: %{kind: :timing, event: event}}} = socket) do
    socket
    |> assign(:series_prompt, nil)
    |> SurfaceData.show_event(event)
    |> SurfaceData.push_events(false)
  end

  def cancel_scope(socket), do: assign(socket, :series_prompt, nil)

  @doc "Undoes the newest change on the stack."
  @spec undo(socket()) :: socket()
  def undo(socket) do
    case UndoStack.pop(socket.assigns.undo) do
      {nil, _stack} -> Toast.show(socket, dgettext("dashboard_calendar", "Nothing to undo."))
      {entry, stack} -> socket |> assign(:undo, stack) |> undo_unless_moving(entry)
    end
  end

  # An event moving to another calendar takes no change until it has moved,
  # undos included: the change stays on the stack for once it has. A move's
  # own undo has its own check (`Transfer.undo/2`).
  defp undo_unless_moving(socket, %{kind: kind, id: id} = entry)
       when kind in [:timing, :edit, :create] do
    if Transfer.moving?(socket, id),
      do: socket |> remember(true, entry) |> refuse({:error, :moving}),
      else: undo_entry(socket, entry)
  end

  defp undo_unless_moving(socket, entry), do: undo_entry(socket, entry)

  @doc """
  After the write `ref` failed: forgets the change it made, which was never
  written, and nothing else (a write with no entry of its own, such as one to
  a whole series, forgets nothing). When the write was an undo, the change it
  was taking back goes on the stack again, since the event still has it. The
  restored entry goes on top, whatever was pushed since, so it is the next
  undo. An undo whose write the queue dropped (`{:dropped, ...}` after a
  series change) is not restored: the event it described no longer holds
  that change.
  """
  @spec forget(socket(), WriteQueue.ref()) :: socket()
  def forget(socket, ref) do
    {undone, undoing} = Map.pop(socket.assigns.undoing, ref)
    stack = UndoStack.drop(socket.assigns.undo, &(Map.get(&1, :ref) == ref))

    assign(socket,
      undo: if(undone, do: UndoStack.push(stack, undone), else: stack),
      undoing: undoing
    )
  end

  @doc "After the write `ref` answered other than by failing: an undo it made is done."
  @spec settled(socket(), WriteQueue.ref()) :: socket()
  def settled(socket, ref),
    do: assign(socket, :undoing, Map.delete(socket.assigns.undoing, ref))

  # Undoing writes the timing the change replaced, so it only runs while the
  # event still has the timing the change gave it; an event moved or synced
  # since would be put back over a newer version.
  defp undo_entry(socket, %{kind: :delete} = entry), do: Deletion.undo(socket, entry)
  defp undo_entry(socket, %{kind: :gone} = entry), do: Deletion.too_late(socket, entry)
  defp undo_entry(socket, %{kind: :edit} = entry), do: PanelEdits.undo(socket, entry)
  defp undo_entry(socket, %{kind: :create} = entry), do: Creation.undo(socket, entry)
  defp undo_entry(socket, %{kind: :transfer} = entry), do: Transfer.undo(socket, entry)

  # A block from the bookable layer names no event, so the moving check
  # above does not apply (see `BlockTime`).
  defp undo_entry(socket, %{kind: :block} = entry), do: BlockTime.undo(socket, entry)

  # An opening names no event either (see `OpenBooking`).
  defp undo_entry(socket, %{kind: :opening} = entry), do: OpenBooking.undo(socket, entry)

  defp undo_entry(socket, %{kind: :timing} = entry) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with {:ok, event} <- Map.fetch(socket.assigns.events_by_id, entry.id),
         true <- unchanged_since?(event, entry),
         :ok <- EditGuard.check(user.id, integrations, event) do
      {socket, ref} =
        Writes.update(
          socket,
          event,
          Map.merge(event, entry.before),
          entry.before,
          scope_opts(entry.scope)
        )

      socket
      |> assign(:undoing, Map.put(socket.assigns.undoing, ref, entry))
      |> Toast.show(change_text(socket, event, entry.before, :moved_back), key: entry.key)
    else
      {:error, :rate_limited, _message} = refusal ->
        socket |> assign(:undo, UndoStack.push(socket.assigns.undo, entry)) |> refuse(refusal)

      {:error, _reason} = refusal ->
        refuse(socket, refusal)

      _gone_or_changed ->
        Toast.show(
          socket,
          dgettext("dashboard_calendar", "That change can't be undone any more.")
        )
    end
  end

  defp unchanged_since?(event, %{after: %{start_at: start_at, end_at: end_at}}),
    do: same?(event.start_at, start_at) and same?(event.end_at, end_at)

  defp apply_timing(socket, event, changes) do
    case Changes.edit_scopes(event) do
      {:ok, :series} ->
        socket
        |> SurfaceData.show_event(Map.merge(event, changes))
        |> assign(:series_prompt, %{
          kind: :timing,
          event: event,
          changes: changes,
          title: EventPayload.title(event)
        })
        |> SurfaceData.push_events(false)

      {:ok, _single_or_this_only} ->
        write_timing(socket, event, changes, nil)
    end
  end

  # A change to one event (on its own, or one occurrence of a series) can be
  # undone; a change to several events of a series cannot, as the series'
  # cached rows are dropped until the next sync.
  defp write_timing(socket, event, changes, scope) do
    undoable? = scope in [nil, :this_only]

    {socket, ref} =
      Writes.update(socket, event, Map.merge(event, changes), changes, scope_opts(scope))

    # `ref` names the write, so a failure of it forgets this entry alone.
    entry = %{
      kind: :timing,
      key: WriteQueue.key(event),
      ref: ref,
      id: EventPayload.id(event),
      before: Map.take(event, [:start_at, :end_at]),
      after: Map.take(changes, [:start_at, :end_at]),
      scope: scope
    }

    socket
    |> remember(undoable?, entry)
    |> remember_untold(undoable?, event)
    |> Toast.show(timing_message(socket, event, changes, scope),
      undo: undoable?,
      key: entry.key
    )
  end

  defp remember(socket, false, _entry), do: socket

  defp remember(socket, true, entry),
    do: assign(socket, :undo, UndoStack.push(socket.assigns.undo, entry))

  # The first untold move is the starting point: a later one keeps it.
  defp remember_untold(socket, true = _one_event?, event) do
    if guests?(event),
      do:
        assign(
          socket,
          :untold_moves,
          Map.put_new(socket.assigns.untold_moves, EventPayload.id(event), event)
        ),
      else: socket
  end

  defp remember_untold(socket, false, _event), do: socket

  defp guests?(event), do: event |> Map.get(:attendees) |> List.wrap() |> Enum.any?()

  defp scope_opts(nil), do: []
  defp scope_opts(scope), do: [recurrence_scope: scope]

  defp timing_message(socket, event, changes, scope),
    do: socket |> timing_text(event, changes, scope) |> with_guest_note(event)

  defp timing_text(_socket, _event, _changes, scope) when scope in [:following, :all],
    do:
      dgettext(
        "dashboard_calendar",
        "Series changed. Changes to several events can't be undone here."
      )

  defp timing_text(socket, event, changes, _scope),
    do: change_text(socket, event, changes, :moved)

  # Names what changed: only the end, only the start, else the whole move.
  # Forward (`:moved`) and undo (`:moved_back`) share the rule.
  defp change_text(socket, from, to, kind) do
    cond do
      same?(to.start_at, from.start_at) ->
        dgettext("dashboard_calendar", "Now ends at %{time}", time: time_text(socket, to.end_at))

      same?(to.end_at, from.end_at) ->
        dgettext("dashboard_calendar", "Now starts at %{time}",
          time: time_text(socket, to.start_at)
        )

      kind == :moved ->
        dgettext("dashboard_calendar", "Moved to %{when}", when: when_text(socket, to.start_at))

      kind == :moved_back ->
        dgettext("dashboard_calendar", "Moved back to %{when}",
          when: when_text(socket, to.start_at)
        )
    end
  end

  defp with_guest_note(text, event) do
    if guests?(event),
      do: text <> " " <> dgettext("dashboard_calendar", "Guests haven't been told."),
      else: text
  end

  @doc "An instant as the toasts name it, in the organiser's zone and clock: \"Thu 15 Oct, 13:00\"."
  @spec when_text(socket(), DateTime.t()) :: String.t()
  def when_text(socket, at) do
    local = DateTime.shift_zone!(at, socket.assigns.timezone)
    locale = Gettext.get_locale(TymeslotWeb.Gettext)
    day = LocaleFormat.format_short_weekday_date(DateTime.to_date(local), locale)

    "#{day}, #{TimeFormat.format(DateTime.to_time(local), socket.assigns.time_format)}"
  end

  defp time_text(socket, at) do
    at
    |> DateTime.shift_zone!(socket.assigns.timezone)
    |> DateTime.to_time()
    |> TimeFormat.format(socket.assigns.time_format)
  end

  defp refuse(socket, {:error, :moving}) do
    send(self(), {:flash, {:warning, CalendarEditMessages.moving_message()}})
    socket
  end

  defp refuse(socket, refusal) do
    send(self(), {:flash, CalendarEditMessages.refusal(refusal)})
    socket
  end

  defp timed_event(socket, id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, %{all_day: false, start_at: %DateTime{}, end_at: %DateTime{}} = event} -> {:ok, event}
      _other -> :error
    end
  end

  defp changed?(event, start_at, end_at),
    do: not (same?(start_at, event.start_at) and same?(end_at, event.end_at))

  defp same?(a, b), do: DateTime.compare(a, b) == :eq
end
