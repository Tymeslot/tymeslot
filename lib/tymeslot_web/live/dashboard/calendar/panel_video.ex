defmodule TymeslotWeb.Dashboard.Calendar.PanelVideo do
  @moduledoc """
  Adding and removing the video call of the event the side panel shows.

  Choosing a provider creates a room on someone else's server and puts its
  link on the event; removing takes the link off. Both are written through
  the write queue's video path (`Writes.change_video/4`), after the event's
  earlier writes, behind the gates every edit passes plus two of its own:
  the video integration must be one of the organiser's active ones, and the
  event must not be the calendar copy of a booking, whose room belongs to
  the meeting. No undo entry: a link put back would be a new room.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Tymeslot.CalendarGrid.Changes
  alias Tymeslot.CalendarGrid.EditGuard
  alias Tymeslot.CalendarGrid.EventPayload
  alias Tymeslot.CalendarGrid.WriteQueue
  alias TymeslotWeb.Dashboard.Calendar.Manipulation
  alias TymeslotWeb.Dashboard.Calendar.PanelEdits
  alias TymeslotWeb.Dashboard.Calendar.PanelState
  alias TymeslotWeb.Dashboard.Calendar.PanelStatus
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Dashboard.Calendar.Transfer
  alias TymeslotWeb.Dashboard.Calendar.Writes
  alias TymeslotWeb.Dashboard.CalendarEditMessages

  @type socket :: Phoenix.LiveView.Socket.t()

  @doc """
  The organiser chose `raw` (an integration id, or `""` to remove the call)
  for the event the panel shows.
  """
  @spec change(socket(), String.t()) :: socket()
  def change(socket, raw) when is_binary(raw) do
    %{current_user: user, integrations: integrations} = socket.assigns

    with %{mode: :edit, event_id: id} <- socket.assigns.panel,
         {:ok, event} <- Map.fetch(socket.assigns.events_by_id, id),
         {:ok, video_id} <- parse(raw),
         false <- already_chosen?(event, video_id),
         :ok <- idle(socket, event),
         :ok <- owned(socket.assigns.video_integrations, video_id),
         :ok <- EditGuard.check(user.id, integrations, event),
         :ok <- Changes.ensure_video_changeable(event) do
      socket
      |> Writes.change_video(event, optimistic(event, video_id), video_id)
      |> PanelEdits.put_status(:saving)
    else
      refusal -> refused(socket, refusal)
    end
  end

  def change(socket, _raw), do: socket

  @doc """
  A write to the event `key` was put back (`:revert_event`). The queue's
  video path answers with no reference the panel could track, so a panel
  on that event still saying "Saving…" with none of its own writes running
  was waiting for this video change: its header says it was put back.
  """
  @spec reverted(socket(), WriteQueue.key()) :: socket()
  def reverted(socket, key) do
    if waiting_on?(socket, key),
      do:
        PanelEdits.put_status(
          socket,
          {:failed, dgettext("dashboard_calendar_editing", "The change was put back.")}
        ),
      else: socket
  end

  @doc """
  The video change `ref` answered `:unchanged` (a sync already set the link,
  or a series' room was kept): nothing was written, so the optimistic event
  is replaced by the one the surface's cache holds, and a panel waiting on
  that change says it is saved.
  """
  @spec unchanged(socket(), WriteQueue.ref()) :: socket()
  def unchanged(socket, {key, _seq}) do
    if waiting_on?(socket, key),
      do: socket |> SurfaceData.reload(:events) |> PanelEdits.put_status(:saved),
      else: socket
  end

  @doc """
  The video change `ref` has landed with `updated`, the event as the change
  wrote it: the queue settles and, for a panel open on that event with no
  writes of its own running, the header says it is saved.
  """
  @spec settled(socket(), WriteQueue.ref(), map()) :: socket()
  def settled(socket, {key, _seq} = ref, updated) do
    socket =
      socket
      |> Writes.settle(ref, {:ok, updated})
      |> show_result(updated)
      |> Manipulation.settled(ref)

    if waiting_on?(socket, key) and not Writes.saving?(socket, updated),
      do: PanelEdits.put_status(socket, :saved),
      else: socket
  end

  # A panel open on the event `key` that says "Saving…" with none of its own
  # writes running is waiting for a video change.
  defp waiting_on?(%{assigns: %{panel: %{status: :saving, writes: []}}} = socket, key) do
    case PanelState.current_event(socket.assigns) do
      %{} = event -> WriteQueue.key(event) == key
      nil -> false
    end
  end

  defp waiting_on?(_socket, _key), do: false

  # The event as the change wrote it replaces the optimistic one, unless a
  # later write to it is still pending, whose own version is the newer.
  defp show_result(socket, updated) do
    if Writes.saving?(socket, updated),
      do: socket,
      else: socket |> SurfaceData.show_event(updated) |> SurfaceData.push_events(false)
  end

  # "Remove" arrives as an empty value; anything else must be an
  # integration id, so a malformed one is ignored rather than read as a removal.
  defp parse(""), do: {:ok, nil}

  defp parse(raw) do
    case Integer.parse(raw) do
      {id, ""} -> {:ok, id}
      _malformed -> :error
    end
  end

  # Clicking what the event already has is not an edit. An event whose
  # integration is set but whose link is missing is not settled: choosing
  # it again is how a room that failed to be created is repaired.
  defp already_chosen?(%{video_integration_id: nil, video_link: nil}, nil), do: true

  defp already_chosen?(%{video_integration_id: id, video_link: link}, id)
       when is_integer(id) and is_binary(link),
       do: true

  defp already_chosen?(_event, _video_id), do: false

  # The panel only offers the organiser's own active integrations, so
  # anything else is forged.
  defp owned(_integrations, nil), do: :ok

  defp owned(integrations, id),
    do: if(Enum.any?(integrations, &(&1.id == id)), do: :ok, else: :forged)

  defp optimistic(event, nil), do: %{event | video_integration_id: nil, video_link: nil}
  defp optimistic(event, id), do: %{event | video_integration_id: id}

  defp refused(socket, {:error, :moving}),
    do: refuse(socket, CalendarEditMessages.moving_message())

  defp refused(socket, {:error, :linked_to_booking}),
    do: refuse_flash(socket, {:error, CalendarEditMessages.booking_video_refused_message()})

  defp refused(socket, {:error, _reason} = refusal),
    do: refuse_flash(socket, CalendarEditMessages.refusal(refusal))

  defp refused(socket, {:error, :rate_limited, _message} = refusal),
    do: refuse_flash(socket, CalendarEditMessages.refusal(refusal))

  # Nothing the panel offered: a malformed or forged choice.
  defp refused(socket, bad) when bad in [:forged, :error], do: redraw_select(socket)

  # No panel, an event no longer loaded, or a choice that changes nothing.
  defp refused(socket, _ignored), do: socket

  # The panel's own event is not the one moving.
  defp idle(socket, event),
    do: if(Transfer.moving?(socket, EventPayload.id(event)), do: {:error, :moving}, else: :ok)

  # The select shows what the client chose; a new id for its wrapper draws it
  # again with the server's value (as the Calendar and Repeat selects do).
  defp redraw_select(socket) do
    PanelState.update(
      socket,
      &Map.update(&1, :video_version, 1, fn version -> version + 1 end)
    )
  end

  defp refuse(socket, message),
    do: socket |> redraw_select() |> PanelState.update(&PanelStatus.refused(&1, message))

  defp refuse_flash(socket, flash) do
    send(self(), {:flash, flash})
    redraw_select(socket)
  end
end
