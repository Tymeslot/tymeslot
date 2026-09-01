defmodule Tymeslot.Integrations.Calendar.Outlook.DeltaSync do
  @moduledoc """
  Outlook (Microsoft Graph) delta-link change tracking.

  Given an integration that already has a stored `graph_delta_link`, fetches
  the changes the Graph API has accumulated since that link was issued,
  applies the changes to the local cache (upserts changed events, deletes
  removed ones, reconciles bookings), persists the new delta link returned
  by the API, and broadcasts the cache update so connected dashboards
  refresh.

  The bootstrap path (no delta link present yet) is handled by the worker
  via `OutlookCalendarAPI.bootstrap_sync/1` — this module is the steady-state
  optimisation that lets us catch up between webhook deliveries without a
  full re-sync.
  """

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Sync
  alias Tymeslot.Integrations.Calendar.SyncBroadcast
  alias Tymeslot.Integrations.HealthCheck.ErrorAnalysis

  # Microsoft Graph rejects these query parameters on the `events/delta`
  # change-tracking resource. Stored `graph_delta_link` URLs written before
  # this was known may still carry them — strip before reuse.
  @unsupported_delta_params ~w($orderby $filter $select $expand $search)

  @max_delta_pages 100

  @doc """
  Fetches and applies Outlook delta changes for an integration that has a
  stored `graph_delta_link`. Returns `:ok` on success, or `{:error, class}` on
  any failure (already logged with context).

  The class distinguishes a remote that is briefly unwell (`:transient` — a
  Graph 5xx, a timeout, an open circuit) from one that needs somebody to act
  (`:hard` — bad credentials, a failed local write). The caller decides what to
  do with a job that runs out of retries; only `:transient` is safe to abandon
  to the next scheduled sweep.
  """
  @spec fetch_and_apply(map()) :: :ok | {:error, ErrorAnalysis.error_class()}
  def fetch_and_apply(integration) do
    delta_link = integration.graph_delta_link

    if obsolete_delta_link?(delta_link) do
      # Older bootstraps wrote a `/me/events/delta` link whose `$deltatoken`
      # froze a ~30-day window at the moment of bootstrap and never widened.
      # Clearing the link forces the next sync to re-bootstrap via
      # `calendarView/delta` with a rolling ±365-day window.
      Logger.info(
        "Outlook delta link uses obsolete /events/delta endpoint; clearing for re-bootstrap",
        calendar_integration_id: integration.id
      )

      CalendarIntegrationWebhookQueries.update_delta_link(integration, nil)
      {:error, :transient}
    else
      do_fetch_and_apply(integration, delta_link)
    end
  end

  defp do_fetch_and_apply(integration, delta_link) do
    api_module = Config.outlook_calendar_api_module()

    result =
      AccessToken.with_access_token(integration, &api_module.refresh_token/1, fn token ->
        CalendarCircuitBreaker.call(:outlook, fn ->
          fetch_delta_page(token, delta_link, [])
        end)
      end)

    handle_fetch_result(result, integration)
  end

  defp obsolete_delta_link?(nil), do: false
  defp obsolete_delta_link?(url) when is_binary(url), do: String.contains?(url, "/events/delta")
  defp obsolete_delta_link?(_other), do: false

  defp handle_fetch_result({:ok, {:ok, events, new_delta_link}}, integration) do
    apply_delta(integration, events, new_delta_link)
  end

  # CalendarCircuitBreaker.call returns {:error, :circuit_open} when the breaker
  # is open, and {:error, reason} for errors returned by the function it wraps.
  # The {:ok, {:error, ...}} shape never occurs — errors are not wrapped in {:ok}.
  defp handle_fetch_result({:error, :circuit_open}, integration) do
    Logger.warning("Outlook circuit breaker open during delta sync",
      calendar_integration_id: integration.id
    )

    {:error, :transient}
  end

  defp handle_fetch_result({:error, :delta_link_expired}, integration) do
    Logger.warning("Outlook delta link expired (410); clearing stored link for re-bootstrap",
      calendar_integration_id: integration.id
    )

    CalendarIntegrationWebhookQueries.update_delta_link(integration, nil)
    {:error, :transient}
  end

  defp handle_fetch_result({:error, reason} = fetch_error, integration) do
    Logger.warning("Outlook delta fetch failed",
      calendar_integration_id: integration.id,
      error: format_error(fetch_error)
    )

    {:error, ErrorAnalysis.classify_error(reason)}
  end

  defp handle_fetch_result(refresh_error, integration) do
    Logger.warning("Outlook token refresh failed",
      calendar_integration_id: integration.id,
      error: format_error(refresh_error)
    )

    # Deliberately not classified: a refresh that fails is the credential path,
    # which is the case an operator most needs to hear about. Rather than let
    # the conservative "unknown means transient" default silence a revoked
    # grant, keep every refresh failure alertable.
    {:error, :hard}
  end

  defp apply_delta(integration, events, new_delta_link) do
    {removed, changed} = Enum.split_with(events, &Map.has_key?(&1, "@removed"))
    cache_attrs = build_cache_attrs_batch(changed, integration.id)
    removed_uids = process_removed(removed, integration)

    with {:ok, _count} <- ProviderCalendarEventQueries.upsert_batch(cache_attrs),
         :ok <- persist_delta_link(integration, new_delta_link) do
      uids = Enum.map(cache_attrs, & &1.uid) ++ removed_uids
      SyncBroadcast.broadcast_cache_update(integration.user_id, uids)
      :ok
    else
      {:error, reason} ->
        Logger.warning("Outlook delta upsert/persist failed during fallback sweep",
          calendar_integration_id: integration.id,
          error: reason
        )

        # Ours, not the remote's: a failed local write does not heal by waiting
        # for the next sweep, so it stays alertable.
        {:error, :hard}
    end
  end

  defp process_removed(removed, integration) do
    refs =
      for event <- removed,
          event["iCalUId"] || event["id"],
          do: %{provider_event_id: event["id"], uid: event["iCalUId"]}

    Sync.reconcile_deletions(integration, refs)

    Enum.map(refs, fn ref -> ref.uid || ref.provider_event_id end)
  end

  defp fetch_delta_page(token, url, accumulated, page \\ 0)

  defp fetch_delta_page(_token, _url, _accumulated, page) when page >= @max_delta_pages do
    {:error, :too_many_pages}
  end

  defp fetch_delta_page(token, url, accumulated, page) do
    # The circuit breaker wrapping this loop only counts 2-tuple errors as
    # failures, so the client's {:error, type, message} shape is flattened.
    case OutlookCalendarAPI.get_delta_page(token, strip_unsupported_delta_params(url)) do
      {:ok, response} ->
        collect_delta_page(response, token, accumulated, page)

      {:error, :unauthorized, _message} ->
        {:error, :unauthorized}

      {:error, :delta_link_expired, _message} ->
        {:error, :delta_link_expired}

      {:error, type, message} ->
        {:error, {type, message}}
    end
  end

  defp collect_delta_page(response, token, accumulated, page) do
    events = [response["value"] || [] | accumulated]

    cond do
      new_delta_link = response["@odata.deltaLink"] ->
        {:ok, List.flatten(events), new_delta_link}

      next_link = response["@odata.nextLink"] ->
        fetch_delta_page(token, next_link, events, page + 1)

      true ->
        {:ok, List.flatten(events), nil}
    end
  end

  defp build_cache_attrs_batch(events, calendar_integration_id) do
    context = %{
      calendar_integration_id: calendar_integration_id,
      # Microsoft Graph /me/events/delta returns events from the user's primary
      # calendar. The provider_calendar_events.provider_calendar_id column is NOT
      # NULL with 'primary' as the documented default; passing nil causes a
      # Postgres constraint violation.
      provider_calendar_id: "primary",
      synced_at: DateTime.utc_now(:microsecond)
    }

    {:ok, calendar_events} = OutlookProvider.normalise_events(events, context)
    Enum.map(calendar_events, &ProviderCalendarEventSchema.from_calendar_event/1)
  end

  defp persist_delta_link(_integration, nil), do: :ok

  defp persist_delta_link(integration, new_delta_link) do
    case CalendarIntegrationWebhookQueries.update_delta_link(integration, new_delta_link) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.warning("Failed to persist Outlook delta link in fallback sweep",
          calendar_integration_id: integration.id,
          error: inspect(changeset)
        )

        {:error, :delta_link_persistence_failed}
    end
  end

  defp strip_unsupported_delta_params(url) do
    uri = URI.parse(url)

    case uri.query do
      query when query in [nil, ""] ->
        url

      query ->
        # Split and filter on the raw query string rather than decode-then-encode,
        # because URI.encode_query/1 percent-encodes '$' as '%24', which turns
        # '$deltatoken' into '%24deltatoken' and breaks Microsoft Graph requests.
        cleaned_parts =
          query
          |> String.split("&")
          |> Enum.reject(fn part ->
            key = part |> String.split("=", parts: 2) |> hd() |> String.downcase()
            key in @unsupported_delta_params
          end)

        new_query = if cleaned_parts == [], do: nil, else: Enum.join(cleaned_parts, "&")

        uri
        |> Map.put(:query, new_query)
        |> URI.to_string()
    end
  end

  # Normalises both 2-tuple (`{:error, reason}`) and 3-tuple
  # (`{:error, type, reason}` — the `api_error()` shape returned by the
  # Outlook/Graph client) error shapes into a single printable string.
  defp format_error({:error, type, reason}) when is_atom(type),
    do: "#{type}: #{inspect(reason)}"

  defp format_error({:error, reason}), do: inspect(reason)

  defp format_error(other), do: inspect(other)
end
