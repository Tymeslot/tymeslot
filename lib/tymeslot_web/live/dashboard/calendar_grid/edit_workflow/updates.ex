defmodule TymeslotWeb.Dashboard.CalendarGrid.EditWorkflow.Updates do
  @moduledoc "Async update operations for events: timing, fields, and attendees."

  alias Tymeslot.CalendarGrid
  alias Tymeslot.Integrations.Calendar.Events, as: CalendarEvents
  alias Tymeslot.Integrations.Calendar.Operations, as: EventOperations

  @spec update_event_async(
          Phoenix.LiveView.Socket.t(),
          map(),
          map(),
          DateTime.t(),
          DateTime.t(),
          keyword()
        ) ::
          Phoenix.LiveView.Socket.t()
  def update_event_async(socket, original_event, optimistic_event, new_start, new_end, opts \\ []) do
    recurrence_scope = Keyword.get(opts, :recurrence_scope)
    user_id = socket.assigns.current_user.id
    lv_pid = self()

    base_event_data = %{
      summary: optimistic_event.summary || "",
      start_time: new_start,
      end_time: new_end,
      description: optimistic_event.description || original_event.description || "",
      location: optimistic_event.location || original_event.location || "",
      provider_event_id: original_event.provider_event_id
    }

    event_data =
      if recurrence_scope do
        Map.put(base_event_data, :recurrence_scope, recurrence_scope)
      else
        base_event_data
      end

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        CalendarEvents.update_event(
          original_event.uid,
          event_data,
          {original_event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          timing =
            if optimistic_event.all_day do
              %{start_date: optimistic_event.start_date, end_date: optimistic_event.end_date}
            else
              %{start_at: new_start, end_at: new_end}
            end

          CalendarGrid.update_cached_event(
            Map.merge(timing, %{
              uid: original_event.uid,
              calendar_integration_id: original_event.calendar_integration_id,
              provider: original_event.provider,
              provider_calendar_id: original_event.provider_calendar_id,
              provider_event_id: original_event.provider_event_id,
              summary: optimistic_event.summary,
              all_day: optimistic_event.all_day,
              location: optimistic_event.location || original_event.location,
              description: optimistic_event.description || original_event.description,
              attendees: original_event.attendees || [],
              status: original_event.status,
              provider_metadata: original_event.provider_metadata,
              synced_at: DateTime.utc_now(:microsecond)
            })
          )

          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          tag_update_for_offline_retry(original_event, event_data)

          send(
            lv_pid,
            {:event_update_result, {:error, original_event: original_event, reason: reason}}
          )
      end
    end)

    socket
  end

  @spec update_field_async(Phoenix.LiveView.Socket.t(), map(), atom(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def update_field_async(socket, original_event, field, new_value)
      when field in [:summary, :location, :description] do
    user_id = socket.assigns.current_user.id
    lv_pid = self()
    event_data = build_field_event_data(original_event, field, new_value)
    cache_row = build_field_cache_row(original_event, field, new_value)

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        CalendarEvents.update_event(
          original_event.uid,
          event_data,
          {original_event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          CalendarGrid.update_cached_event(cache_row)
          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          tag_update_for_offline_retry(original_event, event_data)

          send(
            lv_pid,
            {:event_update_result, {:error, original_event: original_event, reason: reason}}
          )
      end
    end)

    socket
  end

  @spec update_attendees_async(Phoenix.LiveView.Socket.t(), map(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def update_attendees_async(socket, event, attendees) do
    user_id = socket.assigns.current_user.id
    lv_pid = self()

    event_data = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id,
      attendees: attendees
    }

    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    cache_row =
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: attendees,
        status: event.status,
        provider_metadata: event.provider_metadata,
        synced_at: DateTime.utc_now(:microsecond)
      })

    Task.Supervisor.start_child(Tymeslot.TaskSupervisor, fn ->
      result =
        CalendarEvents.update_event(
          event.uid,
          event_data,
          {event.calendar_integration_id, user_id}
        )

      case result do
        :ok ->
          CalendarGrid.update_cached_event(cache_row)
          send(lv_pid, {:event_update_result, :ok})

        {:error, reason} ->
          tag_update_for_offline_retry(event, event_data)

          send(
            lv_pid,
            {:event_update_result, {:error, original_event: event, reason: reason}}
          )
      end
    end)

    socket
  end

  # Tags the event's cache row as "locally_modified" so OfflineQueue.flush/2
  # retries the write on the next sync cycle. No-op for non-CalDAV
  # integrations — those have no offline queue and fall back to the
  # existing hard-error path.
  defp tag_update_for_offline_retry(event, event_data) do
    meeting = %{
      uid: event.uid,
      calendar_integration_id: event.calendar_integration_id
    }

    EventOperations.tag_for_offline_retry(meeting, :update, event_data)
  end

  defp build_field_event_data(event, field, new_value) do
    base = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }

    case field do
      :summary -> %{base | summary: new_value}
      :location -> %{base | location: new_value}
      :description -> %{base | description: new_value}
    end
  end

  defp build_field_cache_row(event, field, new_value) do
    timing =
      if event.all_day do
        %{start_date: event.start_date, end_date: event.end_date}
      else
        %{start_at: event.start_at, end_at: event.end_at}
      end

    base =
      Map.merge(timing, %{
        uid: event.uid,
        calendar_integration_id: event.calendar_integration_id,
        provider: event.provider,
        provider_calendar_id: event.provider_calendar_id,
        provider_event_id: event.provider_event_id,
        summary: event.summary,
        all_day: event.all_day,
        location: event.location,
        description: event.description,
        attendees: event.attendees || [],
        status: event.status,
        provider_metadata: event.provider_metadata,
        synced_at: DateTime.utc_now(:microsecond)
      })

    Map.put(base, field, new_value)
  end
end
