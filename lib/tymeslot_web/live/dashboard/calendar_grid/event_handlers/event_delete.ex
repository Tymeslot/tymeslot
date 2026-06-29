defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete do
  @moduledoc "Event deletion handlers for the calendar grid."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NotificationFlows
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGridComponent

  @spec handle_request_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_request_delete_event(_params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        case EditWorkflow.assert_owns_event(socket, event) do
          :ok ->
            linked_to_booking =
              EventOperations.event_linked_to_booking?(
                event.calendar_integration_id,
                event.provider_event_id,
                event.uid
              )

            socket =
              socket
              |> assign(:selected_event, nil)
              |> assign(:confirm_delete_event, event)
              |> assign(:confirm_delete_linked_to_booking, linked_to_booking)

            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to delete this event"}})
            {:noreply, socket}
        end
    end
  end

  @spec handle_confirm_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_delete_event(_params, socket) do
    case socket.assigns.confirm_delete_event do
      nil ->
        {:noreply, socket}

      event ->
        case Shared.check_edit_rate_limit(socket) do
          :ok ->
            proceed_with_delete(socket, event)

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, assign(socket, :confirm_delete_event, nil)}
        end
    end
  end

  defp proceed_with_delete(socket, event) do
    attendees = normalise_attendees(event)

    case AttendeeNotifications.event_deleted(event, attendees) do
      {:ok, :no_attendees} ->
        user_id = socket.assigns.current_user.id

        send(
          self(),
          {:execute_delete_event, NotificationFlows.build_delete_payload(event, user_id, false)}
        )

        {:noreply,
         socket
         |> assign(:confirm_delete_event, nil)
         |> assign(:deleting_event, true)}

      {:needs_confirmation, _count} ->
        {:noreply,
         socket
         |> assign(:confirm_delete_event, nil)
         |> assign(:notify_prompt, %{
           kind: :delete,
           summary: nil,
           event: event,
           attendees: attendees
         })}
    end
  end

  defp normalise_attendees(event) do
    (Map.get(event, :attendees) || [])
    |> Enum.map(fn attendee ->
      %{
        email: Map.get(attendee, "email") || Map.get(attendee, :email),
        name: Map.get(attendee, "name") || Map.get(attendee, :name)
      }
    end)
    |> Enum.reject(&(is_nil(&1.email) or &1.email == ""))
  end

  @doc false
  @spec run_delete_event(map()) :: {:ok, map()} | {:error, term(), map()}
  def run_delete_event(payload) do
    %{uid: uid, calendar_integration_id: integration_id, user_id: user_id} = payload

    opts =
      if payload[:provider_event_id], do: [provider_event_id: payload.provider_event_id], else: []

    case EventOperations.delete_event_and_reconcile(
           uid,
           payload[:provider_event_id],
           {integration_id, user_id},
           opts
         ) do
      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        # Carry the uid + integration_id into the failure branch so the
        # LiveView can tag the cache row for offline retry.
        {:error, reason, %{uid: uid, calendar_integration_id: integration_id}}
    end
  end

  @doc false
  @spec handle_delete_result(
          {:ok, map()} | {:error, term()} | {:error, term(), map()},
          Phoenix.LiveView.Socket.t()
        ) :: {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_result({:ok, %{uid: uid, integration_id: integration_id} = result}, socket) do
    CalendarGrid.delete_cached_event(integration_id, uid)

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_deleted
    )

    notify_on_delete = Map.get(socket.assigns, :pending_delete_notify, false)
    socket = assign(socket, :pending_delete_notify, false)

    socket =
      case result do
        %{reconcile_result: :ok, meeting_attendee_email: _email_ok} ->
          put_flash(socket, :info, "Event and linked meeting cancelled.")

        %{reconcile_result: {:error, _reason}, meeting_attendee_email: _email_err} ->
          put_flash(
            socket,
            :error,
            "Event deleted, but meeting cancellation failed. The attendee may not be notified."
          )

        _no_meeting ->
          put_flash(socket, :info, delete_success_flash(notify_on_delete))
      end

    {:noreply, socket}
  end

  def handle_delete_result({:error, _reason, context}, socket) do
    # For CalDAV integrations, tag the cache row so OfflineQueue.flush/2
    # retries the delete on the next sync cycle. QueueWiring is a no-op
    # for non-CalDAV providers, so this is safe to call unconditionally.
    queue_result = EventOperations.tag_for_offline_retry(context, :delete, %{})

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    flash_message =
      case queue_result do
        :ok -> "Delete failed — queued to retry on next sync"
        :ignored -> "Failed to delete event"
      end

    {:noreply, put_flash(socket, :error, flash_message)}
  end

  def handle_delete_result({:error, _reason}, socket) do
    # Fallback: contextless failure (e.g. from tests or older call sites).
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    {:noreply, put_flash(socket, :error, "Failed to delete event")}
  end

  defp delete_success_flash(true), do: "Event deleted. Attendees have been notified."
  defp delete_success_flash(false), do: "Event deleted."

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete_event, nil)
     |> assign(:confirm_delete_linked_to_booking, false)}
  end
end
