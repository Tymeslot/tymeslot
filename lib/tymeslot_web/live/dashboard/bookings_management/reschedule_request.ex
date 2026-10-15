defmodule TymeslotWeb.Dashboard.BookingsManagement.RescheduleRequest do
  @moduledoc """
  Asking an attendee to pick a new time, from the bookings dashboard.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit. The reload is passed in rather than reached for: the list belongs
  to the component, and this module only says when it should be refreshed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  require Logger

  @event [:tymeslot, :dashboard, :meetings, :reschedule, :confirm]

  @doc """
  Sends the request and settles the dialog: closed and the list refreshed on
  success, left open with the row unmarked on failure, so a retry is one click
  away rather than a re-open.
  """
  @spec send(Phoenix.LiveView.Socket.t(), map(), (Phoenix.LiveView.Socket.t() ->
                                                    Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def send(socket, meeting, reload) when is_function(reload, 1) do
    socket = assign(socket, :sending_reschedule, meeting.id)
    user_id = socket.assigns.current_user.id

    case Meetings.send_reschedule_request(meeting) do
      :ok ->
        emit(user_id, meeting.id, result: :ok)

        Flash.info(sent_message(meeting))

        socket
        |> assign(:sending_reschedule, nil)
        |> reload.()
        |> ModalHook.hide_modal(:reschedule_request)

      {:error, reason} ->
        emit(user_id, meeting.id, result: :error, reason: inspect(reason))

        Logger.error("send_reschedule_request_failed",
          reason: LogFormat.reason(reason),
          meeting_id: meeting.id
        )

        Flash.error(
          dgettext("dashboard_bookings", "Failed to send reschedule request. Please try again.")
        )

        assign(socket, :sending_reschedule, nil)
    end
  end

  # A group meeting has no attendee to name; the request went to each of its
  # participants (`meeting` arrives with them loaded, see
  # `Meetings.with_live_participants/1`).
  defp sent_message(meeting) do
    if Helpers.group_meeting?(meeting) do
      count = length(Helpers.participants(meeting))

      dngettext(
        "dashboard_bookings",
        "Reschedule request sent to %{count} participant",
        "Reschedule request sent to %{count} participants",
        count
      )
    else
      dgettext("dashboard_bookings", "Reschedule request sent to %{attendee_name}",
        attendee_name: meeting.attendee_name
      )
    end
  end

  defp emit(user_id, meeting_id, extra) do
    :telemetry.execute(
      @event,
      %{},
      Enum.into(extra, %{user_id: user_id, meeting_id: meeting_id})
    )
  end
end
