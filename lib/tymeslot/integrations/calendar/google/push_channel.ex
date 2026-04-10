defmodule Tymeslot.Integrations.Calendar.Google.PushChannel do
  @moduledoc """
  Manages Google Calendar push notification channel registration.

  Handles subscribing to calendar event changes via Google's push notification
  API, fetching the initial sync token, and persisting channel state to the
  database.
  """

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken

  @doc """
  Registers a Google Calendar push notification channel for the integration,
  fetches an initial sync token, and persists all channel state to the database.

  Returns `{:ok, updated_integration}` on success, or an error tuple on failure.

  Requires `:webhook_base_url` to be configured in the `:tymeslot` application env.
  """
  @spec register_push_channel(CalendarIntegrationSchema.t()) ::
          {:ok, CalendarIntegrationSchema.t()}
          | {:error, :webhook_base_url_not_configured}
          | {:error, :circuit_open}
          | CalendarAPI.api_error()
  def register_push_channel(%CalendarIntegrationSchema{} = integration) do
    case Application.get_env(:tymeslot, :webhook_base_url) do
      nil ->
        {:error, :webhook_base_url_not_configured}

      webhook_base_url ->
        do_register_push_channel(integration, webhook_base_url)
    end
  end

  # --- Private helpers ---

  defp do_register_push_channel(integration, webhook_base_url) do
    calendar_id = integration.default_booking_calendar_id || "primary"
    channel_id = UUID.generate()
    channel_secret = Base.url_encode64(:crypto.strong_rand_bytes(32))

    AccessToken.with_access_token(integration, &CalendarAPI.refresh_token/1, fn token ->
      with {:ok, channel_attrs} <-
             subscribe_to_calendar_events(
               token,
               calendar_id,
               channel_id,
               channel_secret,
               webhook_base_url
             ),
           {:ok, sync_token} <- fetch_initial_sync_token(token, calendar_id) do
        persist_push_channel(integration, Map.put(channel_attrs, :google_sync_token, sync_token))
      end
    end)
  end

  defp subscribe_to_calendar_events(
         token,
         calendar_id,
         channel_id,
         channel_secret,
         webhook_base_url
       ) do
    body = %{
      "id" => channel_id,
      "token" => channel_secret,
      "type" => "web_hook",
      "address" => "#{webhook_base_url}/webhooks/google-calendar"
    }

    result =
      CalendarCircuitBreaker.call(:google, fn ->
        CalendarAPI.make_request_with_body(
          :post,
          "/calendars/#{URI.encode(calendar_id)}/events/watch",
          token,
          body
        )
      end)

    case result do
      {:ok, response} when is_map(response) ->
        resource_id = response["resourceId"]

        expires_at =
          case response["expiration"] do
            nil ->
              # Default to 7 days if Google omits expiration
              DateTime.truncate(DateTime.add(DateTime.utc_now(), 7 * 24 * 3600, :second), :second)

            expiration_ms ->
              expiration_ms
              |> to_integer()
              |> DateTime.from_unix!(:millisecond)
              |> DateTime.truncate(:second)
          end

        {:ok,
         %{
           google_channel_id: channel_id,
           google_channel_resource_id: resource_id,
           google_channel_expires_at: expires_at,
           google_channel_secret: channel_secret
         }}

      {:ok, error} ->
        error

      {:error, :circuit_open} = error ->
        error
    end
  end

  defp fetch_initial_sync_token(token, calendar_id) do
    fetch_sync_token_page(token, calendar_id, nil)
  end

  defp fetch_sync_token_page(token, calendar_id, page_token) do
    params =
      maybe_put_page_token(
        %{"maxResults" => "250", "fields" => "nextPageToken,nextSyncToken"},
        page_token
      )

    result =
      CalendarCircuitBreaker.call(:google, fn ->
        CalendarAPI.make_request(
          :get,
          "/calendars/#{URI.encode(calendar_id)}/events",
          token,
          params
        )
      end)

    case result do
      {:ok, response} when is_map(response) ->
        cond do
          sync_token = response["nextSyncToken"] ->
            {:ok, sync_token}

          next_page = response["nextPageToken"] ->
            fetch_sync_token_page(token, calendar_id, next_page)

          true ->
            {:ok, nil}
        end

      {:ok, error} ->
        error

      {:error, :circuit_open} = error ->
        error
    end
  end

  defp maybe_put_page_token(params, nil), do: params
  defp maybe_put_page_token(params, token), do: Map.put(params, "pageToken", token)

  defp persist_push_channel(integration, attrs) do
    case CalendarIntegrationWebhookQueries.update_push_channel(integration, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:db_error, changeset}}
    end
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
end
