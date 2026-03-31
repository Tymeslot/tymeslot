defmodule TymeslotWeb.OutlookLifecycleController do
  @moduledoc """
  Handles Microsoft Graph lifecycle notifications for Outlook Calendar subscriptions.

  Graph delivers lifecycle events when a subscription requires attention:

    - `reauthorizationRequired` — the subscription's OAuth tokens need to be
      refreshed and the subscription re-authorized. Enqueues a `TokenRefreshJob`
      and asynchronously re-registers the Graph subscription.

    - `subscriptionRemoved` — Graph has removed the subscription (e.g. due to
      token expiry or inactivity). We attempt to re-register it so that change
      notifications resume automatically.

  All well-formed payloads return HTTP 202 regardless of the outcome, so Graph
  does not retry indefinitely.
  """

  use TymeslotWeb, :controller

  require Logger

  alias Plug.Crypto
  alias Tymeslot.Integrations.Calendar, as: CalendarIntegrations
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker

  @doc """
  Receives a Microsoft Graph lifecycle notification.
  """
  @spec webhook(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def webhook(conn, _params) do
    notifications = get_in(conn.body_params, ["value"]) || []

    # Deduplicate by subscription_id within the batch — only process the
    # first event per subscription to avoid spawning redundant work.
    notifications
    |> Enum.uniq_by(fn n -> n["subscriptionId"] end)
    |> Enum.each(&process_lifecycle_notification/1)

    conn |> send_resp(202, "") |> halt()
  end

  # Private helpers

  defp process_lifecycle_notification(
         %{
           "subscriptionId" => subscription_id,
           "lifecycleEvent" => event_type
         } = notification
       ) do
    client_state = notification["clientState"] || ""

    case CalendarIntegrations.get_by_graph_subscription_id(subscription_id) do
      {:error, :not_found} ->
        :ok

      {:ok, integration} ->
        expected_state = integration.graph_client_state || ""

        if valid_client_state?(client_state, expected_state) do
          case RateLimiter.check_calendar_webhook_rate_limit(integration.id) do
            :ok ->
              handle_lifecycle_event(integration, event_type)

            {:error, :rate_limited} ->
              Logger.warning("Outlook lifecycle webhook rate limited",
                integration_id: integration.id
              )
          end
        else
          Logger.warning("Outlook lifecycle: clientState verification failed",
            subscription_id: subscription_id,
            integration_id: integration.id
          )
        end
    end
  end

  defp process_lifecycle_notification(_notification), do: :ok

  defp valid_client_state?(received, expected)
       when is_binary(received) and is_binary(expected) and byte_size(received) > 0 and
              byte_size(expected) > 0 do
    Crypto.secure_compare(received, expected)
  end

  defp valid_client_state?(_received, _expected), do: false

  defp handle_lifecycle_event(integration, "reauthorizationRequired") do
    Logger.info("Outlook Graph subscription requires reauthorization",
      integration_id: integration.id,
      graph_subscription_id: integration.graph_subscription_id
    )

    enqueue_token_refresh(integration)
    enqueue_reregistration(integration)
  end

  defp handle_lifecycle_event(integration, "subscriptionRemoved") do
    Logger.info("Outlook Graph subscription removed; re-registering",
      integration_id: integration.id,
      graph_subscription_id: integration.graph_subscription_id
    )

    enqueue_reregistration(integration)
  end

  defp handle_lifecycle_event(integration, event_type) do
    Logger.warning("Outlook lifecycle: unrecognised event type",
      integration_id: integration.id,
      lifecycle_event: event_type
    )
  end

  defp enqueue_token_refresh(integration) do
    case %{"integration_id" => integration.id} |> TokenRefreshJob.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue TokenRefreshJob", reason: inspect(reason))
    end
  end

  defp enqueue_reregistration(integration) do
    args = %{"calendar_integration_id" => integration.id}

    case args |> ReregisterOutlookSubscriptionWorker.new() |> Oban.insert() do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to enqueue ReregisterOutlookSubscriptionWorker",
          integration_id: integration.id,
          reason: inspect(reason)
        )
    end
  end
end
