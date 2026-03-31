defmodule TymeslotWeb.OutlookCalendarWebhookController do
  @moduledoc """
  Handles incoming Microsoft Graph change notifications for Outlook Calendar.

  Microsoft Graph delivers notifications in two forms:

    1. Validation challenge — a GET or POST with `?validationToken=...`. We must
       respond with the token as plain text within 10 seconds to confirm ownership
       of the endpoint before Graph will activate the subscription.

    2. Change notifications — a POST with a JSON body containing one or more
       notification objects. Each notification identifies a subscription and
       carries a `clientState` value we compare against the stored secret using
       a timing-safe comparison before enqueuing a sync job.

  All well-formed change notification payloads receive HTTP 202; validation
  challenges receive HTTP 200 with the token echoed back. Invalid or unknown
  notifications are silently skipped.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Plug.Crypto
  alias Tymeslot.Integrations.Calendar, as: CalendarIntegrations
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  @doc """
  Receives a Microsoft Graph change notification or validation challenge.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, %{"validationToken" => token})
      when is_binary(token) and byte_size(token) > 0 and byte_size(token) <= 256 do
    if String.printable?(token) do
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(200, token)
      |> halt()
    else
      conn |> send_resp(400, "") |> halt()
    end
  end

  def webhook(conn, _params) do
    notifications = Enum.take(get_in(conn.body_params, ["value"]) || [], 50)

    Enum.each(notifications, &process_notification/1)

    conn |> send_resp(202, "") |> halt()
  end

  # Private helpers

  defp process_notification(%{"subscriptionId" => subscription_id} = notification) do
    case CalendarIntegrations.get_by_graph_subscription_id(subscription_id) do
      {:error, :not_found} ->
        :ok

      {:ok, integration} ->
        client_state = notification["clientState"] || ""
        expected_state = integration.graph_client_state || ""

        if valid_client_state?(client_state, expected_state) do
          handle_valid_notification(integration, notification)
        else
          Logger.warning("Outlook Calendar webhook: clientState verification failed",
            subscription_id: subscription_id,
            integration_id: integration.id
          )
        end
    end
  end

  defp process_notification(_notification), do: :ok

  defp valid_client_state?(received, expected)
       when is_binary(received) and is_binary(expected) and byte_size(received) > 0 and
              byte_size(expected) > 0 do
    Crypto.secure_compare(received, expected)
  end

  defp valid_client_state?(_received, _expected), do: false

  defp handle_valid_notification(integration, notification) do
    case RateLimiter.check_calendar_webhook_rate_limit(integration.id) do
      :ok ->
        case get_in(notification, ["resourceData", "id"]) do
          nil ->
            Logger.warning("Outlook webhook notification missing resourceData",
              subscription_id: notification["subscriptionId"]
            )

          graph_resource_id ->
            enqueue_sync(integration, graph_resource_id)
            touch_notification_timestamp(integration)
        end

      {:error, :rate_limited} ->
        Logger.warning("Outlook Calendar webhook rate limited",
          integration_id: integration.id
        )
    end
  end

  defp enqueue_sync(integration, graph_resource_id) do
    args = %{
      "calendar_integration_id" => integration.id,
      "graph_resource_id" => graph_resource_id
    }

    job = SyncOutlookCalendarWorker.new(args)

    case Oban.insert(job) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error("Failed to enqueue SyncOutlookCalendarWorker",
          integration_id: integration.id,
          reason: inspect(reason)
        )
    end
  end

  defp touch_notification_timestamp(integration) do
    case CalendarIntegrations.touch_notification_at(
           integration,
           :last_outlook_notification_at
         ) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to update last_outlook_notification_at",
          integration_id: integration.id,
          reason: inspect(changeset)
        )
    end
  end
end
