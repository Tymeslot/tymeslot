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

    cache_row =
      build_cache_row(original_event, %{
        start_at: new_start,
        end_at: new_end,
        start_date: optimistic_event.start_date,
        end_date: optimistic_event.end_date,
        all_day: optimistic_event.all_day,
        summary: optimistic_event.summary,
        location: optimistic_event.location || original_event.location,
        description: optimistic_event.description || original_event.description
      })

    run_update_async(socket, original_event, event_data, cache_row)
  end

  @spec update_field_async(Phoenix.LiveView.Socket.t(), map(), atom(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def update_field_async(socket, original_event, field, new_value)
      when field in [:summary, :location, :description] do
    event_data = build_field_event_data(original_event, field, new_value)
    cache_row = build_field_cache_row(original_event, field, new_value)

    run_update_async(socket, original_event, event_data, cache_row)
  end

  @doc """
  Pushes an all-day toggle (or all-day date-range change) to the provider.

  `optimistic_event` carries the post-toggle state: when `all_day` is true its
  `start_date`/`end_date` drive a date-only provider write; when false its
  `start_at`/`end_at` drive a timed write. The provider mappers emit the correct
  date-only or datetime representation from the `start_time`/`end_time` value
  (a `Date` for all-day, a `DateTime` for timed).
  """
  @spec toggle_all_day_async(Phoenix.LiveView.Socket.t(), map(), map()) ::
          Phoenix.LiveView.Socket.t()
  def toggle_all_day_async(socket, original_event, optimistic_event) do
    event_data = build_all_day_event_data(optimistic_event)
    cache_row = build_cache_row(optimistic_event, %{})

    run_update_async(socket, original_event, event_data, cache_row)
  end

  @doc """
  Pushes a reminder-list change to the provider.

  Reminders are synced to the provider only — Tymeslot never fires the
  notification itself. The provider mappers serialise `:reminders` into Google
  overrides, Outlook's single `reminderMinutesBeforeStart`, or CalDAV VALARMs.
  """
  @spec update_reminders_async(Phoenix.LiveView.Socket.t(), map(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def update_reminders_async(socket, event, reminders) do
    event_data =
      event
      |> base_timing_event_data()
      |> Map.put(:reminders, reminders)

    cache_row = build_cache_row(event, %{reminders: reminders})

    run_update_async(socket, event, event_data, cache_row)
  end

  @doc """
  Pushes a recurrence-rule change to the provider.

  The `recurrence_rule` is the canonical RRULE string (or `nil` to clear the
  rule). `recurrence_scope` (`"this"`, `"following"`, `"all"`) is forwarded when
  the edit applies to an existing recurring series, so the provider knows which
  occurrences the rule change affects. The provider mappers serialise the rule
  into Google's `recurrence` list, Outlook's pattern/range object, or a CalDAV
  RRULE line.
  """
  @spec update_recurrence_async(Phoenix.LiveView.Socket.t(), map(), String.t() | nil, keyword()) ::
          Phoenix.LiveView.Socket.t()
  def update_recurrence_async(socket, event, recurrence_rule, opts \\ []) do
    recurrence_scope = Keyword.get(opts, :recurrence_scope)

    event_data =
      event
      |> base_timing_event_data()
      |> Map.put(:recurrence_rule, recurrence_rule)
      |> maybe_put_scope(recurrence_scope)

    cache_row = build_cache_row(event, %{recurrence_rule: recurrence_rule})

    run_update_async(socket, event, event_data, cache_row)
  end

  defp maybe_put_scope(event_data, nil), do: event_data
  defp maybe_put_scope(event_data, scope), do: Map.put(event_data, :recurrence_scope, scope)

  @doc """
  Pushes a per-event colour override to the provider.

  `colour` is a Tymeslot palette key (e.g. `"tomato"`) or `nil` to clear the
  override. The provider mappers translate the key into Google's `colorId` or
  CalDAV's `COLOR` property at the boundary; `nil` leaves the provider's colour
  untouched. The unchanged timing is always sent so the provider write is valid.
  """
  @spec update_colour_async(Phoenix.LiveView.Socket.t(), map(), String.t() | nil) ::
          Phoenix.LiveView.Socket.t()
  def update_colour_async(socket, event, colour) do
    event_data =
      event
      |> base_timing_event_data()
      |> Map.put(:colour, colour)

    cache_row = build_cache_row(event, %{colour: colour})

    run_update_async(socket, event, event_data, cache_row)
  end

  @spec update_attendees_async(Phoenix.LiveView.Socket.t(), map(), [map()]) ::
          Phoenix.LiveView.Socket.t()
  def update_attendees_async(socket, event, attendees) do
    event_data = %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id,
      attendees: attendees
    }

    cache_row = build_cache_row(event, %{attendees: attendees})

    run_update_async(socket, event, event_data, cache_row)
  end

  # Runs a provider update in a supervised Task, then refreshes the cache and
  # reports the outcome to the LiveView. On failure it tags the event for
  # offline retry (CalDAV) and reports the error. Shared by every async update
  # that has already precomputed its `event_data` and `cache_row`.
  defp run_update_async(socket, original_event, event_data, cache_row) do
    user_id = socket.assigns.current_user.id
    lv_pid = self()

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

  # Provider event_data carrying the event's current timing (date-only for
  # all-day, datetime for timed). Used by updates that change a non-timing field
  # (e.g. reminders) but must still send the unchanged times to the provider.
  defp base_timing_event_data(event), do: build_all_day_event_data(event)

  defp build_all_day_event_data(%{all_day: true} = event) do
    %{
      summary: event.summary || "",
      start_time: event.start_date,
      end_time: event.end_date,
      all_day: true,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }
  end

  defp build_all_day_event_data(event) do
    %{
      summary: event.summary || "",
      start_time: event.start_at,
      end_time: event.end_at,
      all_day: false,
      description: event.description || "",
      location: event.location || "",
      provider_event_id: event.provider_event_id
    }
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
    build_cache_row(event, %{field => new_value})
  end

  # Builds a cache row from a canonical event source, applying `overrides` last.
  # Timing keys (`start_at`/`end_at` vs `start_date`/`end_date`) follow the
  # `all_day` flag of the resulting row (override-aware), so a toggle that flips
  # `all_day` and supplies the new timing keys produces a consistent row.
  defp build_cache_row(event, overrides) do
    all_day = Map.get(overrides, :all_day, event.all_day)

    timing =
      if all_day do
        %{
          start_date: Map.get(overrides, :start_date, event.start_date),
          end_date: Map.get(overrides, :end_date, event.end_date),
          start_at: nil,
          end_at: nil
        }
      else
        %{
          start_at: Map.get(overrides, :start_at, event.start_at),
          end_at: Map.get(overrides, :end_at, event.end_at),
          start_date: nil,
          end_date: nil
        }
      end

    base = %{
      uid: event.uid,
      calendar_integration_id: event.calendar_integration_id,
      provider: event.provider,
      provider_calendar_id: event.provider_calendar_id,
      provider_event_id: event.provider_event_id,
      summary: event.summary,
      all_day: all_day,
      location: event.location,
      description: event.description,
      colour: Map.get(event, :colour),
      attendees: event.attendees || [],
      reminders: event.reminders || [],
      recurrence_rule: event.recurrence_rule,
      status: event.status,
      provider_metadata: event.provider_metadata,
      synced_at: DateTime.utc_now(:microsecond)
    }

    base
    |> Map.merge(overrides)
    |> Map.merge(timing)
  end
end
