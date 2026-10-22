defmodule TymeslotWeb.Dashboard.Calendar.BookingMove do
  @moduledoc """
  The preview's "Move booking to …" for a booking whose event the host moved
  in their own calendar: the booking follows the event to its new time, and
  the attendee and guests are emailed it.

  The Meetings page's path throughout, so the two pages cannot differ on
  which bookings qualify or what a move does: the offer is
  `Tymeslot.Meetings.calendar_move_offers/1`'s (carried on the booking as
  `move_offer`), the dialog is opened from a fresh offer by
  `TymeslotWeb.Dashboard.BookingsManagement.CalendarMove.show/3` (scoped to
  the signed-in organiser, with its refusals and telemetry), and the outcome
  is told with that page's messages (`CalendarMove.announce/3`) and
  telemetry (`CalendarMove.emit_confirm/3`).

  What differs is where the move runs: off the process, like the calendar's
  other writes (`Tymeslot.CalendarGrid.WriteTask`). The booking is drawn at
  its new time at once; the answer, `{:booking_move_result, meeting_id,
  result}`, reaches `DashboardLive` (`CalendarMessages`), which hands it to
  `settled/3` while the calendar is on screen and flashes it on any other
  dashboard page. Once the host has left the dashboard altogether the move
  still completes and its emails still go, recorded by the telemetry the
  task emits itself, but no one is shown its outcome. Every outcome reloads
  the events, so the grid shows what the server holds. While a move runs,
  the preview shows its button busy and a second one for that booking is
  not started.

  The dialog closes when the move starts, so the answer never touches a
  dialog open by then (another booking's Move, a Cancel, a prompt). Only
  when the calendar time changed again meanwhile is the dialog reopened
  with the new time, and then only over nothing: with a dialog already
  open, the warning flash alone says so, and the booking's button offers
  the new time.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ecto.UUID
  alias Tymeslot.CalendarGrid.WriteTask
  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.BookingsManagement.CalendarMove
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  # The surface's dialogs (`SurfaceModals`), by the assign each shows while set.
  @dialogs ~w(series_prompt delete_prompt series_move_prompt remove_guest_prompt
    decline_request_modal_data cancel_meeting_modal_data
    reschedule_request_modal_data calendar_move_modal_data)a

  @doc "Opens the confirmation for the booking `id`, or says why it can no longer move."
  @spec open(socket(), String.t()) :: socket()
  def open(socket, id) do
    case UUID.cast(id) do
      {:ok, id} ->
        if moving?(socket, id),
          do: socket,
          else:
            socket
            |> assign(:preview, nil)
            |> CalendarMove.show(%{"id" => id}, &SurfaceData.reload(&1, :events))

      :error ->
        socket
    end
  end

  @doc """
  Starts moving the booking to the time the dialog showed, under the Meetings
  page's rate limit, and closes the dialog.
  """
  @spec confirm(socket()) :: socket()
  def confirm(socket) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check(:dashboard_reschedule, user_id) do
      {:error, :rate_limited, message} ->
        Flash.put_flash(socket, :error, message)

      :ok ->
        case socket.assigns.calendar_move_modal_data do
          %{meeting: meeting, offer: offer} -> start(socket, meeting.id, offer, user_id)
          nil -> socket
        end
    end
  end

  @doc """
  Settles the move of `meeting_id` that answered `result`: the flash, then
  the events reloaded. A surface mounted since, with no window loaded yet,
  only flashes it.
  """
  @spec settled(socket(), Ecto.UUID.t(), {:ok, term()} | {:error, term()}) :: socket()
  def settled(%{assigns: %{ready?: true}} = socket, meeting_id, result) do
    outcome = CalendarMove.announce(socket, meeting_id, result)

    socket
    |> done(meeting_id)
    |> SurfaceData.reload(:events)
    |> reopen_if_free(meeting_id, outcome)
  end

  def settled(socket, meeting_id, result) do
    _outcome = CalendarMove.announce(socket, meeting_id, result)
    done(socket, meeting_id)
  end

  @doc "Whether the booking `meeting_id` is being moved."
  @spec moving?(socket(), Ecto.UUID.t()) :: boolean()
  def moving?(socket, meeting_id), do: MapSet.member?(socket.assigns.moving_booking, meeting_id)

  defp done(socket, meeting_id),
    do: assign(socket, :moving_booking, MapSet.delete(socket.assigns.moving_booking, meeting_id))

  # The calendar time changed again before the move: its new time is offered
  # afresh, unless a dialog is open by now.
  defp reopen_if_free(socket, meeting_id, :offer_changed) do
    if Enum.any?(@dialogs, &socket.assigns[&1]),
      do: socket,
      else:
        socket
        |> assign(:preview, nil)
        |> CalendarMove.show(%{"id" => meeting_id}, & &1)
  end

  defp reopen_if_free(socket, _meeting_id, _outcome), do: socket

  defp start(socket, meeting_id, offer, user_id) do
    if moving?(socket, meeting_id) do
      ModalHook.hide_modal(socket, :calendar_move)
    else
      :ok =
        WriteTask.start(
          {:booking_move_result, meeting_id},
          fn -> move(meeting_id, user_id, offer) end,
          {:error, :failed_to_update_meeting}
        )

      socket
      |> ModalHook.hide_modal(:calendar_move)
      |> assign(:moving_booking, MapSet.put(socket.assigns.moving_booking, meeting_id))
      |> show_moved(meeting_id, offer)
      |> push_event("calendar:preview-closed", %{})
    end
  end

  # Runs off the LiveView's process. The telemetry is emitted here, so a
  # move whose LiveView is gone by the time it answers is still recorded.
  defp move(meeting_id, user_id, offer) do
    result = Meetings.move_to_calendar_time(meeting_id, user_id, offer)
    :ok = CalendarMove.emit_confirm(user_id, meeting_id, result)
    result
  end

  # The booking at its new time until the answer reloads the window.
  defp show_moved(socket, meeting_id, offer) do
    case Map.fetch(socket.assigns.events_by_id, "booking-" <> meeting_id) do
      {:ok, event} ->
        socket
        |> SurfaceData.show_event(%{
          event
          | start_at: offer.start_time,
            end_at: offer.end_time,
            move_offer: nil
        })
        |> SurfaceData.push_events(false)

      :error ->
        socket
    end
  end
end
