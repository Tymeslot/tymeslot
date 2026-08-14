defmodule Tymeslot.Workers.RenewWebhookChannelsWorker do
  @moduledoc """
  Oban worker that proactively renews expiring Google Calendar push channels
  and Microsoft Graph subscriptions.

  Runs daily at 02:00 UTC. Fetches all integrations whose webhook channel or
  Graph subscription expires within the next 48 hours, then re-registers each
  one. A random stagger of 0–30 seconds between renewals avoids burst traffic
  to provider APIs.

  When `WEBHOOK_BASE_URL` is configured, the same run also backfills
  integrations that have no channel/subscription yet — those connected before
  push was enabled. The daily cadence doubles as retry throttling: a
  registration that keeps failing is retried at most once per day rather than
  on every fallback-sync tick.
  """

  use Oban.Worker,
    queue: :calendar_integrations,
    max_attempts: 3,
    unique: [period: 86_400]

  use Gettext, backend: TymeslotWeb.Gettext

  require Logger

  alias Tymeslot.Infrastructure.Config
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationQueries
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationSchema
  alias Tymeslot.Integrations.Calendar.CalendarIntegrationWebhookQueries
  alias Tymeslot.Integrations.CalendarManagement

  # Batch entry point: enumerate expiring integrations and schedule one
  # per-integration renewal job with a staggered `schedule_in` delay.
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
  @impl Oban.Worker
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

      {:error, :requires_reencryption, integration} ->
        CalendarManagement.handle_reauth_required(integration)
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp schedule_google_renewals do
    expiring = CalendarIntegrationWebhookQueries.list_expiring_google_channels(48)

    unregistered =
      backfill(&CalendarIntegrationWebhookQueries.list_unregistered_google_channels/0)

    schedule_renewal_jobs(expiring ++ unregistered, "google")
  end

  defp schedule_outlook_renewals do
    expiring = CalendarIntegrationWebhookQueries.list_expiring_outlook_subscriptions(48)

    unregistered =
      backfill(&CalendarIntegrationWebhookQueries.list_unregistered_outlook_subscriptions/0)

    schedule_renewal_jobs(expiring ++ unregistered, "outlook")
  end

  # Push registration backfill: integrations connected before WEBHOOK_BASE_URL
  # was configured have no channel/subscription. When push is enabled, fold them
  # into the daily run so they adopt push automatically. Expiring and unregistered
  # lists are disjoint (expiring requires a non-nil id, unregistered requires nil),
  # so no deduplication is needed. When push is disabled the backfill is skipped
  # entirely, leaving polling-only deployments untouched.
  defp backfill(list_fun) do
    if push_enabled?(), do: list_fun.(), else: []
  end

  defp push_enabled? do
    case Application.get_env(:tymeslot, :webhook_base_url) do
      url when is_binary(url) -> String.trim(url) != ""
      _other -> false
    end
  end

  defp schedule_renewal_jobs(integrations, provider) do
    integrations
    |> Enum.with_index()
    |> Enum.flat_map(fn {integration, index} ->
      stagger = index * Enum.random(5..30)

      case %{
             "calendar_integration_id" => integration.id,
             "provider" => provider
           }
           |> new(schedule_in: stagger)
           |> Oban.insert() do
        {:ok, _job} ->
          [integration.id]

        {:error, reason} ->
          Logger.warning("Failed to enqueue webhook renewal job",
            calendar_integration_id: integration.id,
            provider: provider,
            error: inspect(reason)
          )

          []
      end
    end)
  end

  # The two providers differ only in which API call registers the subscription
  # and what it is called in the logs. Every decision about the outcome is
  # identical, so it is made once in `handle_renewal/3`.
  @renewal_labels %{
    "google" => "Google Calendar push channel",
    "outlook" => "Outlook Graph subscription"
  }

  defp renew_single(integration, "google" = provider) do
    api = Config.google_calendar_api_module()

    integration
    |> api.register_push_channel()
    |> handle_renewal(integration, provider)
  end

  defp renew_single(integration, "outlook" = provider) do
    api = Config.outlook_calendar_api_module()

    integration
    |> api.register_graph_subscription()
    |> handle_renewal(integration, provider)
  end

  defp handle_renewal({:ok, _updated}, _integration, _provider), do: :ok

  defp handle_renewal({:error, :webhook_base_url_not_configured}, integration, provider) do
    Logger.warning("Webhook base URL not configured; skipping renewal",
      calendar_integration_id: integration.id,
      channel_kind: @renewal_labels[provider]
    )

    :ok
  end

  # The channel endpoint is calendar-scoped, so a 404 means the calendar this
  # integration books into is gone at the provider (see
  # `Integrations.Calendar.HTTP.not_found_message/1`). Retrying re-asks a
  # settled question, and the third attempt raises a permanent-failure admin
  # alert every single day about a condition only the owner can resolve. Flag
  # for reconnection and discard, matching what the sync workers already do
  # with the same 404.
  defp handle_renewal({:error, :not_found, _reason}, integration, provider) do
    Logger.warning(
      "Booking calendar no longer exists; flagging integration for reconnection",
      calendar_integration_id: integration.id,
      provider: provider
    )

    CalendarManagement.flag_for_reconnection(
      integration,
      booking_calendar_missing_message(provider),
      "Booking calendar not found — user action required"
    )
  end

  defp handle_renewal({:error, _type, reason}, integration, provider),
    do: log_renewal_failure(integration, provider, reason)

  defp handle_renewal({:error, reason}, integration, provider),
    do: log_renewal_failure(integration, provider, reason)

  defp log_renewal_failure(integration, provider, reason) do
    Logger.error("Failed to renew webhook channel",
      calendar_integration_id: integration.id,
      channel_kind: @renewal_labels[provider],
      error: inspect(reason)
    )

    {:error, reason}
  end

  # Separate clauses rather than an interpolated provider name: gettext
  # extracts literals, so an interpolated msgid could never be translated.
  defp booking_calendar_missing_message("google") do
    dgettext(
      "dashboard_calendar_providers",
      "The booking calendar no longer exists on Google. Please reconnect the integration and choose a different calendar."
    )
  end

  defp booking_calendar_missing_message("outlook") do
    dgettext(
      "dashboard_calendar_providers",
      "The booking calendar no longer exists on Outlook. Please reconnect the integration and choose a different calendar."
    )
  end
end
