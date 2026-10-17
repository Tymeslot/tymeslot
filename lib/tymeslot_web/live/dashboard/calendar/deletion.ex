defmodule TymeslotWeb.Dashboard.Calendar.Deletion do
  @moduledoc """
  Deleting from the calendar surface.

  A delete nobody is told about goes at once, without a confirmation: it is
  scheduled behind its undo window (`Tymeslot.CalendarGrid.ScheduledDelete`),
  the event leaves the grid, and the toast offers Undo, which cancels the
  delete before anything reaches the calendar. A delete that tells someone
  (the calendar copy of a booking, whose meeting it cancels, or an event
  whose guests the organiser invited) asks first, and once confirmed runs at
  once and cannot be undone, since the email cannot be taken back; "Delete
  without telling them" is an ordinary delete with Undo. A member of a
  repeating series first asks for this event or all of them.

  `pending_deletes` (see `PendingDeletes`) holds the deletes whose events
  stay hidden until they have run, across a reload, a remount and a week
  change. A surface that loads while one is waiting takes it up again and
  offers Undo for the newest (`resume/1`). Each delete's outcome arrives from
  its job (`settled/3`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Clock
  alias TymeslotWeb.Dashboard.Calendar.PendingDeletes
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc "A delete asked for from the preview or the Delete key."
  @spec request(socket(), String.t()) :: socket()
  def request(socket, id) when is_binary(id) do
    case Map.fetch(socket.assigns.events_by_id, id) do
      {:ok, event} -> socket |> assign(:preview, nil) |> request_event(event)
      :error -> socket
    end
  end

  def request(socket, _id), do: socket

  @doc "The organiser chose this event or all events of a series."
  @spec choose_scope(socket(), String.t()) :: socket()
  def choose_scope(%{assigns: %{series_prompt: %{kind: :delete, event: event}}} = socket, scope) do
    socket = assign(socket, :series_prompt, nil)

    case scope do
      "occurrence" -> ask_or_delete(socket, event, :occurrence)
      "series" -> ask_or_delete(socket, event, :series)
      _unknown -> socket
    end
  end

  def choose_scope(socket, _scope), do: socket

  @doc "The organiser confirmed a delete that tells someone; `\"false\"` keeps the guests out of it."
  @spec confirm(socket(), String.t()) :: socket()
  def confirm(%{assigns: %{delete_prompt: %{} = prompt}} = socket, notify) do
    socket = assign(socket, :delete_prompt, nil)

    case {prompt.notice, notify} do
      {{:attendees, _count}, "false"} ->
        delete_with_undo(socket, prompt.event, prompt.scope)

      {notice, _notify} ->
        delete_now(socket, prompt.event, prompt.scope, match?({:attendees, _count}, notice))
    end
  end

  def confirm(socket, _notify), do: socket

  @doc "Closes the confirmation; nothing is deleted."
  @spec cancel(socket()) :: socket()
  def cancel(socket), do: assign(socket, :delete_prompt, nil)

  @doc "Undoes a delete still inside its undo window."
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :delete, token: token, title: title}) do
    case CalendarGrid.cancel_scheduled_delete(socket.assigns.current_user.id, token) do
      :ok ->
        socket
        |> assign(:pending_deletes, Map.delete(socket.assigns.pending_deletes, token))
        |> SurfaceData.refilter()
        |> SurfaceData.push_events(false)
        |> Toast.show(dgettext("dashboard_calendar", "“%{title}” is back", title: title))

      {:error, :too_late} ->
        Toast.show(
          socket,
          dgettext(
            "dashboard_calendar",
            "Too late to undo: “%{title}” has already been deleted.",
            title: title
          )
        )
    end
  end

  @doc """
  Takes up the deletes that are waiting when the surface loads: each stays
  hidden (see `PendingDeletes`), and the newest one still inside its undo
  window gets its Undo toast back.
  """
  @spec resume(socket()) :: socket()
  def resume(socket) do
    jobs = CalendarGrid.pending_deletes(socket.assigns.current_user.id)
    pending = PendingDeletes.from_jobs(jobs)
    socket = assign(socket, :pending_deletes, Map.merge(pending, socket.assigns.pending_deletes))

    case PendingDeletes.latest_undoable(pending, open_jobs(jobs)) do
      {token, %{title: title}} -> offer_undo(socket, token, title)
      nil -> socket
    end
  end

  # Jobs whose undo window has not closed yet.
  defp open_jobs(jobs) do
    now = Clock.utc_now()
    Enum.filter(jobs, &(DateTime.compare(&1.scheduled_at, now) == :gt))
  end

  @doc "A scheduled delete ran: the grid follows what the calendar now holds."
  @spec settled(socket(), pos_integer(), term()) :: socket()
  def settled(socket, token, outcome) do
    {pending, rest} = Map.pop(socket.assigns.pending_deletes, token)

    socket
    |> assign(:pending_deletes, rest)
    |> assign(:undo, UndoStack.drop(socket.assigns.undo, &(Map.get(&1, :token) == token)))
    |> report(token, outcome, pending)
    |> SurfaceData.reload(:events)
  end

  defp request_event(socket, event) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with :ok <- EditGuard.check(user.id, integrations, event),
         false <- Writes.saving?(socket, event),
         {:ok, scopes} <- CalendarGrid.deletion_scopes(event) do
      case scopes do
        :series ->
          assign(socket, :series_prompt, %{
            kind: :delete,
            event: event,
            title: EventPayload.title(event)
          })

        :single ->
          ask_or_delete(socket, event, :occurrence)
      end
    else
      true ->
        flash(
          socket,
          {:warning,
           dgettext(
             "dashboard_calendar",
             "This event is still saving. Delete it once it has saved."
           )}
        )

      {:error, :recurring_event} ->
        flash(socket, {:error, CalendarEditMessages.recurring_delete_refused_message()})

      refusal ->
        flash(socket, CalendarEditMessages.refusal(refusal))
    end
  end

  defp ask_or_delete(socket, event, scope) do
    case CalendarGrid.delete_notice(socket.assigns.current_user.id, event) do
      :silent ->
        delete_with_undo(socket, event, scope)

      {:notifies, notice} ->
        assign(socket, :delete_prompt, %{
          event: event,
          scope: scope,
          notice: notice,
          title: EventPayload.title(event)
        })
    end
  end

  defp delete_with_undo(socket, event, scope) do
    title = EventPayload.title(event)

    case CalendarGrid.schedule_delete(socket.assigns.current_user.id, event, scope, []) do
      {:ok, token} ->
        socket
        |> hide(token, event, scope, false)
        |> offer_undo(token, title)

      {:error, _reason} ->
        not_scheduled(socket)
    end
  end

  defp delete_now(socket, event, scope, notify?) do
    opts = [delay: 0, notify_attendees: notify?]

    case CalendarGrid.schedule_delete(socket.assigns.current_user.id, event, scope, opts) do
      {:ok, token} ->
        socket
        |> hide(token, event, scope, true)
        |> Toast.show(
          dgettext("dashboard_calendar", "Deleting “%{title}”…",
            title: EventPayload.title(event)
          ),
          key: {:delete, token}
        )

      {:error, _reason} ->
        not_scheduled(socket)
    end
  end

  defp hide(socket, token, event, scope, confirmed?) do
    pending = PendingDeletes.entry(event, scope, confirmed?)

    socket
    |> assign(:pending_deletes, Map.put(socket.assigns.pending_deletes, token, pending))
    |> SurfaceData.refilter()
    |> SurfaceData.push_events(false)
  end

  defp offer_undo(socket, token, title) do
    socket
    |> assign(
      :undo,
      UndoStack.push(socket.assigns.undo, %{kind: :delete, token: token, title: title})
    )
    |> Toast.show(dgettext("dashboard_calendar", "Deleted “%{title}”", title: title),
      undo: true,
      key: {:delete, token}
    )
  end

  # A delete with Undo already said "Deleted"; its Undo has run out now. A
  # confirmed one said "Deleting…" and now names the result.
  defp report(socket, token, :deleted, %{confirmed: true, title: title}),
    do:
      Toast.show(socket, dgettext("dashboard_calendar", "Deleted “%{title}”", title: title),
        key: {:delete, token}
      )

  defp report(socket, token, :deleted, _pending), do: Toast.dismiss(socket, {:delete, token})

  defp report(socket, token, {:queued, _reason}, _pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash({:warning, CalendarEditMessages.delete_failed_message(%{retry: :queued}, false)})

  defp report(socket, token, {:failed, reason}, _pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash(
        {:error,
         CalendarEditMessages.delete_failed_message(%{reason: reason, retry: :not_queued}, false)}
      )

  defp not_scheduled(socket),
    do:
      flash(
        socket,
        {:error, dgettext("dashboard_calendar", "Couldn't delete the event. Please try again.")}
      )

  defp flash(socket, message) do
    send(self(), {:flash, message})
    socket
  end
end
