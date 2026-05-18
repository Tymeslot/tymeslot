defmodule TymeslotWeb.Themes.Core.MeetingManagement do
  @moduledoc "Meeting cancel/keep/reschedule flow helpers for the scheduling dispatcher."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Meetings
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Themes.Core.MountHelpers

  @doc """
  Loads and validates a meeting by UID for the given action.

  The `organizer_user_id` from the resolved profile is used to scope the lookup,
  ensuring that only the meeting belonging to the profile owner can be accessed.
  This prevents IDOR attacks on the cancel and reschedule routes.
  """
  @spec validate_and_load_meeting(String.t(), atom(), integer()) ::
          {:ok, map()} | {:error, String.t()}
  def validate_and_load_meeting(meeting_uid, action, organizer_user_id) do
    case Meetings.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id) do
      {:ok, meeting} ->
        case validate_meeting_action(meeting, action) do
          :ok -> {:ok, meeting}
          {:error, reason} -> {:error, reason}
        end

      {:error, :not_found} ->
        {:error, "Meeting not found"}
    end
  end

  @doc "Validates whether the given action is permitted for the meeting."
  @spec validate_meeting_action(map(), atom()) :: :ok | {:error, String.t()}
  def validate_meeting_action(meeting, :cancel) do
    Policy.can_cancel_meeting?(meeting)
  end

  def validate_meeting_action(meeting, :reschedule) do
    Policy.can_reschedule_meeting?(meeting)
  end

  def validate_meeting_action(_unused_meeting, :cancel_confirmed) do
    :ok
  end

  @doc "Handles cancel_meeting and keep_meeting events."
  @spec handle_meeting_event(String.t(), map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_meeting_event("cancel_meeting", _unused_params, socket) do
    if socket.assigns[:live_action] == :cancel do
      meeting = socket.assigns[:meeting]
      client_ip = ClientIP.get(socket)

      case RateLimiter.check_meeting_cancel_rate_limit(client_ip) do
        :ok ->
          case Meetings.cancel_meeting(meeting) do
            {:ok, _result} ->
              cancel_confirmed_url = build_cancel_confirmed_url(socket, meeting)
              {:noreply, redirect(socket, to: cancel_confirmed_url)}

            {:error, reason} ->
              {:noreply, put_flash(socket, :error, "Failed to cancel meeting: #{reason}")}
          end

        {:error, :rate_limited, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_meeting_event("keep_meeting", _unused_params, socket) do
    if socket.assigns[:live_action] == :cancel do
      client_ip = ClientIP.get(socket)

      case RateLimiter.check_meeting_keep_rate_limit(client_ip) do
        :ok ->
          {:noreply, assign(socket, :meeting_kept, true)}

        {:error, :rate_limited, message} ->
          {:noreply, put_flash(socket, :error, message)}
      end
    else
      {:noreply, socket}
    end
  end

  @doc "Assigns action-specific data to the socket (e.g. duration for reschedule)."
  @spec assign_action_specific_data(Phoenix.LiveView.Socket.t(), atom(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  def assign_action_specific_data(socket, :reschedule, meeting, params) do
    duration_str = Duration.format_for_url(meeting.duration)

    socket
    |> MountHelpers.assign_user_timezone(params)
    |> assign(:duration, duration_str)
  end

  def assign_action_specific_data(socket, _other_action, _unused_meeting, _unused_params),
    do: socket

  @doc "Builds the URL to redirect to after a meeting is cancelled."
  @spec build_cancel_confirmed_url(Phoenix.LiveView.Socket.t(), map()) :: String.t()
  def build_cancel_confirmed_url(socket, meeting) do
    case socket.assigns[:organizer_profile] do
      %{username: username} when is_binary(username) and byte_size(username) > 0 ->
        "/#{username}/meeting/#{meeting.uid}/cancel-confirmed"

      _no_username ->
        "/meeting/#{meeting.uid}/cancel-confirmed"
    end
  end
end
