defmodule Tymeslot.Integrations.Calendar.CalDAV.QueueWiring do
  @moduledoc """
  Tags `provider_calendar_events` cache rows with a `sync_state` value so
  `OfflineQueue.flush/2` can replay a failed write on the next sync cycle.

  Sits between the domain (`CalendarEventWorker`, booking flows) and the
  cache table. Callers describe _what_ they tried to do — create, update,
  delete a meeting — and this module writes the correct queue marker
  provided the target integration is a CalDAV-family provider.

  Non-CalDAV providers (Google, Outlook) are silently no-op'd: they have
  their own retry surface and no offline queue reads from this table.

  ## Idempotency

  `tag/3` and `clear/2` are idempotent. Calling `tag/3` twice results in
  one cache row with the most recent `sync_state`. Calling `clear/2`
  when the row is already `synced` (or absent) is a no-op. This lets the
  worker call `clear/2` unconditionally on success without checking
  prior state.

  ## Semantics of each action

    * `:create` → `sync_state: "locally_created"`; row carries the full
                  `event_data` so `OfflineQueue` can reconstruct the PUT.
    * `:update` → `sync_state: "locally_modified"`; same payload.
    * `:delete` → `sync_state: "locally_deleted"`; minimum fields only —
                  a DELETE only needs the uid and the cached href.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  @type action :: :create | :update | :delete
  @type meeting :: %{
          :uid => String.t(),
          :calendar_integration_id => integer(),
          optional(atom()) => term()
        }

  @doc """
  Tags a cache row for offline retry.

  `event_data` is the map produced by
  `Tymeslot.Integrations.Calendar.CalendarEventBuilder.build_event_data/1`
  and carries the fields `OfflineQueue` will need to reconstruct the
  CalDAV write: `summary`, `start_time`, `end_time`, `location`, `timezone`.

  Returns `:ok` on success, or `:ignored` when the meeting's integration
  is not a CalDAV-family provider. Never raises.
  """
  @spec tag(meeting(), action(), map()) :: :ok | :ignored
  def tag(%{calendar_integration_id: nil}, _action, _event_data), do: :ignored

  def tag(%{calendar_integration_id: integration_id} = meeting, action, event_data) do
    with {:ok, integration} <- fetch_integration(integration_id),
         true <- caldav_provider?(integration) do
      attrs = build_attrs(meeting, integration, action, event_data)
      _result = ProviderCalendarEventQueries.upsert_queue_entry(attrs)

      Logger.info("CalDAV queue wiring tagged cache row for offline retry",
        calendar_integration_id: integration_id,
        uid: meeting.uid,
        action: action
      )

      :ok
    else
      _not_caldav -> :ignored
    end
  end

  @doc """
  Clears a previously-tagged cache row back to `"synced"`.

  Called from the worker's success path so a row tagged on a transient
  failure earlier in the same Oban run is untagged once the retry
  succeeds. Matches on `(integration_id, uid)` and updates only if the
  row exists — a missing row is a no-op.

  Returns `:ok` regardless of outcome.
  """
  @spec clear(meeting(), String.t() | nil) :: :ok
  def clear(%{calendar_integration_id: nil}, _etag), do: :ok

  def clear(%{calendar_integration_id: integration_id, uid: uid}, etag) do
    _result = ProviderCalendarEventQueries.mark_synced(integration_id, uid, etag)
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp fetch_integration(integration_id) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        {:ok, integration}

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  defp caldav_provider?(%{provider: provider}) when is_binary(provider) do
    atom =
      try do
        String.to_existing_atom(provider)
      rescue
        ArgumentError -> nil
      end

    atom in ProviderConfig.caldav_based_providers()
  end

  defp build_attrs(meeting, integration, action, event_data) do
    now = DateTime.utc_now(:microsecond)
    sync_state = sync_state_for(action)
    {all_day, start_at, end_at} = resolve_timing(event_data)

    %{
      uid: meeting.uid,
      calendar_integration_id: integration.id,
      provider: integration.provider,
      provider_calendar_id: List.first(integration.calendar_paths),
      summary: event_data[:summary] || event_data["summary"],
      description: event_data[:description] || event_data["description"],
      location: event_data[:location] || event_data["location"],
      timezone: event_data[:timezone] || event_data["timezone"],
      all_day: all_day,
      start_at: start_at,
      end_at: end_at,
      status: "confirmed",
      transparency: "opaque",
      synced_at: now,
      sync_state: sync_state,
      sync_last_attempt_at: now,
      created_by_tymeslot: true
    }
  end

  defp sync_state_for(:create), do: "locally_created"
  defp sync_state_for(:update), do: "locally_modified"
  defp sync_state_for(:delete), do: "locally_deleted"

  defp resolve_timing(event_data) do
    start = event_data[:start_time] || event_data["start_time"]
    end_val = event_data[:end_time] || event_data["end_time"]

    case {start, end_val} do
      {%DateTime{} = s, %DateTime{} = e} -> {false, ensure_usec(s), ensure_usec(e)}
      {%DateTime{} = s, nil} -> {false, ensure_usec(s), nil}
      _other -> {false, nil, nil}
    end
  end

  defp ensure_usec(%DateTime{microsecond: {_us, 6}} = dt), do: dt

  defp ensure_usec(%DateTime{} = dt) do
    {us, _precision} = dt.microsecond
    %{dt | microsecond: {us, 6}}
  end
end
