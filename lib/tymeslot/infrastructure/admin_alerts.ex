defmodule Tymeslot.Infrastructure.AdminAlerts do
  @moduledoc """
  Behaviour and dispatcher for sending administrative alerts.

  This allows the application to trigger alerts without knowing how they are
  delivered. The default implementation (`EmailNotifier`) uses Core's standard
  email delivery infrastructure: it logs every alert, and additionally sends an
  email to the configured admin recipient when the feature is enabled.

  ## Configuration

  Alerts are gated behind two settings:

    * `:tymeslot, :admin_alerts_enabled` — boolean feature flag (default `false`)
    * `:tymeslot, :admin_alert_email` — recipient address (default `nil`)

  Both must be set for emails to actually be delivered. Both can be controlled
  at runtime via the `ADMIN_ALERTS_ENABLED` and `ADMIN_ALERT_EMAIL` environment
  variables. SaaS deployments override `:admin_alerts_enabled` to `true` in
  config and supply the email address via the deployment environment.

  Self-hosters can enable this to receive error reports for their own debugging
  or to share with the project — see `CONTRIBUTING.md` for details.
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
          | :pubsub_broadcast_failed
          | :dispute_created
          | :dispute_lost
          | :reconciliation_discrepancies
          | :subscription_not_in_database
          | atom()

  @callback send_alert(alert_type(), map()) :: :ok | {:error, any()}

  require Logger

  @doc """
  Sends an administrative alert using the configured implementation.

  Errors raised by the implementation are caught and logged so that alert
  failures never propagate up and break the calling code path.
  """
  @spec send_alert(alert_type(), map()) :: :ok | {:error, any()}
  def send_alert(type, metadata \\ %{}) do
    impl().send_alert(type, metadata)
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

  @doc """
  Returns true if the given value is a syntactically plausible email address.

  Used to gate admin alert email delivery — a malformed or empty address means
  no email is sent, even if the feature flag is enabled.
  """
  @spec valid_email?(term()) :: boolean()
  def valid_email?(value) when is_binary(value) do
    value
    |> String.trim()
    |> Kernel.=~(~r/^[^\s@]+@[^\s@]+\.[^\s@]+$/)
  end

  def valid_email?(_other), do: false

  defp impl do
    Application.get_env(
      :tymeslot,
      :admin_alerts_impl,
      Tymeslot.Infrastructure.AdminAlerts.EmailNotifier
    )
  end
end
