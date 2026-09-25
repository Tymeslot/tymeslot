defmodule TymeslotWeb.AuthLive.SecurityHelper do
  @moduledoc """
  Security utilities for AuthLive: CSRF validation and its failure message.
  Extracted from AuthLive to separate security concerns and improve maintainability.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.Component
  alias Plug.Crypto
  alias Tymeslot.Security.SecurityLogger
  alias TymeslotWeb.Helpers.ClientIP

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
        %{ip_address: ClientIP.get(socket), user_agent: ClientIP.get_user_agent(socket)}
      )

      {:error, :invalid_csrf}
    end
  end

  @doc """
  The message a form shows when `validate_csrf_token/2` rejects it.
  """
  @spec csrf_message() :: String.t()
  def csrf_message,
    do: dgettext("auth", "Security validation failed. Please refresh the page.")

  @spec get_current_user_id(Phoenix.LiveView.Socket.t()) :: integer() | nil
  defp get_current_user_id(socket) do
    case socket.assigns[:current_user] do
      %{id: id} -> id
      _other -> nil
    end
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
