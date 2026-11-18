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
  change. A surface that loads while one is waiting takes it up again
  (`resume/1`), and once its hook names the browser tab it runs in, offers
  Undo for the newest that tab scheduled (`adopt_tab/2`), so a reload keeps
  the deleting tab's Undo and another tab never gets it. Each delete's
  outcome arrives from its job (`settled/3`), which turns the delete's Undo
  into a marker that Ctrl Z answers with "too late" (`too_late/2`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.Clock
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PendingDeletes
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Toast
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.UndoStack
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  # A tab id is a UUID; anything longer is not one of ours.
  @max_tab_id_bytes 64

  @doc "A delete asked for from the preview or the Delete key."
  @spec request(socket(), String.t()) :: socket()
  def request(socket, id) when is_binary(id) do
    case PanelState.fetch_event(socket.assigns, id) do
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

  @doc """
  The organiser confirmed a delete that tells someone. `notify` is `"true"`
  or `"false"` (`"false"` keeps an event's guests out of it and leaves Undo);
  anything else is ignored and the question stays open.
  """
  @spec confirm(socket(), String.t()) :: socket()
  def confirm(%{assigns: %{delete_prompt: %{notice: notice} = prompt}} = socket, notify)
      when notify in ["true", "false"] do
    socket = assign(socket, :delete_prompt, nil)

    case {notice, notify} do
      {{:attendees, _count}, "false"} ->
        delete_with_undo(socket, prompt.event, prompt.scope)

      {{:attendees, _count}, "true"} ->
        delete_now(socket, prompt.event, prompt.scope, true)

      {:booking, _notify} ->
        delete_now(socket, prompt.event, prompt.scope, false)
    end
  end

  def confirm(socket, _notify), do: socket

  @doc "Closes the confirmation; nothing is deleted."
  @spec cancel(socket()) :: socket()
  def cancel(socket), do: assign(socket, :delete_prompt, nil)

  @doc """
  Takes back an event the organiser has just created (`Creation.undo/2`):
  it goes at once and nobody is told, since nobody was. It runs through a
  delete with no undo window, so the event is hidden at once and a refusal
  from the calendar brings it back with the usual flash. The toast that says
  so stays when the delete lands (`origin: :undo`).
  """
  @spec remove_created(socket(), map()) :: socket()
  def remove_created(socket, event) do
    case Changes.schedule_delete(socket.assigns.current_user.id, event, :occurrence, delay: 0) do
      {:ok, token} ->
        pending = event |> PendingDeletes.entry(:occurrence, true) |> Map.put(:origin, :undo)

        socket
        |> assign(:pending_deletes, Map.put(socket.assigns.pending_deletes, token, pending))
        |> PanelState.close_on(EventPayload.id(event))
        |> SurfaceData.refilter()
        |> SurfaceData.push_events(false)
        |> Toast.show(
          dgettext("dashboard_calendar", "Removed “%{title}”", title: EventPayload.title(event)),
          key: {:delete, token}
        )

      {:error, _reason} ->
        not_scheduled(socket)
    end
  end

  @doc "Undoes a delete still inside its undo window."
  @spec undo(socket(), map()) :: socket()
  def undo(socket, %{kind: :delete, token: token, title: title}) do
    case Changes.cancel_scheduled_delete(socket.assigns.current_user.id, token) do
      :ok ->
        socket
        |> assign(:pending_deletes, Map.delete(socket.assigns.pending_deletes, token))
        |> SurfaceData.refilter()
        |> SurfaceData.push_events(false)
        |> Toast.show(dgettext("dashboard_calendar", "“%{title}” is back", title: title))

      {:error, :cancelled} ->
        cancelled(socket, token)

      {:error, :too_late} ->
        Toast.show(
          socket,
          dgettext("dashboard_calendar", "“%{title}” is already being deleted.", title: title),
          key: {:delete, token}
        )
    end
  end

  @doc """
  Another tab scheduled a delete: its event is hidden here too. Undo is not
  offered, since the toast that carries it belongs to the tab that deleted.
  """
  @spec scheduled_elsewhere(socket(), pos_integer(), map(), :occurrence | :series) :: socket()
  def scheduled_elsewhere(socket, token, address, scope) when is_map(address) do
    if Map.has_key?(socket.assigns.pending_deletes, token) do
      socket
    else
      pending =
        Map.put(socket.assigns.pending_deletes, token, PendingDeletes.foreign(address, scope))

      socket
      |> assign(:pending_deletes, pending)
      |> SurfaceData.refilter()
      |> SurfaceData.push_events(false)
    end
  end

  @doc """
  A scheduled delete was undone, here or in another tab: the event is back,
  and so is nothing to undo. Quiet when this surface knew nothing of it.
  """
  @spec cancelled(socket(), pos_integer()) :: socket()
  def cancelled(socket, token) do
    if Map.has_key?(socket.assigns.pending_deletes, token) do
      socket
      |> assign(:pending_deletes, Map.delete(socket.assigns.pending_deletes, token))
      |> assign(:undo, UndoStack.drop(socket.assigns.undo, &(Map.get(&1, :token) == token)))
      |> Toast.dismiss({:delete, token})
      |> SurfaceData.refilter()
      |> SurfaceData.push_events(false)
    else
      socket
    end
  end

  @doc """
  Forgets the hidden deletes whose job is no longer waiting, so a stale entry
  (a delete that ran or was undone while a message was missed) hides its
  event only until the next reload.
  """
  @spec prune(socket()) :: socket()
  def prune(%{assigns: %{pending_deletes: pending}} = socket) when map_size(pending) == 0,
    do: socket

  def prune(socket) do
    tokens =
      socket.assigns.current_user.id
      |> Changes.pending_deletes()
      |> MapSet.new(& &1.token)

    assign(
      socket,
      :pending_deletes,
      Map.filter(socket.assigns.pending_deletes, fn {token, _entry} -> token in tokens end)
    )
  end

  @doc """
  Takes up the deletes that are waiting when the surface loads: each stays
  hidden (see `PendingDeletes`). Undo comes back later, in `adopt_tab/2`.
  """
  @spec resume(socket()) :: socket()
  def resume(socket) do
    pending =
      socket.assigns.current_user.id |> Changes.pending_deletes() |> PendingDeletes.from_jobs()

    assign(socket, :pending_deletes, Map.merge(pending, socket.assigns.pending_deletes))
  end

  @doc """
  The hook names the browser tab it runs in (an id it keeps in
  `sessionStorage`, so a reload keeps it). The first time this surface
  hears it, the newest delete that tab scheduled still inside its undo
  window gets its Undo toast back. Deletes made here from now on carry the
  id. A tab whose browser keeps no storage sends none, and is offered no
  Undo after a reload.
  """
  @spec adopt_tab(socket(), term()) :: socket()
  def adopt_tab(%{assigns: %{tab_id: nil}} = socket, tab)
      when is_binary(tab) and byte_size(tab) in 1..@max_tab_id_bytes do
    socket = assign(socket, :tab_id, tab)
    jobs = socket.assigns.current_user.id |> Changes.pending_deletes() |> open_jobs()

    case PendingDeletes.latest_undoable(socket.assigns.pending_deletes, jobs, tab) do
      {token, %{title: title}} -> offer_undo(socket, token, title)
      nil -> socket
    end
  end

  def adopt_tab(socket, _tab), do: socket

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
    |> assign(:undo, settle_undo(socket.assigns.undo, token, outcome))
    |> report(token, outcome, pending)
    |> SurfaceData.reload(:events)
  end

  # A delete that ran leaves a marker in place of its Undo, so the next Ctrl Z
  # says it is too late instead of quietly taking back an older change. One
  # that did not run has nothing to say and is dropped.
  defp settle_undo(stack, token, {:deleted, _left_behind}),
    do: settle_undo(stack, token, :deleted)

  defp settle_undo(stack, token, :deleted) do
    mine? = &(Map.get(&1, :token) == token)

    case Enum.find(stack, mine?) do
      %{title: title} ->
        UndoStack.replace(stack, mine?, %{kind: :gone, token: token, title: title})

      nil ->
        stack
    end
  end

  defp settle_undo(stack, token, _outcome),
    do: UndoStack.drop(stack, &(Map.get(&1, :token) == token))

  @doc "Ctrl Z on a delete that has already run: it cannot be taken back."
  @spec too_late(socket(), map()) :: socket()
  def too_late(socket, %{kind: :gone, title: title}) do
    Toast.show(
      socket,
      dgettext("dashboard_calendar", "Too late to undo: “%{title}” has already been deleted.",
        title: title
      )
    )
  end

  defp request_event(socket, event) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with :ok <- EditGuard.check(user.id, integrations, event),
         :ok <- not_moving(socket, event),
         false <- Writes.saving?(socket, event),
         {:ok, scopes} <- Changes.deletion_scopes(event) do
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

      {:error, :moving} ->
        flash(socket, {:warning, CalendarEditMessages.moving_message()})

      {:error, :recurring_event} ->
        flash(socket, {:error, CalendarEditMessages.recurring_delete_refused_message()})

      refusal ->
        flash(socket, CalendarEditMessages.refusal(refusal))
    end
  end

  defp not_moving(socket, event),
    do: if(Transfer.moving?(socket, EventPayload.id(event)), do: {:error, :moving}, else: :ok)

  defp ask_or_delete(socket, event, scope) do
    case Changes.delete_notice(socket.assigns.current_user.id, event) do
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

    opts = [tab: socket.assigns.tab_id]

    case Changes.schedule_delete(socket.assigns.current_user.id, event, scope, opts) do
      {:ok, token} ->
        socket
        |> hide(token, PendingDeletes.entry(event, scope, false))
        |> offer_undo(token, title)

      {:error, _reason} ->
        not_scheduled(socket)
    end
  end

  defp delete_now(socket, event, scope, notify?) do
    opts = [delay: 0, notify_attendees: notify?]

    case Changes.schedule_delete(socket.assigns.current_user.id, event, scope, opts) do
      {:ok, token} ->
        socket
        |> hide(token, PendingDeletes.entry(event, scope, true, notify?))
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

  defp hide(socket, token, pending) do
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
  # Another tab's delete is announced there; a removed create already said
  # "Removed" here.
  defp report(socket, _token, :deleted, %{origin: origin}) when origin in [:elsewhere, :undo],
    do: socket

  defp report(socket, token, :deleted, %{confirmed: true, title: title}),
    do:
      Toast.show(socket, dgettext("dashboard_calendar", "Deleted “%{title}”", title: title),
        key: {:delete, token}
      )

  defp report(socket, token, :deleted, _pending), do: Toast.dismiss(socket, {:delete, token})

  # Gone, but someone it should have reached was not: the plain "Deleted" the
  # toast said is not the whole story. The tab that deleted says so; another
  # tab only drops its toast, as it says nothing of a plain delete either.
  defp report(socket, token, {:deleted, :cancel_failed}, %{origin: :elsewhere}),
    do: Toast.dismiss(socket, {:delete, token})

  defp report(socket, token, {:deleted, :cancel_failed}, _pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash({:error, CalendarEditMessages.deleted_but_meeting_not_cancelled_message()})

  defp report(socket, token, {:deleted, :attendees_not_notified}, %{origin: :elsewhere}),
    do: Toast.dismiss(socket, {:delete, token})

  defp report(socket, token, {:deleted, :attendees_not_notified}, _pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash({:warning, CalendarEditMessages.deleted_but_attendees_not_notified_message()})

  defp report(socket, token, {:queued, _reason}, pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash(
        {:warning,
         CalendarEditMessages.delete_failed_message(%{retry: :queued}, notify?(pending))}
      )

  defp report(socket, token, {:failed, reason}, _pending),
    do:
      socket
      |> Toast.dismiss({:delete, token})
      |> flash(
        {:error,
         CalendarEditMessages.delete_failed_message(%{reason: reason, retry: :not_queued}, false)}
      )

  defp notify?(%{notify: notify?}), do: notify?
  defp notify?(_unknown), do: false

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
