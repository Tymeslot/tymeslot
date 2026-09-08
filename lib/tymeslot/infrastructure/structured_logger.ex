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
    base_metadata = [
      domain: :authentication,
      event: event,
      user_id: user_id,
      correlation_id: CorrelationId.get_from_process()
    ]

    merged_metadata = base_metadata ++ Map.to_list(metadata)

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

      _other ->
        Logger.info("Authentication event", merged_metadata)
    end
  end
end
