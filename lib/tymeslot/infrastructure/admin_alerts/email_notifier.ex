defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifier do
  @moduledoc """
  Default implementation of `Tymeslot.Infrastructure.AdminAlerts`.

  Always logs the alert at the registry-defined severity. Additionally delivers
  it when **all** of the following are true:

    1. `:admin_alerts_enabled` is `true`
    2. `:admin_alert_email` is configured to a valid email address
    3. The alert is not about the email pipeline itself (see `self_referential?/2`)
    4. The Oban uniqueness constraint allows the job (i.e. an identical alert
       has not been enqueued within the last 24 hours)

  Warnings and errors are delivered as an admin alert email via
  `Tymeslot.Workers.EmailWorker` at once. Info alerts are recorded for the
  daily digest instead (`Tymeslot.Infrastructure.AdminAlerts.Digest`), where
  the same dedup key collapses repeats into one counted entry.

  The headline, the logged metadata and the delivered metadata are all built from
  a `PIIScrubber`-scrubbed copy of the caller's metadata; only the dedup key is
  derived from the raw values, and it is persisted as a hash.

  Metadata is enriched with deployment context (`tymeslot_version`,
  `deployment_type`, `domain`, `hostname`, `timestamp`) before being passed to
  the template, so error reports include enough information to be actionable.
  """

  @behaviour Tymeslot.Infrastructure.AdminAlerts

  require Logger

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.AdminAlerts.Digest
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber
  alias Tymeslot.Infrastructure.DeploymentType
  alias Tymeslot.Workers.EmailWorker.AdminAlertScheduler
  alias TymeslotWeb.Endpoint

  @impl Tymeslot.Infrastructure.AdminAlerts
  def send_alert(type, metadata) do
    config = AlertTypes.get(type)
    category = if config, do: config.category, else: "General"
    severity = if config, do: config.severity, else: :warning
    metadata = Map.new(metadata)
    scrubbed_metadata = PIIScrubber.scrub(metadata)
    message = AlertTypes.format_message(type, scrubbed_metadata)

    Logger.log(severity, "ADMIN ALERT",
      event_type: type,
      category: category,
      message: message,
      metadata: scrubbed_metadata
    )

    cond do
      self_referential?(type, scrubbed_metadata) ->
        Logger.warning(
          "Admin alert email suppressed: the alert reports a failure of the email pipeline",
          category: category
        )

      AdminAlerts.enabled?() ->
        # Keyed on the raw metadata: masking collapses distinct addresses
        # ("owner@" and "olivia@" both become "o***@"), which would drop the
        # second alert. The key only ever leaves as a SHA-256 hash.
        dedup_key = AlertTypes.dedup_key(type, metadata)
        alert = {type, category, severity, message, scrubbed_metadata, dedup_key}
        with_valid_recipient(category, &deliver(alert, &1))

      true ->
        :noop
    end

    :ok
  end

  # An alert about the email pipeline cannot be delivered by the email pipeline.
  # Enqueuing one is a feedback loop: the alert job fails for the same reason the
  # original did, its own permanent failure raises another alert, and so on until
  # the underlying fault clears. The alert is still logged above at its registry
  # severity, so nothing is lost from the operator's view of the incident; only
  # the undeliverable email is skipped.
  #
  # An error raised while delivering an admin alert email is one: its alert
  # would travel the same broken delivery path, and so is one raised while
  # delivering the daily digest. Only those two actions count; an error in any
  # other email the worker sends is alerted as usual.
  # `ErrorTracking.Alerter` carries the job's worker and action from the
  # occurrence context.
  defp self_referential?(type, %{job_worker: worker, job_action: action})
       when type in [:new_error, :error_regression],
       do: worker == email_worker_name() and action in AdminAlertScheduler.actions()

  # A rejected recipient alert about the admin-alert email itself (e.g. the
  # configured `:admin_alert_email` bounces) would otherwise re-enqueue
  # another admin-alert email to that same dead address, which bounces again,
  # raising another alert — the exact feedback loop this function exists to
  # break. `TransactionalEmailDelivery`/`EmailWorker` tag every
  # `:recipient_email_rejected` report with the job's `action`, and
  # `AdminAlertScheduler.actions/0` are used by admin alert emails alone.
  defp self_referential?(:recipient_email_rejected, %{action: action}),
    do: action in AdminAlertScheduler.actions()

  defp self_referential?(_type, _metadata), do: false

  # Resolved at runtime rather than into a module attribute: naming the module
  # at compile time would make every change to the email worker recompile this
  # one. `inspect/1` rather than `to_string/1` because Oban records the worker
  # without the `Elixir.` prefix.
  defp email_worker_name, do: inspect(Tymeslot.Workers.EmailWorker)

  # The digest is gated exactly like an email: with no usable recipient the
  # digest could never be sent, so nothing is recorded for it.
  defp with_valid_recipient(category, fun) do
    recipient = AdminAlerts.recipient()

    if AdminAlerts.valid_email?(recipient) do
      fun.(recipient)
    else
      AdminAlerts.log_missing_recipient(category: category)
    end
  end

  # Info alerts wait for the daily digest; the deployment context is added
  # once to the digest rather than to every entry.
  defp deliver({type, category, :info, message, metadata, dedup_key}, _recipient) do
    Digest.record(type, category, message, metadata, dedup_key)
  end

  defp deliver({_type, category, severity, message, metadata, dedup_key}, recipient) do
    enriched = Map.merge(metadata, deployment_context())

    EmailScheduler.schedule_admin_alert(recipient, category, severity, message, enriched,
      dedup_key: dedup_key
    )
  end

  @doc """
  The deployment an alert comes from: `tymeslot_version`, `deployment_type`,
  `domain`, `hostname` and `timestamp`. Added to every alert email, and once
  to each digest. `deployment_type` is the normalised value
  (`Tymeslot.Infrastructure.DeploymentType.current/0`), so the legacy `main`
  reads `cloudron`, as it does everywhere else.
  """
  @spec deployment_context() :: map()
  def deployment_context do
    %{
      tymeslot_version: tymeslot_version(),
      deployment_type: DeploymentType.current(),
      domain: domain(),
      hostname: hostname(),
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
  end

  # The public domain this deployment serves. It is what actually identifies the
  # instance to an operator running more than one of them; `hostname/0` below
  # reports the container name, which is an opaque id under Docker and Cloudron.
  # Endpoint.host/0 raises when the endpoint is not running, which an alert
  # raised during boot or shutdown can hit, so this degrades to "unknown" rather
  # than losing the alert to the rescue in `AdminAlerts.send_alert/2`.
  defp domain do
    Endpoint.host()
  rescue
    exception ->
      Logger.warning("Admin alert could not resolve the deployment domain",
        error: Exception.message(exception)
      )

      "unknown"
  end

  defp tymeslot_version do
    case Application.spec(:tymeslot, :vsn) do
      nil -> "unknown"
      vsn -> to_string(vsn)
    end
  end

  # :inet.gethostname/0 is contractually {:ok, hostname()} — every backend path
  # falls back to {:ok, "nohost.nodomain"} rather than erroring, so there is no
  # {:error, _} clause to handle (the posix() error belongs to the /1 arity).
  defp hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
