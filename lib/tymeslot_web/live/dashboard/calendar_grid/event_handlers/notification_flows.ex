defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.NotificationFlows do
  @moduledoc "Attendee-notification flow handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.AttendeeNotifications

  @spec handle_notify_prompt_confirm(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_notify_prompt_confirm(_params, socket) do
    case socket.assigns.notify_prompt do
      nil ->
        {:noreply, socket}

      %{kind: :update, summary: summary, event: event, attendees: attendees} ->
        case AttendeeNotifications.event_updated_confirm(event, summary, attendees) do
          {:ok, :sent} ->
            send(self(), {:flash, {:info, "Changes saved. Attendees will be notified shortly."}})

            {:noreply,
             socket
             |> assign(:notify_prompt, nil)
             |> assign(:pending_notification, true)}

          {:error, _reason} ->
            send(
              self(),
              {:flash, {:warning, "Could not schedule notification. Changes were saved."}}
            )

            {:noreply, assign(socket, :notify_prompt, nil)}
        end

      %{kind: :delete, event: event, attendees: attendees} ->
        case AttendeeNotifications.event_deleted_confirm(event, attendees) do
          {:ok, :sent} ->
            user_id = socket.assigns.current_user.id

            send(
              self(),
              {:execute_delete_event, build_delete_payload(event, user_id, true)}
            )

            {:noreply,
             socket
             |> assign(:notify_prompt, nil)
             |> assign(:deleting_event, true)}

          {:error, _reason} ->
            send(
              self(),
              {:flash, {:warning, "Could not schedule notification. Please try again."}}
            )

            {:noreply, assign(socket, :notify_prompt, nil)}
        end
    end
  end

  @spec handle_notify_prompt_cancel(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_notify_prompt_cancel(_params, socket) do
    case socket.assigns.notify_prompt do
      nil ->
        {:noreply, socket}

      %{kind: :update} ->
        send(self(), {:flash, {:info, "Changes saved."}})
        {:noreply, assign(socket, :notify_prompt, nil)}

      %{kind: :delete, event: event} ->
        user_id = socket.assigns.current_user.id

        send(
          self(),
          {:execute_delete_event, build_delete_payload(event, user_id, false)}
        )

        {:noreply,
         socket
         |> assign(:notify_prompt, nil)
         |> assign(:deleting_event, true)}
    end
  end

  @spec handle_cancel_pending_notification(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_pending_notification(_params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        :ok = AttendeeNotifications.cancel_pending(event)
        send(self(), {:flash, {:info, "Pending notification cancelled."}})
        {:noreply, assign(socket, :pending_notification, false)}
    end
  end

  @doc """
  Builds the payload used to dispatch `{:execute_delete_event, payload}` from
  either the rate-limit-gated confirm path or the notify-prompt branches.
  """
  @spec build_delete_payload(map(), integer(), boolean()) :: map()
  def build_delete_payload(event, user_id, notify_on_delete) do
    %{
      uid: event.uid,
      provider_event_id: event.provider_event_id,
      calendar_integration_id: event.calendar_integration_id,
      user_id: user_id,
      notify_on_delete: notify_on_delete
    }
  end
end
