defmodule Tymeslot.Infrastructure.AdminAlerts.AlertTypes.DedupKey do
  @moduledoc """
  Stable identity strings for admin alerts, reached through
  `AlertTypes.dedup_key/2`.

  The keys are hashed and stored per open dedup window
  (`AdminAlertScheduler`), so changing the key a type produces emails the
  admin again about every incident of that type still open.
  """

  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes.Messages

  # Types keyed on one metadata field: `"<type>:<field>"`. The default is what
  # a missing field reads as; `nil` interpolates as an empty string.
  @keyed_on %{
    # One alert per ErrorTracker error.
    new_error: {:error_id, nil},
    # Enqueue failures embed per-occurrence detail (attempt count, error
    # text), so dedup on the event family instead: a burst of drops from the
    # same broken event type collapses into a single alert per window, while a
    # distinct event family still raises its own alert.
    payment_event_enqueue_failed: {:event, "unknown"},
    # Anomaly messages embed per-run counts, so dedup on the anomaly kind.
    analytics_tracking_anomaly: {:kind, "unknown"},
    # Every enquiry sent while the contact recipient is suppressed is
    # rejected the same way, so a run of failed forms is one incident: key on
    # the recipient, not the job. Only one contact recipient is configured, so
    # its masked form cannot stand for two different inboxes.
    contact_recipient_rejected: {:recipients_masked, "unknown"},
    # The message embeds `days_past_due`, which the daily dunning run
    # increments on every pass over the same stuck row, so a message-based
    # key would change daily. One alert per stuck subscription per window.
    dunning_stalled: {:stripe_subscription_id, "unknown"},
    # The message carries the hook's refusal, whose text can differ between
    # the daily runs of one stuck deletion: one alert per stuck account.
    account_deletion_stalled: {:user_id, "unknown"},
    # A hold repeats daily for as long as the account is the last admin; one
    # alert per account per window, kept apart from a failed deletion's.
    account_deletion_held_last_admin: {:user_id, "unknown"},
    # Each payment left unrefunded is money an attendee is owed, so one alert
    # per payment, whatever the reason text says.
    late_payment_refund_failed: {:booking_payment_id, "unknown"},
    # One alert per account: two accounts failing must not collapse into one.
    connect_revocation_failed: {:stripe_account_id, "unknown"},
    # Each unfinished withdrawal is a host owed a refund or a cancellation,
    # so one alert per withdrawal.
    subscription_withdrawal_unfinished: {:withdrawal_id, "unknown"},
    # A volume that refuses deletes fails every one of them for the same
    # reason, so key on the reason rather than the path: one alert per cause.
    upload_delete_failed: {:reason_code, "unknown"},
    stripe_webhook_secret_missing: {:env_var, nil}
  }

  @doc """
  Returns a stable identity string used to deduplicate repeat alerts.

  Defaults to the formatted message. Add a clause (or a `@keyed_on` entry)
  when the message embeds per-occurrence detail (ids, error text) that would
  defeat deduplication: a burst of permanently failed jobs from one broken
  worker should collapse into a single alert per dedup window, not one email
  per job.

  Unlike `format_message/2`, this takes the caller's raw, unscrubbed metadata:
  masking maps distinct addresses to one form (`owner@` and `olivia@` both
  become `o***@`), so a key built from a masked message could swallow a second
  person's alert. The key is only ever persisted as a SHA-256 hash (see
  `AdminAlertScheduler`), but a clause that picks its own fields should still
  key on ids rather than personal data.
  """
  @spec dedup_key(atom(), map()) :: String.t()
  def dedup_key(type, metadata) when is_map_key(@keyed_on, type) do
    {field, default} = Map.fetch!(@keyed_on, type)
    "#{type}:#{Map.get(metadata, field, default)}"
  end

  # A regression is a new incident each time the error comes back after
  # being resolved.
  def dedup_key(:error_regression, metadata) do
    "error_regression:#{Map.get(metadata, :error_id)}:#{Map.get(metadata, :occurrence_id)}"
  end

  # A sync run's batch (`Calendar.InvalidEventReport`) embeds a count and
  # sample event ids that change from run to run, so dedup on the provider,
  # integration and the run's most common reason instead: the operator needs
  # to know that one integration keeps producing unusable events, and again
  # when it starts failing in a new way, not on every run. Matched on the
  # batch's shape, so other callers of this type (the calendar audit task)
  # keep the default message-based key.
  def dedup_key(:invalid_calendar_event, %{calendar_integration_id: integration_id} = metadata) do
    provider = Map.get(metadata, :provider, "unknown")

    "invalid_calendar_event:#{provider}:#{integration_id}:#{Messages.reason_text(metadata)}"
  end

  # One orphaned event is its own incident: another event whose referent never
  # appeared is a second one the operator has to reconcile by hand, so key on
  # the event rather than the message. Stripe's event id is the identity where
  # the event carries one; otherwise the object it refers to, and failing that
  # the job, which is unique to the event.
  def dedup_key(:payment_event_orphaned, metadata) do
    event_type = Map.get(metadata, :event_type, "unknown")

    identity =
      Map.get(metadata, :event_id) || Map.get(metadata, :referent_id) ||
        "job #{Map.get(metadata, :job_id, "unknown")}"

    "payment_event_orphaned:#{event_type}:#{identity}"
  end

  # Call sites identify the affected recipient through whichever id they have
  # to hand (a Connect account, a booking payment, a meeting), so two different
  # hosts' bounces in the same window raise two alerts, not one. Without an id
  # the full message is the key; Postmark's rejection text usually names the
  # address, which still tells two recipients apart.
  def dedup_key(:recipient_email_rejected, metadata) do
    case Messages.recipient_email_rejected_identifier(metadata) do
      nil -> Messages.format_message(:recipient_email_rejected, metadata)
      identifier -> "recipient_email_rejected:#{identifier}"
    end
  end

  # The message names the owner only by masked address, which two owners can
  # share, so key on the calendar integration that failed instead, falling
  # back to the meeting: one alert per broken calendar and reason per window,
  # with no personal data in the key.
  def dedup_key(:calendar_sync_error, metadata) do
    source =
      cond do
        id = Map.get(metadata, :calendar_integration_id) -> "integration #{id}"
        id = Map.get(metadata, :meeting_id) -> "meeting #{id}"
        true -> "unknown"
      end

    "calendar_sync_error:#{source}:#{Messages.reason_text(metadata)}"
  end

  # Aggregate integration health alerts (`HealthCheck.Alerting`) embed a live
  # count in the message, which would change the key on every hourly run and
  # email the admin every hour for one incident. Key on the signal and its
  # threshold band instead, so a steady incident alerts once per window and a
  # worsening one (band "elevated" to "severe") alerts again. An auto-pause
  # alert also carries its run's date: each daily run reports different
  # integrations, and the next run lands just inside the 24-hour window.
  # The hourly signals carry the hour their incident began, and their recovery
  # the same hour, so a second incident on the same day alerts again instead
  # of colliding with the first. Matched on the signal shape only, so the
  # shared Telegram token alert keeps its message-based key.
  def dedup_key(:integration_health_failure, %{signal: signal, band: band} = metadata) do
    health_key([
      "integration_health_failure",
      signal,
      Map.get(metadata, :run_date),
      Map.get(metadata, :incident_started_at),
      band
    ])
  end

  def dedup_key(:integration_health_recovery, %{signal: signal} = metadata) do
    health_key([
      "integration_health_recovery",
      signal,
      Map.get(metadata, :incident_started_at)
    ])
  end

  # Every sweep that discards jobs is its own incident, but two sweeps that
  # each discard one job of the same worker read the same, so key on the
  # jobs themselves.
  def dedup_key(:oban_jobs_force_discarded, metadata) do
    "oban_jobs_force_discarded:#{Map.get(metadata, :discarded_by)}:#{Map.get(metadata, :job_ids)}"
  end

  # The message embeds a live failure count and the last error, which change
  # from one opening to the next. Key on the breaker and the clock hour it
  # opened in, so a breaker flapping between open and half-open alerts at
  # most once an hour, and each other breaker alerts on its own.
  def dedup_key(:circuit_breaker_open, metadata) do
    "circuit_breaker_open:#{Map.get(metadata, :breaker)}:#{hour_bucket(metadata, :opened_at)}"
  end

  # The same for sustained pool pressure: the monitor raises one alert per
  # window while it lasts, which collapses to one per repo and hour.
  def dedup_key(:database_pool_pressure, metadata) do
    "database_pool_pressure:#{Map.get(metadata, :repo)}:#{hour_bucket(metadata, :detected_at)}"
  end

  def dedup_key(type, metadata), do: Messages.format_message(type, metadata)

  defp health_key(parts), do: parts |> Enum.reject(&is_nil/1) |> Enum.join(":")

  # "2026-09-27T14:05:00Z" becomes "2026-09-27T14": the UTC hour an ISO 8601
  # timestamp falls in.
  defp hour_bucket(metadata, key) do
    case Map.get(metadata, key) do
      timestamp when is_binary(timestamp) -> String.slice(timestamp, 0, 13)
      _missing -> "unknown"
    end
  end
end
