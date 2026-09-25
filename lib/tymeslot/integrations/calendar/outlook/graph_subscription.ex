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
  alias Tymeslot.Integrations.Calendar.ProviderConfig
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken
  alias Tymeslot.Integrations.Calendar.Sync

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
  """
  @spec bootstrap_sync(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, term()}
          | CalendarAPI.api_error()
  def bootstrap_sync(%CalendarIntegrationSchema{} = integration) do
    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      with {:ok, {events, delta_link}} <- fetch_initial_delta(token),
           {:ok, calendar_events} <- normalise_delta_events(events, integration),
           # Through `Sync.upsert_cache/2` for the ownership flagging it adds;
           # see the note in `DeltaSync.apply_delta/3`.
           {:ok, _count} <- Sync.upsert_cache(integration, calendar_events) do
        persist_subscription(integration, %{graph_delta_link: delta_link})
      end
    end)
  end

  @doc """
  Makes sure the integration has a live Microsoft Graph push subscription and
  persists its id, expiry and client state. Requires `:webhook_base_url`.

  An integration that already stores a subscription has that subscription
  renewed in place (`PATCH /subscriptions/{id}`), which is how Graph expects a
  subscription to be kept alive. A new one is created only when there is none
  stored, or Graph answers that the stored one no longer exists.

  Renewing in place is what keeps this safe to repeat. Creating a fresh
  subscription on every renewal left the previous one pushing to us until it
  expired, up to two days later, and a job re-run after a lost
  acknowledgement (a lifeline rescue) created yet another. A repeated renewal
  now only extends the same subscription again.

  What remains is the create path itself: if the process stops after Graph
  accepted the new subscription and before its id was stored, the next run
  cannot know about it and creates another. The stray one expires on its own
  within two days, and nothing is delivered for it, since incoming
  notifications are matched to an integration by the stored subscription id.

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

  # Every Graph call below goes through `CalendarCircuitBreaker.call/2`, whose
  # result comes in these shapes:
  #
  #   * `{:ok, result}` — a success. The breaker passes `{:ok, _}` returns
  #     through untouched and wraps any other non-error shape in `{:ok, _}`, so
  #     `fetch_delta_page/5`'s 3-tuple success arrives as
  #     `{:ok, {:ok, events, link}}`.
  #   * `{:error, type, message}` — a `CalendarAPI` error (an HTTP error status
  #     or a transport failure), passed through unwrapped. Older breaker
  #     versions wrapped it as `{:ok, {:error, type, message}}`;
  #     `unwrap_breaker_result/1` folds that form into this one.
  #   * `{:error, :circuit_open}` — the breaker refused the call.
  #   * `{:error, reason}` — any other failure: `:breaker_not_found`, an
  #     exception the breaker rescued (`{:error, %RuntimeError{}}`), or a plain
  #     2-tuple error from the wrapped function (`:pagination_limit_exceeded`).
  #
  # Every error shape must fall through to the caller as it is: matching only
  # the ones expected turns the rest into a `CaseClauseError` that crashes it.

  defp do_register(integration, webhook_base_url) do
    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      case renew_stored_subscription(token, integration, webhook_base_url) do
        {:ok, subscription_attrs} ->
          persist_subscription(integration, subscription_attrs)

        :none ->
          create_and_persist(token, integration, webhook_base_url)

        error ->
          error
      end
    end)
  end

  # A stored subscription is only renewable together with the client state it
  # was created with: Graph keeps sending that value, and notifications are
  # verified against the stored copy. Without one there is nothing to renew.
  defp renew_stored_subscription(
         token,
         %CalendarIntegrationSchema{
           graph_subscription_id: subscription_id,
           graph_client_state: client_state
         } = integration,
         webhook_base_url
       )
       when is_binary(subscription_id) and is_binary(client_state) do
    body = %{
      "expirationDateTime" => subscription_expiration(),
      "notificationUrl" => notification_url(webhook_base_url)
    }

    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        CalendarAPI.make_request_with_body(
          :patch,
          "/subscriptions/#{URI.encode(subscription_id)}",
          token,
          body
        )
      end)

    case unwrap_breaker_result(result) do
      {:ok, response} when is_map(response) ->
        {:ok, %{graph_subscription_expires_at: expires_at(response)}}

      # Expired, or removed by Graph (the `subscriptionRemoved` lifecycle
      # event): it can no longer be renewed, so a new one is needed.
      {:error, :not_found, _message} ->
        Logger.info("Stored Graph subscription no longer exists; creating a new one",
          calendar_integration_id: integration.id
        )

        :none

      error ->
        error
    end
  end

  defp renew_stored_subscription(_token, _integration, _webhook_base_url), do: :none

  # See the note above `do_register/2`: both forms of an API error mean the same.
  defp unwrap_breaker_result({:ok, {:error, _type, _message} = error}), do: error
  defp unwrap_breaker_result(result), do: result

  defp create_and_persist(token, integration, webhook_base_url) do
    client_state = Base.url_encode64(:crypto.strong_rand_bytes(32))

    with {:ok, subscription_attrs} <-
           create_subscription(token, client_state, subscription_expiration(), webhook_base_url) do
      persist_subscription(
        integration,
        Map.put(subscription_attrs, :graph_client_state, client_state)
      )
    end
  end

  defp subscription_expiration do
    DateTime.utc_now()
    |> DateTime.add(2 * 24 * 3600, :second)
    |> DateTime.to_iso8601()
  end

  defp notification_url(webhook_base_url), do: "#{webhook_base_url}/webhooks/outlook-calendar"

  defp expires_at(response), do: parse_iso8601_datetime(response["expirationDateTime"])

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
      "notificationUrl" => notification_url(webhook_base_url),
      "lifecycleNotificationUrl" => "#{webhook_base_url}/webhooks/outlook-lifecycle",
      "resource" => "me/events",
      "expirationDateTime" => expiration,
      "clientState" => client_state
    }

    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        CalendarAPI.make_request_with_body(:post, "/subscriptions", token, body)
      end)

    case unwrap_breaker_result(result) do
      {:ok, response} when is_map(response) ->
        {:ok,
         %{
           graph_subscription_id: response["id"],
           graph_subscription_expires_at: expires_at(response)
         }}

      error ->
        error
    end
  end

  defp fetch_initial_delta(token) do
    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        fetch_delta_page(token, @delta_path, initial_delta_params(), [])
      end)

    case unwrap_breaker_result(result) do
      {:ok, {:ok, events, delta_link}} ->
        {:ok, {events, delta_link}}

      error ->
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
