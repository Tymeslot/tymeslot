defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypes do
  @moduledoc """
  Central registry of all admin alert types.

  Each alert type is defined once in `@registry` with its category and severity.
  The `format_message/2` function provides human-readable messages for each type.

  To add a new alert type:
  1. Add an entry to `@registry`
  2. Add a `format_message/2` clause

  This module lives in Core so that both standalone (Core) and SaaS deployments
  can use the same registry. Some registered types (e.g. `:reconciliation_discrepancies`)
  are only raised by SaaS call sites, but the definitions live here so Core can
  format any incoming alert uniformly.
  """

  @registry %{
    unhandled_webhook: %{category: "Webhook", severity: :warning},
    refund_processed: %{category: "Payment", severity: :info},
    unlinked_refund: %{category: "Payment", severity: :error},
    dispute_created: %{category: "Dispute", severity: :error},
    dispute_lost: %{category: "Dispute", severity: :error},
    calendar_sync_error: %{category: "Calendar", severity: :error},
    invalid_calendar_event: %{category: "Calendar", severity: :warning},
    pubsub_broadcast_failed: %{category: "System", severity: :error},
    integration_health_failure: %{category: "System", severity: :error},
    integration_health_recovery: %{category: "System", severity: :info},
    oban_queue_stuck: %{category: "Queue", severity: :error},
    oban_jobs_accumulating: %{category: "Queue", severity: :warning},
    oban_job_failure: %{category: "Queue", severity: :error},
    unhandled_crash: %{category: "System", severity: :error},
    reconciliation_discrepancies: %{category: "Payment", severity: :warning},
    subscription_not_in_database: %{category: "Payment", severity: :warning}
  }

  @doc "Returns the full registry map for enumeration and lookup."
  @spec registered_types() :: %{
          atom() => %{category: String.t(), severity: :info | :warning | :error}
        }
  def registered_types, do: @registry

  @doc "Looks up category and severity for the given alert type. Returns nil for unknown types."
  @spec get(atom()) :: %{category: String.t(), severity: :info | :warning | :error} | nil
  def get(type), do: Map.get(@registry, type)

  @doc """
  Returns a stable identity string used to deduplicate repeat alerts.

  Defaults to the formatted message. Add a clause when the message embeds
  per-occurrence detail (ids, error text) that would defeat deduplication —
  a burst of permanently failed jobs from one broken worker should collapse
  into a single alert per dedup window, not one email per job.
  """
  @spec dedup_key(atom(), map()) :: String.t()
  def dedup_key(:oban_job_failure, metadata) do
    worker = Map.get(metadata, :worker, "unknown")
    queue = Map.get(metadata, :queue, "unknown")
    "oban_job_failure:#{worker}:#{queue}"
  end

  # Crash alerts carry stable crash-identity fields (reason_code + the top
  # stacktrace frame). Dedup on those rather than the rendered message so a
  # crash storm with per-occurrence detail (e.g. a user id in the message)
  # collapses into a single alert per 24h window instead of one email each.
  # The stacktrace is a multi-line string; only the first line is used so
  # frame counts that drift over time don't fragment the key.
  def dedup_key(:unhandled_crash, metadata) do
    reason_code = Map.get(metadata, :reason_code)
    stacktrace = Map.get(metadata, :stacktrace)

    if reason_code && stacktrace do
      top_frame =
        stacktrace |> to_string() |> String.split("\n") |> List.first("") |> String.trim()

      "unhandled_crash:#{reason_code}:#{top_frame}"
    else
      format_message(:unhandled_crash, metadata)
    end
  end

  def dedup_key(type, metadata), do: format_message(type, metadata)

  @doc "Formats a human-readable message for the given alert type and metadata."
  @spec format_message(atom(), map()) :: String.t()
  def format_message(:unhandled_webhook, metadata) do
    type = Map.get(metadata, :event_type, "unknown")
    id = Map.get(metadata, :event_id, "unknown")
    "Unhandled Stripe webhook event: #{type} (ID: #{id})"
  end

  # Call sites pass :total_refunded; :amount is accepted as a fallback for
  # any callers that haven't been migrated yet.
  def format_message(:refund_processed, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")
    amount = Map.get(metadata, :total_refunded, Map.get(metadata, :amount, "unknown"))
    "Refund of #{amount} processed for user #{user_id}"
  end

  def format_message(:unlinked_refund, metadata) do
    charge_id = Map.get(metadata, :charge_id, "unknown")
    amount = Map.get(metadata, :total_refunded, Map.get(metadata, :amount, "unknown"))
    "Unlinked refund of #{amount} received for charge #{charge_id}"
  end

  def format_message(:dispute_created, metadata) do
    id = Map.get(metadata, :dispute_id, "unknown")
    reason = Map.get(metadata, :reason, "unknown")
    "New dispute created: #{id} (Reason: #{reason}) — Manual review required"
  end

  def format_message(:dispute_lost, metadata) do
    id = Map.get(metadata, :dispute_id, "unknown")
    user_id = Map.get(metadata, :user_id, "unknown")
    "Dispute lost: #{id} for user #{user_id} — Consider manual access revocation"
  end

  def format_message(:calendar_sync_error, metadata) do
    email = Map.get(metadata, :owner_email, "unknown")
    reason = Map.get(metadata, :reason, "unknown")
    "Calendar sync error for #{email}: #{format_reason(reason)}"
  end

  def format_message(:pubsub_broadcast_failed, metadata) do
    event = Map.get(metadata, :event, "unknown")
    "PubSub broadcast failed for #{event}"
  end

  def format_message(:integration_health_failure, metadata) do
    integration_id = Map.get(metadata, :integration_id, "unknown")
    "Integration health check failed for integration #{integration_id}"
  end

  def format_message(:integration_health_recovery, metadata) do
    integration_id = Map.get(metadata, :integration_id, "unknown")
    "Integration #{integration_id} recovered from health check failure"
  end

  def format_message(:oban_queue_stuck, metadata) do
    queues = Map.get(metadata, :affected_queues, [])
    state = Map.get(metadata, :job_state, "unknown")
    "Oban queues stuck with #{state} jobs: #{inspect(queues)}"
  end

  def format_message(:oban_jobs_accumulating, metadata) do
    queues = Map.get(metadata, :affected_queues, [])
    threshold = Map.get(metadata, :threshold, "unknown")
    "Oban job accumulation detected (threshold: #{threshold}): #{inspect(queues)}"
  end

  def format_message(:oban_job_failure, metadata) do
    worker = Map.get(metadata, :worker, "unknown")
    queue = Map.get(metadata, :queue, "unknown")
    reason = Map.get(metadata, :reason_message) || Map.get(metadata, :reason_code, "unknown")
    "Oban job #{worker} (queue: #{queue}) failed permanently: #{reason}"
  end

  def format_message(:reconciliation_discrepancies, metadata) do
    count = Map.get(metadata, :discrepancies_count, "unknown")
    "Payment reconciliation found #{count} discrepancies"
  end

  def format_message(:subscription_not_in_database, metadata) do
    stripe_id = Map.get(metadata, :stripe_subscription_id, "unknown")
    "Active Stripe subscription #{stripe_id} has no matching database record"
  end

  def format_message(:invalid_calendar_event, metadata) do
    provider = Map.get(metadata, :provider, "unknown")
    reason = Map.get(metadata, :reason, "unknown")
    event_id = Map.get(metadata, :event_id) || Map.get(metadata, :event_uid, "unknown")
    "Invalid #{provider} calendar event (event_id: #{event_id}): #{reason}"
  end

  def format_message(:unhandled_crash, metadata) do
    kind = Map.get(metadata, :kind, "error")
    detail = Map.get(metadata, :reason_message) || Map.get(metadata, :summary, "unknown")
    "Unhandled #{kind} crash: #{detail}"
  end

  def format_message(type, _metadata) do
    "Alert: #{type}"
  end

  defp format_reason(reason) when is_exception(reason), do: Exception.message(reason)
  defp format_reason(reason) when is_binary(reason) or is_atom(reason), do: to_string(reason)
  defp format_reason(reason), do: inspect(reason)
end
