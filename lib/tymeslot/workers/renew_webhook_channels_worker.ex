defmodule Tymeslot.Workers.RenewWebhookChannelsWorker do
  @moduledoc """
  Oban worker that proactively renews expiring Google Calendar push channels
  and Microsoft Graph subscriptions.

  Runs daily at 02:00 UTC. Fetches all integrations whose webhook channel or
  Graph subscription expires within the next 48 hours, then re-registers each
  one. A random stagger of 0–30 seconds between renewals avoids burst traffic
  to provider APIs.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    unique: [period: 86_400]

  require Logger

  alias Tymeslot.DatabaseQueries.CalendarIntegrationQueries
  alias Tymeslot.DatabaseSchemas.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.Google.CalendarAPI, as: GoogleCalendarAPI
  alias Tymeslot.Integrations.Calendar.Outlook.CalendarAPI, as: OutlookCalendarAPI

  # Batch entry point: enumerate expiring integrations and schedule one
  # per-integration renewal job with a staggered `scheduled_in` delay.
  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) when not is_map_key(args, "calendar_integration_id") do
    google_ids = schedule_google_renewals()
    outlook_ids = schedule_outlook_renewals()

    Logger.info("Webhook channel renewal jobs scheduled",
      google_channels_scheduled: length(google_ids),
      outlook_subscriptions_scheduled: length(outlook_ids)
    )

    :ok
  end

  # Per-integration renewal: renew a single integration's webhook channel.
  def perform(%Oban.Job{
        args: %{"calendar_integration_id" => integration_id, "provider" => provider}
      }) do
    case CalendarIntegrationQueries.get(integration_id) do
      {:ok, integration} ->
        integration = CalendarIntegrationSchema.decrypt_oauth_tokens(integration)
        renew_single(integration, provider)

      {:error, :not_found} ->
        Logger.warning("Integration not found for webhook renewal; discarding",
          calendar_integration_id: integration_id
        )

        {:discard, "Integration not found"}
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp google_calendar_api do
    Application.get_env(:tymeslot, :google_calendar_api_module, GoogleCalendarAPI)
  end

  defp outlook_calendar_api do
    Application.get_env(:tymeslot, :outlook_calendar_api_module, OutlookCalendarAPI)
  end

  defp schedule_google_renewals do
    48
    |> CalendarIntegrationQueries.list_expiring_google_channels()
    |> schedule_renewal_jobs("google")
  end

  defp schedule_outlook_renewals do
    48
    |> CalendarIntegrationQueries.list_expiring_outlook_subscriptions()
    |> schedule_renewal_jobs("outlook")
  end

  defp schedule_renewal_jobs(integrations, provider) do
    integrations
    |> Enum.with_index()
    |> Enum.map(fn {integration, index} ->
      stagger = index * Enum.random(5..30)

      %{
        "calendar_integration_id" => integration.id,
        "provider" => provider
      }
      |> new(scheduled_in: stagger)
      |> Oban.insert()

      integration.id
    end)
  end

  defp renew_single(integration, "google") do
    case google_calendar_api().register_push_channel(integration) do
      {:ok, _updated} ->
        :ok

      {:error, :webhook_base_url_not_configured} ->
        Logger.warning(
          "Webhook base URL not configured; skipping Google push channel renewal",
          calendar_integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to renew Google Calendar push channel",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end

  defp renew_single(integration, "outlook") do
    case outlook_calendar_api().register_graph_subscription(integration) do
      {:ok, _updated} ->
        :ok

      {:error, :webhook_base_url_not_configured} ->
        Logger.warning(
          "Webhook base URL not configured; skipping Outlook Graph subscription renewal",
          calendar_integration_id: integration.id
        )

        :ok

      {:error, reason} ->
        Logger.error("Failed to renew Outlook Graph subscription",
          calendar_integration_id: integration.id,
          error: inspect(reason)
        )

        {:error, reason}
    end
  end
end
