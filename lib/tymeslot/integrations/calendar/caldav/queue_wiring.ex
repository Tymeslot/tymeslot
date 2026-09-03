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
  alias Tymeslot.Integrations.CalendarManagement

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
         true <- caldav_provider?(integration),
         [_head | _tail] <- integration.calendar_paths do
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

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
        {:error, :requires_reencryption}
    end
  end

  defp caldav_provider?(%{provider: provider}) when is_binary(provider) do
    provider in ProviderConfig.caldav_based_provider_strings()
  end

  defp build_attrs(meeting, integration, action, event_data) do
    now = DateTime.utc_now(:microsecond)
    sync_state = sync_state_for(action)
    event_data = normalize_event_data(event_data)
    {all_day, start_at, end_at} = resolve_timing(event_data)

    %{
      uid: meeting.uid,
      calendar_integration_id: integration.id,
      provider: integration.provider,
      provider_calendar_id: List.first(integration.calendar_paths),
      summary: event_data[:summary],
      description: event_data[:description],
      location: event_data[:location],
      timezone: event_data[:timezone],
      all_day: all_day,
      start_at: start_at,
      end_at: end_at,
      status: status_string(event_data[:status]),
      transparency: transparency_string(event_data[:transparency]),
      synced_at: now,
      sync_state: sync_state,
      sync_last_attempt_at: now,
      created_by_tymeslot: true
    }
  end

  defp sync_state_for(:create), do: "locally_created"
  defp sync_state_for(:update), do: "locally_modified"
  defp sync_state_for(:delete), do: "locally_deleted"

  # `event_data[:status]` carries the held-request marker
  # (`CalendarEventBuilder.build_event_data/1` sets `:tentative` for a
  # meeting still awaiting approval). Losing it here is what let a replayed
  # offline-queue write land as an ordinary confirmed event on the host's
  # calendar for a request nobody had approved yet.
  defp status_string(nil), do: "confirmed"
  defp status_string(status) when is_atom(status), do: Atom.to_string(status)
  defp status_string(status) when is_binary(status), do: status

  defp transparency_string(nil), do: "opaque"

  defp transparency_string(transparency) when is_atom(transparency),
    do: Atom.to_string(transparency)

  defp transparency_string(transparency) when is_binary(transparency), do: transparency

  # `event_data` is documented as the atom-keyed map `CalendarEventBuilder`
  # produces, but it can also arrive from a payload that has been through JSON
  # and so carries string keys. Answer the question once, here, rather than at
  # every read below.
  @event_data_keys ~w(summary description location timezone start_time end_time)a

  defp normalize_event_data(event_data) when is_map(event_data) do
    Enum.reduce(@event_data_keys, event_data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> Map.put(acc, key, Map.get(acc, Atom.to_string(key)))
        _present -> acc
      end
    end)
  end

  defp resolve_timing(event_data) do
    start = event_data[:start_time]
    end_val = event_data[:end_time]

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
