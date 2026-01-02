defmodule Tymeslot.Infrastructure.StructuredLogger do
  @moduledoc """
  Provides structured logging utilities with consistent formatting and correlation ID support.

  This module ensures all logs follow a consistent structure, making them easier to
  parse, search, and analyze in log aggregation systems.
  """

  require Logger
  alias Tymeslot.Infrastructure.CorrelationId

  @doc """
  Logs an authentication event with structured data.

  ## Parameters
  - event: The authentication event type (e.g., :login_attempt, :logout, :password_reset)
  - user_id: The user ID (can be nil for failed attempts)
  - metadata: Additional metadata map

  ## Examples

      log_auth_event(:login_success, user.id, %{
        email: user.email,
        ip_address: "192.168.1.1",
        user_agent: "Mozilla/5.0..."
      })
  """
  @spec log_auth_event(atom(), String.t() | integer() | nil, map()) :: :ok
  def log_auth_event(event, user_id, metadata \\ %{}) do
    base_metadata = %{
      domain: :authentication,
      event: event,
      user_id: user_id,
      correlation_id: CorrelationId.get_from_process()
    }

    merged_metadata = Map.merge(base_metadata, metadata)

    case event do
      :login_success ->
        Logger.info("User logged in successfully", merged_metadata)

      :login_failure ->
        Logger.warning("Login attempt failed", merged_metadata)

      :logout ->
        Logger.info("User logged out", merged_metadata)

      :password_reset_requested ->
        Logger.info("Password reset requested", merged_metadata)

      :password_reset_completed ->
        Logger.info("Password reset completed", merged_metadata)

      :account_locked ->
        Logger.error("Account locked due to too many failed attempts", merged_metadata)

      _ ->
        Logger.info("Authentication event: #{event}", merged_metadata)
    end
  end

  @doc """
  Logs an API call with structured data.

  ## Examples

      log_api_call(:oauth_github, :request, %{
        method: "POST",
        url: "https://api.github.com/...",
        headers: %{...}
      })
  """
  @spec log_api_call(atom(), atom(), map()) :: :ok
  def log_api_call(service, phase, metadata \\ %{}) do
    merged_metadata = build_api_metadata(service, phase, metadata)
    log_by_phase(phase, merged_metadata)
  end

  defp build_api_metadata(service, phase, metadata) do
    base_metadata = %{
      domain: :external_api,
      service: service,
      phase: phase,
      correlation_id: CorrelationId.get_from_process()
    }

    Map.merge(base_metadata, metadata)
  end

  defp log_by_phase(:request, metadata) do
    Logger.info("API request initiated", metadata)
  end

  defp log_by_phase(:response, metadata) do
    log_response_by_status(metadata)
  end

  defp log_by_phase(:error, metadata) do
    Logger.error("API request failed", metadata)
  end

  defp log_by_phase(phase, metadata) do
    Logger.info("API event: #{phase}", metadata)
  end

  defp log_response_by_status(metadata) do
    status = metadata[:status_code] || metadata[:status]

    cond do
      is_nil(status) ->
        Logger.info("API response received", metadata)

      status >= 200 and status < 300 ->
        Logger.info("API request successful", metadata)

      status >= 400 and status < 500 ->
        Logger.warning("API client error", metadata)

      status >= 500 ->
        Logger.error("API server error", metadata)

      true ->
        Logger.info("API response received", metadata)
    end
  end

  @doc """
  Logs database operations with structured data.

  ## Examples

      log_database_operation(:insert, :users, %{
        user_id: user.id,
        duration_ms: 45
      })
  """
  @spec log_database_operation(atom(), atom(), map()) :: :ok
  def log_database_operation(operation, table, metadata \\ %{}) do
    base_metadata = %{
      domain: :database,
      operation: operation,
      table: table,
      correlation_id: CorrelationId.get_from_process()
    }

    merged_metadata = Map.merge(base_metadata, metadata)

    duration = metadata[:duration_ms]

    cond do
      duration && duration > 1000 ->
        Logger.warning("Slow database operation", merged_metadata)

      metadata[:error] ->
        Logger.error("Database operation failed", merged_metadata)

      true ->
        Logger.debug("Database operation completed", merged_metadata)
    end
  end

  @doc """
  Logs business logic events with structured data.

  ## Examples

      log_business_event(:appointment_booked, %{
        appointment_id: appointment.id,
        organizer_id: organizer.id,
        attendee_email: attendee_email,
        duration: 30
      })
  """
  @spec log_business_event(atom(), map()) :: :ok
  def log_business_event(event, metadata \\ %{}) do
    base_metadata = %{
      domain: :business,
      event: event,
      correlation_id: CorrelationId.get_from_process()
    }

    merged_metadata = Map.merge(base_metadata, metadata)

    Logger.info("Business event: #{event}", merged_metadata)
  end

  @doc """
  Logs errors with consistent structure and correlation ID.

  ## Examples

      log_error(:email_delivery_failed, "Connection timeout", %{
        email_to: "user@example.com",
        attempt: 3,
        max_attempts: 3
      })
  """
  @spec log_error(atom(), String.t(), map()) :: :ok
  def log_error(error_type, message, metadata \\ %{}) do
    base_metadata = %{
      domain: :error,
      error_type: error_type,
      correlation_id: CorrelationId.get_from_process()
    }

    merged_metadata = Map.merge(base_metadata, metadata)

    Logger.error(message, merged_metadata)
  end

  @doc """
  Creates a child logger with additional context.

  Useful for adding context that should be included in all subsequent logs
  within a specific module or function.

  ## Examples

      logger = StructuredLogger.with_context(%{
        user_id: user.id,
        request_id: request_id
      })
      
      logger.(:info, "Processing user request", %{action: "update_profile"})
  """
  @spec with_context(map()) :: (atom(), String.t(), map() -> :ok)
  def with_context(context) do
    fn level, message, metadata ->
      merged_metadata = Map.merge(context, metadata)

      case level do
        :debug -> Logger.debug(message, merged_metadata)
        :info -> Logger.info(message, merged_metadata)
        :warning -> Logger.warning(message, merged_metadata)
        :error -> Logger.error(message, merged_metadata)
      end
    end
  end

  @doc """
  Logs the execution time of a function with structured data.

  ## Examples

      with_timing(:send_email, %{email_to: "user@example.com"}, fn ->
        EmailService.send_welcome_email(user)
      end)
  """
  @spec with_timing(atom(), map(), function()) :: any()
  def with_timing(operation, metadata \\ %{}, fun) do
    start_time = System.monotonic_time(:millisecond)

    try do
      result = fun.()

      duration = System.monotonic_time(:millisecond) - start_time

      base_metadata = %{
        operation: operation,
        duration_ms: duration,
        status: :success,
        correlation_id: CorrelationId.get_from_process()
      }

      Logger.info("Operation completed", Map.merge(base_metadata, metadata))

      result
    rescue
      error ->
        duration = System.monotonic_time(:millisecond) - start_time

        base_metadata = %{
          operation: operation,
          duration_ms: duration,
          status: :error,
          error: Exception.format(:error, error),
          correlation_id: CorrelationId.get_from_process()
        }

        Logger.error("Operation failed", Map.merge(base_metadata, metadata))

        reraise error, __STACKTRACE__
    end
  end
end
