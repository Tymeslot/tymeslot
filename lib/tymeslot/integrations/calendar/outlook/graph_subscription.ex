defmodule Tymeslot.Integrations.Calendar.Outlook.GraphSubscription do
  @moduledoc """
  Manages Microsoft Graph change-notification subscriptions and initial delta
  bootstraps for Outlook Calendar integrations.

  Two independent concerns live here:

  - `bootstrap_sync/1` — paginated `calendarView/delta` call that populates the
    cache and seeds `graph_delta_link`. Has **no webhook dependency**: it's
    plain HTTP and works on every deployment, self-hosted or managed.
  - `register/1` — creates a Graph push subscription so changes are pushed to
    our webhook. Requires `:webhook_base_url` because the subscription payload
    needs a `notificationUrl`. Deployments without a public webhook address
    still sync correctly via the fallback sweep polling `bootstrap_sync`.

  ## Why `calendarView/delta` and not `events/delta`

  `/me/events/delta` accepts no date parameters and freezes the initial window
  Graph picks (about 30 days from bootstrap) into the returned `$deltatoken`
  forever — events outside that window never surface, no matter how far in the
  future the calendar moves. `/me/calendarView/delta` accepts explicit
  `startDateTime`/`endDateTime` parameters and tracks changes to occurrences
  within the requested window, which matches what the rest of the codebase
  reads for the dashboard and booking flows.
  """

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken

  @max_delta_pages 50

  @delta_path "/me/calendarView/delta"

  # Microsoft Graph rejects these query parameters on the `calendarView/delta`
  # change-tracking resource with HTTP 400 `ErrorInvalidUrlQuery`. They must
  # never appear on either the initial request or on any follow-up URL
  # (`@odata.nextLink`, `@odata.deltaLink`) that we reuse.
  @unsupported_delta_params ~w($orderby $filter $select $expand $search)

  @doc """
  Fetches the initial `events/delta` snapshot, normalises and persists the
  events to the cache, and stores the returned delta link on the integration
  so subsequent sweeps can fetch incremental changes.

  Works on every deployment — no webhook URL required.

  Bypasses `Sync.post_commit_reconciliation/2`, and so enqueues no cross-calendar
  mirror write-backs. That is deliberate and costs nothing here: this is a
  first-run baseline for an integration that by definition has no sync links
  pointing at it yet, since a link cannot be configured against a calendar
  before it connects. Whatever this writes is reconciled by the first
  `Tymeslot.Workers.SyncLinkReconcileSweepWorker` pass after a link is created,
  which is also the first moment mirroring means anything for it.
  """
  @spec bootstrap_sync(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, term()}
          | CalendarAPI.api_error()
  def bootstrap_sync(%CalendarIntegrationSchema{} = integration) do
    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      with {:ok, {events, delta_link}} <- fetch_initial_delta(token),
           {:ok, calendar_events} <- normalise_delta_events(events, integration),
           cache_attrs =
             Enum.map(calendar_events, &ProviderCalendarEventSchema.from_calendar_event/1),
           {:ok, _count} <- ProviderCalendarEventQueries.upsert_batch(cache_attrs) do
        persist_subscription(integration, %{graph_delta_link: delta_link})
      end
    end)
  end

  @doc """
  Creates a Microsoft Graph push subscription for the integration and persists
  the subscription id, expiry, and client state. Requires `:webhook_base_url`.

  Does **not** touch `graph_delta_link` — that's `bootstrap_sync/1`'s job.
  """
  @spec register(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :webhook_base_url_not_configured}
          | {:error, term()}
          | CalendarAPI.api_error()
  def register(%CalendarIntegrationSchema{} = integration) do
    case Application.get_env(:tymeslot, :webhook_base_url) do
      nil ->
        {:error, :webhook_base_url_not_configured}

      webhook_base_url ->
        do_register(integration, webhook_base_url)
    end
  end

  # Private helpers

  # Both Graph calls below unwrap a `CalendarCircuitBreaker.call/2` result, which
  # comes in three shapes:
  #
  #   * `{:ok, result}` — the breaker passes `{:ok, _}` returns through untouched
  #     and wraps any *other* shape in `{:ok, _}`. `CalendarAPI` signals failure
  #     with a 3-tuple, so its errors arrive as `{:ok, {:error, type, message}}`,
  #     and `fetch_delta_page/5`'s 3-tuple success as `{:ok, {:ok, events, link}}`.
  #   * `{:error, :circuit_open}` — the breaker refused the call.
  #   * `{:error, reason}` — any other breaker-level failure: `:breaker_not_found`,
  #     an exception the breaker rescued (`{:error, %RuntimeError{}}`), or a plain
  #     2-tuple error from the wrapped function (`:pagination_limit_exceeded`).
  #
  # The last shape must stay a catch-all: matching only `:circuit_open` turns
  # every rescued exception into a `CaseClauseError` that crashes the caller.

  defp do_register(integration, webhook_base_url) do
    client_state = Base.url_encode64(:crypto.strong_rand_bytes(32))

    expiration =
      DateTime.utc_now()
      |> DateTime.add(2 * 24 * 3600, :second)
      |> DateTime.to_iso8601()

    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      with {:ok, subscription_attrs} <-
             create_subscription(token, client_state, expiration, webhook_base_url) do
        persist_subscription(
          integration,
          Map.put(subscription_attrs, :graph_client_state, client_state)
        )
      end
    end)
  end

  defp normalise_delta_events(events, %CalendarIntegrationSchema{} = integration) do
    context = %{
      calendar_integration_id: integration.id,
      provider_calendar_id: integration.default_booking_calendar_id || "primary",
      synced_at: DateTime.utc_now(:microsecond)
    }

    OutlookProvider.normalise_events(events, context)
  end

  defp create_subscription(token, client_state, expiration, webhook_base_url) do
    body = %{
      "changeType" => "created,updated,deleted",
      "notificationUrl" => "#{webhook_base_url}/webhooks/outlook-calendar",
      "lifecycleNotificationUrl" => "#{webhook_base_url}/webhooks/outlook-lifecycle",
      "resource" => "me/events",
      "expirationDateTime" => expiration,
      "clientState" => client_state
    }

    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        CalendarAPI.make_request_with_body(:post, "/subscriptions", token, body)
      end)

    case result do
      {:ok, response} when is_map(response) ->
        expires_at = parse_iso8601_datetime(response["expirationDateTime"])

        {:ok,
         %{
           graph_subscription_id: response["id"],
           graph_subscription_expires_at: expires_at
         }}

      {:ok, error} ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_initial_delta(token) do
    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        fetch_delta_page(token, @delta_path, initial_delta_params(), [])
      end)

    case result do
      {:ok, {:ok, events, delta_link}} ->
        {:ok, {events, delta_link}}

      {:ok, error} ->
        error

      {:error, _reason} = error ->
        error
    end
  end

  defp fetch_delta_page(token, path, params, accumulated, page \\ 1) do
    if page > @max_delta_pages do
      Logger.warning("Outlook delta pagination limit reached", pages: page)
      {:error, :pagination_limit_exceeded}
    else
      with {:ok, response} <- CalendarAPI.make_request(:get, path, token, params) do
        events = accumulated ++ (response["value"] || [])

        cond do
          delta_link = response["@odata.deltaLink"] ->
            {:ok, events, delta_link}

          next_link = response["@odata.nextLink"] ->
            next_uri = URI.parse(next_link)

            next_params =
              (next_uri.query || "")
              |> URI.decode_query()
              |> drop_unsupported_delta_params()

            fetch_delta_page(
              token,
              strip_api_version_prefix(next_uri.path),
              next_params,
              events,
              page + 1
            )

          true ->
            {:ok, events, nil}
        end
      end
    end
  end

  # `calendarView/delta` requires `startDateTime` + `endDateTime` on the very
  # first request; the returned `$deltatoken` thereafter encodes that window,
  # so subsequent calls (using the stored deltaLink as-is) do not repeat them.
  defp initial_delta_params do
    now = DateTime.utc_now()

    %{
      "startDateTime" =>
        now
        |> DateTime.add(-ProviderConfig.sync_window_past_days() * 86_400, :second)
        |> DateTime.to_iso8601(),
      "endDateTime" =>
        now
        |> DateTime.add(ProviderConfig.sync_window_future_days() * 86_400, :second)
        |> DateTime.to_iso8601()
    }
  end

  defp drop_unsupported_delta_params(params) do
    Map.reject(params, fn {key, _value} ->
      String.downcase(to_string(key)) in @unsupported_delta_params
    end)
  end

  # `@odata.nextLink` comes back as an absolute URL whose path starts with the
  # Graph API version segment (`/v1.0` or `/beta`). `CalendarAPI.make_request/4`
  # already prepends the full base URL including the version, so we must strip
  # it from the path to avoid hitting `/v1.0/v1.0/...`.
  defp strip_api_version_prefix("/v1.0/" <> rest), do: "/" <> rest
  defp strip_api_version_prefix("/beta/" <> rest), do: "/" <> rest
  defp strip_api_version_prefix(path), do: path

  defp parse_iso8601_datetime(nil), do: nil

  defp parse_iso8601_datetime(dt_string) do
    case DateTime.from_iso8601(dt_string) do
      {:ok, dt, _offset} -> DateTime.truncate(dt, :second)
      _error -> nil
    end
  end

  defp persist_subscription(integration, attrs) do
    case CalendarIntegrationWebhookQueries.update_graph_subscription(integration, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:db_error, changeset}}
    end
  end
end
