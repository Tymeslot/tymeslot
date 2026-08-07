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
  queue with an incremented `sync_attempts` and a human-readable
  description of the failure in `sync_last_error`. The next sync cycle
  retries automatically — there is no backoff beyond the sync cadence
  itself.

  A `412 Precondition Failed` response to a `locally_modified` flush
  follows the usual conflict-resolution policy (`:keep_local` for
  Tymeslot-owned events, `:fail` otherwise — the default is configured
  per row via `conflict_policy_for/1`).
  """

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Base, as: CalDAVBase
  alias Tymeslot.Integrations.Calendar.CalDAV.Errors, as: CalDAVErrors
  alias Tymeslot.Integrations.Calendar.CalDAV.Events
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema

  # `sync_last_error` is read by the account owner, so every value written to
  # it is a sentence. Transport failures get theirs from
  # `CalDAVErrors.describe_error/1`; the three below cover the local-state
  # failures that never reach the wire. They live as functions at the bottom of
  # this module rather than as module attributes: a `dgettext/2` call in an
  # attribute would freeze the locale at compile time.

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
    with {:ok, path} <- primary_path(integration),
         {:ok, event_data} <- sendable_event_data(row) do
      case Events.create_calendar_event(client, path, event_data, events_opts()) do
        {:ok, _uid} ->
          ProviderCalendarEventQueries.mark_synced(integration.id, row.uid, nil)
          log_success(row, :created)

        {:error, reason} ->
          record_failure(integration, row, :created, reason)
      end
    else
      {:error, reason} -> record_skip(integration, row, reason)
    end
  end

  defp flush_row(
         %ProviderCalendarEventSchema{sync_state: "locally_modified"} = row,
         integration,
         client
       ) do
    with {:ok, path} <- primary_path(integration),
         {:ok, event_data} <- sendable_event_data(row) do
      opts =
        events_opts() ++
          [
            etag: row.etag,
            conflict_resolution: conflict_policy_for(row)
          ]

      case Events.update_calendar_event(client, path, row.uid, event_data, opts) do
        :ok ->
          ProviderCalendarEventQueries.mark_synced(integration.id, row.uid, nil)
          log_success(row, :modified)

        {:error, reason} ->
          record_failure(integration, row, :modified, reason)
      end
    else
      {:error, reason} -> record_skip(integration, row, reason)
    end
  end

  defp flush_row(
         %ProviderCalendarEventSchema{sync_state: "locally_deleted"} = row,
         integration,
         client
       ) do
    case primary_path(integration) do
      {:error, reason} ->
        record_skip(integration, row, reason)

      {:ok, path} ->
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
    # The state itself is a developer detail, so it goes to the log; the row
    # records the attempt with a message the account owner can read.
    Logger.error("CalDAV offline queue row carries an unknown sync_state",
      calendar_integration_id: integration.id,
      uid: row.uid,
      sync_state: inspect(other)
    )

    ProviderCalendarEventQueries.mark_sync_failed(
      integration.id,
      row.uid,
      unsendable_change_message()
    )
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
      start_time: start_time(event),
      end_time: end_time(event),
      all_day: event.all_day,
      timezone: event.timezone,
      provider_event_id: event.provider_event_id
    }
  end

  # All-day events are modelled with `start_date`/`end_date` only, leaving
  # `start_at`/`end_at` NULL — the 20260408110831 migration dropped those
  # columns' NOT NULL constraints for exactly that reason. Reading `start_at`
  # unconditionally therefore yields `nil` for every all-day row, which
  # `ICalBuilder.Properties.build_dtstart/1` has no clause for. The `Date` is
  # what it wants regardless: it emits DATE-form DTSTART/DTEND from one.
  defp start_time(%{all_day: true, start_date: %Date{} = date}), do: date
  defp start_time(event), do: event.start_at

  defp end_time(%{all_day: true, end_date: %Date{} = date}), do: date
  defp end_time(event), do: event.end_at

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
      [path | _rest] when is_binary(path) -> {:ok, path}
      _other -> {:error, :no_primary_path}
    end
  end

  # `Events.create_calendar_event/4` and `update_calendar_event/5` build the
  # outgoing iCalendar payload via `ICalBuilder` *before* any HTTP call, and
  # `ICalBuilder.Properties.build_dtstart/1` has no clause for a missing start
  # time. A cache row written without one therefore raises `FunctionClauseError`
  # rather than returning an error tuple, which would crash the whole sync job.
  # Since `flush/2` runs before the remote fetch, that also blocks every other
  # queued row and the integration's own remote sync behind it — and because
  # the row is replayed every cycle, it never clears on its own.
  #
  # No retry can make such a row sendable, so it is skipped permanently
  # instead: the owner sees why on the row, and the rest of the sync proceeds.
  defp sendable_event_data(%ProviderCalendarEventSchema{} = row) do
    event_data = row_to_event_data(row)

    if usable_time?(event_data.start_time) and usable_time?(event_data.end_time) do
      {:ok, event_data}
    else
      {:error, :incomplete_event_data}
    end
  end

  defp usable_time?(%DateTime{}), do: true
  defp usable_time?(%Date{}), do: true
  defp usable_time?(_other), do: false

  defp skip_message(:no_primary_path), do: no_primary_path_message()
  defp skip_message(:incomplete_event_data), do: incomplete_event_message()

  # The log keeps the raw term for diagnosis; `sync_last_error` is a
  # user-facing column, so it gets the sentence from `CalDAVErrors.describe_error/1`
  # rather than an inspected atom.
  defp record_failure(integration, row, operation, reason) do
    Logger.warning("CalDAV offline queue replay failed",
      calendar_integration_id: integration.id,
      uid: row.uid,
      operation: operation,
      error: format_reason(reason)
    )

    ProviderCalendarEventQueries.mark_sync_failed(
      integration.id,
      row.uid,
      CalDAVErrors.describe_error(reason)
    )
  end

  defp record_skip(integration, row, reason) do
    Logger.warning("CalDAV offline queue replay skipped",
      calendar_integration_id: integration.id,
      uid: row.uid,
      reason: reason
    )

    ProviderCalendarEventQueries.mark_sync_failed(integration.id, row.uid, skip_message(reason))
  end

  defp log_success(row, operation) do
    Logger.info("CalDAV offline queue replay succeeded",
      uid: row.uid,
      operation: operation
    )
  end

  defp format_reason(reason) when is_binary(reason), do: reason
  defp format_reason(reason), do: inspect(reason)

  defp no_primary_path_message do
    dgettext(
      "dashboard_calendar_providers",
      "No calendar is selected for this connection, so the change could not be sent to the calendar server."
    )
  end

  defp unsendable_change_message do
    dgettext(
      "dashboard_calendar_providers",
      "Tymeslot could not send this change to the calendar server."
    )
  end

  defp incomplete_event_message do
    dgettext(
      "dashboard_calendar_providers",
      "This change is missing the event's start or end time, so it could not be sent to the calendar server."
    )
  end
end
