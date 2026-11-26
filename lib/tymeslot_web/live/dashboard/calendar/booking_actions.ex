defmodule TymeslotWeb.Dashboard.Calendar.BookingActions do
  @moduledoc """
  The preview's actions on a booking (`BookingPreview`): Accept and Decline a
  request, Reschedule and Cancel a booking, and Move one whose event the host
  moved in their calendar (`BookingMove`), reached as `"booking:" <> name`
  events from `CalendarSurface`.

  Each runs the Meetings page's own path, so the two pages cannot differ on
  what an action does or who is told: the same ownership check (the meeting
  is looked up scoped to the signed-in organiser), the same rules
  (`Bookings.Policy`, `Meetings.Approval`), the same rate limits, the same
  dialogs (wrapped for the calendar in `BookingDeclineModal`,
  `BookingCancelModal` and `BookingRescheduleModal`, opened through
  `ModalHook` under the Meetings page's names) and the same messages. Every
  outcome reloads the events, so the grid shows what happened.
  """

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [push_event: 3]

  alias Ecto.UUID
  alias Tymeslot.Bookings.Policy
  alias Tymeslot.Security.RateLimiter
  alias TymeslotWeb.Dashboard.BookingsManagement.Cancellation
  alias TymeslotWeb.Dashboard.BookingsManagement.ModalMeeting
  alias TymeslotWeb.Dashboard.BookingsManagement.RequestActions
  alias TymeslotWeb.Dashboard.BookingsManagement.RescheduleRequest
  alias TymeslotWeb.Dashboard.Calendar.BookingMove
  alias TymeslotWeb.Dashboard.Calendar.SurfaceData
  alias TymeslotWeb.Hooks.ModalHook
  alias TymeslotWeb.Live.Shared.Flash

  @type socket :: Phoenix.LiveView.Socket.t()

  # What `booking:close` may name; anything else is ignored.
  @modals %{
    "decline" => :decline_request,
    "cancel" => :cancel_meeting,
    "reschedule" => :reschedule_request,
    "move" => :calendar_move
  }

  @doc "The assigns the actions and their dialogs read, before any is used."
  @spec defaults(socket()) :: socket()
  def defaults(socket) do
    socket
    |> ModalHook.mount_modal(
      decline_request: false,
      cancel_meeting: false,
      reschedule_request: false,
      calendar_move: false
    )
    |> assign(
      answering_request: MapSet.new(),
      moving_booking: MapSet.new(),
      answering_opts: %{},
      sending_reschedule: nil
    )
    |> assign(Cancellation.dialog_assigns())
  end

  @doc "Handles the `booking:` event `name`. Unknown names and malformed params change nothing."
  @spec handle(String.t(), map(), socket()) :: socket()
  def handle("accept", %{"id" => id}, socket) when is_binary(id) do
    with_idle_request(socket, id, fn socket, id ->
      with_limit(socket, :dashboard_meeting_approval, approval_key(socket), &accept(&1, id))
    end)
  end

  def handle("decline", %{"id" => id}, socket) when is_binary(id),
    do: with_idle_request(socket, id, &open_decline/2)

  # Declining while this request's Accept is in flight would restart its
  # answer under the same async name and drop the Accept's result.
  def handle("confirm_decline", params, socket) do
    case socket.assigns.decline_request_modal_data do
      nil ->
        socket

      meeting ->
        if RequestActions.answering?(socket.assigns.answering_request, meeting.id),
          do: socket,
          else:
            with_limit(
              socket,
              :dashboard_meeting_approval,
              approval_key(socket),
              &decline(&1, meeting, params)
            )
    end
  end

  def handle("cancel", %{"id" => id}, socket) when is_binary(id) do
    user_id = socket.assigns.current_user.id

    case ModalMeeting.fetch(user_id, %{"id" => id}, &Policy.can_cancel_meeting?/1) do
      {:ok, meeting} ->
        socket |> assign(:preview, nil) |> Cancellation.open(meeting)

      {:error, :policy_blocked, reason} ->
        refuse(socket, reason)

      {:error, _not_found_or_malformed, _detail} ->
        socket
    end
  end

  def handle("confirm_cancel", params, socket) do
    with_limit(socket, :dashboard_cancel, socket.assigns.current_user.id, fn socket ->
      case socket.assigns.cancel_meeting_modal_data do
        nil -> socket
        meeting -> Cancellation.confirm(socket, meeting, params, &reload_events/1)
      end
    end)
  end

  # `can_request_reschedule?/1` rather than the Meetings page's
  # `can_reschedule_meeting?/1`: it refuses a held request, which the domain
  # would refuse at confirm anyway.
  def handle("reschedule", %{"id" => id}, socket) when is_binary(id) do
    user_id = socket.assigns.current_user.id

    case ModalMeeting.fetch(user_id, %{"id" => id}, &Policy.can_request_reschedule?/1) do
      {:ok, meeting} ->
        socket |> assign(:preview, nil) |> ModalHook.show_modal(:reschedule_request, meeting)

      {:error, :policy_blocked, reason} ->
        refuse(socket, reason)

      {:error, _not_found_or_malformed, _detail} ->
        socket
    end
  end

  # On success `RescheduleRequest.send/3` reloads and closes the dialog; on
  # failure it leaves it open for another try.
  def handle("confirm_reschedule", _params, socket) do
    with_limit(socket, :dashboard_reschedule, socket.assigns.current_user.id, fn socket ->
      case socket.assigns.reschedule_request_modal_data do
        nil -> socket
        meeting -> RescheduleRequest.send(socket, meeting, &SurfaceData.reload(&1, :events))
      end
    end)
  end

  def handle("move", %{"id" => id}, socket) when is_binary(id), do: BookingMove.open(socket, id)

  def handle("confirm_move", _params, socket), do: BookingMove.confirm(socket)

  # Focus goes back to the event the dialog was opened from, as when the
  # preview itself closes.
  def handle("close", %{"modal" => modal}, socket) when is_map_key(@modals, modal) do
    socket
    |> ModalHook.hide_modal(Map.fetch!(@modals, modal))
    |> assign(Cancellation.dialog_assigns())
    |> push_event("calendar:preview-closed", %{})
  end

  def handle(_name, _params, socket), do: socket

  # Approving runs off the socket's process (`RequestActions.approve/3`), so
  # Accept shows its progress; `CalendarSurface.handle_async/3` hands the
  # result back to `RequestActions.handle_answer/3`, which reloads. A session
  # of a series request answers the whole series, and the flash says so, as
  # it does in the bookings list.
  defp accept(socket, id) do
    {:noreply, socket} = RequestActions.approve(socket, %{"id" => id}, &reload_events/1)
    socket
  end

  # The id as stored (`Ecto.UUID.cast/1` lowercases it), so a request whose
  # answer is already in flight is recognised however its id is spelt; an id
  # that is not a UUID changes nothing.
  defp with_idle_request(socket, id, fun) do
    case UUID.cast(id) do
      {:ok, id} ->
        if RequestActions.answering?(socket.assigns.answering_request, id),
          do: socket,
          else: fun.(socket, id)

      :error ->
        socket
    end
  end

  defp open_decline(socket, id) do
    case RequestActions.fetch_held_request(socket, %{"id" => id}) do
      {:ok, meeting} ->
        socket |> assign(:preview, nil) |> ModalHook.show_modal(:decline_request, meeting)

      {:error, message} ->
        socket |> RequestActions.flash_and_stay(message) |> SurfaceData.reload(:events)
    end
  end

  defp decline(socket, meeting, params) do
    reason = RequestActions.decline_reason(Map.get(params, "reason"))

    {:noreply, socket} =
      socket
      |> ModalHook.hide_modal(:decline_request)
      |> RequestActions.decline(meeting, reason, &reload_events/1)

    socket
  end

  defp reload_events(socket), do: SurfaceData.reload(socket, :events)

  # The action is no longer allowed (started, ended, already cancelled): the
  # block on screen is stale, so it is reloaded with the reason.
  defp refuse(socket, reason),
    do:
      socket
      |> Flash.put_flash(:error, ModalMeeting.refusal_message(reason))
      |> SurfaceData.reload(:events)

  defp with_limit(socket, limiter, key, fun) do
    case RateLimiter.check(limiter, key) do
      :ok -> fun.(socket)
      {:error, :rate_limited, message} -> Flash.put_flash(socket, :error, message)
    end
  end

  defp approval_key(socket), do: socket.assigns.current_user.id
end
