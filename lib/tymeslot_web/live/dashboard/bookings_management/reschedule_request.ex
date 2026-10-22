defmodule TymeslotWeb.Dashboard.BookingsManagement.RescheduleRequest do
  @moduledoc """
  Asking an attendee to pick a new time, from the bookings dashboard.

  Split out of `BookingsManagementComponent` to keep that module inside the
  size limit. The reload is passed in rather than reached for: the list belongs
  to the component, and this module only says when it should be refreshed.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Meetings.MeetingSchema
  alias TymeslotWeb.Components.Dashboard.Meetings.Helpers
  alias TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Shared.Flash

  require Refusal

  require Logger

  @event [:tymeslot, :dashboard, :meetings, :reschedule, :confirm]

  @doc """
  Opens the way to a new time for the host's meeting `params["id"]`, if
  `policy` allows one: the dialog asking its attendee, or, for a meeting
  confirmed from a poll, which has nobody to ask, the host's own move
  (`HostMoveModal`, through `:host_move_meeting`). A refusal is flashed.
  """
  @spec show(Phoenix.LiveView.Socket.t(), map(), (MeetingSchema.t() -> :ok | {:error, term()})) ::
          Phoenix.LiveView.Socket.t()
  def show(socket, params, policy) do
    user_id = socket.assigns.current_user.id

    case ModalMeeting.fetch(user_id, params, policy) do
      {:ok, meeting} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :open],
          %{},
          %{user_id: user_id, meeting_id: meeting.id}
        )

        open(socket, meeting)

      {:error, :policy_blocked, reason} ->
        :telemetry.execute(
          [:tymeslot, :dashboard, :meetings, :reschedule, :blocked],
          %{},
          %{user_id: user_id, reason: inspect(reason)}
        )

        Flash.error(ModalMeeting.refusal_message(reason))
        socket

      {:error, _not_found_or_invalid, _reason} ->
        socket
    end
  end

  defp open(socket, meeting) do
    if HostManaged.managed_by_host?(meeting),
      do: assign(socket, :host_move_meeting, meeting),
      else: ModalHook.show_modal(socket, :reschedule_request, meeting)
  end

  @doc "Closes the host's move, refreshing the list once the meeting moved."
  @spec close_host_move(Phoenix.LiveView.Socket.t(), atom(), (Phoenix.LiveView.Socket.t() ->
                                                                Phoenix.LiveView.Socket.t())) ::
          Phoenix.LiveView.Socket.t()
  def close_host_move(socket, result, reload) do
    socket = assign(socket, :host_move_meeting, nil)
    if result == :moved, do: reload.(socket), else: socket
  end

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

      {:error, reason} when Refusal.is_refusal(reason) ->
        emit(user_id, meeting.id, result: :error, reason: inspect(reason))
        Flash.error(BookingErrorMessage.message(reason))
        assign(socket, :sending_reschedule, nil)

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
