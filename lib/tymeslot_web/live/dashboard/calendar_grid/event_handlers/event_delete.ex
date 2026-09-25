defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.EventDelete do
  @moduledoc "Event deletion handlers for the calendar grid."

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 2, assign: 3]
  import Phoenix.LiveView, only: [put_flash: 3, send_update: 2]

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Attendee
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
        with :ok <- EditWorkflow.assert_event_writable(socket, event),
             {:ok, scopes} <- CalendarGrid.deletion_scopes(event) do
          linked_to_booking =
            CalendarEvents.event_linked_to_booking?(
              event.calendar_integration_id,
              event.provider_event_id,
              event.uid
            )

          {:noreply,
           assign(socket,
             selected_event: nil,
             confirm_delete_event: event,
             confirm_delete_scopes: scopes,
             confirm_delete_linked_to_booking: linked_to_booking
           )}
        else
          {:error, :read_only} = error ->
            Shared.flash_guard_error(socket, error)

          {:error, :recurring_event} ->
            send(self(), {:flash, {:error, recurring_delete_refused_message()}})
            {:noreply, socket}

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
  def handle_confirm_delete_event(params, socket) do
    case socket.assigns.confirm_delete_event do
      nil ->
        {:noreply, socket}

      event ->
        case Shared.check_edit_rate_limit(socket) do
          :ok ->
            proceed_with_delete(socket, event, parse_scope(params))

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

  # Only a series member's modal sends a scope; anything else deletes the
  # event it was opened for, which is what `:occurrence` means outside a
  # series.
  defp parse_scope(%{"scope" => "series"}), do: :series
  defp parse_scope(_params), do: :occurrence

  defp proceed_with_delete(socket, event, scope) do
    attendees = normalise_attendees(event)

    case AttendeeNotifications.event_deleted(event, attendees) do
      {:ok, :no_attendees} ->
        user_id = socket.assigns.current_user.id

        send(
          self(),
          {:execute_delete_event,
           NotificationFlows.build_delete_payload(event, user_id, false, scope)}
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
           attendees: attendees,
           scope: scope
         })}
    end
  end

  defp normalise_attendees(event) do
    (Map.get(event, :attendees) || [])
    |> Enum.map(&Attendee.normalise/1)
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

    pending = Map.get(socket.assigns, :pending_delete) || %{}

    socket
    |> assign(:pending_delete, nil)
    |> put_deleted_flash(linked_meeting, pending)
    |> then(&{:noreply, &1})
  end

  def handle_delete_result({:error, failure}, socket) do
    send_update(CalendarGridComponent,
      id: "calendar",
      action: :event_delete_failed
    )

    {:noreply,
     socket
     |> assign(:pending_delete, nil)
     |> put_flash(:error, delete_failed_message(failure))}
  end

  defp put_deleted_flash(socket, :cancelled, _pending) do
    put_flash(
      socket,
      :info,
      dgettext("dashboard_calendar_events", "Event and linked meeting cancelled.")
    )
  end

  defp put_deleted_flash(socket, :cancel_failed, _pending) do
    put_flash(
      socket,
      :error,
      dgettext(
        "dashboard_calendar_events",
        "Event deleted, but meeting cancellation failed. The attendee may not be notified."
      )
    )
  end

  defp put_deleted_flash(socket, :none, pending) do
    scope = Map.get(pending, :scope, :occurrence)
    notified? = Map.get(pending, :notify_on_delete, false)
    put_flash(socket, :info, delete_success_flash(scope, notified?))
  end

  # A queued delete will be replayed on the next sync; anything else is final.
  defp delete_failed_message(%{retry: :queued}),
    do: dgettext("dashboard_calendar_events", "Delete failed - queued to retry on next sync")

  defp delete_failed_message(%{reason: :recurring_event}), do: recurring_delete_refused_message()

  # The cached row does not say which occurrence or series the event is.
  defp delete_failed_message(%{reason: reason})
       when reason in [:unaddressable_occurrence, :unaddressable_series] do
    dgettext(
      "dashboard_calendar_events",
      "This event could not be deleted here. Please delete it in your calendar app."
    )
  end

  defp delete_failed_message(_failure),
    do: dgettext("dashboard_calendar_events", "Failed to delete event")

  # Exchange has no scoped delete, so none of its series can be deleted here.
  defp recurring_delete_refused_message do
    dgettext(
      "dashboard_calendar_events",
      "Recurring Exchange events cannot be deleted here yet. Please delete this one in your calendar app."
    )
  end

  defp delete_success_flash(:series, true),
    do:
      dgettext(
        "dashboard_calendar_events",
        "Recurring event deleted. Attendees have been notified."
      )

  defp delete_success_flash(:series, false),
    do: dgettext("dashboard_calendar_events", "Recurring event deleted.")

  defp delete_success_flash(:occurrence, true),
    do: dgettext("dashboard_calendar_events", "Event deleted. Attendees have been notified.")

  defp delete_success_flash(:occurrence, false),
    do: dgettext("dashboard_calendar_events", "Event deleted.")

  @spec handle_cancel_delete_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_delete_event(_params, socket) do
    {:noreply,
     socket
     |> assign(:confirm_delete_event, nil)
     |> assign(:confirm_delete_linked_to_booking, false)}
  end
end
