defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete do
  @moduledoc "Event deletion handlers for the calendar grid."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
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
        case EditWorkflow.assert_event_writable(socket, event) do
          :ok ->
            linked_to_booking =
              CalendarEvents.event_linked_to_booking?(
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

          {:error, :read_only} = error ->
            Shared.flash_guard_error(socket, error)

          {:error, :unauthorized} ->
            send(
              self(),
              {:flash,
               {:error,
                dgettext(
                  "dashboard_calendar_events",
                  "You don't have permission to delete this event"
                )}}
            )

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
            send(
              self(),
              {:flash,
               {:warning,
                dgettext("dashboard_calendar_events", "Too many edits. Please wait a moment.")}}
            )

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
  @spec handle_delete_result({:ok, map()} | {:error, map()}, Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_delete_result({:ok, %{linked_meeting: linked_meeting}}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_deleted
    )

    notify_on_delete = Map.get(socket.assigns, :pending_delete_notify, false)

    socket
    |> assign(:pending_delete_notify, false)
    |> put_deleted_flash(linked_meeting, notify_on_delete)
    |> then(&{:noreply, &1})
  end

  def handle_delete_result({:error, failure}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    {:noreply, put_flash(socket, :error, delete_failed_message(failure))}
  end

  defp put_deleted_flash(socket, :cancelled, _notify_on_delete) do
    put_flash(
      socket,
      :info,
      dgettext("dashboard_calendar_events", "Event and linked meeting cancelled.")
    )
  end

  defp put_deleted_flash(socket, :cancel_failed, _notify_on_delete) do
    put_flash(
      socket,
      :error,
      dgettext(
        "dashboard_calendar_events",
        "Event deleted, but meeting cancellation failed. The attendee may not be notified."
      )
    )
  end

  defp put_deleted_flash(socket, :none, notify_on_delete),
    do: put_flash(socket, :info, delete_success_flash(notify_on_delete))

  # A queued delete will be replayed on the next sync; anything else is final.
  defp delete_failed_message(%{retry: :queued}),
    do: dgettext("dashboard_calendar_events", "Delete failed - queued to retry on next sync")

  defp delete_failed_message(_failure),
    do: dgettext("dashboard_calendar_events", "Failed to delete event")

  defp delete_success_flash(true),
    do: dgettext("dashboard_calendar_events", "Event deleted. Attendees have been notified.")

  defp delete_success_flash(false), do: dgettext("dashboard_calendar_events", "Event deleted.")

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete_event, nil)
     |> assign(:confirm_delete_linked_to_booking, false)}
  end
end
