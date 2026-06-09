defmodule Tymeslot.Infrastructure.AdminAlerts.EmailNotifier do
  @moduledoc """
  Default implementation of `Tymeslot.Infrastructure.AdminAlerts`.

  Always logs the alert at the registry-defined severity. Additionally enqueues
  an admin alert email via `Tymeslot.Workers.EmailWorker` when **all** of the
  following are true:

    1. `:admin_alerts_enabled` is `true`
    2. `:admin_alert_email` is configured to a valid email address
    3. The Oban uniqueness constraint allows the job (i.e. an identical alert
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

    if alerts_enabled?() do
      dedup_key = AlertTypes.dedup_key(type, scrubbed_metadata)
      maybe_enqueue_email(category, severity, message, scrubbed_metadata, dedup_key)
    end

    :ok
  end

  defp alerts_enabled? do
    Application.get_env(:tymeslot, :admin_alerts_enabled, false) == true
  end

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

  # Dialyzer: :inet.gethostname/0 is typed {:ok, hostname()} but the Erlang
  # docs allow {:error, posix()} — keep the fallback for hostile environments.
  @dialyzer {:nowarn_function, hostname: 0}
  defp hostname do
    case :inet.gethostname() do
      {:ok, name} -> to_string(name)
      {:error, _reason} -> "unknown"
    end
  end
end
