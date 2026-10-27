defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.AttendeeManagement do
  @moduledoc """
  Attendee management event handlers for CalendarGridComponent.

  An event a group meeting with live seats sits on takes no attendee
  changes here (`Shared.check_seat_lock/2`): who attends is who holds a
  seat, managed from the meeting.

  An attendee added or removed is shown at once and written in the
  background; the guest is invited, or told they are off the event, only
  once the calendar has accepted the write (`membership_written/3`, see
  "Telling the attendees" in `CalendarGrid.EventWrites`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Integrations.Calendar.Attendee
  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_add_event_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_add_event_attendee(%{"email" => raw_email}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        email = raw_email |> String.trim() |> String.downcase()
        attendees = attendees_of(event)
        already_present = Enum.any?(attendees, &(comparable_email(&1) == email))

        with true <- Shared.valid_email?(email),
             false <- already_present,
             :ok <- EditWorkflow.assert_event_writable(socket, event),
             :ok <- Shared.check_seat_lock(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          {:noreply, add_attendee(socket, event, attendees, email)}
        else
          {:error, reason} = error when reason in [:unauthorized, :read_only, :group_booking] ->
            Shared.flash_guard_error(socket, error)

          {:error, :rate_limited, _message} = error ->
            Shared.flash_guard_error(socket, error)

          _invalid ->
            {:noreply, socket}
        end
    end
  end

  defp add_attendee(socket, event, attendees, email) do
    new_attendee = Attendee.new(email: email)
    new_attendees = attendees ++ [new_attendee]
    updated_event = %{event | attendees: new_attendees}
    updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

    socket
    |> assign(:selected_event, updated_event)
    |> assign(:events, updated_events)
    |> assign(:attendee_input, "")
    |> Helpers.precompute_derived()
    |> EditWorkflow.update_event_async(event, %{attendees: new_attendees}, notify: :membership)
  end

  @doc """
  Invites the attendees a write accepted by the calendar, or saved to sync
  later, added to the event and tells the ones it removed (`AttendeeNotifications.membership_changed/3`),
  from `original_event`, the event as the write found it, and
  `updated_event`, as it left it, then tells the organiser what was sent.
  """
  @spec membership_written(Phoenix.LiveView.Socket.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  def membership_written(socket, original_event, updated_event) do
    %{added: added, removed: removed} =
      AttendeeNotifications.membership_changed(
        original_event,
        updated_event,
        socket.assigns.current_user.id
      )

    Enum.each([added_flash(added), removed_flash(removed)], &flash/1)
    socket
  end

  defp flash(nil), do: :ok
  defp flash(message), do: send(self(), {:flash, message})

  # The cached list comes back from JSONB string-keyed, and may predate the
  # canonical shape. Reading it into that shape here means the list written
  # back by an add or a remove is canonical throughout.
  defp attendees_of(event), do: Enum.map(event.attendees || [], &Attendee.normalise/1)

  # Providers keep the case an address was stored with (CalDAV, Outlook), but
  # the mailbox is the same whatever its case, so duplicates are found by
  # comparing lowercased addresses. Stored values are left as they are.
  defp comparable_email(%{email: email}) when is_binary(email), do: String.downcase(email)
  defp comparable_email(_missing), do: nil

  # An event the user only attends is changed on their calendar alone; its
  # organiser is the one to tell the guests. A write that added nobody, or
  # removed nobody, has nothing to say about it.
  defp added_flash({:ok, :noop}), do: nil

  defp added_flash({:ok, :not_organiser}),
    do:
      {:info,
       dgettext(
         "dashboard_calendar_events",
         "Attendee added. They were not invited, as you don't organise this event."
       )}

  defp added_flash({:ok, :sent}),
    do: {:info, dgettext("dashboard_calendar_events", "Attendee added and invited.")}

  defp added_flash({:ok, :after_sync}),
    do:
      {:info,
       dgettext(
         "dashboard_calendar_events",
         "Attendee added. They will be invited once the change has synced to your calendar."
       )}

  defp added_flash({:error, _reason}),
    do:
      {:warning,
       dgettext(
         "dashboard_calendar_events",
         "Attendee added, but their invitation could not be sent."
       )}

  defp removed_flash({:ok, :noop}), do: nil

  defp removed_flash({:ok, :not_organiser}),
    do:
      {:info,
       dgettext(
         "dashboard_calendar_events",
         "Attendee removed. They were not notified, as you don't organise this event."
       )}

  defp removed_flash({:ok, :sent}),
    do: {:info, dgettext("dashboard_calendar_events", "Attendee removed and notified.")}

  defp removed_flash({:ok, :after_sync}),
    do:
      {:info,
       dgettext(
         "dashboard_calendar_events",
         "Attendee removed. They will be notified once the change has synced to your calendar."
       )}

  defp removed_flash({:error, _reason}),
    do:
      {:warning,
       dgettext(
         "dashboard_calendar_events",
         "Attendee removed, but they could not be notified."
       )}

  defp apply_remove_attendee(socket, event, email) do
    new_attendees = Enum.reject(attendees_of(event), &(&1.email == email))

    updated_event = %{event | attendees: new_attendees}
    updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

    socket
    |> assign(:selected_event, updated_event)
    |> assign(:events, updated_events)
    |> assign(:confirm_remove_attendee, nil)
    |> Helpers.precompute_derived()
    |> EditWorkflow.update_event_async(event, %{attendees: new_attendees}, notify: :membership)
  end

  @spec handle_request_remove_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_request_remove_attendee(%{"email" => email}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with :ok <- EditWorkflow.assert_event_writable(socket, event),
             :ok <- Shared.check_seat_lock(socket, event) do
          {:noreply,
           assign(socket, :confirm_remove_attendee, %{email: email, event_id: event.id})}
        else
          {:error, reason} = error when reason in [:unauthorized, :read_only, :group_booking] ->
            Shared.flash_guard_error(socket, error)
        end
    end
  end

  @spec handle_confirm_remove_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_confirm_remove_attendee(_params, socket) do
    case {socket.assigns.confirm_remove_attendee, socket.assigns.selected_event} do
      {nil, _event} ->
        {:noreply, socket}

      {%{email: _email}, nil} ->
        {:noreply, assign(socket, :confirm_remove_attendee, nil)}

      {%{email: email, event_id: event_id}, %{id: event_id} = event} ->
        with :ok <- Shared.check_seat_lock(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          {:noreply, apply_remove_attendee(socket, event, email)}
        else
          error ->
            socket = assign(socket, :confirm_remove_attendee, nil)
            Shared.flash_guard_error(socket, error)
        end

      {%{email: _email, event_id: _stored_id}, _mismatched_event} ->
        {:noreply, assign(socket, :confirm_remove_attendee, nil)}
    end
  end

  @spec handle_cancel_remove_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_remove_attendee(_params, socket) do
    {:noreply, assign(socket, :confirm_remove_attendee, nil)}
  end

  @spec handle_update_attendee_input(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_attendee_input(%{"email" => value}, socket) do
    {:noreply, assign(socket, :attendee_input, value)}
  end

  @spec handle_remove_pending_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_remove_pending_attendee(%{"email" => email}, socket) do
    updated = List.delete(socket.assigns.pending_attendees, email)
    {:noreply, assign(socket, :pending_attendees, updated)}
  end

  @spec handle_discard_pending_attendees(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_discard_pending_attendees(_params, socket) do
    cond do
      socket.assigns.selected_event != nil ->
        {:noreply,
         socket
         |> assign(:pending_attendees, [])
         |> assign(:confirm_discard_attendees, false)
         |> assign(:selected_event, nil)
         |> assign(:attendee_input, "")}

      socket.assigns.creating_event != nil ->
        {:noreply,
         socket
         |> assign(:creating_event, nil)
         |> assign(:confirm_discard_attendees, false)}

      true ->
        {:noreply, assign(socket, :confirm_discard_attendees, false)}
    end
  end

  @spec handle_cancel_discard_attendees(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_cancel_discard_attendees(_params, socket) do
    {:noreply, assign(socket, :confirm_discard_attendees, false)}
  end
end
