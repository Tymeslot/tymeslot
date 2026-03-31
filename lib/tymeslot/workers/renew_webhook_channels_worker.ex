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

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    google_renewed = renew_google_channels()
    outlook_renewed = renew_outlook_subscriptions()

    Logger.info("Webhook channel renewal complete",
      google_channels_renewed: google_renewed,
      outlook_subscriptions_renewed: outlook_renewed
    )

    :ok
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

  defp renew_google_channels do
    integrations =
      48
      |> CalendarIntegrationQueries.list_expiring_google_channels()
      |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)

    renew_integrations(
      integrations,
      fn integration -> google_calendar_api().register_push_channel(integration) end,
      "Webhook base URL not configured; skipping Google push channel renewal",
      "Failed to renew Google Calendar push channel"
    )
  end

  defp renew_outlook_subscriptions do
    integrations =
      48
      |> CalendarIntegrationQueries.list_expiring_outlook_subscriptions()
      |> Enum.map(&CalendarIntegrationSchema.decrypt_oauth_tokens/1)

    renew_integrations(
      integrations,
      fn integration -> outlook_calendar_api().register_graph_subscription(integration) end,
      "Webhook base URL not configured; skipping Outlook Graph subscription renewal",
      "Failed to renew Outlook Graph subscription"
    )
  end

  defp renew_integrations(integrations, register_fn, skip_log, error_log) do
    integrations
    |> Enum.with_index()
    |> Enum.reduce(0, fn {integration, index}, renewed ->
      if index > 0, do: Process.sleep(:rand.uniform(3) * 1_000)

      case register_fn.(integration) do
        {:ok, _updated} ->
          renewed + 1

        {:error, :webhook_base_url_not_configured} ->
          Logger.warning(skip_log, calendar_integration_id: integration.id)
          renewed

        {:error, reason} ->
          Logger.error(error_log, calendar_integration_id: integration.id, error: inspect(reason))
          renewed
      end
    end)
  end
end
