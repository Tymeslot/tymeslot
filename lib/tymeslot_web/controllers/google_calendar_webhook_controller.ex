defmodule TymeslotWeb.GoogleCalendarWebhookController do
  @moduledoc """
  Handles incoming Google Calendar push notification webhooks.

  Google delivers a POST to /webhooks/google-calendar whenever an event changes
  in a watched calendar. The request carries two identifying headers:

    - X-Goog-Channel-ID  — matches the channel ID we registered
    - X-Goog-Channel-Token — the secret we provided during registration

  We verify the token with a timing-safe comparison before enqueuing a sync job.
  All responses are HTTP 200 to prevent Google from retrying; invalid or unknown
  requests are silently acknowledged.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Plug.Crypto
  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncGoogleCalendarWorker

  @doc """
  Receives a Google Calendar push notification.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, _params) do
    channel_id = extract_header(conn, "x-goog-channel-id")
    token = extract_header(conn, "x-goog-channel-token")

    case CalendarIntegrationQueries.get_by_google_channel_id(channel_id) do
      {:error, :not_found} ->
        conn |> send_resp(200, "") |> halt()

      {:ok, integration} ->
        if valid_token?(token, integration.google_channel_secret) do
          handle_valid_notification(conn, integration)
        else
          Logger.warning("Google Calendar webhook: token verification failed",
            channel_id: channel_id,
            integration_id: integration.id
          )

          conn |> send_resp(200, "") |> halt()
        end
    end
  end

  # Private helpers

  defp extract_header(conn, header_name) do
    case get_req_header(conn, header_name) do
      [value | _rest] -> value
      [] -> ""
    end
  end

  defp valid_token?(received, expected)
       when is_binary(received) and is_binary(expected) and byte_size(received) > 0 and
              byte_size(expected) > 0 do
    Crypto.secure_compare(received, expected)
  end

  defp valid_token?(_received, _expected), do: false

  defp handle_valid_notification(conn, integration) do
    case RateLimiter.check_calendar_webhook_rate_limit(integration.id) do
      :ok ->
        enqueue_sync(integration)
        touch_notification_timestamp(integration)

      {:error, :rate_limited} ->
        Logger.warning("Google Calendar webhook rate limited",
          integration_id: integration.id
        )
    end

    # Always return 200 to prevent Google from retrying
    conn |> send_resp(200, "") |> halt()
  end

  defp enqueue_sync(integration) do
    job = SyncGoogleCalendarWorker.new(%{"calendar_integration_id" => integration.id})

    case Oban.insert(job) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue SyncGoogleCalendarWorker",
          integration_id: integration.id,
          reason: inspect(reason)
        )
    end
  end

  defp touch_notification_timestamp(integration) do
    case CalendarIntegrationQueries.touch_notification_at(
           integration,
           :last_google_notification_at
         ) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to update last_google_notification_at",
          integration_id: integration.id,
          reason: inspect(changeset)
        )
    end
  end
end
