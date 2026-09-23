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
  - An integration already flagged `needs_reauth` never gets the unhealthy
    email: the reauth email has told its owner, and nothing recovers until
    they reconnect. Once they have, an integration still unhealthy for
    another reason gets the unhealthy email as usual, since the reauth path
    leaves `notification_sent_at` untouched.
  - Permanent auth failures (e.g. Google `invalid_grant`) bypass the 48-hour
    threshold via `handle_permanent_auth_failure/3`: the integration is
    flagged `needs_reauth: true`, which itself owns the notification (the
    reauth email, not the unhealthy one; see `CalendarManagement.flag_and_notify/2`
    and `Video.flag_and_notify/2`) on the false to true transition. This
    fast-path sends nothing itself. Oban's 30-day uniqueness window prevents
    duplicate reauth emails while the user has not reconnected.

  ## Atomicity Notes

  `became_unhealthy_at` is set by `Monitor.update_health/2` and persisted
  atomically with the rest of the health state via `Monitor.put_state/3`.

  `notification_sent_at` is stamped only by the email worker handler, after
  confirmed delivery of the unhealthy email. The permanent-auth fast-path
  never writes it.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Clock
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Infrastructure.BreakerOutcome
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Shared.ReauthHandling
  alias Tymeslot.Integrations.Video

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
  def handle_transition(type, integration, transition, health_state, now \\ Clock.utc_now())

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

  @doc """
  Responds to one completed health check: the permanent-auth fast-path, then
  the status transition.

  The order is the point. A check whose result is a permanent auth failure
  flags the integration, which sends the reauth email, and the transition then
  sees the flagged integration, so `maybe_notify_user/4` withholds the
  unhealthy email. Run the other way round, an integration already past the
  48-hour threshold would get both emails from the same check. For any other
  result the fast-path changes nothing, so the transition behaves exactly as
  it would on its own.
  """
  @spec handle_check_result(
          integration_type(),
          map(),
          Monitor.transition(),
          Monitor.health_state(),
          {:ok, any()} | {:error, any()}
        ) :: :ok
  def handle_check_result(type, integration, transition, health_state, check_result) do
    integration = apply_permanent_auth_failure(type, integration, check_result)
    handle_transition(type, integration, transition, health_state)
  end

  @doc """
  Fast-path handler for permanent OAuth auth failures (e.g. Google
  `invalid_grant`, Outlook `invalid_client`, atomic `:unauthorized`).

  When the assessor's `check_result` carries a permanent auth marker, the
  integration is flagged `needs_reauth: true` so the dashboard reconnect
  banner shows immediately, and flagging enqueues the reauth email on the same
  health check rather than leaving the owner to wait 48 hours for the
  unhealthy one.

  Non-auth failures and successes are passed through untouched. Safe to call
  on every check: Oban's 30-day uniqueness window on the email job prevents
  duplicate sends until the user reconnects. A health check goes through
  `handle_check_result/5`, which also runs the transition in the right order.
  """
  @spec handle_permanent_auth_failure(
          integration_type(),
          map(),
          {:ok, any()} | {:error, any()}
        ) :: :ok
  def handle_permanent_auth_failure(type, integration, check_result) do
    _integration = apply_permanent_auth_failure(type, integration, check_result)
    :ok
  end

  # Private Functions

  # Returns the integration as the rest of the check should see it: flagged
  # when the flag was written, untouched otherwise (including when the write
  # failed, since nothing was flagged and no reauth email went out).
  defp apply_permanent_auth_failure(type, integration, {:error, reason}) do
    if BreakerOutcome.permanent_credential_error?(reason) do
      Logger.warning("Permanent auth failure detected, flagging for reauth",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        reason: inspect(reason)
      )

      case flag_for_reauth(type, integration, ReauthHandling.rejection_cause(reason)) do
        :ok ->
          %{integration | needs_reauth: true}

        {:error, _reason} ->
          Logger.error(
            "Failed to set needs_reauth flag, so no reauth email is sent until a flag write succeeds",
            type: type,
            integration_id: integration.id,
            provider: integration.provider
          )

          integration
      end
    else
      integration
    end
  end

  defp apply_permanent_auth_failure(_type, integration, _check_result), do: integration

  # Re-uses the worker entry points on each domain. Their return values are
  # Oban-shaped (`{:discard, _} | {:error, _}`). We normalise to `:ok | {:error, _}`
  # so callers can gate subsequent actions on a successful DB write:
  # `{:discard, _}` means the flag was written (the integration is irrecoverably
  # broken and no retry is needed), which is a success from this module's perspective.
  defp flag_for_reauth(:video, integration, cause) do
    case Video.handle_reauth_required(integration, cause: cause) do
      {:discard, _msg} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp flag_for_reauth(:calendar, integration, cause) do
    case CalendarManagement.handle_reauth_required(integration, cause: cause) do
      {:discard, _msg} -> :ok
      {:error, _reason} = err -> err
    end
  end

  defp clear_notification_state(type, integration_id) do
    IntegrationHealthStateQueries.update_fields(type, integration_id,
      became_unhealthy_at: nil,
      notification_sent_at: nil
    )
  end

  # An integration flagged `needs_reauth` already told its owner to reconnect,
  # through the reauth email sent when the flag was set, and cannot recover
  # until they do. Its probes keep failing, however they are classified (a
  # provider that refuses to spend flagged credentials reports the refusal
  # locally), so without this guard the 48-hour threshold would send the
  # unhealthy email about the same failure as well.
  defp maybe_notify_user(_type, %{needs_reauth: true}, _health_state, _now), do: :ok

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

        EmailScheduler.schedule_integration_unhealthy_notification(user, integration, type)

      {:error, _reason} ->
        Logger.warning("User not found for integration unhealthy notification",
          integration_id: integration.id,
          user_id: integration.user_id
        )
    end
  end
end
