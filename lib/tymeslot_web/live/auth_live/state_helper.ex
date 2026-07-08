defmodule TymeslotWeb.AuthLive.StateHelper do
  @moduledoc """
  Helper module for managing authentication state transitions and path mappings.
  Extracted from AuthLive to separate concerns and improve maintainability.
  """

  use Gettext, backend: TymeslotWeb.Gettext

  alias Phoenix.LiveView
  alias Tymeslot.Auth.{AuthActions, PasswordReset}
  alias Tymeslot.Infrastructure.Config
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
  @password_reset_states [:reset_password, :reset_password_form, :reset_password_sent]

  def determine_auth_state(socket, params, uri) do
    state = get_auth_state_from_uri(uri, params)
    socket = assign(socket, :current_state, state)

    cond do
      state == :signup and not Config.password_auth_enabled?() ->
        redirect_to_login(socket, AuthActions.password_auth_disabled_message())

      state in [:signup, :complete_registration] and not Config.registration_enabled?() ->
        redirect_to_login(socket, AuthActions.registration_disabled_message())

      state in @password_reset_states and not Config.password_auth_enabled?() ->
        redirect_to_login(socket, AuthActions.password_auth_disabled_message())

      true ->
        socket
    end
  end

  defp redirect_to_login(socket, message) do
    socket
    |> assign(:current_state, :login)
    |> LiveView.put_flash(:info, message)
    |> LiveView.push_patch(to: "/auth/login")
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
        case socket.assigns[:pending_oauth_registration] do
          nil ->
            socket
            |> LiveView.put_flash(
              :error,
              dgettext("auth", "No pending registration found. Please sign in again.")
            )
            |> LiveView.redirect(to: "/auth/login")

          reg_data ->
            has_oauth_error = params["error"] != nil

            socket
            |> assign(:temp_user, %{
              provider: reg_data[:provider],
              email: reg_data[:email],
              name: reg_data[:name],
              verified_email: reg_data[:is_verified] == true,
              github_user_id: reg_data[:github_user_id],
              google_user_id: reg_data[:google_user_id],
              provider_uid: reg_data[:provider_uid]
            })
            |> assign(:email_required, reg_data[:email_from_provider] != true)
            |> assign(:has_oauth_error, has_oauth_error)
        end

      _other_state ->
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

  defp uri_matches?(uri, path) do
    uri_path = URI.parse(uri).path || ""
    uri_path == path or String.starts_with?(uri_path, path <> "?")
  end

  defp reset_password_with_token?(uri, params) do
    uri_path = URI.parse(uri).path || ""
    String.starts_with?(uri_path, "/auth/reset-password/") and Map.has_key?(params, "token")
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
        Logger.error("Invalid reset token", reason: inspect(reason))

        socket
        |> assign(:current_state, :invalid_token)
        |> assign(:errors, %{general: message})
    end
  end
end
