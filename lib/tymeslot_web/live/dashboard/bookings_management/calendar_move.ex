defmodule TymeslotWeb.Dashboard.BookingsManagement.CalendarMove do
  @moduledoc """
  Moving a booking to the time its calendar event now has, from the bookings
  dashboard.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit. Whether a move is allowed is `Tymeslot.Meetings`' decision; this
  module opens the confirmation from a fresh offer, so the host agrees to the
  time the calendar has now rather than the one the list was drawn with,
  moves the booking only to the time the dialog showed, and turns the outcome
  into a flash. The reload is passed in because the list belongs to the
  component.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Ecto.UUID
  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @event [:tymeslot, :dashboard, :meetings, :calendar_move]

  @doc """
  Opens the confirmation for the signed-in host's meeting, or says why not.
  The lookup is scoped to the host, so another organiser's id is not found.
  A refusal also refreshes the list, since it means the card the host clicked
  is out of date and its Move button should go.
  """
  @spec show(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                    Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def show(socket, params, reload) when is_function(reload, 1) do
    user_id = socket.assigns.current_user.id

    case cast_id(params) do
      {:ok, id} ->
        case open(socket, id, user_id) do
          {:ok, socket} -> socket
          {:error, socket} -> reload.(socket)
        end

      {:error, reason} ->
        emit(user_id, requested_id(params), :open, reason)
        Flash.error(refusal_message(reason))
        reload.(socket)
    end
  end

  # The confirmation from a fresh offer, or the dialog closed with the reason
  # it cannot open.
  defp open(socket, meeting_id, user_id) do
    with {:ok, meeting} <- Meetings.get_meeting_for_organizer(meeting_id, user_id),
         {:ok, offer} <- Meetings.calendar_move_offer(meeting) do
      emit(user_id, meeting.id, :open, :ok)
      {:ok, ModalHook.show_modal(socket, :calendar_move, %{meeting: meeting, offer: offer})}
    else
      {:error, reason} ->
        emit(user_id, meeting_id, :open, reason)
        Flash.error(refusal_message(reason))
        {:error, ModalHook.hide_modal(socket, :calendar_move)}
    end
  end

  @doc """
  Moves the booking to the time the dialog showed and settles it: the list is
  refreshed whatever the outcome, since a refused move means the card on
  screen is out of date. The dialog closes, unless the calendar time changed
  again since it opened: then it shows the new time for the host to confirm.
  """
  @spec confirm(Phoenix.LiveView.Socket.t(), (Phoenix.LiveView.Socket.t() ->
                                                Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def confirm(socket, reload) when is_function(reload, 1) do
    user_id = socket.assigns.current_user.id

    case RateLimiter.check(:dashboard_reschedule, user_id) do
      {:error, :rate_limited, message} ->
        Flash.error(message)
        socket

      :ok ->
        {:noreply, socket} =
          ModalHook.with_modal_data(socket, :calendar_move, fn %{meeting: meeting, offer: offer} ->
            {:noreply, move(socket, meeting.id, user_id, offer, reload)}
          end)

        socket
    end
  end

  defp move(socket, meeting_id, user_id, offer, reload) do
    case Meetings.move_to_calendar_time(meeting_id, user_id, offer) do
      {:ok, moved} ->
        emit(user_id, meeting_id, :confirm, :ok)

        Flash.info(
          dgettext("dashboard_bookings", "Booking moved to %{time}",
            time: time_phrase(socket, moved)
          )
        )

        socket |> reload.() |> ModalHook.hide_modal(:calendar_move)

      # The event moved again while the dialog was open. Its new time is
      # offered afresh; should it no longer be movable at all, `open/3` says
      # why instead.
      {:error, :offer_changed} ->
        emit(user_id, meeting_id, :confirm, :offer_changed)
        Flash.warning(refusal_message(:offer_changed))
        {_opened_or_closed, socket} = socket |> reload.() |> open(meeting_id, user_id)
        socket

      {:error, reason} ->
        emit(user_id, meeting_id, :confirm, reason)
        Flash.error(refusal_message(reason))
        socket |> reload.() |> ModalHook.hide_modal(:calendar_move)
    end
  end

  defp time_phrase(socket, times) do
    profile = socket.assigns[:profile]

    Helpers.format_move_time(
      times,
      Helpers.get_meeting_timezone(times, profile),
      socket.assigns.time_format
    )
  end

  defp requested_id(%{"id" => id}) when is_binary(id), do: id
  defp requested_id(_params), do: nil

  defp cast_id(%{"id" => id}) when is_binary(id) do
    case UUID.cast(String.trim(id)) do
      {:ok, uuid} -> {:ok, uuid}
      :error -> {:error, :not_found}
    end
  end

  defp cast_id(_params), do: {:error, :not_found}

  defp refusal_message(:calendar_write_pending) do
    dgettext(
      "dashboard_bookings",
      "Tymeslot is still updating your calendar for this booking. Please try again in a moment."
    )
  end

  defp refusal_message(:offer_changed) do
    dgettext(
      "dashboard_bookings",
      "The meeting has moved again in your calendar. Check the new time and confirm the move."
    )
  end

  defp refusal_message(:slot_taken) do
    dgettext(
      "dashboard_bookings",
      "Tymeslot could not move this booking. Another booking already starts at that time."
    )
  end

  defp refusal_message(:failed_to_update_meeting) do
    dgettext("dashboard_bookings", "Tymeslot could not move this booking. Please try again.")
  end

  defp refusal_message(_reason) do
    dgettext(
      "dashboard_bookings",
      "This booking can no longer be moved to its calendar time."
    )
  end

  defp emit(user_id, meeting_id, step, result) do
    :telemetry.execute(
      @event ++ [step],
      %{},
      %{user_id: user_id, meeting_id: meeting_id, result: inspect(result)}
    )
  end
end
