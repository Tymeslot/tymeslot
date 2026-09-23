defmodule Tymeslot.Workers.DataRetentionWorker do
  @moduledoc """
  Cross-domain Oban worker that prunes old data across several unrelated
  domains on a shared schedule.

  Cleans up:
  1. Outgoing webhook delivery logs (60 days retention)
  2. Incoming Stripe webhook events (90 days retention)
  3. Slack delivery logs (60 days retention)
  4. Telegram delivery logs (60 days retention)
  5. Analytics page-view events (90 days retention)
  6. Hourly calendar availability refusal counters (30 days retention)
  7. Abandoned Telegram setup stubs (own minute-scale TTL, not a day count)

  Ensures the database doesn't grow indefinitely by removing
  old records based on configured retention periods.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3600]

  require Logger

  alias Tymeslot.Analytics
  alias Tymeslot.Integrations.HealthCheck.AvailabilityRefusalQueries
  alias Tymeslot.Slack
  alias Tymeslot.Telegram
  alias Tymeslot.Webhooks.WebhookQueries

  @retention Application.compile_env(:tymeslot, :payments, [])[:retention] || []

  # Each entry drives one `run_cleanup/2` pass: which args key overrides the
  # retention window, which `@retention` key and literal back it up, and
  # which prune function (always `(days) -> {deleted_count, nil}`) to call.
  @retention_jobs [
    %{
      name: "webhook delivery",
      args_key: "retention_days",
      config_key: :outgoing_webhook_days,
      default_days: 60,
      prune: &WebhookQueries.cleanup_old_deliveries/1
    },
    %{
      name: "Stripe webhook event",
      args_key: "stripe_event_retention_days",
      config_key: :stripe_event_days,
      default_days: 90,
      prune: &__MODULE__.prune_incoming_webhook_events/1
    },
    %{
      name: "Slack delivery",
      args_key: "slack_delivery_retention_days",
      config_key: :outgoing_webhook_days,
      default_days: 60,
      prune: &Slack.prune_deliveries/1
    },
    %{
      name: "Telegram delivery",
      args_key: "telegram_delivery_retention_days",
      config_key: :outgoing_webhook_days,
      default_days: 60,
      prune: &Telegram.prune_deliveries/1
    },
    %{
      name: "analytics event",
      args_key: "analytics_event_retention_days",
      config_key: :analytics_event_days,
      default_days: 90,
      prune: &Analytics.prune_events/1
    },
    %{
      name: "availability refusal",
      args_key: "availability_refusal_retention_days",
      config_key: :availability_refusal_days,
      default_days: 30,
      prune: &AvailabilityRefusalQueries.prune_older_than/1
    }
  ]

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Nullify payloads on incoming Stripe events past the payload retention window
    nullify_stale_payloads(args)

    prune_orphaned_telegram_stubs()

    Enum.each(@retention_jobs, &run_cleanup(&1, args))

    :ok
  end

  @doc false
  # Public only so it can be captured as `&__MODULE__.prune_incoming_webhook_events/1`
  # in `@retention_jobs`; not part of the worker's external API.
  @spec prune_incoming_webhook_events(integer()) :: {non_neg_integer(), nil}
  def prune_incoming_webhook_events(days) do
    cutoff_date = DateTime.add(DateTime.utc_now(), -days, :day)
    WebhookQueries.delete_old_webhook_events(cutoff_date)
  end

  defp run_cleanup(
         %{
           name: name,
           args_key: args_key,
           config_key: config_key,
           default_days: default_days,
           prune: prune
         },
         args
       ) do
    retention_days =
      Map.get(args, args_key) ||
        @retention[config_key] ||
        default_days

    Logger.info("Starting retention cleanup", job: name, retention_days: retention_days)

    {count, _rows} = prune.(retention_days)

    Logger.info("Retention cleanup completed",
      job: name,
      deleted_count: count,
      retention_days: retention_days
    )
  end

  # Deliberately not a `@retention_jobs` entry: those take a retention window
  # in whole days, while an abandoned link-flow stub expires after minutes and
  # owns its own TTL in `TelegramQueries`.
  defp prune_orphaned_telegram_stubs do
    case Telegram.prune_orphaned_stubs() do
      {count, _rows} when count > 0 ->
        Logger.info("Pruned abandoned Telegram setup stubs", deleted_count: count)

      {0, _rows} ->
        Logger.debug("No abandoned Telegram setup stubs to prune")
    end
  end

  defp nullify_stale_payloads(args) do
    retention_days =
      Map.get(args, "payload_retention_days") ||
        @retention[:payload_days] ||
        30

    cutoff_date = DateTime.add(DateTime.utc_now(), -retention_days, :day)

    case WebhookQueries.nullify_stale_payloads(cutoff_date) do
      {count, _nil} when count > 0 ->
        Logger.info("Nullified stale webhook payloads",
          count: count,
          retention_days: retention_days
        )

      {0, _nil} ->
        Logger.debug("No stale webhook payloads to nullify")
    end
  end
end
