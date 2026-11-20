defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypes.Messages do
  @moduledoc """
  Human-readable messages for admin alert types, reached through
  `AlertTypes.format_message/2`. Every type registered in `AlertTypes` has a
  clause here.
  """

  @doc """
  Formats a human-readable message for the given alert type and metadata.

  Expects metadata already passed through `PIIScrubber.scrub/1`: the message
  reaches Logger and the persisted Oban job args, so it reads masked keys
  (`owner_email_masked`) and relies on the scrubber's sweep of free-form
  strings rather than masking anything itself.

  `dedup_key/2`'s message-based fallbacks (the default clause and
  `:recipient_email_rejected` without an id) call this on raw, unscrubbed
  metadata. That is safe only because the dedup key is SHA-256 hashed before
  it is stored (`AdminAlertScheduler`); a key built that way must never be
  logged raw.
  """
  @spec format_message(atom(), map()) :: String.t()
  def format_message(:unhandled_webhook, metadata) do
    type = Map.get(metadata, :event_type, "unknown")
    id = Map.get(metadata, :event_id, "unknown")
    "Unhandled Stripe webhook event: #{type} (ID: #{id})"
  end

  # Call sites pass :total_refunded; :amount is accepted as a fallback for
  # callers that pass the older key.
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
    "New dispute created: #{id} (Reason: #{reason_text(metadata)}) — Manual review required"
  end

  def format_message(:dispute_lost, metadata) do
    id = Map.get(metadata, :dispute_id, "unknown")
    user_id = Map.get(metadata, :user_id, "unknown")
    "Dispute lost: #{id} for user #{user_id} — Consider manual access revocation"
  end

  def format_message(:calendar_sync_error, metadata) do
    email = Map.get(metadata, :owner_email_masked, "unknown")
    "Calendar sync error for #{email}: #{reason_text(metadata)}"
  end

  # Aggregate signals (`HealthCheck.Alerting`) describe many integrations, so
  # the summary is the whole message rather than one integration's.
  def format_message(:integration_health_failure, %{signal: _signal, summary: summary}),
    do: summary

  def format_message(:integration_health_failure, metadata) do
    integration_id = Map.get(metadata, :integration_id, "unknown")

    case Map.get(metadata, :summary) do
      nil -> "Integration health check failed for integration #{integration_id}"
      summary -> "#{summary} (integration #{integration_id})"
    end
  end

  def format_message(:integration_health_recovery, metadata) do
    Map.get(metadata, :summary, "Integration health recovered")
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

  def format_message(:oban_jobs_force_discarded, metadata) do
    count = Map.get(metadata, :count, "unknown")
    discarded_by = Map.get(metadata, :discarded_by, "unknown")
    jobs = Map.get(metadata, :jobs, "unknown")
    "#{discarded_by} discarded #{count} Oban jobs that never finished: #{jobs}"
  end

  def format_message(:circuit_breaker_open, %{old_state: :half_open} = metadata) do
    breaker = Map.get(metadata, :breaker, "unknown")
    last_error = Map.get(metadata, :last_error) || "unknown"
    "Circuit breaker #{breaker} reopened: its recovery probe failed (last error: #{last_error})"
  end

  def format_message(:circuit_breaker_open, metadata) do
    breaker = Map.get(metadata, :breaker, "unknown")
    count = Map.get(metadata, :failure_count) || "unknown"
    last_error = Map.get(metadata, :last_error) || "unknown"
    "Circuit breaker #{breaker} opened after #{count} failures (last error: #{last_error})"
  end

  def format_message(:database_pool_pressure, metadata) do
    repo = Map.get(metadata, :repo, "unknown")
    count = Map.get(metadata, :slow_checkouts, "unknown")
    threshold = Map.get(metadata, :threshold_ms, "unknown")
    window = Map.get(metadata, :window_seconds, "unknown")

    "Database pool pressure on #{repo}: #{count} queries waited more than #{threshold} ms " <>
      "for a connection in the last #{window} seconds"
  end

  def format_message(:stripe_webhook_secret_missing, metadata) do
    env_var = Map.get(metadata, :env_var, "unknown")
    summary = Map.get(metadata, :summary, "Stripe webhooks are rejected")
    "#{env_var} is not set: #{summary}"
  end

  def format_message(type, metadata) when type in [:new_error, :error_regression] do
    kind = metadata |> Map.get(:kind, "unknown") |> to_string() |> String.trim_leading("Elixir.")
    source = Map.get(metadata, :source_function, "unknown")
    "#{Map.get(metadata, :summary)}: #{kind} in #{source}: #{reason_text(metadata)}"
  end

  def format_message(:reconciliation_discrepancies, metadata) do
    count = Map.get(metadata, :discrepancies_count, "unknown")
    "Payment reconciliation found #{count} discrepancies"
  end

  def format_message(:reconciliation_incomplete, metadata) do
    count = Map.get(metadata, :unresolved_count, "unknown")

    "Payment reconciliation could not look up #{count} subscriptions at Stripe, " <>
      "so it did not check for subscriptions missing there"
  end

  def format_message(:subscription_not_in_database, metadata) do
    stripe_id = Map.get(metadata, :stripe_subscription_id, "unknown")
    "Active Stripe subscription #{stripe_id} has no matching database record"
  end

  def format_message(:payment_event_enqueue_failed, metadata) do
    event = Map.get(metadata, :event, "unknown")
    detail = Map.get(metadata, :summary) || Map.get(metadata, :reason_message, "unknown")
    "Payment event enqueue failed for #{event}: #{detail}"
  end

  # The day count is deliberately in the message: the admin needs to see how
  # long the row has been stalled. It is what makes the message unusable as a
  # dedup key, which is why this type has its own `dedup_key/2` clause.
  def format_message(:dunning_stalled, metadata) do
    stripe_id = Map.get(metadata, :stripe_subscription_id, "unknown")
    days = Map.get(metadata, :days_past_due, "unknown")

    "Dunning stalled for subscription #{stripe_id}: #{days} days past due is beyond the " <>
      "auto-cancel guard, so it is never cancelled and still grants Pro; manual review required"
  end

  def format_message(:account_deletion_billing_sync_failed, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")
    detail = Map.get(metadata, :reason_message, "unknown")

    "Subscription renewal for user #{user_id} could not be synced with an account deletion " <>
      "after every retry (#{detail}); check the subscription at Stripe by hand"
  end

  def format_message(:account_deletion_held_last_admin, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")

    "Account deletion for user #{user_id} is on hold: the account is the last admin who can " <>
      "sign in. Make another account an admin and the deletion goes ahead on its next daily " <>
      "check; the owner can still restore the account meanwhile"
  end

  def format_message(:account_deletion_stalled, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")
    detail = Map.get(metadata, :reason_message, "unknown")

    "Account deletion for user #{user_id} failed after every retry (#{detail}); the daily " <>
      "sweep tries again, but the account stays past its deletion date until the cause is fixed"
  end

  # Discarded after the snooze cap because the subscription, customer or
  # dispute it refers to never appeared. The ids are what the operator needs
  # to find the event in Stripe and reconcile it by hand.
  def format_message(:payment_event_orphaned, metadata) do
    event_type = Map.get(metadata, :event_type, "unknown")
    event_id = Map.get(metadata, :event_id) || "unknown"
    referent = Map.get(metadata, :referent_id) || "unknown"
    summary = Map.get(metadata, :summary, "its referent never appeared")

    "Payment event #{event_type} (ID: #{event_id}, referent: #{referent}) discarded: " <>
      "#{summary} (#{reason_text(metadata)})"
  end

  # The booking stays on the host's outstanding-refunds list; the id is what
  # the operator needs to find the charge in Stripe. The job is unique per
  # payment over every state, so a fresh one cannot be inserted: retrying
  # means retrying this one.
  def format_message(:late_payment_refund_failed, metadata) do
    id = Map.get(metadata, :booking_payment_id, "unknown")
    job_id = Map.get(metadata, :oban_job_id, "unknown")

    "Refund of booking payment #{id}, paid after its slot was taken, failed on every " <>
      "attempt (#{reason_text(metadata)}); the attendee is still owed the money. " <>
      "To settle it, refund the booking from the host's payments settings (or the " <>
      "Stripe dashboard), or once the cause is fixed retry Oban job #{job_id}"
  end

  # The job is unique per account, so once the cause is fixed the way to try
  # again is to retry this one.
  def format_message(:connect_revocation_failed, metadata) do
    account = Map.get(metadata, :stripe_account_id, "unknown")
    job_id = Map.get(metadata, :oban_job_id, "unknown")

    "Revoking Tymeslot's access to Stripe account #{account} failed on every attempt " <>
      "(#{reason_text(metadata)}); the account is no longer connected in Tymeslot but " <>
      "still authorises it. Once the cause is fixed, retry Oban job #{job_id}, or remove " <>
      "Tymeslot from the account's authorised apps in the Stripe dashboard"
  end

  def format_message(:subscription_withdrawal_unfinished, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")
    withdrawal_id = Map.get(metadata, :withdrawal_id, "unknown")
    stripe_id = Map.get(metadata, :stripe_subscription_id, "unknown")

    "Withdrawal #{withdrawal_id} of user #{user_id} (subscription #{stripe_id}) is recorded " <>
      "but unfinished (#{reason_text(metadata)}); the host may still be owed a refund or a " <>
      "cancellation. Once the cause is fixed, finish it from a release shell or ask the host " <>
      "to press Finish my withdrawal"
  end

  # One alert per integration and sync run (`Calendar.InvalidEventReport`).
  def format_message(:invalid_calendar_event, %{count: count} = metadata) do
    provider = Map.get(metadata, :provider, "unknown")
    integration_id = Map.get(metadata, :calendar_integration_id, "unknown")
    samples = Map.get(metadata, :sample_events, "unknown")

    summary =
      Map.get(metadata, :summary, "#{count} invalid #{provider} calendar event(s) skipped")

    "#{summary} for integration #{integration_id} " <>
      "(most common reason: #{reason_text(metadata)}). First affected: #{samples}"
  end

  def format_message(:invalid_calendar_event, metadata) do
    Map.get(metadata, :summary, "Invalid calendar event: #{reason_text(metadata)}")
  end

  def format_message(:analytics_tracking_anomaly, metadata) do
    kind = Map.get(metadata, :kind, "unknown")
    "Booking analytics tracking anomaly: #{kind}"
  end

  def format_message(:recipient_email_rejected, metadata) do
    summary = Map.get(metadata, :summary, "Recipient permanently undeliverable")
    reason = Map.get(metadata, :reason_message, "unknown")

    labels =
      Enum.reject(
        [recipient_email_rejected_identifier(metadata), recipients_label(metadata)],
        &is_nil/1
      )

    case labels do
      [] -> "#{summary}: #{reason}"
      labels -> "#{summary} (#{Enum.join(labels, ", ")}): #{reason}"
    end
  end

  # Unlike `:recipient_email_rejected`, the refused address is our own inbox,
  # so every enquiry bounces until it is reactivated with the mail provider.
  def format_message(:contact_recipient_rejected, metadata) do
    recipient =
      case Map.get(metadata, :recipients_masked) do
        masked when is_binary(masked) and masked != "" -> " (#{masked})"
        _none -> ""
      end

    action = Map.get(metadata, :action, "unknown")
    job_id = Map.get(metadata, :job_id, "unknown")

    "The configured contact recipient#{recipient} is being rejected by the mail provider, " <>
      "so incoming enquiries are not being delivered; reactivate the address with the provider " <>
      "(#{action}, job #{job_id}: #{reason_text(metadata)})"
  end

  # A configured email (a payment notice, say) is lost once Oban stops
  # retrying; the job id is what the operator needs to find and resend it.
  # Keyed by the job, so each lost email raises its own alert.
  def format_message(:configured_email_exhausted, metadata) do
    template = Map.get(metadata, :template, "unknown")
    job_id = Map.get(metadata, :job_id, "unknown")

    "Email from template #{template} was not sent after its final attempt (job #{job_id}); " <>
      "it will not be retried (#{reason_text(metadata)})"
  end

  # The hook's record of the sign-up (terms acceptance, say) is lost once
  # Oban stops retrying; the user id is what the operator needs to restore it.
  def format_message(:user_registered_hook_failed, metadata) do
    user_id = Map.get(metadata, :user_id, "unknown")

    "Registration hook failed on its final attempt for user #{user_id}; " <>
      "its record is missing (#{reason_text(metadata)})"
  end

  # The last seat of a group meeting was released but the meeting could not
  # be cancelled, so it may still block the host's time as confirmed.
  def format_message(:group_meeting_release_failed, metadata) do
    meeting_id = Map.get(metadata, :meeting_id, "unknown")

    "Group meeting #{meeting_id} lost its last participant but could not be cancelled, " <>
      "so it may still show as confirmed (#{reason_text(metadata)})"
  end

  # A path outside the upload directory was refused, not attempted: the row
  # that named it is what needs a look, and the file must not be deleted.
  def format_message(:upload_delete_failed, %{reason_code: :path_traversal_attempt} = metadata) do
    path = Map.get(metadata, :file_path, "unknown")

    "Deleting uploaded file #{path} was refused: the path is outside the upload directory; " <>
      "check the record that points at it"
  end

  # A replaced or removed upload is still on disk, unreferenced.
  def format_message(:upload_delete_failed, metadata) do
    path = Map.get(metadata, :file_path, "unknown")

    "Uploaded file #{path} could not be deleted and is still on disk; " <>
      "remove it by hand (#{reason_text(metadata)})"
  end

  # Every retry is spent: personal files outlive the account they belonged to.
  def format_message(:account_files_delete_failed, metadata) do
    profile_id = Map.get(metadata, :profile_id, "unknown")
    paths = Map.get(metadata, :paths, "unknown")

    "Uploaded files of deleted profile #{profile_id} could not be removed after every retry; " <>
      "delete #{paths} by hand (#{reason_text(metadata)})"
  end

  def format_message(type, _metadata) do
    "Alert: #{type}"
  end

  @doc false
  # Shared with `AlertTypes.DedupKey`, which keys a rejection on the same id.
  @spec recipient_email_rejected_identifier(map()) :: String.t() | nil
  def recipient_email_rejected_identifier(metadata) do
    cond do
      id = Map.get(metadata, :connect_account_id) -> "connect account #{id}"
      id = Map.get(metadata, :booking_payment_id) -> "booking payment #{id}"
      id = Map.get(metadata, :meeting_id) -> "meeting #{id}"
      true -> nil
    end
  end

  defp recipients_label(metadata) do
    case Map.get(metadata, :recipients_masked) do
      recipients when is_binary(recipients) and recipients != "" -> "to #{recipients}"
      _none -> nil
    end
  end

  # The reason as `AdminAlerts.report/2` flattens it: the normalised message,
  # falling back to the bare code for callers that set only that.
  @doc false
  @spec reason_text(map()) :: term()
  def reason_text(metadata) do
    Map.get(metadata, :reason_message) || Map.get(metadata, :reason_code, "unknown")
  end
end
