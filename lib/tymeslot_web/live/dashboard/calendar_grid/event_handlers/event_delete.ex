defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete do
  @moduledoc "Event deletion handlers for the calendar grid."

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
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
            send(
              self(),
              {:execute_delete_event,
               %{
                 uid: event.uid,
                 provider_event_id: event.provider_event_id,
                 calendar_integration_id: event.calendar_integration_id,
                 user_id: socket.assigns.current_user.id
               }}
            )

            {:noreply, assign(socket, :deleting_event, true)}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, assign(socket, :confirm_delete_event, nil)}
        end
    end
  end

  @doc false
  @spec run_delete_event(map()) :: {:ok, map()} | {:error, term()}
  def run_delete_event(payload) do
    %{uid: uid, calendar_integration_id: integration_id, user_id: user_id} = payload

    opts =
      if payload[:provider_event_id], do: [provider_event_id: payload.provider_event_id], else: []

    EventOperations.delete_event_and_reconcile(
      uid,
      payload[:provider_event_id],
      {integration_id, user_id},
      opts
    )
  end

  @doc false
  @spec handle_delete_result({:ok, map()} | {:error, term()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_result({:ok, %{uid: uid, integration_id: integration_id} = result}, socket) do
    CalendarGrid.delete_cached_event(integration_id, uid)

    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_deleted
    )

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
          socket
      end

    {:noreply, socket}
  end

  def handle_delete_result({:error, _reason}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    {:noreply, put_flash(socket, :error, "Failed to delete event")}
  end

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete_event, nil)
     |> assign(:confirm_delete_linked_to_booking, false)}
  end
end
