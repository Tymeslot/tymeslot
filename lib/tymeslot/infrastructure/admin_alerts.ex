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
          | :oban_job_failure
          | :pubsub_broadcast_failed
          | :dispute_created
          | :dispute_lost
          | :reconciliation_discrepancies
          | :subscription_not_in_database
          | :payment_event_enqueue_failed
          | :analytics_tracking_anomaly
          | :unhandled_crash
          | atom()

  @callback send_alert(alert_type(), map()) :: :ok | {:error, any()}

  require Logger

  alias Tymeslot.Infrastructure.AdminAlerts.ReasonNormaliser

  @doc """
  Reports an administrative alert using the canonical call shape.

  This is the preferred entrypoint for application code. Call sites supply:

    * `:summary` (required) — a one-line description of what happened
    * `:reason` (optional) — any term; normalised into `reason_code` /
      `reason_message` flat keys before dispatch
    * `:context` (optional) — a map of domain fields to include verbatim

  The normalised reason and context are merged with `:summary` and passed to
  `send_alert/2`. `send_alert/2` remains the low-level primitive for tests
  and future non-standard callers; new production code should use
  `report/2`.
  """
  @spec report(alert_type(), keyword()) :: :ok | {:error, term()}
  def report(type, opts) when is_list(opts) do
    summary = Keyword.fetch!(opts, :summary)
    reason = Keyword.get(opts, :reason)
    context = Keyword.get(opts, :context, %{})

    payload =
      context
      |> Map.new()
      |> maybe_put_reason(reason)
      |> Map.put(:summary, summary)

    send_alert(type, payload)
  end

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

  defp maybe_put_reason(payload, nil), do: payload

  defp maybe_put_reason(payload, reason) do
    %{code: code, message: message} = ReasonNormaliser.normalise(reason)

    payload
    |> Map.put(:reason_code, code)
    |> Map.put(:reason_message, message)
  end
end
