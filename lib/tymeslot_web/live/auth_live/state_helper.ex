defmodule TymeslotWeb.AuthLive.StateHelper do
  @moduledoc """
  Helper module for managing authentication state transitions and path mappings.
  Extracted from AuthLive to separate concerns and improve maintainability.
  """

  alias Tymeslot.Auth.PasswordReset
  import Phoenix.Component, only: [assign: 3]
  require Logger

  # Available authentication states
  @auth_states ~w(
    login
    signup
    verify_email
    reset_password
    reset_password_form
    reset_password_sent
    complete_registration
    password_reset_success
    invalid_token
  )a

  @doc """
  Determine authentication state from URI and params.
  """
  @spec determine_auth_state(Phoenix.LiveView.Socket.t(), map(), String.t()) ::
          Phoenix.LiveView.Socket.t()
  def determine_auth_state(socket, params, uri) do
    state = get_auth_state_from_uri(uri, params)
    assign(socket, :current_state, state)
  end

  @doc """
  Get the path for a given authentication state.
  """
  @spec get_path_for_state(atom()) :: String.t()
  def get_path_for_state(state) do
    state_paths = %{
      login: "/auth/login",
      signup: "/auth/signup",
      verify_email: "/auth/verify-email",
      reset_password: "/auth/reset-password",
      reset_password_sent: "/auth/reset-password-sent",
      complete_registration: "/auth/complete-registration",
      password_reset_success: "/auth/password-reset-success"
    }

    Map.get(state_paths, state, "/auth/login")
  end

  @doc """
  Handle state-specific parameters and validation.
  """
  @spec handle_auth_params(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def handle_auth_params(socket, params) do
    case socket.assigns.current_state do
      :reset_password_form ->
        socket
        |> assign(:reset_token, params["token"])
        |> validate_reset_token(params["token"])

      :complete_registration ->
        has_oauth_error = params["error"] != nil

        socket
        |> assign(:temp_user, %{
          provider: params["oauth_provider"],
          email: params["oauth_email"],
          name: params["oauth_name"],
          verified_email: params["oauth_verified"] == "true",
          github_user_id: params["oauth_github_id"],
          google_user_id: params["oauth_google_id"]
        })
        |> assign(:email_required, params["oauth_email_from_provider"] != "true")
        |> assign(:has_oauth_error, has_oauth_error)

      _ ->
        socket
    end
  end

  @doc """
  Validate if a navigation to the given state is allowed.
  """
  @spec valid_state?(String.t()) :: boolean()
  def valid_state?(state) when is_binary(state) do
    String.to_existing_atom(state) in @auth_states
  rescue
    ArgumentError -> false
  end

  @doc """
  Clear errors from socket assigns.
  """
  @spec clear_errors(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_errors(socket) do
    assign(socket, :errors, %{})
  end

  # Private Functions

  defp get_auth_state_from_uri(uri, params) do
    case get_auth_state_by_path(uri) do
      {:ok, state} -> state
      :not_found -> get_auth_state_with_params(uri, params)
    end
  end

  defp get_auth_state_by_path(uri) do
    result = Enum.find(auth_path_mappings(), fn {path, _state} -> uri_matches?(uri, path) end)

    case result do
      {_path, state} -> {:ok, state}
      nil -> :not_found
    end
  end

  defp get_auth_state_with_params(uri, params) do
    cond do
      reset_password_with_token?(uri, params) -> :reset_password_form
      uri_matches?(uri, "/auth/reset-password") -> :reset_password
      true -> :login
    end
  end

  defp auth_path_mappings do
    [
      {"/auth/login", :login},
      {"/auth/signup", :signup},
      {"/auth/verify-email", :verify_email},
      {"/auth/reset-password-sent", :reset_password_sent},
      {"/auth/complete-registration", :complete_registration},
      {"/auth/password-reset-success", :password_reset_success}
    ]
  end

  defp uri_matches?(uri, path), do: String.contains?(uri, path)

  defp reset_password_with_token?(uri, params) do
    uri_matches?(uri, "/auth/reset-password") and Map.has_key?(params, "token")
  end

  defp validate_reset_token(socket, token) do
    sanitized_token =
      token
      |> to_string()
      |> String.trim()

    case PasswordReset.verify_token(sanitized_token) do
      {:ok, _reset, _message} ->
        socket

      {:error, reason, message} ->
        Logger.error("Invalid reset token: #{inspect(reason)}")

        socket
        |> assign(:current_state, :invalid_token)
        |> assign(:errors, %{general: message})
    end
  end
end
