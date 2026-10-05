defmodule TymeslotWeb.Themes.Shared.CalendarDownload do
  @moduledoc """
  Where the booking confirmation's "Add to calendar" link points, held in
  `:calendar_ics_path` (`nil` hides the link).

  A solo booking downloads its meeting (`/:username/meeting/:uid/calendar.ics`).
  A group booking downloads the booker's own seat
  (`/seat/:token/calendar.ics`): each seat is its own calendar event, with
  its own UID and its own cancel and reschedule links, and the shared slot is
  not exportable at all. The token is the one the booker's confirmation email
  carries. A group booking whose seat cannot be found offers no link rather
  than the slot's.
  """

  use Phoenix.VerifiedRoutes,
    endpoint: TymeslotWeb.Endpoint,
    router: TymeslotWeb.Router

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.MeetingSchema

  @doc """
  Assigns `:calendar_ics_path` for `meeting`, just booked by `email`.
  """
  @spec assign_booked(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def assign_booked(socket, meeting, email),
    do: assign(socket, :calendar_ics_path, download_path(socket, meeting, email))

  defp download_path(socket, %MeetingSchema{} = meeting, email) do
    if Meetings.group?(meeting),
      do: seat_path(meeting, email),
      else: meeting_path(socket.assigns[:username_context], meeting.uid)
  end

  defp download_path(socket, meeting, _email),
    do: meeting_path(socket.assigns[:username_context], Map.get(meeting, :uid))

  defp seat_path(meeting, email) do
    case Meetings.booker_seat_token(meeting, email) do
      {:ok, token} -> ~p"/seat/#{token}/calendar.ics"
      {:error, :not_found} -> nil
    end
  end

  defp meeting_path(username, uid)
       when is_binary(username) and username != "" and is_binary(uid) and uid != "",
       do: ~p"/#{username}/meeting/#{uid}/calendar.ics"

  defp meeting_path(_username, _uid), do: nil
end
