defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.AttendeeManagement do
  @moduledoc "Attendee management event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.AttendeeNotifications
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates
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
        existing_emails = Enum.map(event.attendees || [], &attendee_email/1)
        already_present = email in existing_emails

        with true <- Shared.valid_email?(email),
             false <- already_present,
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          new_attendee = %{"email" => email, "name" => nil, "status" => "needs_action"}
          new_attendees = (event.attendees || []) ++ [new_attendee]
          updated_event = %{event | attendees: new_attendees}
          updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

          {:ok, _result} =
            AttendeeNotifications.attendees_added(event, [%{email: email, name: nil}])

          send(self(), {:flash, {:info, "Attendee added and invited."}})

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> assign(:attendee_input, "")
            |> Helpers.precompute_derived()
            |> Updates.update_attendees_async(event, new_attendees)

          {:noreply, socket}
        else
          {:error, :unauthorized} = error -> Shared.flash_guard_error(socket, error)
          {:error, :rate_limited, _message} = error -> Shared.flash_guard_error(socket, error)
          _invalid -> {:noreply, socket}
        end
    end
  end

  defp attendee_email(%{} = attendee),
    do: Map.get(attendee, "email") || Map.get(attendee, :email)

  defp normalise_attendee(%{} = attendee) do
    %{
      email: Map.get(attendee, "email") || Map.get(attendee, :email),
      name: Map.get(attendee, "name") || Map.get(attendee, :name)
    }
  end

  defp apply_remove_attendee(socket, event, email) do
    {removed, new_attendees} =
      Enum.split_with(event.attendees || [], &(attendee_email(&1) == email))

    updated_event = %{event | attendees: new_attendees}
    updated_events = Shared.replace_event(socket.assigns.events, event.id, updated_event)

    normalised_removed = Enum.map(removed, &normalise_attendee/1)

    if normalised_removed != [] do
      {:ok, _result} = AttendeeNotifications.attendees_removed(event, normalised_removed)
      send(self(), {:flash, {:info, "Attendee removed and notified."}})
    end

    socket
    |> assign(:selected_event, updated_event)
    |> assign(:events, updated_events)
    |> assign(:confirm_remove_attendee, nil)
    |> Helpers.precompute_derived()
    |> Updates.update_attendees_async(event, new_attendees)
  end

  @spec handle_request_remove_attendee(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_request_remove_attendee(%{"email" => email}, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        case EditWorkflow.assert_owns_event(socket, event) do
          :ok ->
            {:noreply,
             assign(socket, :confirm_remove_attendee, %{email: email, event_id: event.id})}

          {:error, :unauthorized} = error ->
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
        case Shared.check_edit_rate_limit(socket) do
          :ok ->
            {:noreply, apply_remove_attendee(socket, event, email)}

          {:error, :rate_limited, _message} = error ->
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
