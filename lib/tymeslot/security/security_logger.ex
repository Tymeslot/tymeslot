defmodule Tymeslot.Security.SecurityLogger do
  @moduledoc """
  Security event logging for monitoring malicious input attempts.

  Logs security events without exposing sensitive data, providing
  visibility into attack patterns for monitoring and response.
  """

  require Logger

  @doc """
  Logs blocked malicious input attempts.

  ## Parameters
  - `field` - The input field or context (atom)
  - `pattern_type` - Type of malicious pattern detected (string)
  - `metadata` - Additional context (map)

  ## Examples

      SecurityLogger.log_blocked_input(:email, "sql_injection", %{ip: "192.168.1.1"})
      SecurityLogger.log_blocked_input(:message, "xss_attempt", %{user_id: 123})
  """
  @spec log_blocked_input(atom(), String.t(), map()) :: :ok
  def log_blocked_input(field, pattern_type, metadata \\ %{}) do
    sanitized_metadata = sanitize_metadata(metadata)

    Logger.warning("Malicious input blocked",
      field: field,
      pattern_type: pattern_type,
      ip_address: sanitized_metadata[:ip],
      user_id: sanitized_metadata[:user_id],
      user_agent: sanitized_metadata[:user_agent],
      timestamp: DateTime.utc_now()
    )
  end

  @doc """
  Logs validation failures that may indicate attack attempts.
  """
  @spec log_validation_failure(atom(), String.t(), map()) :: :ok
  def log_validation_failure(field, error_type, metadata \\ %{}) do
    sanitized_metadata = sanitize_metadata(metadata)

    Logger.info("Validation failure",
      field: field,
      error_type: error_type,
      ip_address: sanitized_metadata[:ip],
      user_id: sanitized_metadata[:user_id],
      timestamp: DateTime.utc_now()
    )
  end

  @doc """
  Logs successful validation for security monitoring.
  """
  @spec log_successful_validation(atom(), map()) :: :ok
  def log_successful_validation(field, metadata \\ %{}) do
    sanitized_metadata = sanitize_metadata(metadata)

    Logger.debug("Validation successful",
      field: field,
      ip_address: sanitized_metadata[:ip],
      user_id: sanitized_metadata[:user_id],
      timestamp: DateTime.utc_now()
    )
  end

  # Private functions

  defp sanitize_metadata(metadata) when is_map(metadata) do
    metadata
    |> Map.take([:ip, :user_id, :user_agent])
    |> Enum.reduce(%{}, fn {key, value}, acc ->
      case sanitize_metadata_value(key, value) do
        nil -> acc
        sanitized_value -> Map.put(acc, key, sanitized_value)
      end
    end)
  end

  defp sanitize_metadata(_), do: %{}

  defp sanitize_metadata_value(:ip, value) when is_binary(value) do
    # Basic IP validation - only log if it looks like a valid IP
    if Regex.match?(~r/^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}$/, value) do
      value
    else
      nil
    end
  end

  defp sanitize_metadata_value(:user_id, value) when is_integer(value) and value > 0 do
    value
  end

  defp sanitize_metadata_value(:user_agent, value) when is_binary(value) do
    # Truncate user agent to prevent log injection
    value
    |> String.slice(0, 200)
    |> String.replace(~r/[\r\n\t]/, " ")
  end

  defp sanitize_metadata_value(_, _), do: nil

  # === EXISTING AUTHENTICATION LOGGING FUNCTIONS ===

  @doc """
  Logs a general security event with structured metadata.
  """
  @spec log_security_event(String.t(), map()) :: :ok
  def log_security_event(event_type, details \\ %{}) do
    metadata = %{
      event_type: event_type,
      timestamp: DateTime.to_iso8601(DateTime.utc_now()),
      user_id: details[:user_id],
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      session_id: details[:session_id],
      additional_data: details[:additional_data] || %{}
    }

    Logger.info("Security Event: #{event_type}", metadata)

    # Also send to external monitoring if configured
    if Application.get_env(:tymeslot, :security_monitoring_enabled, false) do
      send_to_monitoring_service(metadata)
    end

    :ok
  end

  @doc """
  Logs authentication attempts with success/failure details.
  """
  @spec log_authentication_attempt(String.t(), boolean(), String.t() | nil, map()) :: :ok
  def log_authentication_attempt(email, success, reason \\ nil, metadata \\ %{}) do
    event_details = %{
      email: email,
      success: success,
      reason: reason,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        login_method: metadata[:login_method] || "email_password"
      }
    }

    event_type = if success, do: "authentication_success", else: "authentication_failure"
    log_security_event(event_type, event_details)
  end

  @doc """
  Logs session-related events (creation, deletion, validation).
  """
  @spec log_session_event(String.t(), integer(), String.t(), map()) :: :ok
  def log_session_event(event_type, user_id, session_id, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      # Never log raw session tokens. Redact to last 8 chars.
      session_id: redact_session_id(session_id),
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: metadata[:additional_data] || %{}
    }

    log_security_event("session_#{event_type}", event_details)
  end

  # Redact sensitive session identifiers before logging
  defp redact_session_id(nil), do: nil

  defp redact_session_id(session_id) when is_binary(session_id) do
    if String.length(session_id) >= 8 do
      "…" <> String.slice(session_id, -8, 8)
    else
      "…REDACTED"
    end
  end

  defp redact_session_id(_), do: nil

  @doc """
  Logs rate limiting violations.
  """
  @spec log_rate_limit_violation(String.t(), String.t(), map()) :: :ok
  def log_rate_limit_violation(identifier, limit_type, metadata \\ %{}) do
    event_details = %{
      identifier: identifier,
      limit_type: limit_type,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        current_count: metadata[:current_count],
        limit: metadata[:limit],
        window_seconds: metadata[:window_seconds]
      }
    }

    log_security_event("rate_limit_violation", event_details)
  end

  @doc """
  Logs account lockout events.
  """
  @spec log_account_lockout(String.t(), String.t(), map()) :: :ok
  def log_account_lockout(identifier, lockout_type, metadata \\ %{}) do
    event_details = %{
      identifier: identifier,
      lockout_type: lockout_type,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        failed_attempts: metadata[:failed_attempts],
        lockout_duration_minutes: metadata[:lockout_duration_minutes]
      }
    }

    log_security_event("account_lockout", event_details)
  end

  @doc """
  Logs CSRF token validation failures for authentication forms.
  """
  @spec log_csrf_violation(integer() | nil, String.t(), map()) :: :ok
  def log_csrf_violation(user_id, action, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      action: action,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        referer: metadata[:referer],
        origin: metadata[:origin]
      }
    }

    log_security_event("csrf_violation", event_details)
  end

  @doc """
  Logs password change events.
  """
  @spec log_password_change(integer(), map()) :: :ok
  def log_password_change(user_id, metadata \\ %{}) do
    event_details = %{
      user_id: user_id,
      ip_address: metadata[:ip_address],
      user_agent: metadata[:user_agent],
      additional_data: %{
        sessions_invalidated: metadata[:sessions_invalidated] || false
      }
    }

    log_security_event("password_change", event_details)
  end

  @doc """
  Logs social authentication events.
  """
  @spec log_social_auth_event(String.t(), boolean(), map()) :: :ok
  def log_social_auth_event(provider, success, details \\ %{}) do
    event_type = if success, do: "social_auth_success", else: "social_auth_failure"

    event_details = %{
      provider: provider,
      success: success,
      email: details[:email],
      ip_address: details[:ip_address],
      user_agent: details[:user_agent],
      additional_data: %{
        oauth_state_valid: details[:oauth_state_valid],
        error_reason: details[:error_reason]
      }
    }

    log_security_event(event_type, event_details)
  end

  # Private helper functions for external monitoring

  defp send_to_monitoring_service(metadata) do
    Task.start(fn ->
      case Application.get_env(:tymeslot, :security_monitoring_webhook) do
        nil ->
          Logger.debug("Security monitoring webhook not configured")

        webhook_url ->
          send_webhook(webhook_url, metadata)
      end
    end)
  end

  defp send_webhook(webhook_url, metadata) do
    headers = [{"Content-Type", "application/json"}]
    body = Jason.encode!(metadata)

    case HTTPoison.post(webhook_url, body, headers) do
      {:ok, %HTTPoison.Response{status_code: status}} when status < 300 ->
        Logger.debug("Security event sent to monitoring service")

      {:ok, %HTTPoison.Response{status_code: status}} ->
        Logger.warning("Failed to send security event to monitoring service", status: status)

      {:error, reason} ->
        Logger.error("Error sending security event to monitoring service", error: reason)
    end
  rescue
    error ->
      Logger.error("Exception sending security event to monitoring service",
        error: inspect(error)
      )
  end
end
