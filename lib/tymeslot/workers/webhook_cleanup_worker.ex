defmodule Tymeslot.Workers.WebhookCleanupWorker do
  @moduledoc """
  Oban worker for cleaning up old webhook data.

  Cleans up:
  1. Outgoing webhook delivery logs (60 days retention)
  2. Incoming Stripe webhook events (90 days retention)

  Ensures the database doesn't grow indefinitely by removing
  old records based on configured retention periods.
  """

  use Oban.Worker,
    queue: :default,
    max_attempts: 3,
    unique: [period: 3600]

  require Logger

  import Ecto.Query
  alias Tymeslot.DatabaseQueries.WebhookQueries
  alias Tymeslot.DatabaseSchemas.WebhookEventSchema, as: WebhookEvent
  alias Tymeslot.Repo

  @impl Oban.Worker
  def perform(%Oban.Job{args: args}) do
    # Clean up outgoing webhook deliveries
    cleanup_outgoing_webhooks(args)

    # Nullify payloads on incoming Stripe events past the payload retention window
    nullify_stale_payloads(args)

    # Clean up incoming Stripe webhook events
    cleanup_incoming_webhook_events(args)

    :ok
  end

  defp cleanup_outgoing_webhooks(args) do
    # Default to 60 days retention
    retention_days =
      Map.get(args, "retention_days") ||
        get_in(Application.get_env(:tymeslot, :payments, []), [:retention, :outgoing_webhook_days]) ||
        60

    Logger.info("Starting webhook delivery cleanup", retention_days: retention_days)

    {count, _rows} = WebhookQueries.cleanup_old_deliveries(retention_days)

    Logger.info("Webhook delivery cleanup completed",
      deleted_count: count,
      retention_days: retention_days
    )
  end

  defp nullify_stale_payloads(args) do
    retention_days =
      Map.get(args, "payload_retention_days") ||
        get_in(Application.get_env(:tymeslot, :payments, []), [:retention, :payload_days]) ||
        30

    cutoff_date =
      DateTime.utc_now()
      |> DateTime.add(-retention_days, :day)
      |> DateTime.to_naive()

    query =
      from(w in WebhookEvent,
        where: w.inserted_at < ^cutoff_date and not is_nil(w.payload)
      )

    case Repo.update_all(query, set: [payload: nil]) do
      {count, _nil} when count > 0 ->
        Logger.info("Nullified stale webhook payloads",
          count: count,
          retention_days: retention_days
        )

      {0, _nil} ->
        Logger.debug("No stale webhook payloads to nullify")
    end
  end

  defp cleanup_incoming_webhook_events(args) do
    # Default to 90 days retention for Stripe events
    retention_days =
      Map.get(args, "stripe_event_retention_days") ||
        get_in(Application.get_env(:tymeslot, :payments, []), [:retention, :stripe_event_days]) ||
        90

    # WebhookEventSchema.inserted_at is a NaiveDateTime (:naive_datetime), so the
    # cutoff must be NaiveDateTime too — passing a DateTime silently fails to match.
    cutoff_date =
      DateTime.utc_now()
      |> DateTime.add(-retention_days, :day)
      |> DateTime.to_naive()

    query =
      from(w in WebhookEvent,
        where: w.inserted_at < ^cutoff_date
      )

    case Repo.delete_all(query) do
      {count, nil} when count > 0 ->
        Logger.info("Cleaned up old Stripe webhook events",
          count: count,
          retention_days: retention_days
        )

      {0, nil} ->
        Logger.debug("No old Stripe webhook events to clean up")

      error ->
        Logger.error("Failed to clean up Stripe webhook events", error: error)
    end
  end
end
