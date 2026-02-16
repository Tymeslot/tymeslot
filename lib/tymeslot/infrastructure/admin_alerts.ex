defmodule Tymeslot.Infrastructure.AdminAlerts do
  @moduledoc """
  Behaviour for sending administrative alerts.

  This allows the core application to trigger alerts without knowing
  how they are delivered (e.g., email, Slack, internal dashboard).
  In standalone mode, these alerts typically just go to the logs.
  In SaaS mode, they can be routed to a centralized monitoring system.
  """

  @type alert_type ::
          :unlinked_refund
          | :refund_processed
          | :unhandled_webhook
          | :calendar_sync_error
          | :integration_health_failure
          | :integration_health_recovery
          | :oban_queue_stuck
          | :oban_jobs_accumulating
          | atom()

  @callback send_alert(alert_type(), map(), keyword()) :: :ok | {:error, any()}

  require Logger

  @doc """
  Sends an administrative alert using the configured implementation.
  """
  def send_alert(type, metadata \\ %{}, opts \\ []) do
    impl().send_alert(type, metadata, opts)
  rescue
    exception ->
      Logger.error("Failed to send admin alert",
        type: type,
        error: Exception.message(exception),
        stacktrace: __STACKTRACE__
      )

      {:error, exception}
  catch
    kind, reason ->
      Logger.error("Failed to send admin alert",
        type: type,
        error: {kind, reason},
        stacktrace: __STACKTRACE__
      )

      {:error, {kind, reason}}
  end

  defp impl do
    Application.get_env(
      :tymeslot,
      :admin_alerts_impl,
      Tymeslot.Infrastructure.AdminAlerts.Default
    )
  end
end

defmodule Tymeslot.Infrastructure.AdminAlerts.Default do
  @moduledoc """
  Default implementation of AdminAlerts that logs alerts to the system logger.
  """
  @behaviour Tymeslot.Infrastructure.AdminAlerts

  require Logger

  @impl Tymeslot.Infrastructure.AdminAlerts
  def send_alert(type, metadata, opts) do
    level = Keyword.get(opts, :level, :warning)

    Logger.log(level, "ADMIN ALERT: #{type}",
      event_type: type,
      metadata: metadata
    )

    :ok
  end
end
