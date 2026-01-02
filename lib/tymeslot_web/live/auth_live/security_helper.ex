defmodule TymeslotWeb.AuthLive.SecurityHelper do
  @moduledoc """
  Security utilities for AuthLive including CSRF validation and client metadata extraction.
  Extracted from AuthLive to separate security concerns and improve maintainability.
  """

  alias Phoenix.Component
  alias Plug.Crypto
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP
  require Logger

  @doc """
  Validate CSRF token from form submission.

  Note: Phoenix's protect_from_forgery plug already provides framework-level CSRF protection.
  This additional validation serves a different purpose:
  1. Enhanced security monitoring and logging for authentication forms
  2. Detailed attack attribution (IP address, user agent, timing)
  3. Integration with external security monitoring systems
  4. Forensic data collection for security incident investigation

  This is applied selectively to high-risk authentication events rather than all forms
  to maintain performance while providing actionable security intelligence.
  """
  @spec validate_csrf_token(Phoenix.LiveView.Socket.t(), map()) :: :ok | {:error, :invalid_csrf}
  def validate_csrf_token(socket, params) do
    provided_token = params["_csrf_token"]
    expected_token = socket.assigns.csrf_token

    if is_binary(provided_token) and is_binary(expected_token) and
         Crypto.secure_compare(provided_token, expected_token) do
      :ok
    else
      # Log CSRF violation
      SecurityLogger.log_csrf_violation(
        get_current_user_id(socket),
        "form_submission",
        %{
          ip_address: ClientIP.get(socket),
          user_agent: ClientIP.get_user_agent(socket)
        }
      )

      {:error, :invalid_csrf}
    end
  end

  @doc """
  Extract client IP address from socket for rate limiting and security logging.
  Delegates to the standardized ClientIP module for consistent IP extraction.
  """
  @spec extract_remote_ip(Phoenix.LiveView.Socket.t()) :: String.t()
  def extract_remote_ip(socket) do
    ClientIP.get(socket)
  end

  @doc """
  Extract client metadata for security logging and rate limiting.
  """
  @spec extract_client_metadata(Phoenix.LiveView.Socket.t()) :: map()
  def extract_client_metadata(socket) do
    %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket)
    }
  end

  @doc """
  Get current user ID from socket assigns for security logging.
  """
  @spec get_current_user_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  def get_current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _ -> nil
    end
  end

  @doc """
  Set loading state on socket.
  """
  @spec set_loading(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def set_loading(socket, loading \\ true) do
    Component.assign(socket, :loading, loading)
  end

  @doc """
  Set error messages on socket.
  """
  @spec set_errors(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def set_errors(socket, errors) do
    socket
    |> Component.assign(:loading, false)
    |> Component.assign(:errors, errors)
  end
end
