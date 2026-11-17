defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypesDedupKeyTest do
  # Pins every dedup key to a literal. Keys are hashed and stored per open
  # dedup window, so a key that changes on deploy emails the admin again
  # about every incident still open.
  use ExUnit.Case, async: true

  @moduletag :infrastructure
  @moduletag :unit

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes

  @keyed [
    {:new_error, %{error_id: 42}, "new_error:42"},
    {:error_regression, %{error_id: 42, occurrence_id: 7}, "error_regression:42:7"},
    {:payment_event_enqueue_failed, %{event: "invoice.paid"},
     "payment_event_enqueue_failed:invoice.paid"},
    {:analytics_tracking_anomaly, %{kind: :missing_views},
     "analytics_tracking_anomaly:missing_views"},
    {:invalid_calendar_event,
     %{calendar_integration_id: 9, provider: :google, reason_message: "no start"},
     "invalid_calendar_event:google:9:no start"},
    {:payment_event_orphaned, %{event_type: "invoice.paid", event_id: "evt_1"},
     "payment_event_orphaned:invoice.paid:evt_1"},
    {:payment_event_orphaned, %{event_type: "invoice.paid", job_id: 5},
     "payment_event_orphaned:invoice.paid:job 5"},
    {:recipient_email_rejected, %{meeting_id: 3}, "recipient_email_rejected:meeting 3"},
    {:contact_recipient_rejected, %{recipients_masked: "c***@example.com"},
     "contact_recipient_rejected:c***@example.com"},
    {:calendar_sync_error, %{calendar_integration_id: 9, reason_code: :timeout},
     "calendar_sync_error:integration 9:timeout"},
    {:calendar_sync_error, %{meeting_id: 3, reason_message: "gone"},
     "calendar_sync_error:meeting 3:gone"},
    {:dunning_stalled, %{stripe_subscription_id: "sub_1", days_past_due: 40},
     "dunning_stalled:sub_1"},
    {:integration_health_failure,
     %{signal: :caldav, band: "severe", run_date: "2026-11-17", incident_started_at: nil},
     "integration_health_failure:caldav:2026-11-17:severe"},
    {:integration_health_recovery, %{signal: :caldav, incident_started_at: "2026-11-17T10"},
     "integration_health_recovery:caldav:2026-11-17T10"},
    {:oban_jobs_force_discarded, %{discarded_by: "Sweeper", job_ids: "1,2"},
     "oban_jobs_force_discarded:Sweeper:1,2"},
    {:circuit_breaker_open, %{breaker: :stripe, opened_at: "2026-09-27T14:05:00Z"},
     "circuit_breaker_open:stripe:2026-09-27T14"},
    {:database_pool_pressure, %{repo: "Repo", detected_at: "2026-09-27T14:05:00Z"},
     "database_pool_pressure:Repo:2026-09-27T14"},
    {:account_deletion_stalled, %{user_id: 11}, "account_deletion_stalled:11"},
    {:account_deletion_held_last_admin, %{user_id: 11}, "account_deletion_held_last_admin:11"},
    {:late_payment_refund_failed, %{booking_payment_id: 12}, "late_payment_refund_failed:12"},
    {:connect_revocation_failed, %{stripe_account_id: "acct_1"},
     "connect_revocation_failed:acct_1"},
    {:subscription_withdrawal_unfinished, %{withdrawal_id: 13},
     "subscription_withdrawal_unfinished:13"},
    {:upload_delete_failed, %{reason_code: :eacces}, "upload_delete_failed:eacces"},
    {:stripe_webhook_secret_missing, %{env_var: "STRIPE_WEBHOOK_SECRET"},
     "stripe_webhook_secret_missing:STRIPE_WEBHOOK_SECRET"},
    {:refund_processed, %{user_id: 11, total_refunded: "10.00"},
     "Refund of 10.00 processed for user 11"}
  ]

  # A missing field defaults to "unknown" for most types, but `:new_error`
  # and `:stripe_webhook_secret_missing` interpolate nil as an empty string.
  @empty [
    {:new_error, "new_error:"},
    {:error_regression, "error_regression::"},
    {:payment_event_enqueue_failed, "payment_event_enqueue_failed:unknown"},
    {:analytics_tracking_anomaly, "analytics_tracking_anomaly:unknown"},
    {:payment_event_orphaned, "payment_event_orphaned:unknown:job unknown"},
    {:recipient_email_rejected, "Recipient permanently undeliverable: unknown"},
    {:contact_recipient_rejected, "contact_recipient_rejected:unknown"},
    {:calendar_sync_error, "calendar_sync_error:unknown:unknown"},
    {:dunning_stalled, "dunning_stalled:unknown"},
    {:oban_jobs_force_discarded, "oban_jobs_force_discarded::"},
    {:circuit_breaker_open, "circuit_breaker_open::unknown"},
    {:database_pool_pressure, "database_pool_pressure::unknown"},
    {:account_deletion_stalled, "account_deletion_stalled:unknown"},
    {:account_deletion_held_last_admin, "account_deletion_held_last_admin:unknown"},
    {:late_payment_refund_failed, "late_payment_refund_failed:unknown"},
    {:connect_revocation_failed, "connect_revocation_failed:unknown"},
    {:subscription_withdrawal_unfinished, "subscription_withdrawal_unfinished:unknown"},
    {:upload_delete_failed, "upload_delete_failed:unknown"},
    {:stripe_webhook_secret_missing, "stripe_webhook_secret_missing:"},
    {:invalid_calendar_event, "Invalid calendar event: unknown"},
    {:integration_health_recovery, "Integration health recovered"}
  ]

  test "each type's key for representative metadata is unchanged" do
    mismatches =
      for {type, metadata, expected} <- @keyed,
          (actual = AlertTypes.dedup_key(type, metadata)) != expected,
          do: {type, metadata, actual}

    assert mismatches == []
  end

  test "each type's key for empty metadata is unchanged" do
    mismatches =
      for {type, expected} <- @empty,
          (actual = AlertTypes.dedup_key(type, %{})) != expected,
          do: {type, actual}

    assert mismatches == []
  end

  test "a field present with a nil value is interpolated as an empty string" do
    assert AlertTypes.dedup_key(:dunning_stalled, %{stripe_subscription_id: nil}) ==
             "dunning_stalled:"

    assert AlertTypes.dedup_key(:new_error, %{error_id: nil}) == "new_error:"
  end
end
