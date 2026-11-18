defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypes do
  @moduledoc """
  Central registry of all admin alert types.

  Each alert type is defined once in `@registry` with its category and severity.
  `format_message/2` and `dedup_key/2` delegate to the sibling modules that
  hold each type's message and deduplication key.

  To add a new alert type:
  1. Add an entry to `@registry`
  2. Add a `format_message/2` clause in `alert_types/messages.ex`
  3. If the message embeds per-occurrence detail, give the type its own key in
     `alert_types/dedup_key.ex` (a `@keyed_on` entry, or a `dedup_key/2` clause)

  This module lives in Core so that both standalone (Core) and SaaS deployments
  can use the same registry. Some registered types (e.g. `:reconciliation_discrepancies`)
  are only raised by SaaS call sites, but the definitions live here so Core can
  format any incoming alert uniformly.
  """

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes.{DedupKey, Messages}

  @registry %{
    unhandled_webhook: %{category: "Webhook", severity: :warning},
    refund_processed: %{category: "Payment", severity: :info},
    unlinked_refund: %{category: "Payment", severity: :error},
    dispute_created: %{category: "Dispute", severity: :error},
    dispute_lost: %{category: "Dispute", severity: :error},
    calendar_sync_error: %{category: "Calendar", severity: :error},
    invalid_calendar_event: %{category: "Calendar", severity: :warning},
    integration_health_failure: %{category: "System", severity: :error},
    integration_health_recovery: %{category: "System", severity: :info},
    oban_queue_stuck: %{category: "Queue", severity: :error},
    oban_jobs_accumulating: %{category: "Queue", severity: :warning},
    oban_jobs_force_discarded: %{category: "Queue", severity: :error},
    circuit_breaker_open: %{category: "System", severity: :warning},
    database_pool_pressure: %{category: "System", severity: :warning},
    stripe_webhook_secret_missing: %{category: "Payment", severity: :error},
    new_error: %{category: "Errors", severity: :error},
    error_regression: %{category: "Errors", severity: :error},
    reconciliation_discrepancies: %{category: "Payment", severity: :warning},
    reconciliation_incomplete: %{category: "Payment", severity: :warning},
    subscription_not_in_database: %{category: "Payment", severity: :warning},
    payment_event_enqueue_failed: %{category: "Payment", severity: :error},
    payment_event_orphaned: %{category: "Payment", severity: :error},
    dunning_stalled: %{category: "Payment", severity: :error},
    late_payment_refund_failed: %{category: "Payment", severity: :error},
    connect_revocation_failed: %{category: "Payment", severity: :error},
    subscription_withdrawal_unfinished: %{category: "Payment", severity: :error},
    account_deletion_billing_sync_failed: %{category: "Payment", severity: :error},
    account_deletion_stalled: %{category: "Account", severity: :error},
    account_deletion_held_last_admin: %{category: "Account", severity: :warning},
    analytics_tracking_anomaly: %{category: "Analytics", severity: :warning},
    recipient_email_rejected: %{category: "Email", severity: :info},
    configured_email_exhausted: %{category: "Email", severity: :error},
    contact_recipient_rejected: %{category: "Email", severity: :error},
    user_registered_hook_failed: %{category: "System", severity: :error},
    group_meeting_release_failed: %{category: "Booking", severity: :error},
    upload_delete_failed: %{category: "System", severity: :warning},
    account_files_delete_failed: %{category: "Account", severity: :error}
  }

  @doc "Returns the full registry map for enumeration and lookup."
  @spec registered_types() :: %{
          atom() => %{category: String.t(), severity: :info | :warning | :error}
        }
  def registered_types, do: @registry

  @doc "Looks up category and severity for the given alert type. Returns nil for unknown types."
  @spec get(atom()) :: %{category: String.t(), severity: :info | :warning | :error} | nil
  def get(type), do: Map.get(@registry, type)

  @doc "See `DedupKey.dedup_key/2`."
  @spec dedup_key(atom(), map()) :: String.t()
  defdelegate dedup_key(type, metadata), to: DedupKey

  @doc "See `Messages.format_message/2`."
  @spec format_message(atom(), map()) :: String.t()
  defdelegate format_message(type, metadata), to: Messages
end
