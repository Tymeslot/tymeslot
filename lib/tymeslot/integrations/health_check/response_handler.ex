defmodule Tymeslot.Integrations.HealthCheck.ResponseHandler do
  @moduledoc """
  Domain: Failure Response & Recovery Actions

  Takes appropriate actions when integrations change health status.
  Handles user notifications for sustained unhealthy integrations and
  recovery logging. Integrations are never auto-deactivated; health
  status is surfaced without touching the `is_active` flag.

  ## Notification Policy

  - A user email is sent after 48 hours of sustained unhealthy status.
  - Once a notification has been sent, another will not be sent for 30 days.
  - Recovery clears the cooldown so a new failure cycle can notify promptly.
  - Recovery is silent — no email is sent.
  - The in-app badge shows immediately on `:unhealthy` status, regardless
    of the 48-hour email threshold.

  ## Atomicity Notes

  `became_unhealthy_at` is set by `Monitor.update_health/2` and persisted
  atomically with the rest of the health state via `Monitor.put_state/3`.

  `notification_sent_at` is stamped by the email worker handler after
  confirmed delivery, not on job enqueue.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.DatabaseQueries.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Workers.EmailWorker

  @type integration_type :: :calendar | :video

  @notification_threshold_hours 48
  @notification_cooldown_days 30

  @doc """
  Handles a health status transition by taking appropriate action.
  `health_state` is the new (post-update) state for the integration.
  """
  @spec handle_transition(
          integration_type(),
          map(),
          Monitor.transition(),
          Monitor.health_state(),
          DateTime.t()
        ) :: :ok
  def handle_transition(type, integration, transition, health_state, now \\ DateTime.utc_now())

  def handle_transition(type, integration, {:no_change, _old, :unhealthy}, health_state, now) do
    # Still unhealthy — check if the 48h email should fire
    maybe_notify_user(type, integration, health_state, now)
    :ok
  end

  def handle_transition(_type, _integration, {:no_change, _old, _new}, _health_state, _now),
    do: :ok

  def handle_transition(type, integration, {:initial_failure, nil, :unhealthy}, health_state, now) do
    Logger.error("Integration health check failed on first attempt",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    maybe_notify_user(type, integration, health_state, now)
    :ok
  end

  def handle_transition(
        type,
        integration,
        {:became_unhealthy, old_status, :unhealthy},
        health_state,
        now
      ) do
    Logger.error("Integration health critical",
      previous_status: inspect(old_status),
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    maybe_notify_user(type, integration, health_state, now)
    :ok
  end

  def handle_transition(
        type,
        integration,
        {:became_healthy, old_status, :healthy},
        _health_state,
        _now
      ) do
    Logger.info("Integration health recovered",
      type: type,
      integration_id: integration.id,
      provider: integration.provider,
      previous_status: inspect(old_status)
    )

    clear_notification_state(type, integration.id)
    :ok
  end

  def handle_transition(
        type,
        integration,
        {:became_degraded, :healthy, :degraded},
        _health_state,
        _now
      ) do
    Logger.warning("Integration health degraded",
      type: type,
      integration_id: integration.id,
      provider: integration.provider
    )

    :ok
  end

  # Private Functions

  defp clear_notification_state(type, integration_id) do
    IntegrationHealthStateQueries.update_fields(type, integration_id,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    )
  end

  defp maybe_notify_user(type, integration, health_state, now) do
    with %{became_unhealthy_at: at} when at != nil <- health_state,
         true <- hours_since(at, now) >= @notification_threshold_hours,
         true <- outside_cooldown?(health_state.notification_sent_at, now) do
      send_user_notification(type, integration)
    else
      _skipped -> :ok
    end
  end

  defp hours_since(datetime, now) do
    DateTime.diff(now, datetime, :second) / 3600
  end

  defp outside_cooldown?(nil, _now), do: true

  defp outside_cooldown?(sent_at, now) do
    DateTime.diff(now, sent_at, :day) >= @notification_cooldown_days
  end

  defp send_user_notification(type, integration) do
    case UserQueries.get_user(integration.user_id) do
      {:ok, user} ->
        Logger.info("Dispatching integration unhealthy notification email",
          user_id: user.id,
          integration_id: integration.id,
          type: type
        )

        EmailWorker.schedule_integration_unhealthy_notification(user, integration, type)

      {:error, _reason} ->
        Logger.warning("User not found for integration unhealthy notification",
          integration_id: integration.id,
          user_id: integration.user_id
        )
    end
  end
end
