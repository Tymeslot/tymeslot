defmodule Tymeslot.Auth.AuthActions do
  @moduledoc """
  Handles authentication-related actions for auth UI components.
  Acts as a bridge between UI components and the Auth context.
  Extracts business logic from LiveView components.
  """

  import Phoenix.Component, only: [assign: 3]

  alias Tymeslot.Auth.{PasswordReset, Registration, Validation}
  alias Tymeslot.Infrastructure.Config
  alias TymeslotWeb.Helpers.ClientIP

  require Logger

  @type signup_params :: Tymeslot.Auth.Validation.signup_params()

  @registration_disabled_message "Registration is currently disabled."
  @password_auth_disabled_message "Password authentication is currently disabled."

  @doc """
  Returns the user-facing message for when registration is disabled.
  """
  @spec registration_disabled_message() :: String.t()
  def registration_disabled_message, do: @registration_disabled_message

  @doc """
  Returns the user-facing message for when password authentication is disabled.
  """
  @spec password_auth_disabled_message() :: String.t()
  def password_auth_disabled_message, do: @password_auth_disabled_message

  # Registration Actions

  @doc """
  Handles user registration with email verification.
  """
  @spec register_user(signup_params(), Phoenix.LiveView.Socket.t()) ::
          {:ok, atom(), String.t()} | {:error, String.t()} | {:error, :field_errors, map()}
  def register_user(user_params, socket) do
    cond do
      not Config.password_auth_enabled?() -> {:error, @password_auth_disabled_message}
      not Config.registration_enabled?() -> {:error, @registration_disabled_message}
      true -> do_register_user(user_params, socket)
    end
  end

  defp do_register_user(user_params, socket) do
    converted_params = convert_terms_accepted(user_params)

    metadata = %{
      ip: ClientIP.get(socket),
      user_agent: ClientIP.get_user_agent(socket),
      source: "signup",
      terms_accepted: Map.get(converted_params, "terms_accepted")
    }

    case Registration.register_user(
           converted_params,
           socket,
           calling_app: :auth,
           metadata: metadata
         ) do
      {:ok, _user, message} ->
        {:ok, :verify_email, message}

      {:error, :input, errors} when is_map(errors) ->
        {:error, :field_errors, errors}

      {:error, _reason, message} ->
        {:error, message}
    end
  end

  # Password Reset Actions

  @doc """
  Initiates password reset flow for the given email.
  """
  @spec request_password_reset(String.t(), term()) ::
          {:ok, atom(), String.t()} | {:error, String.t()}
  def request_password_reset(email, socket) do
    if Config.password_auth_enabled?() do
      do_request_password_reset(email, socket)
    else
      {:error, @password_auth_disabled_message}
    end
  end

  defp do_request_password_reset(email, socket) do
    ip = ClientIP.get(socket)

    case PasswordReset.initiate_reset(email, socket_or_conn: socket, ip: ip) do
      {:ok, :reset_initiated, message} ->
        {:ok, :reset_password_sent, message}

      {:error, :invalid_input, message} ->
        {:error, message}

      {:error, reason, _message} ->
        {:error, normalize_auth_error(reason)}
    end
  end

  @doc """
  Completes password reset with new password.
  """
  @spec reset_password(String.t(), String.t(), String.t(), term()) ::
          {:ok, atom(), String.t()} | {:error, String.t()}
  def reset_password(token, password, password_confirmation, _socket) do
    if Config.password_auth_enabled?() do
      do_reset_password(token, password, password_confirmation)
    else
      {:error, @password_auth_disabled_message}
    end
  end

  defp do_reset_password(token, password, password_confirmation) do
    case PasswordReset.reset_password(token, password, password_confirmation) do
      {:ok, _user, _message} ->
        {:ok, :password_reset_success,
         "Your password has been reset successfully. Please log in with your new password."}

      {:error, reason, _message} ->
        {:error, normalize_auth_error(reason)}
    end
  end

  # Validation Actions

  @doc """
  Validates signup form input.
  """
  @spec validate_signup_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_signup_input(params) do
    Validation.validate_signup_input(params)
  end

  @doc """
  Validates login form input.
  """
  @spec validate_login_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_login_input(params) do
    Validation.validate_login_input(params)
  end

  @doc """
  Validates password reset form input.
  """
  @spec validate_password_reset_input(map()) :: {:ok, map()} | {:error, map()}
  def validate_password_reset_input(%{"email" => _email} = params) do
    Validation.validate_password_reset_input(params)
  end

  def validate_password_reset_input(
        %{"password" => _password, "password_confirmation" => _confirmation} = params
      ) do
    Validation.validate_new_password_input(params)
  end

  def validate_password_reset_input(_params), do: {:error, %{base: ["Invalid input format"]}}

  # State Management

  @doc """
  Updates socket with loading state.
  """
  @spec set_loading(Phoenix.LiveView.Socket.t(), boolean()) :: Phoenix.LiveView.Socket.t()
  def set_loading(socket, loading) do
    assign(socket, :loading, loading)
  end

  @doc """
  Updates socket with error state.
  """
  @spec set_errors(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def set_errors(socket, errors) do
    socket
    |> assign(:errors, errors)
    |> assign(:loading, false)
  end

  @doc """
  Updates socket with form data.
  """
  @spec set_form_data(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def set_form_data(socket, form_data) do
    assign(socket, :form_data, form_data)
  end

  @doc """
  Transitions to a new authentication state.
  """
  @spec transition_state(term(), atom(), atom()) :: term()
  def transition_state(socket, new_state, previous_state) do
    socket
    |> assign(:current_state, new_state)
    |> assign(:previous_state, previous_state)
    |> assign(:loading, false)
  end

  @doc """
  Converts terms_accepted string to boolean.
  """
  @spec convert_terms_accepted(map()) :: map()
  def convert_terms_accepted(user_params) do
    Map.update(user_params, "terms_accepted", false, fn
      "true" -> true
      "on" -> true
      true -> true
      _other -> false
    end)
  end

  # Private Functions

  defp normalize_auth_error(reason) do
    case reason do
      :rate_limited -> "Too many attempts. Please try again later"
      :server_error -> "A server error occurred. Please try again"
      :invalid_input -> "Invalid input provided"
      :invalid_password -> "Invalid password"
      :invalid_token -> get_token_error_message(:invalid_token)
      :token_expired -> get_token_error_message(:token_expired)
    end
  end

  defp get_token_error_message(:invalid_token), do: "Invalid or expired token"

  defp get_token_error_message(:token_expired),
    do: "This link has expired. Please request a new one"
end
