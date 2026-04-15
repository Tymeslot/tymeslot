defmodule Tymeslot.Integrations.Calendar.CalDAV.OfflineQueue do
  @moduledoc """
  Replays locally-modified cache rows to the remote CalDAV server.

  Called at the start of every CalDAV sync cycle, **before** fetching
  remote changes. This ordering ensures local edits reach the server
  first so a subsequent pull cannot clobber them.

  ## Queue model

  Each row in `provider_calendar_events` carries a `sync_state` column
  set by the code that writes the row:

    * `"synced"`           — no pending work, skipped by the flush
    * `"locally_created"`  — PUT with `If-None-Match: *`
    * `"locally_modified"` — PUT with `If-Match: <cached etag>`
    * `"locally_deleted"`  — DELETE

  ## Success / failure

  On success the row is marked `"synced"` (or the cache row is deleted
  for a successful `locally_deleted`). On failure the row stays in the
  queue with an incremented `sync_attempts` and the formatted error in
  `sync_last_error`. The next sync cycle retries automatically — there
  is no backoff beyond the sync cadence itself.

  A `412 Precondition Failed` response to a `locally_modified` flush
  follows the usual conflict-resolution policy (`:keep_local` for
  Tymeslot-owned events, `:fail` otherwise — the default is configured
  per row via `conflict_policy_for/1`).
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Base, as: CalDAVBase
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  @spec flush(map(), CalDAVBase.client()) :: :ok
  def flush(integration, client) do
    integration.id
    |> ProviderCalendarEventQueries.list_pending()
    |> Enum.each(&flush_row(&1, integration, client))

    :ok
  end

  # ---------------------------------------------------------------------------
  # Per-row replay
  # ---------------------------------------------------------------------------

  defp flush_row(
         %ProviderCalendarEventSchema{sync_state: "locally_created"} = row,
         integration,
         client
       ) do
    case primary_path(integration) do
      nil ->
        record_skip(integration, row, "no primary calendar path")

      path ->
        case Events.create_calendar_event(client, path, row_to_event_data(row), events_opts()) do
          {:ok, _uid} ->
            ProviderCalendarEventQueries.mark_synced(integration.id, row.uid, nil)
            log_success(row, :created)

          {:error, reason} ->
            record_failure(integration, row, :created, reason)
        end
    end
  end

  defp flush_row(
         %ProviderCalendarEventSchema{sync_state: "locally_modified"} = row,
         integration,
         client
       ) do
    case primary_path(integration) do
      nil ->
        record_skip(integration, row, "no primary calendar path")

      path ->
        opts =
          events_opts() ++
            [
              etag: row.etag,
              conflict_resolution: conflict_policy_for(row)
            ]

        case Events.update_calendar_event(client, path, row.uid, row_to_event_data(row), opts) do
          :ok ->
            ProviderCalendarEventQueries.mark_synced(integration.id, row.uid, nil)
            log_success(row, :modified)

          {:error, reason} ->
            record_failure(integration, row, :modified, reason)
        end
    end
  end

  defp flush_row(
         %ProviderCalendarEventSchema{sync_state: "locally_deleted"} = row,
         integration,
         client
       ) do
    case primary_path(integration) do
      nil ->
        record_skip(integration, row, "no primary calendar path")

      path ->
        case Events.delete_calendar_event(client, path, row.uid, events_opts()) do
          :ok ->
            ProviderCalendarEventQueries.delete_by_uid(integration.id, row.uid)
            log_success(row, :deleted)

          # Already gone on the server — finish the local delete regardless.
          {:error, :not_found} ->
            ProviderCalendarEventQueries.delete_by_uid(integration.id, row.uid)
            log_success(row, :deleted)

          {:error, reason} ->
            record_failure(integration, row, :deleted, reason)
        end
    end
  end

  defp flush_row(%ProviderCalendarEventSchema{sync_state: other} = row, integration, _client) do
    # Defensive: an unknown sync_state string should never reach the queue.
    # Mark the attempt so it's visible in dashboards and continue.
    record_failure(integration, row, :unknown, "unknown sync_state: #{inspect(other)}")
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp row_to_event_data(%ProviderCalendarEventSchema{} = row) do
    event = ProviderCalendarEventSchema.to_calendar_event(row)

    %{
      uid: event.uid,
      summary: event.summary,
      description: event.description,
      location: event.location,
      start_time: event.start_at,
      end_time: event.end_at,
      all_day: event.all_day,
      timezone: event.timezone,
      provider_event_id: event.provider_event_id
    }
  end

  defp conflict_policy_for(%ProviderCalendarEventSchema{created_by_tymeslot: true}),
    do: :keep_local

  defp conflict_policy_for(_row), do: :fail

  # The OfflineQueue runs inside an Oban worker which already rate-limits
  # by the sync cadence, so we bypass the per-operation circuit breaker.
  # Using the breaker here would also push the HTTP call into a separate
  # process, breaking Req.Test stub visibility in unit tests.
  defp events_opts, do: [skip_breaker: true]

  defp primary_path(integration) do
    case integration.calendar_paths do
      [path | _rest] when is_binary(path) -> path
      _other -> nil
    end
  end

  defp record_failure(integration, row, operation, reason) do
    reason_str = format_reason(reason)

    Logger.warning("CalDAV offline queue replay failed",
      calendar_integration_id: integration.id,
      uid: row.uid,
      operation: operation,
      error: reason_str
    )

    ProviderCalendarEventQueries.mark_sync_failed(integration.id, row.uid, reason_str)
  end

  defp record_skip(integration, row, reason) do
    Logger.warning("CalDAV offline queue replay skipped",
      calendar_integration_id: integration.id,
      uid: row.uid,
      reason: reason
    )

    ProviderCalendarEventQueries.mark_sync_failed(integration.id, row.uid, reason)
  end

  defp log_success(row, operation) do
    Logger.info("CalDAV offline queue replay succeeded",
      uid: row.uid,
      operation: operation
    )
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)
end
