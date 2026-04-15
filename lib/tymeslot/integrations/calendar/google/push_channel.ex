defmodule Tymeslot.Integrations.Calendar.Google.PushChannel do
  @moduledoc """
  Manages Google Calendar push notification channel subscriptions.

  Subscribes the integration to calendar change notifications via Google's
  watch API and persists the channel's identifier, expiry, and secret. This
  module has no responsibility for the event cache or for seeding sync tokens
  — both of those happen in `Tymeslot.Workers.SyncGoogleCalendarWorker` via
  the `bootstrap_sync/1` path, which works independently of whether a push
  channel has been subscribed.

  Push subscription is a bonus on top of polling: it only fires on deployments
  that expose a public webhook URL. Self-hosted deployments without one still
  get correct sync via the Oban fallback sweep.
  """

  alias Ecto.UUID
  alias Tymeslot.Infrastructure.CalendarCircuitBreaker
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI
  alias Tymeslot.Integrations.Calendar.Shared.AccessToken

  @doc """
  Subscribes the integration to Google Calendar push notifications and persists
  the channel state. Requires `:webhook_base_url` to be configured — callers
  that may run without one should guard the call.
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
             ) do
        persist_push_channel(integration, channel_attrs)
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

  defp persist_push_channel(integration, attrs) do
    case CalendarIntegrationWebhookQueries.update_push_channel(integration, attrs) do
      {:ok, updated} -> {:ok, updated}
      {:error, changeset} -> {:error, {:db_error, changeset}}
    end
  end

  defp to_integer(v) when is_integer(v), do: v
  defp to_integer(v) when is_binary(v), do: String.to_integer(v)
end
