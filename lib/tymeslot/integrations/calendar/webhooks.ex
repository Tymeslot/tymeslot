defmodule Tymeslot.Integrations.Calendar.Webhooks do
  @moduledoc """
  Handles calendar provider push notifications once the web layer has parsed
  them out of the request.

  Each handler finds the integration a notification belongs to, checks the
  secret the provider echoes back against the one stored at registration,
  applies the per-integration rate limit, and enqueues the background work the
  notification calls for:

    * a Google push notification enqueues an incremental calendar sync;
    * a Microsoft Graph change notification enqueues a sync of the one event
      it names;
    * a Microsoft Graph lifecycle notification enqueues a token refresh and a
      subscription re-registration (`reauthorizationRequired`), or only the
      re-registration (`subscriptionRemoved`).

  Unknown, unverifiable and rate-limited notifications are dropped without
  side effects. The callers acknowledge every notification regardless of the
  outcome, so providers do not retry, and none of these functions raise on a
  failed enqueue: the failure is logged instead.
  """

  require Logger

  alias Plug.Crypto
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.Calendar.TokenRefreshJob
  alias Tymeslot.Security.RateLimiter
  alias Tymeslot.Workers.ReregisterOutlookSubscriptionWorker
  alias Tymeslot.Workers.SyncGoogleCalendarWorker
  alias Tymeslot.Workers.SyncOutlookCalendarWorker

  @type integration :: CalendarIntegrationSchema.t()

  # Bounds the lookups and job inserts one Graph request can cause.
  @max_notifications_per_batch 50

  # Gives the token refresh a head start before the subscription it
  # re-registers needs the refreshed token.
  @reregistration_delay_after_refresh_seconds 30

  @doc """
  Handles a Google Calendar push notification identified by the
  `X-Goog-Channel-ID` and `X-Goog-Channel-Token` header values.

  Enqueues a `SyncGoogleCalendarWorker` job for the integration owning the
  channel and records the notification time. A missing header is passed as an
  empty string and fails verification.
  """
  @spec handle_google_notification(String.t(), String.t()) ::
          :ok | {:error, :not_found | :invalid_token | :rate_limited | :enqueue_failed}
  def handle_google_notification(channel_id, channel_token)
      when is_binary(channel_id) and is_binary(channel_token) do
    with {:ok, integration} <-
           CalendarIntegrationWebhookQueries.get_by_google_channel_id(channel_id),
         :ok <- verify_google_token(integration, channel_id, channel_token),
         :ok <- check_rate_limit(integration, "Google Calendar webhook rate limited"),
         :ok <- enqueue_google_sync(integration) do
      touch_notification_at(integration, :last_google_notification_at)
    end
  end

  @doc """
  Handles the `value` list of a Microsoft Graph change notification payload.

  Each notification whose subscription and `clientState` match an integration
  enqueues a `SyncOutlookCalendarWorker` job for the event in its
  `resourceData` and records the notification time. Only the first
  #{@max_notifications_per_batch} notifications are considered.
  """
  @spec handle_outlook_notifications([map()]) :: :ok
  def handle_outlook_notifications(notifications) when is_list(notifications) do
    notifications = Enum.take(notifications, @max_notifications_per_batch)

    integrations_by_subscription_id =
      notifications
      |> Enum.map(& &1["subscriptionId"])
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> load_integrations_by_subscription_id()

    Enum.each(notifications, &handle_outlook_notification(&1, integrations_by_subscription_id))
  end

  @doc """
  Handles the `value` list of a Microsoft Graph lifecycle notification payload.

  Only the first event per subscription is acted on, and only the first
  #{@max_notifications_per_batch} events are considered. See the module
  documentation for what each lifecycle event enqueues.
  """
  @spec handle_outlook_lifecycle_notifications([map()]) :: :ok
  def handle_outlook_lifecycle_notifications(notifications) when is_list(notifications) do
    notifications
    |> Enum.take(@max_notifications_per_batch)
    |> Enum.uniq_by(& &1["subscriptionId"])
    |> Enum.each(&handle_lifecycle_notification/1)
  end

  # Google

  defp verify_google_token(integration, channel_id, channel_token) do
    if valid_secret?(channel_token, integration.google_channel_secret) do
      :ok
    else
      Logger.warning("Google Calendar webhook: token verification failed",
        channel_id: channel_id,
        integration_id: integration.id
      )

      {:error, :invalid_token}
    end
  end

  defp enqueue_google_sync(integration) do
    %{"calendar_integration_id" => integration.id}
    |> SyncGoogleCalendarWorker.new()
    |> insert_job(integration, "Failed to enqueue SyncGoogleCalendarWorker")
  end

  # Outlook change notifications

  defp load_integrations_by_subscription_id([]), do: %{}

  defp load_integrations_by_subscription_id(subscription_ids) do
    subscription_ids
    |> CalendarIntegrationWebhookQueries.get_by_graph_subscription_ids()
    |> Map.new(&{&1.graph_subscription_id, &1})
  end

  defp handle_outlook_notification(
         %{"subscriptionId" => subscription_id} = notification,
         integrations
       ) do
    with {:ok, integration} <- Map.fetch(integrations, subscription_id),
         :ok <-
           verify_client_state(
             integration,
             notification,
             "Outlook Calendar webhook: clientState verification failed"
           ),
         :ok <- check_rate_limit(integration, "Outlook Calendar webhook rate limited") do
      sync_outlook_resource(integration, notification)
    end
  end

  defp handle_outlook_notification(_notification, _integrations), do: :ok

  defp sync_outlook_resource(integration, notification) do
    case get_in(notification, ["resourceData", "id"]) do
      nil ->
        Logger.warning("Outlook webhook notification missing resourceData",
          subscription_id: notification["subscriptionId"]
        )

      graph_resource_id ->
        %{"calendar_integration_id" => integration.id, "graph_resource_id" => graph_resource_id}
        |> SyncOutlookCalendarWorker.new()
        |> insert_job(integration, "Failed to enqueue SyncOutlookCalendarWorker")

        touch_notification_at(integration, :last_outlook_notification_at)
    end
  end

  # Outlook lifecycle notifications

  defp handle_lifecycle_notification(
         %{"subscriptionId" => subscription_id, "lifecycleEvent" => event_type} = notification
       ) do
    with {:ok, integration} <-
           CalendarIntegrationWebhookQueries.get_by_graph_subscription_id(subscription_id),
         :ok <-
           verify_client_state(
             integration,
             notification,
             "Outlook lifecycle: clientState verification failed"
           ),
         :ok <- check_rate_limit(integration, "Outlook lifecycle webhook rate limited") do
      handle_lifecycle_event(integration, event_type)
    end
  end

  defp handle_lifecycle_notification(_notification), do: :ok

  defp handle_lifecycle_event(integration, "reauthorizationRequired") do
    Logger.info("Outlook Graph subscription requires reauthorization",
      integration_id: integration.id,
      graph_subscription_id: integration.graph_subscription_id
    )

    %{"integration_id" => integration.id}
    |> TokenRefreshJob.new()
    |> insert_job(integration, "Failed to enqueue TokenRefreshJob")

    enqueue_reregistration(integration,
      schedule_in: @reregistration_delay_after_refresh_seconds
    )
  end

  defp handle_lifecycle_event(integration, "subscriptionRemoved") do
    Logger.info("Outlook Graph subscription removed; re-registering",
      integration_id: integration.id,
      graph_subscription_id: integration.graph_subscription_id
    )

    enqueue_reregistration(integration, [])
  end

  defp handle_lifecycle_event(integration, event_type) do
    Logger.warning("Outlook lifecycle: unrecognised event type",
      integration_id: integration.id,
      lifecycle_event: event_type
    )
  end

  defp enqueue_reregistration(integration, opts) do
    %{"calendar_integration_id" => integration.id}
    |> ReregisterOutlookSubscriptionWorker.new(opts)
    |> insert_job(integration, "Failed to enqueue ReregisterOutlookSubscriptionWorker")
  end

  # Shared

  defp verify_client_state(integration, notification, failure_message) do
    if valid_secret?(notification["clientState"], integration.graph_client_state) do
      :ok
    else
      Logger.warning(failure_message,
        subscription_id: notification["subscriptionId"],
        integration_id: integration.id
      )

      {:error, :invalid_client_state}
    end
  end

  # Timing-safe; an absent or empty secret on either side never matches.
  defp valid_secret?(received, expected)
       when is_binary(received) and is_binary(expected) and byte_size(received) > 0 and
              byte_size(expected) > 0 do
    Crypto.secure_compare(received, expected)
  end

  defp valid_secret?(_received, _expected), do: false

  defp check_rate_limit(integration, message) do
    case RateLimiter.check_calendar_webhook_rate_limit(integration.id) do
      :ok ->
        :ok

      {:error, :rate_limited} = error ->
        Logger.warning(message, integration_id: integration.id)
        error
    end
  end

  defp insert_job(job, integration, failure_message) do
    case Oban.insert(job) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(failure_message, integration_id: integration.id, reason: inspect(reason))
        {:error, :enqueue_failed}
    end
  end

  defp touch_notification_at(integration, field) do
    case CalendarIntegrationWebhookQueries.touch_notification_at(integration, field) do
      {:ok, _updated} ->
        :ok

      {:error, changeset} ->
        Logger.error("Failed to update the webhook notification timestamp",
          integration_id: integration.id,
          field: field,
          reason: inspect(changeset)
        )

        :ok
    end
  end
end
