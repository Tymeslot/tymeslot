defmodule Tymeslot.Integrations.Calendar.CalDAV.Sync.EventFetch do
  @moduledoc """
  Fetches a window of events from CalDAV calendar paths and reconciles the
  result, including paths that have disappeared from the server.

  This is the path every sync tier eventually funnels into: Tier 3 uses it
  directly, Tier 2 falls back to it for a calendar whose CTag moved, and Tier 1
  for a calendar whose sync token expired or whose delta came without event
  data. Every tier walks the configured paths through `each_path/3`, so a
  missing calendar is handled the same way whichever tier found it.

  ## Missing paths

  A 404 on a calendar path is ambiguous, so the two cases are separated
  deliberately. The *booking* calendar (the first configured path) disappearing
  needs the account owner to pick a different one, so it surfaces as
  `:booking_calendar_missing`. Any other path disappearing is routine — the
  owner deleted a calendar they had merely subscribed to — and is handled by
  dropping it from the integration so it is not re-fetched, and re-404ed, on
  every subsequent sweep.
  """

  require Logger

  alias Tymeslot.Integrations.Calendar.CalDAV.Events, as: CalDAVEvents
  alias Tymeslot.Integrations.Calendar.CalDAV.Sync.State
  alias Tymeslot.Integrations.Calendar.CalDAV.SyncReconciler
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.ProviderConfig

  # How far back and forward to fetch events on a full sync.
  # Centralised in ProviderConfig so all providers use the same window.
  @sync_window_past_days ProviderConfig.sync_window_past_days()
  @sync_window_future_days ProviderConfig.sync_window_future_days()

  @typedoc """
  Outcome of a fetch. `:booking_calendar_missing` and `:unauthorized` are
  reported rather than acted on: deciding what they mean for the job is the
  caller's business.
  """
  @type result :: :ok | {:error, term()}

  @doc """
  Fetches every configured path in full, then reconciles any that went
  missing.
  """
  @spec fetch_paths(struct(), map()) :: result()
  def fetch_paths(integration, client) do
    each_path(integration, client, &fetch_path(integration, client, &1, []))
  end

  @doc """
  Syncs each configured path in turn with `sync_path`, then reconciles any
  that went missing.

  `sync_path` returns `:ok`, `:not_found` for a collection the server no
  longer has, or an error. The walk stops at the first error, but collects
  404s across all paths so the missing-path decision is made once with the
  full picture rather than per path.
  """
  @spec each_path(struct(), map(), (String.t() -> result() | :not_found)) :: result()
  def each_path(_integration, %{calendar_paths: []}, _sync_path),
    do: {:error, :no_calendar_paths}

  def each_path(integration, client, sync_path) do
    {status, missing} =
      Enum.reduce_while(client.calendar_paths, {:ok, []}, fn path, {:ok, missing} ->
        case sync_path.(path) do
          :ok -> {:cont, {:ok, missing}}
          :not_found -> {:cont, {:ok, [path | missing]}}
          error -> {:halt, {error, missing}}
        end
      end)

    handle_missing_paths(integration, client, missing, status)
  end

  @doc """
  Fetches and reconciles a single calendar path.

  Returns the bare `:not_found` sentinel when the collection is missing, for
  `each_path/3` to decide between dropping the path and flagging the
  integration.

  Options:

    * `:new_ctag` — a `getctag` value to store as the path's sync token once
      the events have been reconciled. Only written on success: a failed
      reconciliation must not advance the token past changes it never applied.
  """
  @spec fetch_path(struct(), map(), String.t(), keyword()) :: result() | :not_found
  def fetch_path(integration, client, calendar_path, opts) do
    range_now = DateTime.utc_now()
    start_time = DateTime.add(range_now, -@sync_window_past_days, :day)
    end_time = DateTime.add(range_now, @sync_window_future_days, :day)

    case CalDAVEvents.fetch_events(client, calendar_path, start_time, end_time) do
      {:ok, events} ->
        Logger.info("CalDAV full fetch completed",
          calendar_integration_id: integration.id,
          event_count: length(events),
          calendar_path: calendar_path
        )

        reconcile(integration, events, {start_time, end_time, range_now}, calendar_path, opts)

      {:error, :not_found} ->
        :not_found

      # Auth failures are reported upwards for the caller to act on; logging
      # them here would double up on the line it writes when it does.
      {:error, reason} when reason in [:unauthorized, :forbidden] ->
        {:error, reason}

      {:error, reason} ->
        Logger.error("CalDAV sync failed",
          calendar_integration_id: integration.id,
          phase: "full fetch",
          calendar_path: calendar_path,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp reconcile(integration, events, {start_time, end_time, range_now}, calendar_path, opts) do
    case SyncReconciler.process_full_fetch(
           integration,
           events,
           start_time,
           end_time,
           range_now,
           calendar_path
         ) do
      :ok ->
        State.put(integration, sync_token_opt(calendar_path, opts))
        :ok

      {:error, reason} ->
        Logger.error("CalDAV full fetch event processing failed; sync token NOT updated",
          calendar_integration_id: integration.id,
          calendar_path: calendar_path,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp sync_token_opt(calendar_path, opts) do
    case Keyword.get(opts, :new_ctag) do
      nil -> []
      ctag -> [sync_token: {calendar_path, ctag}]
    end
  end

  defp handle_missing_paths(_integration, _client, [], status), do: status

  defp handle_missing_paths(integration, client, missing, status) do
    if List.first(client.calendar_paths) in missing do
      {:error, :booking_calendar_missing}
    else
      remove_missing_paths(integration, missing)
      status
    end
  end

  defp remove_missing_paths(integration, missing) do
    Logger.warning("CalDAV calendar paths no longer exist on server; removing from sync",
      calendar_integration_id: integration.id,
      missing_count: length(missing)
    )

    case CalendarIntegrationQueries.remove_calendar_paths(integration, missing) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to remove missing CalDAV calendar paths",
          calendar_integration_id: integration.id,
          error: inspect(changeset.errors)
        )

        :ok
    end
  end
end
