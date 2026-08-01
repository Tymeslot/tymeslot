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
  - Permanent auth failures (e.g. Google `invalid_grant`) bypass the 48-hour
    threshold via `handle_permanent_auth_failure/4`: the integration is flagged
    `needs_reauth: true` and the notification is enqueued on the same check.
    Oban's 30-day uniqueness window prevents duplicates while the user
    has not reconnected.

  ## Atomicity Notes

  `became_unhealthy_at` is set by `Monitor.update_health/2` and persisted
  atomically with the rest of the health state via `Monitor.put_state/3`.

  `notification_sent_at` is stamped by the email worker handler after
  confirmed delivery, not on job enqueue.
  """

  require Logger

  alias Tymeslot.Auth.UserQueries
  alias Tymeslot.Emails.EmailScheduler
  alias Tymeslot.Integrations.CalendarManagement
  alias Tymeslot.Integrations.HealthCheck.IntegrationHealthStateQueries
  alias Tymeslot.Integrations.HealthCheck.Monitor
  alias Tymeslot.Integrations.Video

  @type integration_type :: :calendar | :video

  @notification_threshold_hours 48
  @notification_cooldown_days 30

  # OAuth error markers that mean the user must reconnect — retrying the call
  # will never recover.
  #
  # String markers are matched against whole word tokens extracted from the
  # lowercased error reason (split on non-alphanumeric/underscore boundaries).
  # This prevents `"invalid_grant"` from matching extended forms such as
  # `"invalid_grant_period_started"`, and prevents `"unauthorized"` false
  # positives from strings like `"unauthorized origin"` or `"unauthorized
  # network host"` produced by CalDAV servers and Google JS-API errors.
  #
  # Note: `:unauthorized` atoms are already covered by
  # `@permanent_auth_error_atoms`; the string list intentionally omits the
  # `"unauthorized"` word to avoid the false-positive substring matches
  # described above.
  @permanent_auth_error_strings ~w(invalid_grant invalid_client access_denied)
  @permanent_auth_error_atoms [:unauthorized, :invalid_credentials, :token_expired]

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

  @doc """
  Fast-path handler for permanent OAuth auth failures (e.g. Google
  `invalid_grant`, Outlook `invalid_client`, atomic `:unauthorized`).

  When the assessor's `check_result` carries a permanent auth marker, the
  integration is flagged `needs_reauth: true` so the dashboard reconnect
  banner shows immediately, and the unhealthy-notification email is enqueued
  on the same health check rather than waiting 48 hours.

  Non-auth failures and successes are passed through untouched. Safe to call
  on every check — Oban's 30-day uniqueness window on the email job prevents
  duplicate sends until the user reconnects.
  """
  @spec handle_permanent_auth_failure(
          integration_type(),
          map(),
          {:ok, any()} | {:error, any()}
        ) :: :ok
  def handle_permanent_auth_failure(type, integration, check_result)

  def handle_permanent_auth_failure(type, integration, {:error, reason}) do
    if permanent_auth_error?(reason) do
      Logger.warning("Permanent auth failure detected — flagging for reauth",
        type: type,
        integration_id: integration.id,
        provider: integration.provider,
        reason: inspect(reason)
      )

      case flag_for_reauth(type, integration, reauth_cause(reason)) do
        :ok ->
          maybe_notify_on_reauth(type, integration)

        {:error, _reason} ->
          Logger.error(
            "Failed to set needs_reauth flag — skipping notification until next successful flag write",
            type: type,
            integration_id: integration.id,
            provider: integration.provider
          )
      end
    end

    :ok
  end

  def handle_permanent_auth_failure(_type, _integration, _check_result), do: :ok

  # Private Functions

  defp permanent_auth_error?(reason) when is_atom(reason),
    do: reason in @permanent_auth_error_atoms

  defp permanent_auth_error?(reason) when is_binary(reason),
    do: Enum.any?(@permanent_auth_error_strings, &(&1 in error_tokens(reason)))

  defp permanent_auth_error?({:exception, message}) when is_binary(message),
    do: permanent_auth_error?(message)

  defp permanent_auth_error?(_other), do: false

  # Splits the reason into whole-word tokens for matching. Non-UTF-8 reasons
  # (some providers hand back raw bytes) tokenise to nothing rather than
  # blowing up `String.downcase/1`.
  defp error_tokens(reason) do
    if String.valid?(reason) do
      reason |> String.downcase() |> String.split(~r/[^a-z0-9_]+/, trim: true)
    else
      []
    end
  end

  # `invalid_grant` and `:token_expired` mean the grant itself is gone —
  # expired, or revoked by the user in their provider account. Everything else
  # on the permanent list is the provider refusing the credentials for some
  # other reason. The two get different messages because they send the user to
  # different places, and neither is a decryption problem.
  defp reauth_cause(reason) when is_binary(reason) do
    if "invalid_grant" in error_tokens(reason),
      do: :expired_grant,
      else: :rejected_credentials
  end

  defp reauth_cause(:token_expired), do: :expired_grant
  defp reauth_cause({:exception, message}) when is_binary(message), do: reauth_cause(message)
  defp reauth_cause(_other), do: :rejected_credentials

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

  # Sends a notification for a permanent auth failure if the cooldown window
  # allows it. Fetches the current health state row for `notification_sent_at`
  # so we don't duplicate an email that `maybe_notify_user` already enqueued
  # for the same 30-day window (e.g. the 48-hour threshold fired on the same
  # check before this fast-path ran).
  defp maybe_notify_on_reauth(type, integration) do
    now = DateTime.utc_now()

    notification_sent_at =
      case IntegrationHealthStateQueries.get(type, integration.id) do
        {:ok, record} -> record.notification_sent_at
        {:error, :not_found} -> nil
      end

    if outside_cooldown?(notification_sent_at, now) do
      send_user_notification(type, integration)
    end
  end

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

        EmailScheduler.schedule_integration_unhealthy_notification(user, integration, type)

      {:error, _reason} ->
        Logger.warning("User not found for integration unhealthy notification",
          integration_id: integration.id,
          user_id: integration.user_id
        )
    end
  end
end
