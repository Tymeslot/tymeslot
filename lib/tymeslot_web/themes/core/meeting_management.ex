defmodule TymeslotWeb.Themes.Core.MeetingManagement do
  @moduledoc "Meeting cancel/keep/reschedule flow helpers for the scheduling dispatcher."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, redirect: 2]

  require Logger
  require Tymeslot.Bookings.Refusal

  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Bookings.Refusal
  alias Tymeslot.Infrastructure.Logging.LogFormat
  alias Tymeslot.Meetings
  alias Tymeslot.Meetings.HostManaged
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Utils.DateTimeUtils.Duration
  alias TymeslotWeb.Helpers.ClientIP
  alias TymeslotWeb.Live.Scheduling.Handlers.BookingErrorMessage
  alias TymeslotWeb.Live.Shared.RateLimit
  alias TymeslotWeb.Themes.Shared.TimezoneHelpers

  @doc """
  Loads and validates a meeting by UID for the given action.

  The `organizer_user_id` from the resolved profile is used to scope the lookup,
  ensuring that only the meeting belonging to the profile owner can be accessed.
  This prevents IDOR attacks on the cancel and reschedule routes.

  A group meeting is refused for both with `{:error, :group_meeting}`: its
  uid names the shared slot, which `Tymeslot.Bookings.Cancel` and
  `Tymeslot.Bookings.Reschedule` refuse to act on for a visitor. Each
  participant manages their own spot from the links in their emails.

  `{:error, :not_found}` when the organiser has no meeting with that uid.
  """
  @spec validate_and_load_meeting(String.t(), atom(), integer()) ::
          {:ok, map()}
          | {:error,
             Policy.cancel_refusal()
             | Policy.reschedule_refusal()
             | :group_meeting
             | :managed_by_host
             | :not_found}
  def validate_and_load_meeting(meeting_uid, action, organizer_user_id) do
    case Meetings.get_meeting_by_uid_for_organizer(meeting_uid, organizer_user_id) do
      {:ok, meeting} ->
        with :ok <- validate_meeting_action(meeting, action), do: {:ok, meeting}

      {:error, :not_found} ->
        {:error, :not_found}
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

  @doc """
  What a visitor is told when they open the cancel or reschedule page of a
  meeting the host manages, one confirmed from a poll.
  """
  @spec managed_by_host_message() :: String.t()
  def managed_by_host_message do
    dgettext(
      "booking_manage",
      "This meeting was arranged by a poll, so only its host can move or cancel it. If you can't make it, use \"Can't make it\" in your invitation, or reply to it."
    )
  end

  # Validates whether the given action is permitted for the meeting.
  @spec validate_meeting_action(map(), atom()) ::
          :ok
          | {:error,
             Policy.cancel_refusal()
             | Policy.reschedule_refusal()
             | :group_meeting
             | :managed_by_host}
  defp validate_meeting_action(meeting, action) when action in [:cancel, :reschedule] do
    cond do
      Meetings.group?(meeting) -> {:error, :group_meeting}
      HostManaged.managed?(meeting) -> {:error, :managed_by_host}
      true -> permitted(meeting, action)
    end
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

      RateLimit.with_rate_limit(
        RateLimiter.check(:meeting_cancel, client_ip),
        socket,
        fn ->
          case Meetings.cancel_meeting(meeting) do
            {:ok, _result} ->
              cancel_confirmed_url = build_cancel_confirmed_url(socket, meeting)
              {:noreply, redirect(socket, to: cancel_confirmed_url)}

            {:error, reason} ->
              Logger.warning("Guest cancellation failed",
                meeting_uid: meeting.uid,
                reason: LogFormat.reason(reason)
              )

              {:noreply, put_flash(socket, :error, cancel_error_message(reason))}
          end
        end,
        flash: :socket
      )
    else
      {:noreply, socket}
    end
  end

  def handle_meeting_event("keep_meeting", _unused_params, socket) do
    if socket.assigns[:live_action] == :cancel do
      client_ip = ClientIP.get(socket)

      RateLimit.with_rate_limit(
        RateLimiter.check(:meeting_keep, client_ip),
        socket,
        fn -> {:noreply, assign(socket, :meeting_kept, true)} end,
        flash: :socket
      )
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
    |> TimezoneHelpers.assign_user_timezone(params)
    |> assign(:duration, duration_str)
  end

  def assign_action_specific_data(socket, _other_action, _unused_meeting, _unused_params),
    do: socket

  # A refusal reason is a code that must never reach the visitor as it stands.
  defp cancel_error_message(:group_meeting_not_cancellable), do: group_meeting_message()
  defp cancel_error_message(:managed_by_host), do: managed_by_host_message()

  # The page was loaded while the meeting was live, and someone else (the
  # host, or this attendee in another tab) cancelled it since.
  defp cancel_error_message(:already_cancelled),
    do: dgettext("booking_manage", "This booking was already cancelled.")

  # The meeting started, ended or expired after the page loaded.
  defp cancel_error_message(reason) when Refusal.is_refusal(reason),
    do: BookingErrorMessage.message(reason)

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
