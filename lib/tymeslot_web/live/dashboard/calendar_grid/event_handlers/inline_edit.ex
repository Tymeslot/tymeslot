defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEdit do
  @moduledoc "Inline edit event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Meetings.AttendeeNotifications
  alias Tymeslot.Security.UniversalSanitizer
  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared
  alias TymeslotWeb.Dashboard.CalendarGrid.Helpers

  @spec handle_show_event(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_show_event(%{"event-id" => id_str}, socket) do
    case Shared.parse_int(id_str) do
      {:ok, event_id} ->
        event = Enum.find(socket.assigns.events, &(&1.id == event_id))
        pending? = event != nil and AttendeeNotifications.pending?(event.id)

        {:noreply,
         socket
         |> assign(:selected_event, event)
         |> assign(:pending_attendees, [])
         |> assign(:attendee_input, "")
         |> assign(:pending_notification, pending?)}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_close_event_detail(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_event_detail(_params, socket) do
    sub_modal_open =
      socket.assigns.confirm_remove_attendee != nil or
        socket.assigns.confirm_discard_attendees

    cond do
      sub_modal_open ->
        {:noreply, socket}

      socket.assigns.pending_attendees != [] ->
        {:noreply, assign(socket, :confirm_discard_attendees, true)}

      true ->
        {:noreply,
         socket
         |> assign(:selected_event, nil)
         |> assign(:attendee_input, "")}
    end
  end

  @spec handle_update_event_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_title(%{"value" => new_value}, socket),
    do: handle_update_event_field(:summary, 500, new_value, socket)

  @spec handle_update_edit_video(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_edit_video(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        new_id = parse_video_integration_id(params["video_integration_id"])
        updated_event = Map.put(event, :video_integration_id, new_id)
        {:noreply, assign(socket, :selected_event, updated_event)}
    end
  end

  defp parse_video_integration_id(nil), do: nil
  defp parse_video_integration_id(""), do: nil

  defp parse_video_integration_id(val) when is_binary(val) do
    case Integer.parse(val) do
      {int, ""} -> int
      _other -> nil
    end
  end

  defp parse_video_integration_id(val) when is_integer(val), do: val
  defp parse_video_integration_id(_other), do: nil

  @spec handle_update_event_location(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_location(%{"value" => new_value}, socket),
    do: handle_update_event_field(:location, 1000, new_value, socket)

  @spec handle_update_event_description(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_description(%{"value" => new_value}, socket),
    do: handle_update_event_field(:description, 5000, new_value, socket)

  @spec handle_update_event_time(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_time(params, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        tz = socket.assigns.user_timezone

        with {:ok, start_date} <- Date.from_iso8601(params["start-date"]),
             {:ok, start_time} <- Time.from_iso8601(normalize_time(params["start-time"])),
             {:ok, end_date} <- Date.from_iso8601(params["end-date"]),
             {:ok, end_time} <- Time.from_iso8601(normalize_time(params["end-time"])),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          new_start = Shared.to_utc(start_date, start_time.hour, start_time.minute, tz)
          raw_end = Shared.to_utc(end_date, end_time.hour, end_time.minute, tz)
          apply_time_change(socket, event, new_start, raw_end)
        else
          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          _error ->
            {:noreply, socket}
        end
    end
  end

  @spec handle_update_event_calendar(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_calendar(params, socket) do
    id_str = params["integration-id"] || params["integration_id"]
    cal_id = params["calendar-id"]

    case {socket.assigns.selected_event, Shared.parse_int(id_str)} do
      {nil, _parsed_id} ->
        {:noreply, socket}

      {event, {:ok, new_id}} when new_id == event.calendar_integration_id and is_nil(cal_id) ->
        {:noreply, socket}

      {event, {:ok, new_id}} ->
        with :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_move_rate_limit(socket) do
          updated_event = %{event | calendar_integration_id: new_id}

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()
            |> EditWorkflow.move_event_async(event, new_id, calendar_id: cal_id)

          {:noreply, socket}
        else
          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to move this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many moves. Please wait a moment."}})
            {:noreply, socket}
        end

      _unmatched ->
        {:noreply, socket}
    end
  end

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

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          {:ok, _result} =
            AttendeeNotifications.attendees_added(event, [%{email: email, name: nil}])

          send(self(), {:flash, {:info, "Attendee added and invited."}})

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> assign(:attendee_input, "")
            |> Helpers.precompute_derived()
            |> EditWorkflow.update_attendees_async(event, new_attendees)

          {:noreply, socket}
        else
          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          _invalid ->
            {:noreply, socket}
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

    updated_events =
      Enum.map(socket.assigns.events, fn e ->
        if e.id == event.id, do: updated_event, else: e
      end)

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
    |> EditWorkflow.update_attendees_async(event, new_attendees)
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

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}
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

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, assign(socket, :confirm_remove_attendee, nil)}
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

  defp handle_update_event_field(field, max_length, new_value, socket) do
    case socket.assigns.selected_event do
      nil ->
        {:noreply, socket}

      event ->
        with {:ok, sanitised} <-
               UniversalSanitizer.sanitize_and_validate(new_value, max_length: max_length),
             trimmed = String.trim(sanitised),
             false <- trimmed == (Map.get(event, field) || ""),
             :ok <- EditWorkflow.assert_owns_event(socket, event),
             :ok <- Shared.check_edit_rate_limit(socket) do
          updated_event = Map.put(event, field, trimmed)

          updated_events =
            Enum.map(socket.assigns.events, fn e ->
              if e.id == event.id, do: updated_event, else: e
            end)

          socket =
            socket
            |> assign(:selected_event, updated_event)
            |> assign(:events, updated_events)
            |> Helpers.precompute_derived()
            |> EditWorkflow.update_field_async(event, field, trimmed)

          {:noreply, apply_notify_result(socket, event, updated_event)}
        else
          true ->
            {:noreply, socket}

          {:error, :unauthorized} ->
            send(self(), {:flash, {:error, "You don't have permission to modify this event"}})
            {:noreply, socket}

          {:error, :rate_limited, _message} ->
            send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
            {:noreply, socket}

          {:error, reason} when is_binary(reason) ->
            send(self(), {:flash, {:error, "Input too long"}})
            {:noreply, socket}
        end
    end
  end

  defp normalize_time(t) when byte_size(t) == 5, do: t <> ":00"
  defp normalize_time(t), do: t

  defp apply_time_change(socket, event, _new_start, _raw_end) when event.all_day == true do
    send(self(), {:flash, {:info, "Time editing is not available for all-day events."}})
    {:noreply, socket}
  end

  defp apply_time_change(socket, event, new_start, raw_end) do
    original_duration = DateTime.diff(event.end_at, event.start_at, :second)

    new_end =
      if DateTime.compare(raw_end, new_start) != :gt do
        DateTime.add(new_start, max(original_duration, 900), :second)
      else
        raw_end
      end

    if DateTime.compare(new_start, event.start_at) == :eq and
         DateTime.compare(new_end, event.end_at) == :eq do
      {:noreply, socket}
    else
      optimistic_event = %{event | start_at: new_start, end_at: new_end}

      socket =
        socket
        |> assign(:selected_event, optimistic_event)
        |> EditWorkflow.apply_event_change(event, optimistic_event, new_start, new_end)

      {:noreply, apply_notify_result(socket, event, optimistic_event)}
    end
  end

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

  defp apply_notify_result(socket, original_event, updated_event) do
    socket = EditWorkflow.sync_video_integration_async(socket, original_event, updated_event)

    attendees = updated_event.attendees || original_event.attendees || []

    case EditWorkflow.notify_event_updated(original_event, updated_event, attendees) do
      {:ok, :no_changes} ->
        send(self(), {:flash, {:info, "Changes saved."}})
        socket

      {:ok, :already_pending} ->
        send(self(), {:flash, {:info, "Changes saved. Attendees will be notified shortly."}})
        assign(socket, :pending_notification, true)

      {:needs_confirmation, summary} ->
        assign(socket, :notify_prompt, %{
          kind: :update,
          summary: summary,
          event: updated_event,
          attendees: attendees
        })
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
