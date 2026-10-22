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
  is settled by `CalendarMove.settle/4`, with its messages.

  What differs is where the move runs: off the process, like the calendar's
  other writes (`Tymeslot.CalendarGrid.WriteTask`). The booking is drawn at
  its new time at once; the answer, `{:booking_move_result, meeting_id,
  result}`, reaches `DashboardLive` (`CalendarMessages`), which hands it to
  `settled/3` while the calendar is on screen and flashes it otherwise, so
  it is never lost. Every outcome reloads the events, so the grid shows what
  the server holds. While a move runs, the preview shows its button busy and
  a second one for that booking is not started.
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
  Settles the move of `meeting_id` that answered `result`. A surface mounted
  since, with no window loaded yet, only reports it.
  """
  @spec settled(socket(), Ecto.UUID.t(), {:ok, term()} | {:error, term()}) :: socket()
  def settled(%{assigns: %{ready?: true}} = socket, meeting_id, result) do
    socket
    |> assign(:moving_booking, MapSet.delete(socket.assigns.moving_booking, meeting_id))
    |> CalendarMove.settle(meeting_id, result, &SurfaceData.reload(&1, :events))
  end

  def settled(socket, meeting_id, result) do
    _outcome = CalendarMove.report(socket, meeting_id, result)
    assign(socket, :moving_booking, MapSet.delete(socket.assigns.moving_booking, meeting_id))
  end

  @doc "Whether the booking `meeting_id` is being moved."
  @spec moving?(socket(), Ecto.UUID.t()) :: boolean()
  def moving?(socket, meeting_id), do: MapSet.member?(socket.assigns.moving_booking, meeting_id)

  defp start(socket, meeting_id, offer, user_id) do
    if moving?(socket, meeting_id) do
      ModalHook.hide_modal(socket, :calendar_move)
    else
      :ok =
        WriteTask.start(
          {:booking_move_result, meeting_id},
          fn -> Meetings.move_to_calendar_time(meeting_id, user_id, offer) end,
          {:error, :failed_to_update_meeting}
        )

      socket
      |> ModalHook.hide_modal(:calendar_move)
      |> assign(:moving_booking, MapSet.put(socket.assigns.moving_booking, meeting_id))
      |> show_moved(meeting_id, offer)
      |> push_event("calendar:preview-closed", %{})
    end
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
