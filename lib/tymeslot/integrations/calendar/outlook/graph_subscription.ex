defmodule Tymeslot.Integrations.Calendar.Outlook.GraphSubscription do
  @moduledoc """
  Manages Microsoft Graph change-notification subscriptions and initial delta
  bootstraps for Outlook Calendar integrations.

  Two independent concerns live here:

  - `bootstrap_sync/1` — paginated `events/delta` call that populates the cache
    and seeds `graph_delta_link`. Has **no webhook dependency**: it's plain
    HTTP and works on every deployment, self-hosted or managed.
  - `register/1` — creates a Graph push subscription so changes are pushed to
    our webhook. Requires `:webhook_base_url` because the subscription payload
    needs a `notificationUrl`. Deployments without a public webhook address
    still sync correctly via the fallback sweep polling `bootstrap_sync`.
  """

  require Logger

  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.Provider, as: OutlookProvider
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventQueries
  alias Tymeslot.Integrations.Calendar.ProviderCalendarEventSchema
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken

  @outlook_tymeslot_property_id "String {00020329-0000-0000-C000-000000000046} Name createdBy"
  @max_delta_pages 50

  @doc """
  Fetches the initial `events/delta` snapshot, normalises and persists the
  events to the cache, and stores the returned delta link on the integration
  so subsequent sweeps can fetch incremental changes.

  Works on every deployment — no webhook URL required.
  """
  @spec bootstrap_sync(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :circuit_open}
          | CalendarAPI.api_error()
  def bootstrap_sync(%CalendarIntegrationSchema{} = integration) do
    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      with {:ok, {events, delta_link}} <- fetch_initial_delta(token),
           {:ok, calendar_events} <- normalise_delta_events(events, integration) do
        cache_attrs =
          Enum.map(calendar_events, &ProviderCalendarEventSchema.from_calendar_event/1)

        with {:ok, _count} <- ProviderCalendarEventQueries.upsert_batch(cache_attrs) do
          persist_subscription(integration, %{graph_delta_link: delta_link})
        end
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
          | {:error, :circuit_open}
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

      {:error, :circuit_open} = error ->
        error
    end
  end

  defp fetch_initial_delta(token) do
    params = %{
      "$select" =>
        "id,subject,start,end,iCalUId,location,body,attendees,recurrence,seriesMasterId,type,isAllDay,showAs",
      "$expand" =>
        "singleValueExtendedProperties($filter=id eq '#{@outlook_tymeslot_property_id}')"
    }

    result =
      CalendarCircuitBreaker.call(:outlook, fn ->
        fetch_delta_page(token, "/me/events/delta", params, [])
      end)

    case result do
      {:ok, {:ok, events, delta_link}} ->
        {:ok, {events, delta_link}}

      {:ok, error} ->
        error

      {:error, :circuit_open} = error ->
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
            next_params = URI.decode_query(next_uri.query || "")
            fetch_delta_page(token, next_uri.path, next_params, events, page + 1)

          true ->
            {:ok, events, nil}
        end
      end
    end
  end

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
