defmodule TymeslotWeb.Themes.Core.MeetingManagement do
  @moduledoc "Meeting cancel/keep/reschedule flow helpers for the scheduling dispatcher."

  use Gettext, backend: TymeslotWeb.Gettext

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

  A group meeting is refused for both with `{:error, :group_meeting}`: its
  uid names the shared slot, which `Tymeslot.Bookings.Cancel` and
  `Tymeslot.Bookings.Reschedule` refuse to act on for a visitor. Each
  participant manages their own spot from the links in their emails.
  """
  @spec validate_and_load_meeting(String.t(), atom(), integer()) ::
          {:ok, map()} | {:error, String.t() | :group_meeting}
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

  @doc "What a visitor is told when they open a group meeting's cancel or reschedule page."
  @spec group_meeting_message() :: String.t()
  def group_meeting_message do
    dgettext(
      "booking_manage",
      "This is a group session, so it cannot be changed from this link. To cancel or move your spot, use the links in your confirmation email."
    )
  end

  # Validates whether the given action is permitted for the meeting.
  @spec validate_meeting_action(map(), atom()) :: :ok | {:error, String.t() | :group_meeting}
  defp validate_meeting_action(meeting, action) when action in [:cancel, :reschedule] do
    if Meetings.group?(meeting),
      do: {:error, :group_meeting},
      else: permitted(meeting, action)
  end

  defp validate_meeting_action(_unused_meeting, :cancel_confirmed) do
    :ok
  end

  defp permitted(meeting, :cancel) do
    Policy.can_cancel_meeting?(meeting)
  end

  defp permitted(meeting, :reschedule) do
    Policy.can_reschedule_meeting?(meeting)
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
              {:noreply, put_flash(socket, :error, cancel_error_message(reason))}
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

  # A refusal reason is a code that must never reach the visitor as it stands.
  defp cancel_error_message(:group_meeting_not_cancellable), do: group_meeting_message()

  defp cancel_error_message(_reason),
    do: dgettext("booking_manage", "The meeting could not be cancelled. Please try again.")

  # Builds the URL to redirect to after a meeting is cancelled.
  @spec build_cancel_confirmed_url(Phoenix.LiveView.Socket.t(), map()) :: String.t()
  defp build_cancel_confirmed_url(socket, meeting) do
    case socket.assigns[:organizer_profile] do
      %{username: username} when is_binary(username) and byte_size(username) > 0 ->
        "/#{username}/meeting/#{meeting.uid}/cancel-confirmed"

      _no_username ->
        "/meeting/#{meeting.uid}/cancel-confirmed"
    end
  end
end
