defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.InlineEdit do
  @moduledoc "Inline edit event handlers for CalendarGridComponent."

  import Phoenix.Component, only: [assign: 3]

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
        {:noreply, assign(socket, :selected_event, event)}

      :error ->
        {:noreply, socket}
    end
  end

  @spec handle_close_event_detail(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_close_event_detail(_params, socket) do
    {:noreply, assign(socket, :selected_event, nil)}
  end

  @spec handle_update_event_title(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_update_event_title(%{"value" => new_value}, socket),
    do: handle_update_event_field(:title, 500, new_value, socket)

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
             {:ok, start_time} <- Time.from_iso8601(params["start-time"] <> ":00"),
             {:ok, end_date} <- Date.from_iso8601(params["end-date"]),
             {:ok, end_time} <- Time.from_iso8601(params["end-time"] <> ":00"),
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

          {:noreply, EditWorkflow.update_field_async(socket, event, field, trimmed)}
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
      socket = assign(socket, :selected_event, optimistic_event)

      {:noreply,
       EditWorkflow.apply_event_change(socket, event, optimistic_event, new_start, new_end)}
    end
  end
end
