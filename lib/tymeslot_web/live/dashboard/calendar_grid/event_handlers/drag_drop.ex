defmodule TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.DragDrop do
  @moduledoc "Drag-drop and resize event handlers for CalendarGridComponent."

  alias TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow
  alias TymeslotWeb.Dashboard.CalendarGrid.EventHandlers.Shared

  @spec handle_event_dropped(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_dropped(params, socket) do
    EditWorkflow.with_editable_event(socket, params, fn event ->
      case Shared.check_edit_rate_limit(socket) do
        :ok ->
          tz = socket.assigns.user_timezone

          with {:ok, new_date, new_hour, new_minute, end_date, end_hour, end_minute} <-
                 parse_drop_params(params),
               {:ok, new_start} <- Shared.to_utc(new_date, new_hour, new_minute, tz),
               {:ok, new_end} <- Shared.to_utc(end_date, end_hour, end_minute, tz) do
            optimistic_event = %{event | start_at: new_start, end_at: new_end}
            EditWorkflow.apply_event_change(socket, event, optimistic_event, new_start, new_end)
          else
            error -> drop_failure(error, socket)
          end

        {:error, :rate_limited, _message} ->
          send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
          socket
      end
    end)
  end

  @spec handle_event_resized(map(), Phoenix.LiveView.Socket.t()) ::
          {:noreply, Phoenix.LiveView.Socket.t()}
  def handle_event_resized(params, socket) do
    EditWorkflow.with_editable_event(socket, params, fn event ->
      case Shared.check_edit_rate_limit(socket) do
        :ok ->
          tz = socket.assigns.user_timezone

          with {:ok, event_date} <- Date.from_iso8601(params["event-date"]),
               {:ok, raw_end_hour} <- Shared.parse_int(params["new-end-hour"]),
               {:ok, new_end_minute} <- Shared.parse_int(params["new-end-minute"]),
               {end_date, end_hour, end_minute} =
                 Shared.clamp_end_time(event_date, raw_end_hour, new_end_minute),
               {:ok, new_end} <- Shared.to_utc(end_date, end_hour, end_minute, tz) do
            optimistic_event = %{event | end_at: new_end}

            EditWorkflow.apply_event_change(
              socket,
              event,
              optimistic_event,
              event.start_at,
              new_end
            )
          else
            error -> drop_failure(error, socket)
          end

        {:error, :rate_limited, _message} ->
          send(self(), {:flash, {:warning, "Too many edits. Please wait a moment."}})
          socket
      end
    end)
  end

  # Parses the raw drop coordinates and clamps the end time, returning the
  # resolved start/end components. Keeps the caller's `with` chain flat.
  defp parse_drop_params(params) do
    with {:ok, new_date} <- Date.from_iso8601(params["new-date"]),
         {:ok, new_hour} <- Shared.parse_int(params["new-hour"]),
         {:ok, new_minute} <- Shared.parse_int(params["new-minute"]),
         {:ok, raw_end_hour} <- Shared.parse_int(params["new-end-hour"]),
         {:ok, new_end_minute} <- Shared.parse_int(params["new-end-minute"]) do
      {end_date, end_hour, end_minute} =
        Shared.clamp_end_time(new_date, raw_end_hour, new_end_minute)

      {:ok, new_date, new_hour, new_minute, end_date, end_hour, end_minute}
    end
  end

  # Maps a failed drag/resize `with` clause to the resulting socket. Malformed
  # params (`:error`) are silently ignored — the event simply stays put.
  defp drop_failure(_other, socket), do: socket
end
