defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifier do
  @moduledoc """
  Default implementation of `Tymeslot.Infrastructure.AdminAlerts`.

  Always logs the alert at the registry-defined severity. Additionally enqueues
  an admin alert email via `Tymeslot.Workers.EmailWorker` when **all** of the
  following are true:

    1. `:admin_alerts_enabled` is `true`
    2. `:admin_alert_email` is configured to a valid email address
    3. The alert is not about the email pipeline itself (see `self_referential?/2`)
    4. The Oban uniqueness constraint allows the job (i.e. an identical alert
       has not been enqueued within the last 24 hours)

  Metadata is enriched with deployment context (`tymeslot_version`,
  `deployment_type`, `hostname`, `timestamp`) before being passed to the
  template, so error reports include enough information to be actionable.
  """

  @behaviour Tymeslot.Infrastructure.AdminAlerts

  require Logger

  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.AdminAlerts
  alias Tymeslot.Infrastructure.AdminAlerts.AlertTypes
  alias Tymeslot.Infrastructure.AdminAlerts.PIIScrubber

  @impl Tymeslot.Infrastructure.AdminAlerts
  def send_alert(type, metadata) do
    config = AlertTypes.get(type)
    category = if config, do: config.category, else: "General"
    severity = if config, do: config.severity, else: :warning
    message = AlertTypes.format_message(type, metadata)
    scrubbed_metadata = metadata |> Map.new() |> PIIScrubber.scrub()

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

      alerts_enabled?() ->
        dedup_key = AlertTypes.dedup_key(type, scrubbed_metadata)
        maybe_enqueue_email(category, severity, message, scrubbed_metadata, dedup_key)

      true ->
        :noop
    end

    :ok
  end

  defp alerts_enabled? do
    Application.get_env(:tymeslot, :admin_alerts_enabled, false) == true
  end

  # An alert about the email pipeline cannot be delivered by the email pipeline.
  # Enqueuing one is a feedback loop: the alert job fails for the same reason the
  # original did, its own permanent failure raises another alert, and so on until
  # the underlying fault clears. The alert is still logged above at its registry
  # severity, so nothing is lost from the operator's view of the incident; only
  # the undeliverable email is skipped.
  defp self_referential?(:oban_job_failure, %{worker: worker}),
    do: to_string(worker) == email_worker_name()

  defp self_referential?(_type, _metadata), do: false

  # Resolved at runtime rather than into a module attribute: naming the module
  # at compile time would make every change to the email worker recompile this
  # one. `inspect/1` rather than `to_string/1` because Oban records the worker
  # without the `Elixir.` prefix.
  defp email_worker_name, do: inspect(Tymeslot.Workers.EmailWorker)

  defp maybe_enqueue_email(category, severity, message, metadata, dedup_key) do
    recipient = Application.get_env(:tymeslot, :admin_alert_email)

    if AdminAlerts.valid_email?(recipient) do
      enriched = enrich_metadata(metadata)

      EmailScheduler.schedule_admin_alert(recipient, category, severity, message, enriched,
        dedup_key: dedup_key
      )
    else
      Logger.debug("Admin alert email not delivered: no valid recipient configured",
        category: category
      )
    end
  end

  defp enrich_metadata(metadata) do
    Map.merge(metadata, deployment_context())
  end

  defp deployment_context do
    %{
      tymeslot_version: tymeslot_version(),
      deployment_type: System.get_env("DEPLOYMENT_TYPE") || "unknown",
      hostname: hostname(),
      timestamp: DateTime.to_iso8601(DateTime.utc_now())
    }
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
